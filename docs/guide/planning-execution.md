# Planning & execution

How a query is turned into work, and how that work runs. Everything here is `src/execution/`.
This is the page to read before changing the planner or adding an operator.

## There is no IR (and why that's fine — for now)

The executor goes **directly from the AST to a plan**; there is no intermediate language, no
rewriting pass, no cost-based optimizer. The plan is a handful of structs built inline in
`setupPattern`, and the "optimizations" are two, both applied at that point:

1. **anchor selection** — pick the cheapest place to start a pattern;
2. **predicate pushdown** — turn equality predicates into index seeks before the scan runs.

Why no IR *yet* — three reasons, and none of them is "because it's embedded":

1. **The plan space is tiny.** The subset is single-node patterns, chains, and comma-separated
   patterns joined in source order. There are two interesting decisions — which node to anchor on,
   and the join order across patterns (currently fixed, source order) — and `chooseAnchor` already
   makes the first. An optimizer has almost nothing to reorder.
2. **A cost model has nothing to estimate with.** A cost-based optimizer needs statistics
   (cardinality, selectivity, degree distributions); acmedb has only label counts and an edge-type
   counter. An IR on top of no statistics would be *guessing*, not optimizing.
3. **The dominant cost is already decided.** In a graph DB the dominant cost is I/O — following
   edges and scanning indexes — and that is fixed by index-free adjacency + anchor selection. What
   an optimizer would *add* (join reordering, physical-operator choice) moves cost that is already
   small at this surface.

The deployment shape is a red herring. **SQLite is embedded and has a full query planner and a
bytecode IR** (the VDBE), because SQL's plan space is enormous — join order, subqueries, per-table
index choice — so it *must* optimize. acmedb's language has no such space. The real axes are
**query surface** and **statistics**, not "embedded vs server".

## When an IR / optimizer would start to pay

- **The language grows.** Variable-length paths (`-[:TYPE*1..5]->`), more join types, subqueries,
  or `UNION` would expand the plan space to the point where reordering matters.
- **Statistics exist.** Degree distributions and per-property selectivity would give a cost model
  something real to estimate; without them an optimizer is a heuristic with more steps.
- **A benchmark shows a bad plan.** The trigger to build it is a query that scans measurably more
  than it should, where the fix is reordering joins or switching physical operators — not a hunch.
- **The replication layer lands.** Replication changes who writes and who reads, not how one query
  is planned: the planner is per-query and orthogonal to it. But a larger, more varied workload
  (replicas serving many query shapes) raises the value of statistics-driven planning.

When any of those happens, the IR would slot in between `run` and `setupPattern` — a logical-plan
layer (`Scan`/`Expand`/`Filter`/…) lowered to the physical `PlanStep`s — without touching the
storage or the parser.

## The plan

For one `MATCH` pattern, `setupPattern` walks the chain `[node, edge, node, …]` and produces:

```zig
const Seek = struct { prop: []const u8, value: Index };          // var.prop = literal

const PatternNode = struct { variable_name: []const u8, labels: []const []const u8,
                           seeks: std.ArrayList(Seek), bound: bool };
const PatternEdge = struct { edge_type: []const u8, forward_direction: Direction, variable_name: []const u8,
                           seeks: std.ArrayList(Seek) };

const PlanStep = union(enum) {
    scan:      struct { node: usize },                 // enumerate a node (label or property index)
    expand:    struct { from: usize, to: usize },      // walk an edge from a bound node
    edge_scan: struct { edge: usize },                 // enumerate an edge (edge-property index)
};
```

`PatternNode.seeks` and `PatternEdge.seeks` come from two places: inline `{prop: value}` maps, and
`WHERE` equality predicates (`collectWhereSeeks` walks the `AND` tree and pulls out every
`var.prop = literal`). A node is `bound` if an earlier pattern already gave it a value — the join
mechanism for comma-separated patterns and for `WITH`.

## Anchor selection

`estimate(node)` ranks a node by how many rows it will contribute:

