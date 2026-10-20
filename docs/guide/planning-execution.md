# Planning and execution

This guide covers how a query becomes work and how that work runs. All the code is in
`src/execution/`. Read it before changing the planner or adding a clause.

## There is no IR (and why that is fine for now)

The executor goes **directly from the AST to a plan**. There is no intermediate language, no
rewriting pass and no cost-based optimizer. The plan of a pattern is a handful of structs built in
`planner.setupPattern`, and the optimizations are three, all applied at that point:

1. **Anchor selection** picks the cheapest node to start a pattern from.
2. **Predicate pushdown** turns equality predicates into index seeks before the scan runs.
3. **Edge anchoring** starts a pattern from the edge-property index when only its relationship is
   selective.

There are three reasons not to have an IR yet, and none of them is that acmedb is embedded:

1. **The plan space is small.** Within a `MATCH`, comma-separated patterns run in source order,
   and each pattern is a chain. The decision that matters most is which node of a chain to start
   from, and `chooseAnchor` makes it.
2. **A cost model has little to estimate with.** A cost-based optimizer needs statistics:
   cardinalities, selectivities, degree distributions. acmedb keeps label counts and a counter per
   edge type. An optimizer built on that would be guessing.
3. **Index-free adjacency already fixes the dominant cost.** In a graph database the dominant cost
   is following edges and scanning indexes, and anchor selection decides it. What an optimizer
   would add on top (join reordering, choice of physical operators) moves costs that are already
   small at this size.

SQLite shows that being embedded is not the deciding factor: it is embedded and has a full query
planner and a bytecode IR (the VDBE), because the plan space of SQL is enormous. The deciding
factors are the size of the plan space and the statistics available.

## When an IR or optimizer would start to pay

- **Comma-separated patterns get large.** They are joined in source order today. Reordering them,
  or choosing a hash join over a nested loop, needs a plan to reorder.
- **Statistics exist.** Degree distributions and per-property selectivity would give a cost model
  something real to estimate.
- **A benchmark shows a bad plan.** The trigger should be a query that measurably scans more than
  it needs to, where the fix is a reordering or a different physical operator.

The IR would then sit between `runMatch` and `setupPattern`: a logical plan (`Scan`, `Expand`,
`Filter`, …) lowered to the physical `PlanStep`s, without touching the storage or the parser.
[Performance](performance) lists the known costs that point that way.

## The plan of a pattern

For one pattern, `setupPattern` walks the chain `[node, edge, node, …]` and fills in the
executor's `nodes`, `edges` and `steps`:

```zig
const Seek = struct { property: []const u8, value: Index };   // node.property = value

const PatternNode = struct {
    variable_name: []const u8,
    labels: []const []const u8,
    seeks: std.ArrayList(Seek),
    bound: bool,  // already bound by an earlier pattern or clause
    id: NodeId,   // the node matched on the current search branch
};

const PatternEdge = struct {
    edge_types: []const []const u8,  // empty: any type
    variable_length: bool, min_hops: u32, max_hops: ?u32,
    forward_direction: Direction, undirected: bool,
    variable_name: []const u8,
    bound: ?Relationship,
    seeks: std.ArrayList(Seek),
    matched: []const Relationship,   // the relationships of the current branch
};

const PlanStep = union(enum) {
    scan: struct { node: usize },                // enumerate candidates for a node
    expand: struct { from: usize, to: usize },   // follow an edge from a matched node
    edge_scan: struct { edge: usize },           // enumerate an edge from its property index
};
```

The seeks come from two places:

- inline property maps (`{name: 'Ana'}`);
- the `WHERE` clause. `collectWhereSeeks` walks its `AND` tree and pulls out every
  `variable.property = value` whose value is a literal or a parameter, which is constant for the
  whole query.

A pushed-down seek is still checked against each candidate, and the whole `WHERE` is still
evaluated at the end, so pushdown never changes a result: it only narrows the candidates.

A node is `bound` when an earlier pattern, or an earlier clause through `WITH`, already gave it a
value. This is how comma-separated patterns and clauses join: a bound node needs no scan, and is
only checked against the new pattern's labels and properties.

## Anchor selection

`estimate(node)` ranks a node by how many candidates it would produce:

- already bound: `0`, a free start;
- has an equality seek: `1`, a point lookup;
- unlabeled: the maximum, since it means scanning every node;
- otherwise: the count of its rarest label, **capped by the count of an incident edge type** (a
  pattern cannot produce more rows than there are edges of that type). Variable-length edges do
  not cap it.

`chooseAnchor` takes the minimum. `buildSteps` then lays out the traversal: scan the anchor (unless
it is bound), expand to the right end of the chain, then expand to the left end.

`shouldEdgeAnchor` handles a special case. When the pattern is a single fixed-length edge with a
property seek, and its two endpoints are unbound, unlabeled and have no seeks, the plan is one
`edge_scan` that starts from the edge-property index.

## How steps map to graph operations

Each `PlanStep` is one graph operation:

| Step | Graph operation (`graph.zig`) | Storage (see [storage](storage)) |
| --- | --- | --- |
| `scan` with a seek | `nodesByProperty(property, value)` | property-index prefix scan |
| `scan` with a label | `nodesWithLabel(label)`, then the other labels are checked | label-index prefix scan |
| `scan`, unlabeled | `allNodes()` | a walk of the `#nodes` records |
| `expand` | `neighbours(from, direction, type)` | edge prefix scan |
| `expand` to a bound node | `hasEdge` | edge point lookup |
| `expand` to a node with a selective seek | `nodesByProperty`, then `hasEdge` for each candidate | index seek and point lookups |
| `edge_scan` | `edgesByProperty(property, value)` | edge-property-index prefix scan |

