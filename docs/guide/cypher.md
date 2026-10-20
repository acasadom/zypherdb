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
| `SET` | `n.prop = v`; `n = map` (replace all properties); `n += map` (merge; a `null` entry removes); `n:Label` |
| `DELETE` / `DETACH DELETE` | delete nodes or relationships (detach also removes a node's edges) |
| `REMOVE` | remove a property (`n.prop`) or a label (`n:Label`) |
| `RETURN` | project the result (`DISTINCT`, `ORDER BY`, `SKIP`, `LIMIT`) |

Clauses chain in any number and order, as in openCypher: each sees the rows and effects of the
ones before it. After an updating clause, reading again (`MATCH`, `UNWIND`) needs a `WITH` in
between; `RETURN`, if present, comes last; a query ends with `RETURN` or an updating clause.

## Patterns

```text
(n:Label1:Label2 {prop: value, ...})            # a node (multiple labels allowed)
-[r:TYPE {prop: value, ...}]->                 # an outgoing typed edge
<-[r:TYPE]-   -[r]-   -->   --                  # incoming, either direction, untyped
-[:A|B]->                                       # one of several types
-[r:TYPE*1..3]->   -[*]->   -[*2]->   -[*..3]-> # variable length (min..max hops)
p = (a)-[:TYPE*]->(b)                           # a path variable
```

- A variable (`n`, `r`) is optional; an anonymous node or edge omits it.
- `TYPE` and `Label` are optional; an edge without a type matches any type.
- A variable-length edge matches paths of `min..max` edges (`*` alone: 1 or more; `*0..` includes
  the start node itself); its variable is the list of the path's relationships, in pattern order.
  Within one `MATCH` an edge is used at most once, so paths do not loop back over an edge.
- `p = …` binds the whole path; `length(p)`, `nodes(p)` and `relationships(p)` read it.
- A node may carry several labels; all of them must hold.
- `{…}` holds inline equality predicates, treated as index seeks.

## Expressions

Literals: integers (decimal, `0x…` hex, `0o…` octal), floats (`1.5`, `.5`, `1e3`, `2.5e-3`), strings (`'…'`), booleans (`true`/`false`),
`null`, lists (`[1, 2, 3]`) and maps (`{zone: 'Z1', floors: [1, 2]}`).

Any value takes the postfix operators `.key` (a node's or relationship's property, a map's entry),
`[index]` (a list element — negative indexes count from the end, out of range is `null` — or a map
entry by a string key) and `[from..to]` (a list slice; either end may be left out). A missing
property or entry reads as `null`.

| Operator | Meaning |
| --- | --- |
| `+`, `-`, `*`, `/`, `%`, unary `-` | arithmetic. Two integers give an integer (overflow and division by zero are errors; `/` truncates); a float operand gives a float (IEEE 754: `1.0 / 0` is `Infinity`). `+` also joins strings and lists |
| `^` | power, always a float; binds tighter than `*` and after a sign (`-2 ^ 2` is `4.0`) |
| `=`, `<>` | equality: numbers by value (`1 = 1.0`), NaN equals nothing, lists and maps element by element; values of different types are not equal |
| `<`, `>`, `<=`, `>=` | ordering of numbers, strings, booleans (`false < true`) and lists (lexicographic); other pairs give `null` |
| `AND`, `OR`, `NOT` | boolean logic (three-valued with null) |
| `x IS NULL`, `x IS NOT NULL` | null tests (always true or false, unlike `x = null`) |
| `STARTS WITH`, `ENDS WITH`, `CONTAINS` | string predicates |
| `IN` | list membership, with any list expression on the right (`x IN $allowed`); null-aware |
| `$name` | a query parameter, passed with the query (see the Python and C ABI guides) |
| `CASE WHEN cond THEN v … [ELSE v] END` | conditional expression (no `ELSE` → `null`) |
| `[x IN list WHERE pred \| expr]` | list comprehension (the `WHERE` and the `\| expr` are optional) |
| `any` / `all` / `none` / `single(x IN list WHERE pred)` | quantifiers, three-valued with null |
| `name(arguments…)` | a function call (below); names are case-insensitive |

## Functions

Unless noted, a function returns `null` for a `null` argument. Text functions count Unicode code
points (`size('é')` is 1); `toUpper`/`toLower` change ASCII letters only.

| Group | Functions |
| --- | --- |
| Lists, strings | `size`, `head`, `last`, `tail`, `reverse`, `range(start, end[, step])` |
| Null handling | `coalesce(x, …)` — the first non-null argument |
| Paths | `length(path)`, `nodes(path)`, `relationships(path)` |
| Graph and maps | `id(node)`, `labels(node)`, `type(relationship)`, `keys(entity or map)`, `properties(entity)` (a map), `startNode(r)`, `endNode(r)` |
| Conversions | `toString`, `toInteger` (truncates a float; null for a string that is not a number), `toFloat`, `toBoolean` |
| Strings | `toLower`, `toUpper`, `trim`, `lTrim`, `rTrim`, `replace(text, search, replacement)`, `substring(text, start[, length])`, `split(text, delimiter)` |
| Numbers | `abs`, `sign`, `round` (halves up), `floor`, `ceil`, `sqrt`, `exp`, `log`, `log10`, `sin`, `cos`, `tan`, `cot`, `asin`, `acos`, `atan`, `atan2`, `degrees`, `radians`, `haversin`, `pi()`, `e()`, `rand()` |

An unknown function or a wrong number of arguments fails before the query runs. `id()` of a
relationship is an error: acmedb identifies a relationship by (source, target, type).

## Aggregations

`count(x)` (and `count(*)`), `sum(x)` (an integer unless a float is summed), `avg(x)`, `min(x)`,
`max(x)`, `stDev(x)` / `stDevP(x)` (sample / population standard deviation) and `collect(x)` (a
list). Any projected
expression without an aggregate is an implicit grouping key; aggregations skip nulls, and
`count(*)` counts all rows.

Aggregates may sit anywhere in an expression: `count(*) + 1`, `sum(n.x) * 100 / count(*)`. Outside
its aggregates such an expression may use only constants, parameters and *simple* grouping keys (a
variable or a property that is itself projected), as openCypher requires. `ORDER BY` may combine
the projection's names with aggregates the projection computes (`ORDER BY age + count(x)`). A
`WITH` without aggregates keeps every row (it does not group).

## Types

The runtime values are `int` (64-bit), `float` (64-bit IEEE 754), `str`, `boolean`, `null`, `list`, `map`, whole nodes and
relationships (`RETURN n`), paths, and the temporal types (below). Nulls come from `OPTIONAL MATCH`, missing properties and `CASE` without
`ELSE`; they propagate: a comparison or string predicate with a null operand is null, a null
`WHERE` filters the row out, and aggregations skip nulls. Properties stored in the graph are
`int`, `float`, `str`, `boolean`, temporal values, and lists of one of those types (`[1, 2.5]`,
`['a', 'b']`; not mixed lists or maps); setting a property to `null` removes it.

## Temporal values

| Type | Example | Built by |
| --- | --- | --- |
| `Date` | `2024-07-02` | `date(…)` |
| `LocalTime` | `09:30:00.5` | `localtime(…)` |
| `Time` | `09:30+02:00` | `time(…)` |
| `LocalDateTime` | `2024-07-02T09:30` | `localdatetime(…)` |
| `DateTime` | `2024-07-02T09:30+02:00[Europe/Madrid]` | `datetime(…)` |
| `Duration` | `P1M2DT3H` | `duration(…)` |

Each constructor takes an ISO 8601 string (`date('2015-W30-2')`, `time('214032-0100')`), a map of
fields (`date({year: 1984, week: 10, dayOfWeek: 3})`, `datetime({date: d, hour: 12, timezone:
'Europe/Stockholm'})`), another temporal value, or nothing (the current time, fixed for the
statement; `.realtime()` reads the clock). Precision is the nanosecond; years range over
±999,999,999. The default time zone is UTC. Named zones (`Europe/Madrid`) come from the system's
time zone database (`/usr/share/zoneinfo`).

- Components: `d.year`, `d.month`, `d.week`, `d.dayOfWeek`, `d.hour`, `d.nanosecond`,
  `d.timezone`, `d.offsetMinutes`, `d.epochSeconds`, …; on a duration `dur.days`, `dur.hours`,
  `dur.minutesOfHour`, ….
- Arithmetic: a temporal value `±` a duration (months and days on the calendar, the time part on
  the clock: `date('2020-01-31') + duration('P1M')` is `2020-02-29`); durations add, subtract,
  and scale by numbers.
- `duration.between(a, b)` (and `duration.inMonths`, `inDays`, `inSeconds`);
  `date.truncate('month', d)` and the other `.truncate` functions; `datetime.fromepoch(s, ns)`,
  `datetime.fromepochmillis(ms)`.
- Comparison: values of one type compare in time (date-times and times by instant); durations
  compare only for equality.

