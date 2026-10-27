# Planning and execution

This guide covers how a query becomes work and how that work runs: the plan is made in
`src/planning/` and run in `src/execution/`. Read it before changing the planner or adding a
clause.

## From AST to plan

A checked query becomes a **plan** before it runs (`src/planning/`), and the executor runs the plan
(`src/execution/`). The plan is built once per statement: nothing about it depends on the rows or
the parameter values, only on the query, on the graph's label and edge-type counts and on its
indexes (a prepared statement plans again when the counts drift or an index is made or dropped;
see [below](#prepared-statements-and-the-statement-cache)).

A plan (`Plan.zig`) is a flat array of **operators**, a tagged union, grouped in **chains**, the
same shape as the AST: indices, not pointers, and no `Operator` objects. A chain is a run of
consecutive operators, each handing the rows it makes to the next one. The **main chain** runs a
query (a `UNION` has one per part); without a `RETURN` it ends in `discard`. Other chains run inside an operator, once for each of its rows,
and end with `output`, which hands their rows back:

| Chain | Run by | For each row it gets |
| --- | --- | --- |
| an `OPTIONAL MATCH`'s patterns and `WHERE` | `optional` | its matches, or the row with nulls |
| a `CALL { }`'s subquery | `call_subquery` | the subquery's rows, which extend the row |
| a `MERGE`'s pattern | `merge` | its matches, or nothing (the pattern is created) |
| a `FOREACH`'s clauses | `foreach` | run once per list element |
| a pattern predicate, pattern comprehension, `EXISTS { }` or `COUNT { }` | the expression (`Plan.expression_chains`) | the rows it tests, counts or collects |

`builder.zig` makes the operators clause by clause:

| Clause | Operators |
| --- | --- |
| `MATCH` | per pattern, the pattern's operators (below), then a `filter` for the `WHERE` |
| `OPTIONAL MATCH`, `CALL { }`, `MERGE`, `FOREACH` | one operator, running a chain of its own |
| `UNWIND`, `LOAD CSV`, `CALL` | `unwind`, `load_csv`, `procedure_call` |
| `WITH` (and a subquery's `RETURN`) | `with_streaming` if it only projects and filters, else `with_collecting` and its stages |
| `RETURN` | `return_`; with aggregates or stages, also the stages and `produce_results` |
| their `DISTINCT`, `ORDER BY`, `SKIP`, `LIMIT` | one `projection_stage` each, in that order; `ORDER BY` with a `LIMIT` is a `top`, which keeps `SKIP + LIMIT` rows, and no `limit` follows it |
| `CREATE`, `SET`, `DELETE`, `REMOVE` | `write` |

A query that writes gets an `eager` between each two clauses: every row goes through a clause
before any goes on to the next one, so a clause sees the effect of the one before it on every row.

The builder follows the **variables in scope** (`scope.zig`), exactly as the semantic checks do,
and gives each variable a **slot**: its place in a row. Every binding site gets a new slot (a
pattern variable seen first, an `UNWIND` or `FOREACH` variable, a `YIELD`, each item of a `WITH`,
a comprehension's variable), and every variable the query reads is resolved to the slot in scope
there (`Plan.slot_of`, indexed by AST node). A `WITH` starts a new scope: its items get new slots,
so its `WHERE` and `ORDER BY` can read both the projected names and, unless it aggregates, the
variables before it. A pattern node bound before its pattern (by an earlier pattern or clause) is
checked, not scanned.

The optimizations are four. Three are made when a pattern is planned (`patterns.zig`), one when a
projection is:

1. **Anchor selection** picks the cheapest node to start a pattern from.
2. **Predicate pushdown** turns equality and range predicates into index seeks before the scan
   runs.
3. **Edge anchoring** starts a pattern from a relationship index when only its relationship is
   selective.
4. **Top**: an `ORDER BY` with a `LIMIT` keeps only the first `SKIP + LIMIT` rows in order (a
   partial sort) instead of sorting them all.

Each can be switched off with `PlanOptions` (`where_seeks`, `index_lookups`, `anchor`, `top`;
`Executor.plan_options`). The defaults make the fastest plan; any other setting makes a slower plan
with the same rows, which is what the query fuzzer checks (see
[testing](testing.md#the-query-fuzzer)). A new optimization gets a switch too.

There is no cost-based optimizer. Within a `MATCH`, comma-separated patterns run in source order,
and each pattern is a chain: the decision that matters most is which node of a chain to start from.
A cost model would also have little to estimate with: ZypherDB keeps label counts and a counter per
edge type, not degree distributions or per-property selectivity. Joining patterns differently
(reordering them, a hash join instead of a nested loop) would be new operators and a planner choice
between them; the trigger should be a query that measurably scans more than it needs to.

## The plan of a pattern

For one pattern, `patterns.plan` walks the chain `[node, edge, node, …]` into a `PatternPlan`:

```zig
const Seek = struct { property: []const u8, value: Index };   // node.property = value

const PatternNode = struct {
    variable_name: []const u8,
    slot: Slot,
    labels: []const []const u8,
    seeks: []const Seek,
    ranges: []const RangeSeek,
    seek_index: ?IndexUse,   // the index that answers one of the seeks
    range_index: ?IndexUse,  // the index that answers one of the ranges
    bound: bool,  // bound before the pattern
};

const PatternEdge = struct {
    edge_types: []const []const u8,  // empty: any type
    variable_length: bool, min_hops: u32, max_hops: ?u32,
    shortest: Shortest, where_reads_path: bool,
    forward_direction: Direction, undirected: bool,
    variable_name: []const u8,
    slot: Slot,
    seeks: []const Seek,
    seek_index: ?IndexUse,
};

const IndexUse = struct { index_id: u32, position: u32 };  // the index, and which seek or range
```

The seeks come from two places:

- inline property maps (`{name: 'Ana'}`);
- the `WHERE` clause. `collectWhereSeeks` walks its `AND` tree and pulls out every
  `variable.property = value` whose value is a literal or a parameter, which is constant for the
  whole query.

The `WHERE` also gives ranges. Each `variable.property <op> value`, with `<`, `<=`, `>` or `>=` in
either order, bounds the property from one side (`PatternNode.ranges`). When a node has no
equality seek, the scan of an anchor with a range reads the property index's key range for it
(`Graph.nodesInRange`): numbers and dates, the other types fall back to a scan.

A seek or range reads an index only when one covers it: `findIndexes` looks, for each of the
node's labels, for an index on that label and the seek's property (or document path,
`n.doc.field`), and records it as `seek_index` or `range_index` (`Statistics.propertyIndex`, which
reads the definitions once per plan). A relationship's seek needs an index on its single type. A
seek no index covers still narrows nothing: the candidates come from the label (or every node)
and the seek is checked on each, as in Neo4j.

A pushed-down seek or range is still checked against each candidate, and the whole `WHERE` is
still evaluated at the end. So pushdown never changes a result: it only narrows the candidates.

## Anchor selection

`estimate(node)` ranks a node by what starting there costs: the candidates its scan reads, plus
the rows it leaves for the rest of the pattern.

- already bound: `0`, a free start;
- has an equality seek an index answers: `2`, a point lookup (one read, one row);
- unlabeled and without a range: the maximum, since it means scanning every node;
- otherwise: the candidates are the count of its rarest label, a quarter of it with a range an
  index answers (a
  guess without statistics, enough to prefer a range to a scan of the whole label); the rows are
  the candidates **capped by the count of an incident edge type** (a pattern cannot produce more
  rows than there are edges of that type). Only an edge of one type and fixed length caps it.

The cap makes a start next to a rare relationship type win between scans of similar size, but it
never makes a scan cheaper than reading its candidates: with a single `MAY_OPEN` relationship,
`(g:Group)-[:MAY_OPEN]->(d:Door {name: $door})` still starts from the door's seek, not from a scan
of every group. `chooseAnchor` takes the minimum; a tie goes to the node written first. The pattern's operators are then: a `bound_node` check for each
node bound before it, a `node_scan` of the anchor (unless it is bound), an `expand` for each edge
to the right end of the chain, then to the left end, and a `project_path` if the pattern is named
(`p = ...`).

`shouldEdgeAnchor` handles a special case. When the pattern is a single fixed-length edge with a
seek a relationship index answers, and its two endpoints are unbound and unlabeled, the plan is
one `edge_index_scan` that starts from that index.

## How operators map to graph operations

Each pattern operator is one graph operation (`pattern_matching.zig`):

| Operator | Graph operation (`graph.zig`) | Storage (see [storage](storage)) |
| --- | --- | --- |
| `node_scan` with a seek | `nodesByIndex(index_id, value)` | property-index prefix scan |
| `node_scan` with a range | `nodesInRange(index_id, lower, upper)` | property-index key range |
| `node_scan` with a label | `nodesWithLabel(label)`, then the other labels are checked | label-index prefix scan |
| `node_scan`, unlabeled | `allNodes()` | a walk of the `#nodes` records |
| `expand` | `edgesOf` / `edgesOfType(from, direction)` | edge prefix scan |
| `expand` to a node with a selective seek | `nodesByIndex`, then `hasEdge` for each candidate | index seek and point lookups |
| `edge_index_scan` | `edgesByIndex(index_id, value)` | relationship-index prefix scan |

The `expand` row with a seek covers patterns like `(a)-[:WORKS_IN]->(:Department {code: $code})`.
If the index gives at most `max_indexed_candidates` (8) nodes for the seek, checking an edge to each
is cheaper than scanning every neighbour of `a`.

## How a plan runs

The executor runs a chain in the push model (`operators.zig`): `feed(operator, row)` hands one row
to an operator, which passes each row it makes on to the next one with `feed(operator + 1, row)`.
The loops of a pattern nest through these calls:

```text
node_scan → for each candidate: check labels and seeks, bind, feed(next)
expand    → for each neighbour: check type, labels, seeks, uniqueness, bind, feed(next)
filter    → if the predicate holds: feed(next)
return_   → project the row (or fold it into its group)
```

- **Rows are slots, extended in place.** A row (`bindings.zig`) is an array of values, one per
  slot, so reading a variable is an index. A row passed to an operator is the caller's: the
  operator binds with `bindings.mark()` and `restore`s on the way out (each binding records what
  it changed), so a branch leaves no trace in its siblings, and copies the row only to keep it. A
  `WITH` that only projects writes its slots into the row it gets: the slots it leaves behind are
  still there, but nothing after it reads them; its `DISTINCT` compares its own slots only.
- **Operators that need every row first** (`with_collecting`, `eager`) keep copies. When the chain's
  first operator returns, `runOperators` lets each of them, in chain order, pass its rows on. A
  `with_collecting` first projects or groups them, each with its `ORDER BY` key (which may read
  variables the `WITH` does not project), then its stages apply to the whole list, one after the
  other; a `RETURN`'s stages apply the same way once its chain is done. Stages are never fed a row,
  so they cost nothing per row, and each one has its own time and rows in `PROFILE`.
- **A plan does not change while it runs.** What a run needs besides it is the executor's: each
  operator's kept rows, where each chain's rows go, and the node and relationships each pattern
  element is matched to on the current branch (`node_ids`, `matched_edges`, read by later operators
  of the pattern, so anonymous nodes need no variable).
- **Variable-length edges** (`*min..max`) expand depth-first in `walk`. The walk keeps a trail of
  relationships, reports each end it reaches within the range, and never uses a relationship
  twice. Shortest paths search breadth-first (`shortest_paths.zig`).
- **Relationship uniqueness.** `used_edges` holds the relationships bound on the current branch,
  each with its MATCH. An `expand` skips a relationship its MATCH already uses (`edgeUsed`); a
  nested match (a pattern in an expression) has its own.
- **Iterators are scoped to the frame.** Each iterator lives in the call that opened it, which
  guarantees it is closed before its transaction ends.
- **Early end.** A `RETURN` with a `LIMIT`, and no aggregate, `DISTINCT` or `ORDER BY`, stops the
  query once it has its rows: the internal error `LimitReached` unwinds the matching, and every
  iterator closes on the way out.
- A `UNION` runs its parts one after the other in the same transaction, then concatenates their
  rows, removing duplicates unless it is `UNION ALL`.

`MERGE` runs its pattern's chain from each row. If the pattern has matches, each match becomes a
row and gets `ON MATCH SET`. If not, `writes.createPattern` creates the pattern's unbound nodes and
its relationships, and binds their variables for `ON CREATE SET`.

## Expressions

The builder also compiles the query's expressions (`expression_program.zig`): one instruction
per AST node, indexed as the AST is, so execution never reads an AST kind or looks a name up.

| Expression | Instruction |
| --- | --- |
| a literal | its value |
| a variable | its slot |
| `variable.property` | the variable's slot and the property name (no step through the variable) |
| `$name` | an index into the run's parameter values, looked up by name once per run |
| a function call | the function, resolved by name once |
| `text =~ 'constant'` | the pattern, compiled once (an invalid one fails when, and only if, it is evaluated) |
| a pattern or subquery in an expression | its chain |

`expressions.evaluate` handles only the scalar instructions (constants, slots, parameters,
properties, calls, operators); lists, maps, `CASE`, comprehensions and subqueries are in
`evaluateComplex`, so the function every expression goes through keeps a small stack frame.
Because instructions are indexed by AST node, what is keyed by node needs nothing new: while an
aggregating expression is evaluated for one group, `expression_overrides` gives the values that
stand for its aggregates and grouping keys, by node, before the instruction is read. A schema
command, which has no plan, compiles the expressions of its `OPTIONS` alone.

## EXPLAIN and PROFILE

`EXPLAIN` plans the query and returns the plan's lines without running it; `PROFILE` also runs it
(`execution/profiling.zig`). `planning/explain.zig` makes the lines: each chain from its last
operator to its first (the result on top, as Neo4j shows a plan), a chain run by an operator right
after it, one level deeper, and the chain of an expression's pattern or subquery after the operator
that evaluates it, under a line naming the expression. Each line knows its parent, so the Python
API can rebuild the tree; `query/printer.zig` writes the details back as Cypher.

**Estimates** are per run of a chain, from the counts the planner reads (`statistics.zig`, which
reads each label or relationship-type count once per plan and records it in the plan): a scan
makes the label's count (a quarter of it for a range, one for an equality); an expansion multiplies
by the relationships of its type per node of the start's label; a `LIMIT` caps, an aggregation
without grouping keys makes one row. A filter is not assumed to drop anything, and what the counts
cannot tell (an unlabeled start, a variable-length expansion, the groups of an aggregation) is
`null`.

**PROFILE** counts the rows handed to each operator (an operator's rows are those its successor
was handed) and times each one exclusively: `feed` switches the clock to the operator it enters
and back to its caller when it returns, so the time an operator spends handing rows on belongs to
the operators it hands them to. Without `PROFILE` the cost is one test per `feed`.

## Prepared statements and the statement cache

A `Statement` (`src/statement/Statement.zig`) is a query parsed, checked and planned once. Its
arena owns the text and the AST (the semantic checks rewrite the AST once, at preparation); a
second arena owns the plan, so planning again frees the old one. A plan depends on what kind each
predicate's value is (a literal, a parameter), never on the values, so parameters are bound when it
runs. EXPLAIN, PROFILE and schema commands keep no plan: they are parsed again on each run.

Each run opens the transaction, then reads again the counts the plan was built on
(`Plan.statistics`): when one has changed to `drift_factor` (2) times what it was, or half, and by
at least `drift_floor` (100), the statement plans again before it runs. A plan that looked for
an index also records the schema version (`!schema`, bumped by every `CREATE` or `DROP` of an
index or constraint): any change to it plans again. Reading the counts costs a key lookup each,
too little to see next to a 3 µs point query.

The C context and the Python database keep the statements their `query` calls prepare in a
`StatementCache` (`Cache.zig`), by text, the 64 used most recently. The checks depend on the
procedures defined besides the text, so defining one clears the cache.

## Transactions, the read cache and the entity snapshot

`Executor.run` opens one transaction for the whole query: a write transaction if any clause writes,
otherwise a read transaction, which is a consistent snapshot.

- **Repeated reads.** A pattern in which many rows reach the same few nodes (every member reaches
  their department) reads each node's record from storage once: the store's record cache keeps
  the records a read transaction found (see [storage](storage)).
- **The entity snapshot** (`entities.zig`). Rows hold references to nodes and relationships.
  Before the transaction ends, `EntitySnapshot.capture` reads the labels and properties of every
  entity the result mentions, so the caller can present whole entities as the query left them.

## Aggregation and grouping

A projection is split into **key** items, which are the implicit grouping keys, and **aggregate**
items. For each row, `accumulate` evaluates the keys and finds or creates the row's group in a
hashed `Grouping(Key, KeyContext)`, with expected O(1) time per row. It then updates the group's
`AggregateState`s. When the input ends, `aggregate` turns the groups back into rows. `WITH` uses
the same machinery and binds each group's values to its items' slots, so a node variable passes
through as a node.

An `AggregateState` holds a running reduction. It covers count, sum, min and max, `collect`'s list,
the running mean and variance of `avg`, `stDev` and `stDevP`, and the set of seen values for
`DISTINCT`. Every aggregate skips nulls except `count(*)`, which counts rows.

## Nulls

`null` comes from `OPTIONAL MATCH`, missing properties, `CASE` without `ELSE`, and out-of-range
access. The rule is **propagation**:

- property access on `null` gives `null`, and so does an operator with a `null` operand;
- `AND`, `OR`, `XOR` and `NOT` are three-valued (`false AND null` is `false`, `true AND null` is
  `null`);
- a `WHERE` whose condition is `null` drops the row (`evaluateBool` treats it as false);
- aggregates skip `null`s.

Ordering is separate from comparison. `comparison.zig` implements the `<` of the language, which is
`null` for incomparable values. `Value.order` is the total order that `ORDER BY`, `DISTINCT` and
grouping use, and it places every value, `null` last.

## Why this way — and the alternatives

- **Push, not pull.** The classic design (Volcano) gives each operator a `next()` that pulls one row
  from the operator below it, so every operator keeps its loop's state in an object between calls.
  In the push model the loops of a pattern are nested calls: a scan's iterator is a local variable
  of the call that runs the loop, so it closes, by construction, before the transaction ends, and a
  branch is undone on the way back up. The price is that an operator cannot ask for "just one more
  row"; stopping early is an error (`LimitReached`) that unwinds the calls.
- **A plan, not the AST.** Before it had plans, ZypherDB's executor walked the query's clauses,
  choosing what to do as it went. A plan built ahead makes those choices once: it can be shown (`EXPLAIN`), measured per
  operator (`PROFILE`), kept by a prepared statement, and compared with a plan made without an
  optimization (the query fuzzer).
- **Slots, not names.** A row could be a map from variable names to values. With slots, reading a
  variable is an index, and a branch is undone by a short trail. Measured against a name-based
  design (in a parallel review of this code), slots were 25-44% faster on multi-hop queries; on
  point queries, where the B-tree search dominates, they changed little.
- **Compiled expressions.** Evaluating the AST means deciding, at every node of every row, what
  kind of node it is and looking names up. On an expression-heavy query that dispatch was about a
  third of the time. One instruction per AST node, built with the plan, resolves the names, the
  functions and constant regular expressions once.
- **Plans that do not depend on parameter values.** A plan built for one value of `$name` could pick
  a better anchor for it, but could not be reused for the next value. ZypherDB keeps one plan per
  statement and replans only when the counts drift, which is what prepared statements are for.
- **No cost-based optimizer** yet: [above](#from-ast-to-plan), with the trigger that would change it.
