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

Literals: integers, strings (`'…'`), booleans (`true`/`false`), `null`, and lists (`[1, 2, 3]`).
Property access is `n.prop` (node) or `r.prop` (relationship); a property the entity does not have
reads as `null`.

| Operator | Meaning |
| --- | --- |
| `=`, `<>`, `<`, `>`, `<=`, `>=` | comparison |
| `AND`, `OR`, `NOT` | boolean logic (three-valued with null) |
| `STARTS WITH`, `ENDS WITH`, `CONTAINS` | string predicates |
| `IN` | list membership, with any list expression on the right (`x IN $allowed`); null-aware |
| `$name` | a query parameter, passed with the query (see the Python and C ABI guides) |
| `CASE WHEN cond THEN v … [ELSE v] END` | conditional expression (no `ELSE` → `null`) |
| `name(arguments…)` | a function call (below); names are case-insensitive |

## Functions

Unless noted, a function returns `null` for a `null` argument. Text functions count Unicode code
points (`size('é')` is 1); `toUpper`/`toLower` change ASCII letters only.

| Group | Functions |
| --- | --- |
| Lists, strings | `size`, `head`, `last`, `tail`, `reverse`, `range(start, end[, step])` |
| Null handling | `coalesce(x, …)` — the first non-null argument |
| Graph | `id(node)`, `labels(node)`, `type(relationship)`, `keys(entity)`, `startNode(r)`, `endNode(r)` |
| Conversions | `toString`, `toInteger` (null for a string that is not an integer), `toBoolean` |
| Strings | `toLower`, `toUpper`, `trim`, `lTrim`, `rTrim`, `replace(text, search, replacement)`, `substring(text, start[, length])`, `split(text, delimiter)` |
| Numbers | `abs`, `sign` |

An unknown function or a wrong number of arguments fails before the query runs. `id()` of a
relationship is an error: acmedb identifies a relationship by (source, target, type).

## Aggregations

`count(x)` (and `count(*)`), `sum(x)`, `min(x)`, `max(x)`, and `collect(x)` (a list). Any non-
aggregated projected expression is an implicit grouping key; aggregations skip nulls, and
`count(*)` counts all rows.

## Types

The runtime values are `int` (64-bit), `str`, `boolean`, `null`, `list`, and whole nodes and
relationships (`RETURN n`). Nulls come from `OPTIONAL MATCH`, missing properties and `CASE` without
`ELSE`; they propagate: a comparison or string predicate with a null operand is null, a null
`WHERE` filters the row out, and aggregations skip nulls. Properties stored in the graph are
`int`, `str` or `boolean`; setting a property to `null` removes it.

## Notes on the subset

- `avg`, arithmetic, and a `WHERE` *outside* an `OPTIONAL MATCH` (post-join filter) are not yet
  supported — filter with a `WITH … WHERE` step.
- `UNWIND` after `WITH` (unwinding a `collect`ed list) is deferred; project the list and `size`
  it, or `WITH collect(…) AS l` and iterate client-side.
