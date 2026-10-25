# Testing — how zypherdb tests itself

A database is trusted with data that often exists nowhere else. The worst thing it can do is not
to crash, nor to refuse a query: it is to answer wrongly without saying so, or to store something
that reads back differently, months later, when nobody remembers how it got there. This page
explains how zypherdb looks for those failures: the problem, the one idea behind every technique,
and each technique in turn — what it is, where it comes from, what it buys, what it cannot see,
and what it has found.

The commands to run each one are in [contributing](contributing.md#build-and-test). This page is
about why they exist and what they prove.

## The problem: silent corruption

Most tests are **examples**: a query, the rows it must return. zypherdb has many (`tests/`), and every
example in this documentation runs too. They are necessary, and they have two blind spots.

- **They only test what someone thought of.** Each example is a case its author imagined. Bugs live
  in the cases nobody imagined: a property that is the integer `1` in one node and the float `1.0`
  in another, a label name with a zero byte, a commit that fails halfway, a relationship that
  starts and ends at the same node while a full-text index is being dropped.
- **They check the answer, not the state.** A graph database keeps the same facts several times:
  the node record says the node has the label `Person`, and the label index has a key that says
  the same. Every relationship is stored twice, once from each end. A query that reads only one
  copy can return the right rows while the other copy is already wrong; the next query, which reads
  the other copy, will not.

The openCypher **TCK** (Technology Compatibility Kit) fills a third gap: whether the answers follow
the language at all. It is thousands of scenarios written by the language's authors; zypherdb runs
them (`tests/tck/`) and a baseline file fails the build if one that passed stops passing. But the
TCK is still a set of examples, chosen to define the language, not to find storage bugs: its graphs
are tiny, it never crashes a process, and a disk never fails in it.

## The central idea: an oracle

To find a bug nobody imagined, a test must make inputs nobody wrote by hand — random ones. But a
random input has no expected answer written next to it. Something else must say what the right
answer is. That something is an **oracle**: a second, independent way to reach the same result.
When the two disagree, one of them is wrong, and the test has found a bug without anyone having
predicted it.

Every technique on this page is a choice of oracle:

| Technique | The input | The oracle it compares with |
|---|---|---|
| Example tests, documentation tests | Written by hand | The expected rows, written by hand |
| The TCK | The language's own scenarios | The expected rows, written by the language's authors |
| Integrity checker | Any database | The same database: its derived structures, rebuilt from its records |
| Storage fuzzer | Random operations | A model of the graph in memory |
| Query fuzzer | Random graphs and queries | The same query planned differently, prepared, or split in three |
| Snapshot tests | Plans and error messages | The text a person read and approved |
| Fault fuzzer | Storage that fails on purpose | A twin database whose storage never fails |
| Crash fuzzer | A writer killed with SIGKILL | A twin that ran the same statements without dying |
| Pair assertions | Every record that crosses the storage boundary | The layout the encoder promises |
| LMDB and libmdbx | The same seeds on both engines | The other engine |

The oracles are cheap on purpose. None is a second database written to agree with the first: that
would double the code to maintain, and two implementations written by the same people tend to share
their mistakes. Each oracle is either much simpler than the engine (a model made of hash maps), or
the engine itself reached by a different path (another plan, another engine, another run).

## Where the ideas come from

Most of these techniques are adapted from **TigerBeetle**, a financial database written in Zig
whose testing is unusually thorough and unusually well documented. One lesson of theirs shaped the
whole plan. When the Jepsen project tested TigerBeetle, it found a bug in queries that roughly twenty
fuzzers had missed. The fuzzers were fine; their **generators** made data that was too regular, so
the queries never met the case that failed. The fix was to put random objects in a model, run random
queries, and compare **exact** results with the model. zypherdb's storage fuzzer is built that way
from the start.

Each section below says what was taken as it is, what was adapted, and what was left out. The
query fuzzer's partitioning oracle comes from elsewhere: it is *ternary logic partitioning*, from
Rigger and Su's work on SQLancer (OOPSLA 2020).

## The integrity checker

**What it is.** `zypherdb.integrity.check` (`src/storage/integrity.zig`, with
`integrity_fulltext.zig` and `layout.zig`) reads the whole database, separates the **primary**
data (node and relationship records, relationship properties, schema definitions, id counters) from
the **derived** data (the label, property and edge-property indexes, both edge keys of every
relationship with the neighbour labels they keep, the counters, the full-text postings), rebuilds
every derived key from the primary data, and compares. It also checks that every uniqueness
constraint holds, that the id counters are above every id in use, that every record and value is
well formed, and that no key of an unknown kind is stored. [Storage](storage.md#checking-integrity)
describes it in detail.

**Where it comes from.** Database checkers are old (`fsck`, `PRAGMA integrity_check` in SQLite).
TigerBeetle's contribution was to use one **inside the tests**, after every step, so a corruption is
caught at the operation that caused it rather than when a user trips over it.

**What it guarantees.** After it passes, every derived structure agrees with the records: no index
entry points at a node that lost the label, no relationship is visible from one end only, no counter
is behind, no constraint is broken. That means every query, whatever access path its plan chooses,
reads the same facts. It is also the oracle that the fuzzers below reuse: one checker, written once,
gives every other test a way to say "and the database is still sound".

**What it does not guarantee.** That the records are the *right* records. If a bug writes the wrong
property value into the record, and derives the indexes from that wrong value, everything agrees and
the checker passes. Catching that needs an independent idea of what should be there: the storage
fuzzer's model. The checker is also a full scan, in O(database) time and memory; it is a diagnostic,
not something to run on every commit in production.

Users can run it (`Database.check()` in Python, `zypherdb_check` in C) on a database they suspect, after
a crash, or to attach to a bug report.

## The storage fuzzer, with seeds and swarm testing

**What it is.** `tests/fuzz/storage.zig` runs random operations through the `Graph` API — nodes,
labels, properties of every type, relationships (loops and parallel ones), deletions, full-text
indexes and uniqueness constraints, commits, aborts, closing and reopening — and applies each one to
a **model** (`tests/fuzz/model.zig`): the graph as plain maps in memory. The model also predicts which
operations must fail: a constraint broken, a node deleted while still connected, a value that cannot
be stored. After every commit and every abort, the fuzzer compares the whole database with the model
(`storage_compare.zig`) and runs the integrity checker.

The model is about 180 lines. It can be that small because it ignores everything the engine exists
for: keys, encodings, indexes, speed. It only knows what the graph contains. That is what makes it a
good oracle: it is too simple to share the engine's bugs.

**Seeds.** Every random choice comes from one generator, started from a **seed**. The same seed
makes the same run, operation by operation, so a failure is a command that repeats it
(`zig build fuzz -- storage --seed 42 --verbose`), not a story about something that happened once.
`zig build test` runs a few fixed seeds, so every build replays them; long runs start from a random
seed and try hundreds.

**Swarm testing.** A fuzzer that picks every operation with the same probability on every run tests
the average case over and over. Swarm testing (Groce et al., ISSTA 2012) gives each seed its own
mix instead: which operations run at all and how often, with transactions or without, how many
labels and properties there are, whether values come from every type or from a narrow few. A seed
with three property names and only small integers makes collisions — two nodes with the same value
under a unique constraint — that a seed with every type would almost never make. Some seeds even
copy one node's property onto another on purpose, to break constraints by construction.

**From TigerBeetle.** Taken as it is: the model, seeds with a reproduction command, swarm mixes,
and checking after every step. Adapted: TigerBeetle's fuzzers drive its own storage layer; ours
drives the graph layer on top of a real storage engine, because zypherdb does not do its own I/O.

**What it guarantees.** For the operations it generates, in the combinations its seeds reach, the
database contains exactly what the operations put there — no more, no less, no value changed in
transit — and every operation that must fail fails, without leaving a trace. Closing and reopening in
the middle of a run shows that this also holds for what was written to disk, not only for what is in
memory.

**What it does not guarantee.** Only what the generators produce is tested. An operation the fuzzer
does not have, or a value it never makes, is not covered, which is why it prints how often each
operation ran and how often it failed as predicted: a fuzzer that never breaks a constraint does not
test constraints. It also tests the `Graph` API, not the query language (that is the query fuzzer's
job), and one process with one writer.

**What it found.** A composite uniqueness constraint on `(a, b)` compared `b` by its raw stored bytes,
so a node with `b = 1` and another with `b = 1.0` were both accepted, although the language says
they are equal. Fixed in `06adb6a`: properties after the first are now compared by their index
encoding, as the first one already was.

## The query fuzzer

**What it is.** `tests/fuzz/query.zig` builds a small random graph and generates read queries
(`query_generator.zig`): one or two `MATCH` or `OPTIONAL MATCH` patterns, a `WHERE` made of
comparisons, `IS NULL`, `IN`, `STARTS WITH`, label tests and `EXISTS`, and a `RETURN` that projects
or aggregates, ordered only when the order is total. A query has no hand-written answer, so the fuzzer
runs it several ways and requires the same rows from all of them:

- **Optimizations off.** The planner chooses which node a pattern starts from, pulls equalities and
  ranges out of the `WHERE` as seeks on the pattern's nodes, looks them up in the property indexes,
  and keeps only the first rows for `ORDER BY ... LIMIT`. `zypherdb.PlanOptions` switches each choice
  off; the fuzzer tries random combinations. An optimization must change the speed, never
  the rows.
- **Prepared.** The same query as a prepared statement, run twice (the second run reuses the plan),
  and again after the graph changed under it.
- **Ternary logic partitioning.** For a random predicate `p`, the rows of `Q` must be exactly the
  rows of `Q WHERE p`, plus those of `Q WHERE NOT p`, plus those of `Q WHERE p IS NULL`. In Cypher, as
  in SQL, a predicate is true, false or null, so the three parts cover every row once. A bug in how a
  predicate is evaluated, pushed down, or combined with null rarely breaks all three queries the same
  way.
- **The other engine.** Each seed prints a digest of its results; the LMDB and libmdbx builds must
  print the same digests for the same seeds.

To make runs repeatable, the executor takes a fixed clock and a seeded random generator instead of the
real ones (`Executor.fixed_time`, `Executor.random`).

**From TigerBeetle, and from SQLancer.** The seed and swarm machinery are the storage fuzzer's. The
oracles are not TigerBeetle's: it has no query planner. Comparing a query with itself under different
plans is the idea behind SQLancer's oracles; ternary logic partitioning is one of them, used as
published.

**What it guarantees.** For the queries it generates, the planner's choices, the plan cache and the
storage engine do not change the answer. That covers the code most likely to break when someone makes
the engine faster: a new index path or a new pushdown that drops a row is caught by comparing with the
plan that does not use it.

**What it does not guarantee.** That the answer is *right*. If every plan computes the same wrong
result — a function with the wrong semantics, say — all oracles agree. That is what the TCK is for.
The generated queries do not write, and use no `WITH`, `UNWIND`, shortest paths, or functions beyond
a few (`id`, `labels`, `type`, `count`, `collect`); about two thirds of them return no rows on their
small graph, so the rows that do come back carry most of the testing.

**What it found.** Nothing, in 300 seeds of 200 queries each. A fuzzer that finds nothing has either
nothing to find or a blind spot, so it was checked as described in
[measuring the tests](#measuring-the-tests): six deliberate bugs planted in the planner, six found.

## Snapshot tests

**What it is.** Some output is read by people as a whole: an `EXPLAIN` plan, an error message. Writing
such text by hand in a test is tedious, and checking only a fragment of it lets the rest drift. A
snapshot test (`tests/snapshot.zig`) keeps the expected text in the test, right after
`snap(@src(), ...)`, and compares it with what the code produces. When the output changes on purpose,
`SNAP_UPDATE=1 zig build test` rewrites the literals in the source files, and the change is reviewed
in `git diff` like any other code. `tests/end_to_end/explain_test.zig` checks whole plans, estimates
included; `tests/error_messages_test.zig` checks the code and message of 45 failing queries, through
the C ABI that users see.

**From TigerBeetle.** The idea and the shape are TigerBeetle's `snaptest.zig`. zypherdb has its own
implementation of about 180 lines (no dependencies).

**What it guarantees.** No change to a plan or a message goes unnoticed: each one appears in a diff and
someone decides it is right. It turns "the error message is helpful" from a hope into something
reviewed.

**What it does not guarantee.** That the approved text was right in the first place. A snapshot only
records a decision; its value is that it makes people look.

**What it found.** Reading the first snapshots turned up five issues in text nobody had looked at
whole: a message claiming that only integers, strings and booleans can be stored (long untrue);
`WHERE RETURN n` reported confusingly instead of "expected an expression, found RETURN";
temporal constructors that did not name the function or give a valid example; `SET n = <a literal
that is not a map>` refused only at run time; and an `EXPLAIN` estimate for an expansion from an
already bound node that ignored the label it was bound with.

## The fault fuzzer

**What it is.** Real storage fails: the disk is full, a file cannot grow, the map is too small. Every
such error must reach the caller as an error — without a crash, a memory leak, a transaction left open,
or half of a statement written. `src/storage/engine/faulty.zig` is a storage engine that wraps the real
one and makes its N-th operation fail. A failure behaves as in LMDB: it breaks the write transaction,
so everything after it fails too, and nothing is committed.

`tests/fuzz/faults.zig` runs a random workload (writes, `MERGE`, deletions, constraints, full-text
indexes and searches, the query fuzzer's reads; one-shot or prepared) on two databases: one that fails
and a twin that never does. Each statement runs on the failing database again and again, failing first
at its first storage operation, then at a later one, until a run reaches no failure at all. After each
failure, the statement must have failed with a storage error, the database must be byte for byte what it
was before, the integrity checker must pass, and no transaction may be open. The run that reaches no
failure must match the twin exactly. At the end, no memory may have leaked.

A seed also chooses (swarm again) between transient failures and persistent ones — a dead disk — and,
in some seeds, a failure that leaves the transaction usable. No real engine does that, and that is the
point: if code above the engine ignores a write error, a real engine would hide it by failing the
commit anyway, while the usable transaction commits without the write and the twin comparison shows
the difference.

The failing engine is built only into a second copy of the module that the tests and fuzzers use
(build option `fault_injection`); the library never contains it, so it costs users nothing.

**From TigerBeetle.** Adapted. TigerBeetle simulates its disk and injects faults below its own I/O,
including corrupted and misdirected reads and writes. zypherdb does not do its own I/O — LMDB and
libmdbx do — so faults are injected at the engine's interface instead: an operation fails, or the
process dies. Faults inside the engine are the engine's own responsibility and its own tests.

**What it guarantees.** For every statement in the workload and every point at which storage can fail,
the failure is atomic: the caller gets an error, and the database, the plan cache and memory are left
as if the statement had never run. That is the code path an ordinary test never takes, because a
healthy disk never fails on cue.

**What it does not guarantee.** Allocation failures (out of memory) are not injected yet. Explicit
transactions of several statements, and the C ABI's own transaction handling, are not in the workload.
And it tests the contract — "an engine error surfaces cleanly" — not whether LMDB itself survives a
failing disk.

**What it found.** No bug, in 300 seeds on each engine (about 200,000 faults each). Nine of ten planted
bugs were found; the survivor is a replan that keeps its old plan after a failure, which only an
allocation failure can reach. One behaviour was accepted rather than fixed: when storage cannot return
a count, the planner reads it as unknown and plans without it (`planning/statistics.zig`), so the
statement succeeds with the same rows instead of failing.

## The crash fuzzer

**What it is.** A process can die at any instruction: killed by the system, by a user, by a power
button. When it does, the database must open again, pass the integrity checker, and hold every
transaction the process was told had committed. `tests/fuzz/crash.zig` starts a writer — the fuzz
program itself, run as `crash-writer` — that runs a seed's write workload one statement per
transaction and reports each one done. The writer dies a few times per seed, killed with SIGKILL,
which no program can catch or clean up after:

- at a **crash point** the fuzzer chose: the failing engine has one before every storage operation and
  one after every commit, and the writer kills itself when it reaches the chosen one. These crashes
  are reproducible from the seed, and half are placed near a commit, where atomicity is most at risk;
- or killed by the fuzzer after a random delay, which can land inside the engine — in the middle of a
  commit's writes or its sync — but depends on timing.

After each crash the fuzzer reopens the database, runs the checker, and compares it with a twin that ran
the same statements without dying. The database must equal the twin after the last statement reported,
or after the next one (its commit may have finished an instant before the kill). The writer then
restarts from there; the last writer runs to the end and must reach the twin.

**From TigerBeetle.** Adapted. TigerBeetle crashes and restarts replicas inside its deterministic
simulator, where a crash also loses whatever its simulated disk had not synced. zypherdb's crashes are
real processes killed by the operating system, which is closer to what users see but keeps what the
operating system already holds.

**What it guarantees.** Against a process crash at any of the points tested, a transaction is all or
nothing, a reported commit is never lost, and the database is never left in a state that fails the
checker or refuses to open — on both engines, under every durability setting (a seed picks one).

**What it does not guarantee.** Power failures. When the machine itself stops, what was not yet synced
to the disk is lost, and the durability settings start to matter. Testing that needs a simulated disk
that can drop unsynced writes; zypherdb has none yet. Crashes while the database is being opened, and
several processes writing in turn, are not tested either.

**What it found.** No bug, in 200 seeds on each engine (more than 800 crashes each). Two planted bugs —
a counter written after the commit, and writes made outside the transaction — were both found.

## Pair assertions

**What it is.** An assertion checks, while the program runs, something that must be true. A **pair**
assertion checks the same property at both ends of a boundary: the writer checks the bytes it is about
to store, and the reader checks the bytes it is about to trust. `src/storage/layout.zig` states what a
well-formed record, value, edge key and name are — counts that match, lengths that are exact, list
elements of one kind, map keys in strictly ascending order, times of day within a day, nanoseconds
below a second — and the storage boundary asserts it on both sides (`key_value_store.zig`,
`value_encoding.zig`, `key_encoding.zig`, `graph.zig`). The integrity checker uses the same functions
to report problems instead of stopping.

**From TigerBeetle.** The idea as it is. One difference: TigerBeetle keeps its assertions in production
builds. zypherdb runs them in Debug and ReleaseSafe builds and compiles them out of ReleaseFast, so the
fastest build pays nothing for them; which build users get is a packaging decision.

**What it guarantees.** In checked builds, a bug on either side of the boundary stops the program at the
boundary, with the bytes still at hand, instead of spreading: a bad record is not written, and a bad
record read is not used to answer a query or to derive another write. Every test and fuzzer above runs
with them on, so all of them check the layout too, on every read and write they make.

**What it does not guarantee.** Only the layout is checked, not the meaning: a well-formed record with
the wrong value passes. And in ReleaseFast builds, nothing is checked.

**What it found.** While writing the assertions for names, it turned out that names the storage cannot
hold were accepted. A relationship type containing a zero byte corrupted the edge keys, since the zero
byte separates the parts of a key: the relationship's properties then read as "deleted entity", and the
checker reported the damage. `MATCH (n:A)` also returned a node labelled `A\0B`, and `SET n += $map` with
an empty key stored a property with an empty name. Such names are now refused with an error, in the
language, the C ABI and Python; string *values* with zero bytes are fine.

## Measuring the tests

A test suite that passes says nothing about the tests: perhaps they are good, perhaps they cannot fail.
Two measurements keep zypherdb's honest.

- **Counts.** Every fuzzer prints what it did: how many times each operation ran, how many failed as the
  model predicted, how many faults were injected, how many crashes happened, how often each oracle
  compared something. A fuzzer whose counts show zero for something is not testing it.
- **Mutations.** To check that a fuzzer can find a bug, plant one: change a line of the engine on
  purpose — drop a key, swap a comparison, write a counter one step late — and run the fuzzer. If it
  stays green, it has a blind spot, and it is improved until it catches the mutation. Each fuzzer was
  measured this way when it was written: nine of nine mutations in the storage layer, six of six in the
  planner, nine of ten for faults, two of two for crashes, three of three for the pair assertions.

## Not adopted from TigerBeetle, and why

- **The VOPR**, TigerBeetle's deterministic simulator of a whole cluster: network, clocks, disks and
  crashes, all simulated in one process and driven by a seed. zypherdb is one process with no network,
  and its engine does the I/O. It becomes the right tool with replication (below).
- **Static allocation.** TigerBeetle allocates all its memory at startup and never again, which removes
  out-of-memory failures and leaks by construction. A query engine cannot know in advance how much
  memory a query needs; zypherdb allocates per query, and frees per query through arenas.
- **A hard limit of 70 lines per function.** zypherdb keeps functions under about 60 lines as a guide,
  with exceptions where one large `switch` reads better in one place.

## What replication will add

zypherdb is a single machine today. When replication is built, the hard failures move into the network:
messages lost, delayed, duplicated or reordered, replicas that crash and come back, clocks that
disagree, a change log that arrives torn. The plan for then:

- a **deterministic simulation** in the style of the VOPR: a primary and replicas in one process, with
  the network, the clock and faults on the change log simulated and driven by a seed, and a checker
  that compares each replica with the primary at every position of the log;
- a **consistency model** written down first — what a reader on a replica may see — and then tests of it
  in the style of Jepsen;
- **versioned log and storage formats**, tested between replicas of different versions.

Some decisions taken now keep that possible: every write goes through one place where a change log can
be captured; the log will record effects (the ids allocated, the keys written), never statements, so
`rand()` and `datetime()` are not evaluated again on a replica; the clock and randomness are already
injectable. The integrity checker and the failing engine will be reused.

## What is not tested, in one place

- Power failures and unsynced data (they need a simulated disk).
- Several processes writing to one database at once, and crashes while a database opens.
- Allocation failures.
- ReleaseFast builds run without pair assertions.
- Queries that write, `WITH`, `UNWIND`, shortest paths and most functions, in the query fuzzer (the
  example tests and the TCK cover them, without random inputs).
- Anything the generators cannot produce. This is the limit of every fuzzer, and the reason the counts
  and the mutations above exist.

## Why this way — and the alternatives

- **A second graph database as the oracle.** Running the same queries on, say, Neo4j and comparing is
  differential testing, and it finds real bugs. It was not chosen: it needs a server and a JVM in the
  tests, the two systems disagree on purpose in places (zypherdb's map properties, for instance), and it
  says nothing about storage, crashes or faults. The TCK gives most of its benefit for the language.
- **Coverage-guided fuzzing** (AFL, libFuzzer): mutate inputs and keep those that reach new code. It is
  excellent for parsers, and could be added for the query parser. For the storage layer, the hard part
  is not reaching code but knowing the right answer, which is the oracle's job; a generator that knows
  the graph model reaches deep states faster than byte mutations.
- **Formal verification** of the storage format or the transaction logic would prove properties for every
  input, not only the generated ones. It costs far more per property, and the properties that matter
  most here (an index agrees with its records) are cheap to check at run time.
- **More example tests instead.** Each new bug gets one — a regression test that fails without the fix —
  but examples only grow with what people think of. The fuzzers grow with what the generators can
  combine, which is far more.

## Reading the code

In order, with the file to read for each technique:

1. `src/storage/integrity.zig` — the checker: what is primary, what is derived.
2. `tests/fuzz/model.zig`, then `tests/fuzz/storage.zig` — the model and the fuzzer that drives both;
   `tests/fuzz/main.zig` for seeds and the command line.
3. `tests/fuzz/query.zig` and `query_generator.zig` — the oracles that need no second engine.
4. `tests/snapshot.zig` — a test that rewrites its own source.
5. `src/storage/engine/faulty.zig`, then `tests/fuzz/faults.zig` — failing on purpose.
6. `tests/fuzz/crash.zig` — a program that kills itself, and the parent that checks what is left.
7. `src/storage/layout.zig` — the layout, as functions that both the checker and the assertions use.