The `expand` row with a seek covers patterns like `(a)-[:WORKS_IN]->(:Department {code: $code})`.
If the index gives at most `max_indexed_candidates` (8) nodes for the seek, checking an edge to each
is cheaper than scanning every neighbour of `a`.

The executor follows the Volcano model in spirit: iterators that are advanced with `next()` until
they are exhausted. Instead of `Open`/`Next`/`Close` objects, though, it is a recursive function,
`runStep`, that nests the loops directly:

```text
matchPatterns(i):                 # the i-th pattern of the MATCH
  if i == patterns.len: matchFound()     → WHERE, then keep a copy of the row
  setupPattern(patterns[i]); check the bound nodes; runStep(0)

runStep(s):
  if s == steps.len: bind the path variable, if any; matchPatterns(i + 1)
  scan      → for each candidate: check labels and seeks, bind, runStep(s + 1)
  expand    → for each neighbour: check type, labels, seeks, uniqueness, bind, runStep(s + 1)
  edge_scan → for each indexed edge: bind both ends, runStep(s + 1)
```

- **Bindings are undone by marks.** `bindings.mark()` before binding and `restore` on the way
  out, so a branch leaves no trace in its siblings.
- **Variable-length edges** (`*min..max`) expand depth-first in `expandVariableLength`. The walk
  keeps a trail of relationships, reports each end it reaches within the range, and never uses a
  relationship twice.
- **Relationship uniqueness.** `used_edges` holds the relationships matched so far in the `MATCH`.
  A relationship already in it is skipped (`edgeUsed`).
- **Iterators are scoped to the frame.** Each iterator lives in the `runStep` frame that opened
  it, which guarantees it is closed before its transaction ends.

## Nested matches

Some expressions contain patterns: pattern predicates, pattern comprehensions and `EXISTS { … }`.
`MERGE` matches its pattern too. All of them run through `clauses.nestedMatches(patterns, where,
row)`, which saves the state of the `MATCH` being run around it, matches the patterns starting from
`row`, and puts the state back. A nested match has its own relationship uniqueness.
`Executor.no_where` is the "no condition" sentinel for the cases that have no `WHERE`.

`MERGE` (`runMerge`) is a nested match of its whole pattern for each input row. If the pattern has
matches, each match becomes a row and gets `ON MATCH SET`. If not, `writes.createPattern` creates
the pattern's unbound nodes and its relationships, and binds their variables for `ON CREATE SET`.

## The clause pipeline

`Executor.run` runs a query as a pipeline. Each clause turns the rows (variable bindings) it
receives into the rows the next clause receives, starting from one empty row. The clauses are in
`clauses.zig` and `writes.zig`, and `WITH` and `RETURN` are in `projection.zig`:

```text
rows = [ {} ]
for clause in query:
  MATCH          → every row extended with each match of the patterns that passes WHERE
  OPTIONAL MATCH → the same, but a row without matches is kept, with the new variables null
  UNWIND l AS x  → one row per element of l
  WITH           → project or group, WHERE, DISTINCT, ORDER BY, SKIP, LIMIT
  CREATE, MERGE, SET, DELETE, REMOVE → applied to each row in turn; the rows go on
  RETURN         → project or group, DISTINCT, ORDER BY, SKIP, LIMIT → the result
```

- Each clause sees the effects of every clause before it: a `MATCH` after `CREATE … WITH` finds
  what was created. Within a writing clause, each row sees the writes made for the rows before it.
- A query that writes runs as above: each clause produces all its rows, in the query's arena,
  before the next starts. A writing clause must see the effect of the clauses before it on every
  row, and in this form it does.
- A read-only query streams instead (`pipeline.zig`). Each clause is a stage, and each row goes
  through the stages one at a time:
  - `MATCH` hands each match on as `matchFound` finds it, without copying it;
  - `UNWIND` binds each element in turn;
  - a `WITH` that only projects and filters passes each row on;
  - `RETURN` accumulates or projects each row.

  A `WITH` that groups, sorts, pages or removes duplicates keeps copies of its rows, and passes
  them on once the stages before it are done. A `RETURN` with a `LIMIT`, and no aggregate,
  `DISTINCT` or `ORDER BY`, stops the query once it has its rows: the internal error
  `LimitReached` unwinds the matching, and every iterator closes on the way out.
- A `UNION` runs its parts one after the other in the same transaction, then concatenates their
  rows, removing duplicates unless it is `UNION ALL`.

## Transactions, the read cache and the entity snapshot

`Executor.run` opens one transaction for the whole query: a write transaction if any clause writes,
otherwise a read transaction, which is a consistent snapshot.

- **The read cache** (`read_cache.zig`). In a read-only query a node's labels cannot change, so
  `ReadCache` keeps the answer to each label test made while matching. A pattern in which many
  rows reach the same few nodes (every member reaches their department) tests each node once.
  Queries that write run with the cache off. Properties are not cached; see
  [performance](performance).
- **The entity snapshot** (`entities.zig`). Rows hold references to nodes and relationships.
  Before the transaction ends, `EntitySnapshot.capture` reads the labels and properties of every
  entity the result mentions, so the caller can present whole entities as the query left them.

## Aggregation and grouping

A projection is split into **key** items, which are the implicit grouping keys, and **aggregate**
items. For each row, `accumulate` evaluates the keys and finds or creates the row's group in a
hashed `Grouping(Key, KeyContext)`, with expected O(1) time per row. It then updates the group's
`AggregateState`s. When the input ends, `aggregate` turns the groups back into rows. `WITH` uses
the same machinery, with `Binding`-valued keys, so a node variable passes through as a node.

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