- already bound → `0` (a free start, no scan needed);
- has an equality seek → `1` (a point lookup);
- unlabelled → `∞` (can't be scanned — there is no "all nodes" index);
- otherwise → its smallest label count, **capped by the rarest incident edge type** (you can't
  produce more rows than there are edges of that type).

`chooseAnchor` takes the minimum, and `buildSteps` lays out the traversal: scan the anchor (if it
isn't bound), then expand right, then expand left — a bidirectional walk from the cheapest node.

`shouldEdgeAnchor` is a special case: if the pattern is a *single* edge whose only selectivity is an
inline property seek, and both endpoints are unbound and unselective, the plan is a single
`edge_scan` step that starts from the edge-property index instead of a node.

## How steps map to graph operations

Each `PlanStep` is one graph operation. This is the "volcano translation" — the pattern is not a
tree of join operators but a flat list of steps, and the recursion **is** the operator tree:

| Step | Graph operation (`graph.zig`) | Storage (see [storage](storage)) |
| --- | --- | --- |
| `scan` (with seeks) | `nodesByProperty(prop, value)` | property-index prefix scan |
| `scan` (label) | `nodesWithLabel(label)` then `hasAllLabels` | label-index prefix scan |
| `expand` (unbound neighbour) | `neighbours(from, direction, type)` | edge prefix scan |
| `expand` (bound neighbour) | `hasEdge` (verify) | edge point lookup |
| `edge_scan` | `edgesByProperty(prop, value)` | edge-property-index prefix scan |

The executor is Volcano-shaped in spirit — iterators (`PrefixIterator` / `NodeIdIterator` /
`EdgeIterator`) that you `next()` until exhausted — but instead of explicit `Open`/`Next`/`Close`
objects it is a recursive function, `runStep`, that nests the loops directly:

```text
runStep(step):
  if step == steps.len:  → next pattern, then matchFound()
  scan    → scanNodes: for each candidate id (skip if !hasAllLabels / !nodeSeeksMatch): recurse(step+1)
  expand  → expandEdge: for each neighbour id (skip if !labels / !nodeSeeksMatch / !edgeSeeksMatch): recurse(step+1)
  edge_scan → scanEdgeIndex: for each (src,dst) (skip if type mismatch / !seeks): bind both endpoints, recurse(step+1)
```

Predicates are checked **as early as possible**: the inline seeks became the scan's own lookup, and
the remaining `WHERE` is checked once the pattern has matched (`matchFound`).

## The clause pipeline

`Executor.run` runs a query as a pipeline: each clause turns the rows (variable bindings) it
receives into the rows the next clause receives, starting from one empty row. The clauses are in
`clauses.zig` (reading and writing) and `projection.zig` (WITH, RETURN):

```text
rows = [ {} ]
for clause in query:
  MATCH          → every row extended with each match of the patterns that passes WHERE
  OPTIONAL MATCH → the same, keeping an unmatched row with the clause's new variables = null
  UNWIND l AS x  → one row per element of l (null: none)
  WITH           → project / group / filter / DISTINCT / ORDER BY / SKIP / LIMIT
  CREATE, MERGE, SET, DELETE, REMOVE → applied to each row in turn; the rows go on
  RETURN         → project (or group), DISTINCT, ORDER BY, SKIP, LIMIT → the result
```

- Each clause sees the effects of every clause before it (a MATCH after `CREATE … WITH` finds what
  was created); within a write clause, a row sees the writes made for the rows before it.
- Pattern matching (`pattern_matching.zig`) reports each complete match to `Executor.matchFound`,
  which applies the WHERE and keeps a copy of the row. Relationship uniqueness holds within one
  MATCH; OPTIONAL MATCH is a clause of its own.
- The rows are materialized between clauses, in the query's arena: simple and correct, at the
  cost of memory proportional to the largest intermediate result.

## Aggregation and grouping

The projection is split into `key` items (implicit grouping keys) and `aggregate` items.
`accumulate` evaluates each row's keys and finds-or-creates its group in a hashed
`Grouping(Key, KeyContext)` (keys + one `AggregateState` per aggregate; expected O(1) per row), and
updates the state; `aggregate` then turns groups back into rows. `WITH` uses the same machinery but
with `Binding`-valued keys (so a bare node variable passes through as a node, not a scalar).

`AggregateState` is the running reduction: `count`/`sum`/`min`/`max` accumulate scalars, `collect` appends
to an arena list. Nulls are skipped by every aggregate except `count(*)`, which counts all rows.

## Nulls

Nulls exist because of `OPTIONAL MATCH` (and `CASE` without `ELSE`). The rule is **propagation**:

- a property access on null is null; a comparison or string predicate with a null operand is null;
- `AND`/`OR`/`NOT` are three-valued (`false AND null` is `false`, `true AND null` is `null`);
- a null `WHERE` filters the row out;
- aggregations skip nulls.

This is implemented by `Value.null` plus `isNull` guards in `applyBinaryOperator`/`applyUnaryOperator`/`evaluate` and the
`evalBool` → `false` rule — see `execution/`.
