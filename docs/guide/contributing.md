# Contributing — how to extend the engine

The shape of the codebase makes each kind of change follow a fixed recipe. This page is that
recipe, the principles the code follows, the build/test loop, and the Zig 0.17 gotchas that have
already cost time.

## Build and test

```bash
zig build test    # unit tests in src/ + the suite in tests/
SNAP_UPDATE=1 zig build test   # rewrite the snapshots that differ (review with git diff)
zig build fuzz -- storage --seeds 100   # the storage fuzzer, from a random seed
zig build fuzz -- faults --seeds 100    # the fault fuzzer: storage that fails on purpose
zig build fuzz -- crash --seeds 100     # the crash fuzzer: a writer killed with SIGKILL
                  # (CI runs them all on each change and nightly: see testing.md, "Fuzzing in CI")
zig build         # static + shared libraries and zypherdb.h into zig-out/
make python       # the Python extension module into zig-out/python/
make test-py      # Python tests and documentation tests (pip install -e ".[dev]" once)
make tck          # the openCypher TCK
make docs         # the HTML documentation
```

`make python` and the targets that use it find the Python headers through `PYTHON` (default
`python3`); point it at a virtual environment with `make test-py PYTHON=.venv/bin/python`.

Wheels and the sdist come from an in-tree build backend, `tools/build_backend/zypherdb_build.py`
(declared in the root `pyproject.toml`): `python -m build` (or `pip wheel .`) runs
`zig build python` in ReleaseSafe, stripped, and packs the module with `python/zypherdb` into one
`cp310-abi3` wheel for the platform. It uses a `zig` of the version `build.zig.zon` names, or
`$ZIG`, or else installs the `ziglang` package for the build. Linux wheels target glibc 2.17
(manylinux2014), macOS wheels 10.13 (x86_64) and 11.0 (arm64). `pip install -e .` only puts
`python/` on the path; the package then loads the module `make python` built.

The version comes from git tags, not from `pyproject.toml`: on a tag `v0.2.0` the build is
`0.2.0`; three commits later, `0.2.1.dev3`. A release is a GitHub release with a new tag
`vX.Y.Z`, its notes the version's section of `CHANGELOG.md` (`## X.Y.Z — date`, moved from
`## Unreleased` before tagging): publishing it runs `.github/workflows/publish.yml`, which builds and tests every wheel
and the sdist and uploads them to PyPI.

`zig build test` runs two executables:

- **The suite, `tests/`.** It imports the `zypherdb` module like any client and uses **only the
  public API**. It mirrors the source layers: `tests/storage/`, `tests/query/`,
  `tests/end_to_end/` (whole queries, one file per feature) and `tests/c_api_test.zig`.
  `tests/support.zig` holds the shared helpers: a temporary store, the "people and movies" fixture
  (`loadMoviesGraph`), and `expectQuery`/`expectOrdered`/`expectQueryError`. Most feature work is
  verified with a few `expectQuery` calls, not mocks.
- **Unit tests in `src/`.** A `test` block stays next to its code only when it checks something
  private and small: the key encoding round trip, the laws of `Value`'s order and hash, the generic
  algorithms, diagnostic truncation.

- **The Python tests, `python/tests/`**, check the extension module: value conversion both ways,
  entities, errors, threads.
- **The documentation tests, `python/tests/test_docs.py`**, run every example in `docs/`. The
  tutorial runs as one session, page after page; each other page runs on its own. A `text` block
  right after an example is its expected output and must match exactly. C examples with a `main`
  are compiled with `zig cc` and run. So a change that alters an output shown in the documentation
  fails until the page is updated, and every page states what the engine actually does.

A bug fix comes with a regression test that fails without the fix.

The sections below say how to run each kind of test. Why each one exists, what it guarantees and
what it cannot see are in [testing](testing).

### The openCypher TCK

