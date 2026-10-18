# The openCypher subset

acmedb speaks a **subset of openCypher**. Keywords are case-insensitive; identifiers are
case-sensitive. Strings use single quotes. This page is the reference; the
[tutorial](../tutorial/01-getting-started) introduces each feature by example.

## Clauses

A query is a sequence of clauses:

```text
MATCH …  [OPTIONAL MATCH …]  [UNWIND …]  [WITH …]  [MATCH …]  [writes …]  RETURN …
```

| Clause | Purpose |
| --- | --- |
| `MATCH` | bind variables to patterns; comma-separated patterns are joined |
| `OPTIONAL MATCH` | like `MATCH`, but unmatched variables become `null` (outer join) |
| `UNWIND` | one row per element of a list |
| `WITH` | project/aggregate the rows, then continue the pipeline (with `WHERE`, `ORDER BY`, `SKIP`, `LIMIT`) |
| `CREATE` | create nodes and edges |
| `MERGE` | create-or-match, with `ON CREATE SET` / `ON MATCH SET` |
| `SET` | set a property |
| `DELETE` / `DETACH DELETE` | delete nodes (detach also removes their edges) |
| `REMOVE` | remove a property (`n.prop`) or a label (`n:Label`) |
| `RETURN` | project the result (`DISTINCT`, `ORDER BY`, `SKIP`, `LIMIT`) |

At most one `MATCH` before and one after `WITH` is supported, and at most one each of `OPTIONAL
MATCH`, `UNWIND` and `WITH`.

## Patterns

```text
(n:Label1:Label2 {prop: value, ...})            # a node (multiple labels allowed)
-[r:TYPE {prop: value, ...}]->                 # an outgoing typed edge
<-[r:TYPE]-                                     # an incoming typed edge
```

- A variable (`n`, `r`) is optional; an anonymous node or edge omits it.
- `TYPE` and `Label` are optional; an edge without a type matches any type.
- A node may carry several labels; all of them must hold.
- `{…}` holds inline equality predicates, treated as index seeks.

## Expressions

Literals: integers, strings (`'…'`), booleans (`true`/`false`), and lists (`[1, 2, 3]`). Property
access is `n.prop` (node) or `r.prop` (relationship).

| Operator | Meaning |
| --- | --- |
| `=`, `<>`, `<`, `>`, `<=`, `>=` | comparison |
| `AND`, `OR`, `NOT` | boolean logic (three-valued with null) |
| `STARTS WITH`, `ENDS WITH`, `CONTAINS` | string predicates |
| `IN [...]` | list membership |
| `CASE WHEN cond THEN v … [ELSE v] END` | conditional expression (no `ELSE` → `null`) |
| `size(x)` | length of a list, or of a string |

## Aggregations

`count(x)` (and `count(*)`), `sum(x)`, `min(x)`, `max(x)`, and `collect(x)` (a list). Any non-
aggregated projected expression is an implicit grouping key; aggregations skip nulls, and
`count(*)` counts all rows.

## Types

The runtime values are `int` (64-bit), `str`, `boolean`, `null`, and `list`. Nulls come from
`OPTIONAL MATCH` (and `CASE` without `ELSE`); they propagate: a comparison or string predicate
with a null operand is null, a null `WHERE` filters the row out, and aggregations skip nulls.
Properties stored in the graph are always `int` or `str`.

## Notes on the subset

- `ORDER BY` and `LIMIT` after an aggregation are not applied to the aggregated result; order an
  aggregated query with a `WITH` step instead.
- `avg`, arithmetic, and a `WHERE` *outside* an `OPTIONAL MATCH` (post-join filter) are not yet
  supported — filter with a `WITH … WHERE` step.
- `UNWIND` after `WITH` (unwinding a `collect`ed list) is deferred; project the list and `size`
  it, or `WITH collect(…) AS l` and iterate client-side.