`make tck` runs the [openCypher TCK](https://github.com/opencypher/openCypher/tree/main/tck)
(vendored in `tests/tck/`, see its README) and fails if a scenario in `tests/tck/baseline.txt` no
longer passes; CI does the same. Language work is measured there: pick a reason from
`tests/tck/REPORT.md`, implement it, run `make tck`, then record the newly passing scenarios with
`python -I tests/tck/runner.py --update-baseline --report tests/tck/REPORT.md` in the same commit.
`tests/tck/deviations.txt` lists the scenarios that ZypherDB answers differently on purpose (map
properties, for instance), each with its reason.

### The storage fuzzer and the integrity checker

`tests/fuzz/storage.zig` runs random operations through the `Graph` API — nodes, labels,
properties of every type, relationships (loops and parallel ones too), commits and aborts,
full-text indexes and uniqueness constraints (as statements), closing and reopening the database —
and applies each to a model in memory (`tests/fuzz/model.zig`) that predicts the ones that must
fail (a constraint broken, a node still connected, a value that cannot be stored). After every
commit and abort it checks that the database equals the model, and runs the
[integrity checker](storage.md#checking-integrity).

A run is determined by its seed. Each seed also picks what it exercises (swarm testing): which
operations run and how often, with transactions or without, how many labels and properties, and
whether values come from every type or from a narrow few that collide often. A failure prints the
last operations, the problem, and the command that repeats it:

```bash
zig build fuzz -- storage --seed 42 --steps 1000 --verbose
```

`zig build test` runs eight fixed seeds; a long run takes random ones, on each engine:

```bash
zig build fuzz -Doptimize=ReleaseSafe -- storage --seeds 200 --steps 2000
zig build fuzz -Doptimize=ReleaseSafe -Dstorage-engine=mdbx -- storage --seeds 200 --steps 2000
```

At the end it prints how often each operation ran, and how often it failed as the model said it
must: a fuzzer that never breaks a constraint does not test them. A new mutation of the graph, or a
new kind of failure, gets an operation in the fuzzer and a prediction in the model.

### The query fuzzer

`tests/fuzz/query.zig` builds a small random graph and runs generated read queries
(`tests/fuzz/query_generator.zig`), each compared with itself planned with optimizations off
(`zypherdb.PlanOptions`), prepared, and split by a random predicate into `WHERE p`, `WHERE NOT p` and
`WHERE p IS NULL`. `--steps` is the number of queries per seed. Each seed prints a digest of its
results; run the same seeds on both engines and compare the digests:

```bash
zig build fuzz -- query --seed 42 --steps 200 --verbose
zig build fuzz -Doptimize=ReleaseSafe -- query --seed 500 --seeds 100
zig build fuzz -Doptimize=ReleaseSafe -Dstorage-engine=mdbx -- query --seed 500 --seeds 100
```

A new planner optimization gets a switch in `PlanOptions`, so the fuzzer can compare the plan with
and without it.

### The fault fuzzer

Every storage error must reach the caller as an error, without a panic, a leak, a transaction left
open or a half-written change. `tests/fuzz/faults.zig` checks this with a storage engine that fails
on purpose (`src/storage/engine/faulty.zig`, which wraps the real engine and fails at the N-th
operation). `build.zig` builds a second ZypherDB module with it (build option `fault_injection`) for
the fault test and the fuzzers; the library itself never includes it, so it pays nothing for it.

The fuzzer runs a random workload (`tests/fuzz/fault_workload.zig`: writes, MERGE, deletions,
constraints, full-text indexes and searches, and the query fuzzer's reads; one-shot or prepared) on
two databases: one that fails and a twin that does not. Each statement runs on the failing database
once per fault point, until a run reaches none. After a failure, the statement must have failed
with a storage error (or with the twin's own error), the database must be exactly as before it, and
the integrity checker must pass; once no fault is reached, the outcome and the whole database must
equal the twin's. A seed chooses transient or persistent failures (a dead disk), and whether a
failure breaks the write transaction as a real engine does or leaves it usable: only then does a
write error that the code ignores show up, as a database unlike the twin's.

```bash
zig build fuzz -- faults --seed 42 --steps 40 --verbose
zig build fuzz -Doptimize=ReleaseSafe -Dstorage-engine=mdbx -- faults --seeds 300 --steps 60
```

A new kind of statement that writes gets a template in the workload.

### The crash fuzzer

A process that dies must leave a database that opens, passes the integrity checker and holds every
transaction it committed. `tests/fuzz/crash.zig` starts a writer (the fuzz program itself, run as
`crash-writer`) that runs a seed's write workload, one statement per transaction, and reports each
statement done. The writer dies, a few times per seed, in one of two ways:

- at a crash point: the failing engine (`src/storage/engine/faulty.zig`) has one before each storage
  operation and one after each commit, and the writer sends itself SIGKILL at the one the fuzzer
  chose (half of them near a commit). These crashes are reproducible from the seed.
- killed by the fuzzer a random delay after a report, which can land inside the storage engine (in
  the middle of a commit's writes or its sync), but depends on timing.

After each crash the fuzzer reopens the database, runs the integrity checker, and compares it with a
twin that ran the same statements without crashing: it must equal the twin after the last statement
reported, or after the next one (whose commit may have finished before the kill). The writer then
starts again from there; the last one runs to the end and must reach the twin.

```bash
zig build fuzz -- crash --seed 42 --steps 80 --verbose
zig build fuzz -Doptimize=ReleaseSafe -Dstorage-engine=mdbx -- crash --seeds 200 --steps 80
```

A process crash keeps what the operating system already holds, so every durability setting must keep
every reported commit. Power failures, which lose what was not synced, are not tested: they need a
simulated disk.

### Snapshot tests

Text that a reader checks as a whole — EXPLAIN and PROFILE plans
(`tests/end_to_end/explain_test.zig`) and the error messages a caller of the C ABI or Python
reads (`tests/error_messages_test.zig`) — is compared with a multiline string literal written
right after `snap(@src(), ...)` (`tests/snapshot.zig`):

```zig
try snap(@src(),
    \\Return m.title  [estimated 6]
    \\NodeByLabelScan (m:Movie)  [estimated 4]
).diff(plan_text);
```

When the text changes, the test prints both versions. `SNAP_UPDATE=1 zig build test` rewrites
every literal that differs with the new text; read the change with `git diff` before committing
it. To add a case, write an empty literal (`\\` alone on its line) and run with `SNAP_UPDATE=1`.
If a test crashes during an update, the rest of the run can refuse to rewrite a file that changed
since it was compiled; run the update again.

### Benchmarks

`zig build bench -Doptimize=ReleaseFast` measures the engine, and `bench/python_overhead.py` the
cost the Python layer adds. Results and their conditions are recorded in `bench/RESULTS.md`, and
known risks in [performance](performance). A change that claims a speed-up comes with numbers
from both runs.
A scenario that leaves the baseline needs an explanation in the commit message (for example, an
expected error that used to match only by accident).

## Principles

The style follows Alexander Stepanov's generic programming, within Zig's conventions.

- **Regular types.** A type that is compared, sorted, deduplicated or grouped defines `eql`, a total
  `order` when ordering is meaningful, and a `hash` consistent with `eql`, under the std names. Their
  laws (reflexive, antisymmetric, transitive, total; equal values hash equally) are checked by
  property tests over random values (see `src/value.zig`).
- **Write an algorithm once.** When the same algorithm appears for a second type, make it generic
  over the type (`comptime T: type`) and a context with the operations it needs, following the
  std.HashMap context protocol (`hash(ctx, T) u64`, `eql(ctx, T, T) bool`). Examples:
  `sequence_algorithms.removeDuplicates`, `aggregation.Grouping`, `projection.sortByKey`. Do not
  generalize before there are two concrete uses.
- **Costs are part of the interface.** A public storage operation states its complexity (see
  `src/storage/graph.zig`). A new operation states its own.
- **Ownership is part of the interface.** Say who owns returned memory: an owned copy (`getProperty`
  allocates with the caller's allocator) or a view (an iterator's slices are valid until the next
  `next`).
- **Errors are values** (`error union`s), never `catch unreachable` on I/O. Every error that reaches
  the C ABI or Python carries a `Diagnostic` message and code.
- **No class hierarchies, no Visitor.** Data as concrete types, algorithms as free functions. The
  AST is an arena: no pointers between nodes; build bottom-up and return indices.

## Layout and naming

- **One directory per layer**: `storage/` (engine, keys, graph), `query/` (text to AST), `execution/`
  (AST to rows), `temporal/` (calendar, zones, temporal types). Shared types and algorithms sit in
  `src/` (`value.zig`, `sequence_algorithms.zig`, `diagnostics.zig`). The embeddings sit apart:
  `src/c_api.zig` with `include/zypherdb.h`, and `python/` (the native module in `python/native/`,
  the package in `python/zypherdb/`).
- **One responsibility per file**, as a guide under ~500 lines of code; functions under ~60 lines.
  A large `switch` over token or node kinds (`tokenize`, `evaluate`) is the exception: it reads best
  in one place.
- **Zig's file convention**: a file that *is* a struct (top-level fields) is `TitleCase`
  (`Executor.zig`); any other file is `snake_case`. Zig cannot spread a struct's methods over files,
  so a large struct keeps its state and splits its logic into free functions in other files that
  take it as the first parameter (`expressions.evaluate(executor, …)`). Calls go through the module
  name, so a call site says where the code lives.
- **Descriptive names, no abbreviations** (`edge_type`, `variable_name`, `children`, `diagnostic`).
  Kept on purpose: `id`, `src`/`dst`, std's own names (`tmpDir`), the LMDB and libmdbx C APIs' own names
  inside the bindings, and one-letter names in short loops.

## The recipes

### Add a clause

A clause is a `NodeKind`, a parser rule, an operator and its executor arm.

1. `src/query/ast.zig` — add a `NodeKind` value (and a `Data` payload if it carries state, e.g.
   `unwind.variable_name`). Document its children in the header comment.
2. `src/query/parser.zig` — add a `parse…Clause` function and call it from `parseQuery` in source
   order.
3. `src/planning/` — its operator in `Plan.Operator`, and a case in `builder.planClause` that adds
   it to the chain (and the variables it binds to the scope). A writing clause must be listed in
   `ast.isUpdatingClause` so the query opens a write transaction and gets its `eager`s.
4. `src/execution/operators.zig` — a case in `feed`, which turns each row the operator receives into
   the rows it passes on; a writing clause's work on one row goes in `clauses.applyWrite` and
   `writes.zig`.
5. `src/query/semantics.zig` — the variables it binds, if any, so later clauses see them in scope.
6. `tests/end_to_end/` — queries that use it, in the feature's file; then `make tck`.
7. `docs/guide/cypher.md` — its row in the clause table, and a tutorial step if users need it.

### Add an expression or operator

1. `src/query/ast.zig` — a `NodeKind` (expression) or a `BinaryOperator` value.
2. `src/query/expression_parser.zig` — a `parseAtom` branch (expression), or the loop of the
   precedence level where the operator belongs (see [the language](language)).
3. `src/execution/expressions.zig` — a case in `evaluate` (expression) or `applyBinaryOperator`
   (operator), with the null propagation of [planning and execution](planning-execution.md#nulls).
4. `docs/guide/cypher.md` — the operator table.

### Add a function

Functions need no parser change: a call is parsed by name.

1. `src/execution/functions.zig` — an implementation, `fn (*Executor, []const Value)
   ExecutionError!Value`, and an entry in `builtin_entries` with its number of arguments (`fixed(n,
   f)`, or a `Function` with a range). Temporal functions are implemented in
   `temporal_functions.zig` and listed in `temporal_table`.
   `checkCalls` then rejects wrong arities before the query runs.
2. `docs/guide/cypher.md` — its row in the function table.

### Add an index

Indexes are just more key ranges (see [storage](storage)):

1. `src/storage/key_encoding.zig` — an `append…Key`/`append…Prefix` pair for the new layout.
2. `src/storage/graph.zig` — maintain it in the right mutation (`setProperty`, `addEdge`, …) and
   cleanup (`deleteNodeOnly`, `deleteEdgesInDirection`), and expose a lookup that returns an
   iterator (`nodesByIndex`/`edgesByIndex` are the models). State its cost.
3. If it should drive planning, surface it in `patterns.zig` (`estimate`, `shouldEdgeAnchor`) and
   in the pattern operator that reads it (`pattern_matching.zig`).
4. `src/storage/integrity.zig` — rebuild its keys from the primary data, so the checker compares
   them (until then it reports them as unknown keys); then run the storage fuzzer.

## Zig 0.17 gotchas (rediscovered once, recorded here)

- `@cImport` is removed → hand-written bindings: `extern "c" fn` + `opaque {}` (see
  `src/storage/engine/lmdb_bindings.zig`), or `b.addTranslateC` in `build.zig` for a large header (the
  Python module translates `python/native/python.h`).
- `@intFromEnum` became `@backingInt` (`zig fmt` rewrites it); a struct's field names are
  `@typeInfo(T).@"struct".field_names`.
- The clock and randomness come from `std.Io` (`std.Io.Threaded.global_single_threaded.io()` where
  no `Io` is passed in); `main` takes `std.process.Init`.
- `std.fmt.bufPrintZ` is gone; `std.heap.stackFallback` became `std.heap.BufferFirstAllocator`.
- `std.fs` was reorganized into `std.Io`; `makePath`/`realpathAlloc` no longer exist.
- `std.testing.tmpDir(.{})` returns a `TmpDir` (not an error union); clean up with `.cleanup()`.
- `Allocator.dupeZ` is gone → `dupeSentinel(u8, slice, 0)`.
- `std.ArrayList(T)` is now the *unmanaged* variant: init with `.empty`, and pass the allocator to
  `append(allocator, …)`/`deinit(allocator)`. `ArrayList.init(allocator)` no longer exists.
- Build API: `b.addModule`/`b.createModule`/`b.addLibrary`/`b.addTest`; `link_libc` lives in
  `Module.CreateOptions`.
- `str ** n` (comptime repetition) does not parse in this version; use `@splat` or `@memset`.
- macOS file systems are case-insensitive: renaming `foo.zig` to `Foo.zig` needs two `git mv` steps
  (through a temporary name), or git keeps the old case and Linux builds fail.
