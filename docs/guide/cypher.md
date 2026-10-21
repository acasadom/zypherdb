# Cypher reference

acmedb speaks **openCypher**, the query language of graph databases. It adds a few extensions and
leaves out a few features; both are listed below. This page is the complete reference, and the
[tutorial](../tutorial/01-getting-started) introduces each feature by example.

## Lexical structure

- **Keywords** are case-insensitive: `MATCH` and `match` are the same keyword. **Identifiers** are
  case-sensitive; that covers variables, labels, relationship types and property names. Write an
  identifier that has spaces or symbols between backticks: `` (`my node`:`Floor 3`) ``.
- **Strings** use single or double quotes (`'Ana'`, `"Ana"`), with backslash escapes: `\'`, `\"`,
  `\\`, `\n`, `\t`, `\r`, `\b`, `\f`, and `\uXXXX` or `\UXXXXXXXX` for a code point. A malformed
  escape is a syntax error.
- **Numbers**:
  - integers in decimal, hexadecimal (`0x1F`) or octal (`0o17`);
  - floats (`1.5`, `.5`, `1e3`, `2.5e-3`).
- **Comments**: `// to the end of the line` and `/* … */`.
- **Parameters**: `$name` is a value passed with the query (in Python,
  `db.query(text, name=value)`). A parameter is always a value; it cannot stand for a label, a type
  or a property name.

## Clauses

A query is a pipeline of clauses. Each clause receives the rows of the clause before it and passes
its own rows on; the first clause receives one empty row.

| Clause | What it does |
| --- | --- |
| `MATCH pattern, … [WHERE condition]` | extends each row with every match of the patterns that passes the condition; comma-separated patterns are matched together |
| `OPTIONAL MATCH …` | like `MATCH`, but keeps a row that has no match, with its new variables set to `null` (an outer join) |
| `UNWIND list AS x` | produces one row per element of the list (no row for an empty list or `null`) |
| `CALL procedure(arguments) [YIELD column [AS name], … \| *] [WHERE condition]` | runs a [procedure](#procedures) for each row; each row it returns extends the row with the yielded columns |
| `FOREACH (x IN list \| clause …)` | runs the updating clauses (`CREATE`, `MERGE`, `SET`, `DELETE`, `REMOVE`, `FOREACH`) once per element, with `x` bound to it; `null` has no element. The rows go on unchanged, and what the clauses bind stays inside |
| `CALL { query }`, `CALL (a, b) { query }` | runs the subquery for each row, in turn (a row sees what the subquery wrote for the rows before it). It sees the row's variables only if it imports them: a first `WITH a, b` (or `WITH *`), which `CALL (a, b)` / `CALL (*)` write for you. Each row its `RETURN` returns extends the row with the returned columns, which must be named (`AS`) and new; a subquery without `RETURN` (one that writes) keeps the row once. `IN TRANSACTIONS` and `UNION` inside are not supported |
| `WITH items [ORDER BY …] [SKIP n] [LIMIT n] [WHERE condition]` | projects the rows like `RETURN` (aggregating, sorting, paging) and continues; only the projected names remain |
| `CREATE pattern, …` | creates the nodes and relationships of the pattern; a node already bound is reused as it is, and `CREATE p = …` binds the path created |
| `MERGE pattern [ON CREATE SET …] [ON MATCH SET …]` | matches the whole pattern, and each match becomes a row (with `ON MATCH SET` applied); if nothing matches, creates the whole pattern (with `ON CREATE SET` applied) |
| `SET item, …` | `n.prop = v` sets one property; `n = map` replaces all properties; `n += map` adds and changes properties (a `null` entry removes one); `n:Label` adds labels. The target may be any expression that gives a node or relationship (`SET (CASE WHEN … THEN a ELSE b END).prop = v`); a `null` target does nothing |
| `REMOVE item, …` | removes a property (`n.prop`) or labels (`n:Label:Other`) |
| `DELETE x, …` / `DETACH DELETE x, …` | deletes nodes, relationships and paths, given by any expression (`DELETE paths[0]`; `null` is ignored). It deletes every relationship it is given before any node, and deleting a node that still has relationships needs `DETACH`, which deletes those relationships too |
| `RETURN [DISTINCT] items [ORDER BY …] [SKIP n] [LIMIT n]` | produces the result of the query |
| `query UNION query`, `query UNION ALL query` | combines the rows of both parts (`UNION` drops duplicates, `UNION ALL` keeps them); both parts return the same column names |

- Clauses chain in any number and order, with these rules:
  - after a writing clause, a `WITH` must come before reading again (`MATCH`, `UNWIND`, `CALL`);
  - `RETURN` comes last;
  - a query ends with `RETURN` or with a writing clause;
  - a `CALL` without `YIELD` (or with `YIELD *`) ends the query, and its rows are the result. So
    does a `CALL … YIELD` that is the whole query. Inside a longer query, a `CALL` names the
    columns it uses with `YIELD`.
- `RETURN *` and `WITH *` project every variable in scope, in name order; more items may follow
  (`RETURN *, n.name AS name`).
- The `WHERE` of a `WITH` filters the projected rows before `DISTINCT`, `ORDER BY`, `SKIP` and
  `LIMIT` apply. When the `WITH` does not aggregate, its `WHERE` can also use the variables from
  before the `WITH`.
- `ORDER BY x [ASC | ASCENDING | DESC | DESCENDING], …` sorts the rows, ascending by default.
  Ascending order puts `null`s last. `SKIP` and `LIMIT` take an integer expression or a parameter.
- `ORDER BY` uses the projected names, and, when the projection neither aggregates nor is
  `DISTINCT`, the variables from before it too. A part of an `ORDER BY` expression that repeats a
  projected expression reads its column: `WITH a.name AS name, count(*) AS c ORDER BY a.name` sorts
  by `name`.
- A query is checked before it runs. It fails with an error, and changes nothing, when it:
  - uses a variable that is not defined;
  - `CREATE`s or `MERGE`s a bound node alone or with new labels or properties, or a bound
    relationship;
  - `MERGE`s a relationship without exactly one type;
  - aggregates in a `WHERE` or in a procedure's arguments;
  - names two columns of one projection alike, or two `YIELD` columns alike;
  - after `DISTINCT`, sorts by something that is not projected.
- A whole query is one transaction, `UNION` included: either all of its writes are kept or none
  are.

## Patterns

```text
(n:Label1:Label2 {prop: value, …})                 a node: variable, labels, property equalities
-[r:TYPE {prop: value, …}]->   <-[r:TYPE]-   -[r]-  a relationship: outgoing, incoming, either way
-->   <--   --                                     anonymous relationships
-[:A|B]->                                          one of several types
-[*]->  -[*2]->  -[*1..3]->  -[*..3]->  -[*0..]->  variable length: 1+, exactly 2, 1 to 3, up to 3, 0+
path = (a)-[:TYPE*]->(b)                           a path variable
path = shortestPath((a)-[:TYPE*]-(b))              only a shortest path between a and b
path = allShortestPaths((a)-[*..10]->(b))          every shortest path between them
```

- Every part is optional: `()` is a node with no variable, label or properties, and a relationship
  without a type matches any type.
- A node with several labels must have all of them.
- `{prop: value}` is an equality test on the property. When the value is a constant or a
  parameter, acmedb answers it with an index seek.
- A variable-length relationship binds its variable to the list of the path's relationships, in
  pattern order. `*0..` includes the start node itself.
- Within one `MATCH`, each relationship is used at most once, so a path never goes back over the
  same relationship.
- Each relationship has an id of its own (`id(r)`), so two nodes may be joined by several
  relationships of one type (parallel ones), each matched, changed and deleted on its own.
- `shortestPath` and `allShortestPaths` take a pattern of one variable-length relationship
  (`*`, `*..n`, or `*0..` to include the start). For each pair of end nodes they keep one
  shortest path, or every path of the shortest length; an unbound end gets a path to each node
  reached. When the `WHERE` reads the path (its variable, or the relationship list), the result
  is the shortest path the `WHERE` keeps: paths are then tried by increasing length, which
  explores every path up to that length (bound it with `*..n` on large graphs). Otherwise a
  breadth-first search finds them, in time proportional to the part of the graph it reaches.

## Expressions

### Values and access

The literals are:

- numbers;
- strings;
- `true`, `false` and `null`;
- lists, such as `[1, 'a', [2]]`;
- maps, such as `{name: 'Ana', floors: [1, 2]}`.

| Form | Meaning |
| --- | --- |
| `x.key` | a property of a node or relationship, or an entry of a map; `null` if missing |
| `x[i]` | a list element (a negative index counts from the end, an index out of range gives `null`), or a map entry by a string key |
| `x[from..to]` | a list slice; either end may be left out, and negative values count from the end; a `null` end gives `null` |
| `n:Label`, `n:A:B` | true if the node has every label (`null` for `null`) |
| `n {.name, .*, key: expression, variable}` | a map projection: the map built from the selectors, in order — a property (`.name`, `null` if missing), every property (`.*`), a computed entry, or a variable under its own name. It works on nodes, relationships and maps; on `null` it gives `null` |

### Operators, by precedence (tightest first)

| Operators | Meaning |
| --- | --- |
| `.key`, `[…]` | access (see above) |
| unary `-`, `+` | sign |
| `^` | power; the result is always a float (`-2 ^ 2` is `4.0`) |
| `*`, `/`, `%` | arithmetic. Two integers give an integer: `/` truncates, and overflow or division by zero is an error. With a float operand the result is a float, following IEEE 754 (`1.0 / 0` is infinity) |
| `+`, `-` | arithmetic. `+` also joins strings (`'a' + 1` is `'a1'`), joins lists, and appends an element to a list. A temporal value `±` a duration gives a temporal value |
| `IS NULL`, `IS NOT NULL`, `STARTS WITH`, `ENDS WITH`, `CONTAINS`, `IN` | tests; `IN` is list membership and handles `null` |
| `text =~ pattern` | true if the **whole** string matches the regular expression (Java's syntax, as in Neo4j); `null` if either side is `null` or not a string. Supported: classes, `\d \w \s` and their negations, `^ $ \b`, groups, `\|`, quantifiers (greedy, lazy, possessive), `\Q…\E`, and the flags `(?i)` (case-insensitive, with Unicode's case folding) and `(?s)`. Not supported (an error): backreferences, lookahead and lookbehind. Matching takes time proportional to the text times the pattern, never more |
| `=`, `<>`, `<`, `<=`, `>`, `>=` | comparison; comparisons chain, so `a < b <= c` means `a < b AND b <= c` |
| `NOT` | |
| `AND` | |
| `XOR` | |
| `OR` | |

- **Equality**:
  - numbers compare by value (`1 = 1.0`);
  - `NaN` equals nothing;
  - lists and maps compare element by element;
  - values of different types are never equal.
- **Ordering** (`<` and the others) is defined between:
  - numbers;
  - strings, by code point;
  - booleans (`false < true`);
  - lists, element by element;
  - temporal values of the same type. Date-times and times compare by the instant they denote.

  Ordering any other pair of values gives `null`.
- **`null`** means unknown. An operator with a `null` operand gives `null`, so `null = null` is
  `null`. The exceptions are `IS NULL`, and `AND`/`OR` when the other operand decides the result
  (`false AND null` is `false`). `WHERE` keeps a row only when its condition is `true`.

### Conditionals, comprehensions and subqueries

| Form | Meaning |
| --- | --- |
| `CASE WHEN cond THEN v … [ELSE v] END` | the value of the first branch whose condition is true (`null` if none is and there is no `ELSE`) |
| `CASE x WHEN a THEN v … [ELSE v] END` | the value of the first branch whose value equals `x` |
| `[x IN list WHERE cond \| expr]` | list comprehension (`WHERE` and `\| expr` are optional) |
| `any`, `all`, `none`, `single(x IN list WHERE cond)` | quantifiers, three-valued when `null` is involved |
| `[path = (a)-->(b) WHERE cond \| expr]` | pattern comprehension: `expr` for each match of the pattern |
| `(a)-[:T]->(b)` in a `WHERE` | pattern predicate: true if the pattern has a match; it cannot bind new variables |
| `EXISTS { pattern [WHERE cond] }`, `EXISTS { query }` | true if the pattern has a match, or the subquery a row. The subquery is any query that only reads (`MATCH`, `OPTIONAL MATCH`, `UNWIND`, `WITH`, `CALL`, `RETURN`), run from the current row: it sees the variables in scope, and what it binds or aggregates stays inside it. A `RETURN count(*)` always has a row |
| `COUNT { pattern [WHERE cond] }`, `COUNT { query }` | the number of matches of the pattern, or of rows of the subquery (the same forms as `EXISTS`); an integer per row, not an aggregate |
| `$name` | a parameter |

## Functions

Function names are case-insensitive. A function returns `null` when given a `null` argument,
unless noted otherwise. Calling an unknown function, or passing the wrong number of arguments, fails
before the query runs.

| Group | Functions |
| --- | --- |
| Lists | `size(list)`, `head`, `last`, `tail`, `reverse`, `range(start, end[, step])`, `keys(map or entity)` |
| Strings | `size(text)` (counts code points), `toLower`, `toUpper` (full Unicode case mappings: `toUpper('straße')` is `'STRASSE'`), `trim`, `lTrim`, `rTrim`, `replace(text, search, replacement)`, `substring(text, start[, length])`, `split(text, delimiter)`, `reverse` |
| Conversion | `toString`, `toInteger` (truncates a float; `null` for a string that is not a number), `toFloat`, `toBoolean` |
| Numbers | `abs`, `sign`, `round` (a float; halves round up), `floor`, `ceil`, `sqrt`, `exp`, `log`, `log10`, `sin`, `cos`, `tan`, `cot`, `asin`, `acos`, `atan`, `atan2`, `degrees`, `radians`, `haversin`, `pi()`, `e()`, `rand()` |
| Null | `coalesce(x, …)` returns the first argument that is not `null`; `exists(n.property)` is true if the property is set (the same as `n.property IS NOT NULL`; its argument must be a property) |
| Graph | `id(entity)`, `labels(node)`, `type(relationship)`, `properties(entity)` (a map), `startNode(r)`, `endNode(r)` |
| Paths | `length(path)`, `nodes(path)`, `relationships(path)` |
| Temporal | see [Temporal values](#temporal-values) |

Nodes and relationships have ids of their own, each counted from 0: a node and a relationship may
have the same `id()`.

## Aggregation

The aggregates are:

- `count(x)` and `count(*)`;
- `sum(x)`, an integer unless a float is summed;
- `avg(x)`, `min(x)`, `max(x)`;
- `collect(x)`, which builds a list;
- `stDev(x)` and `stDevP(x)`, the sample and population standard deviation;
- `percentileDisc(x, p)` and `percentileCont(x, p)`, the percentile `p` (between 0 and 1) of the
  numbers: the nearest value, or one interpolated between the two nearest.

Each aggregate accepts `DISTINCT` to use each value only once: `count(DISTINCT x)`.

- In `RETURN` or `WITH`, every item that has no aggregate is a **grouping key**, and the result has
  one row per distinct combination of keys. Without keys, all rows form one group. An empty input
  still gives that one row: `count` is 0, `sum` is 0, and the other aggregates give `null` or `[]`.
- Aggregates skip `null` values; `count(*)` counts rows.
- An aggregate can appear inside an expression (`count(*) + 1`, `sum(x) * 100 / count(*)`). Outside
  its aggregates, such an expression may only use constants, parameters, and grouping keys that are
  themselves projected.
- `ORDER BY` may use the names the projection defines and the aggregates it computes.

## Values and properties

The value types are:

- `null`, booleans, integers (64-bit), floats (64-bit) and strings (UTF-8);
- lists and maps;
- nodes, relationships and paths;
- the six temporal types.

A **property** of a node or relationship may hold:

- a boolean, number, string or temporal value;
- a list whose elements share one of those types (integers and floats count as one type);
- a map.

Setting a property to `null` removes it.

**Documents** (maps stored as properties) are an acmedb extension, since openCypher does not store
maps. A document may nest maps and lists of any values, `null`s included, but it cannot contain
nodes, relationships or paths.

- Read its fields with the usual operators: `n.doc.address.city`.
- A whole document is indexed for equality. A condition on a field inside a document is checked by
  reading each candidate.

`tests/tck/deviations.txt` lists the TCK scenarios where this extension gives a different answer
from standard openCypher.

## Temporal values

| Type | Text form | Constructor |
| --- | --- | --- |
| date | `2025-03-10` | `date(…)` |
| local time | `09:30:00.5` | `localtime(…)` |
| time | `09:30+01:00` | `time(…)` |
| local date-time | `2025-03-10T09:30` | `localdatetime(…)` |
| date-time | `2025-03-10T09:30+01:00[Europe/Madrid]` | `datetime(…)` |
| duration | `P1M2DT3H` | `duration(…)` |

**Constructors** take one of:

- an ISO 8601 string (dates also as `2015-W30-2`, `2015-202` or `20150721`);
- a map of fields (below);
- another temporal value, which is converted;
- no argument, which gives the current time. That time is the same throughout one statement:
  - `date.statement()` and `date.transaction()` (and the same for the other types) also give it;
  - `date.realtime()` and the like read the clock each time.

The **maps** a constructor accepts:

- dates: `{year, month, day}`, `{year, week, dayOfWeek}`, `{year, ordinalDay}`, or
  `{year, quarter, dayOfQuarter}`. `{date: d, …}` changes some fields of a base date `d`.
- times: `{hour, minute, second, millisecond, microsecond, nanosecond}`. `{time: t, …}` changes
  some fields of a base time `t`.
- zones: `timezone: '+01:00'` or `timezone: 'Europe/Madrid'`. On a value that already has a zone it
  converts, giving the same instant elsewhere; on a value without a zone it places the value in that
  zone.
- durations: any of `years`, `quarters`, `months`, `weeks`, `days`, `hours`, `minutes`, `seconds`,
  `milliseconds`, `microseconds` and `nanoseconds`. Fractional values are allowed (`{days: 1.5}`).

**Components** are read like properties (`d.year`):

- dates and date-times: `year`, `quarter`, `month`, `week`, `weekYear`, `day`, `ordinalDay`,
  `dayOfWeek` (1 = Monday), `weekDay`, `dayOfQuarter`;
- times and date-times: `hour`, `minute`, `second`, `millisecond`, `microsecond`, `nanosecond`;
- values with a zone: `timezone`, `offset`, `offsetMinutes`, `offsetSeconds`;
- date-times also: `epochSeconds`, `epochMillis`;
- durations: `years`, `quarters`, `months`, `weeks`, `days`, `hours`, `minutes`, `seconds`,
  `milliseconds`, `microseconds`, `nanoseconds`. The remainders are `quartersOfYear`,
  `monthsOfQuarter`, `monthsOfYear`, `daysOfWeek`, `minutesOfHour`, `secondsOfMinute`,
  `millisecondsOfSecond`, `microsecondsOfSecond`, `nanosecondsOfSecond`.

**Functions**:

- `duration.between(a, b)` gives the months, then the days, then the time that remains.
- `duration.inMonths`, `duration.inDays` and `duration.inSeconds` give the difference in a single
  unit.
- `date.truncate(unit, value[, map])` truncates a value, and the other temporal types have the same
  function. The units are `millennium`, `century`, `decade`, `year`, `weekYear`, `quarter`, `month`,
  `week`, `day`, `hour`, `minute`, `second`, `millisecond`, `microsecond`.
- `datetime.fromepoch(seconds, nanoseconds)` and `datetime.fromepochmillis(milliseconds)` build a
  date-time from the Unix epoch.

**Arithmetic and comparison**:

- A temporal value plus or minus a duration: the months and days move the calendar, and the time
  part moves the clock. For example, `date('2025-01-31') + duration('P1M')` is `2025-02-28`.
- Durations add and subtract, and multiply or divide by numbers.
- Values of the same type compare in time. Durations compare only for equality.

Precision is the nanosecond, and years range over ±999,999,999. The default time zone is UTC. Named
zones come from the system's time zone database.

## Procedures

| Procedure | Yields | What it returns |
| --- | --- | --- |
| `db.labels()` | `label` | the labels some node carries |
| `db.relationshipTypes()` | `relationshipType` | the types some relationship has |
| `db.index.fulltext.queryNodes(index, query[, options])` | `node`, `score` | the nodes of a [full-text index](#full-text-search) that match `query`, best first |
| `db.index.fulltext.queryRelationships(index, query[, options])` | `relationship`, `score` | the same, for an index of relationships |
| `db.index.fulltext.listAvailableAnalyzers()` | `analyzer`, `description` | the full-text analyzers |

Procedure names are case-sensitive, as in Neo4j. The `options` of a full-text query are a map with
`skip` and `limit`, non-negative integers.

A `CALL` that is the whole query may leave out the parentheses: `CALL db.labels`. A procedure that
takes arguments then takes each one from the query parameter of the same name.

## Schema commands

Every property is indexed for equality and ranges without being asked. The kind of index a
command adds that changes anything is a full-text index; `CREATE INDEX` is accepted, so that
Neo4j's scripts run, and changes nothing. Constraints keep values unique. Each schema command is
a statement of its own:

```text
CREATE FULLTEXT INDEX name [IF NOT EXISTS]
  FOR (n:Label1|Label2) ON EACH [n.property1, n.property2]
  [OPTIONS {indexConfig: {`fulltext.analyzer`: 'spanish'}}]

CREATE FULLTEXT INDEX name [IF NOT EXISTS]
  FOR ()-[r:TYPE1|TYPE2]-() ON EACH [r.property]
  [OPTIONS {...}]

CREATE [RANGE | TEXT] INDEX [name] [IF NOT EXISTS]
  FOR (n:Label) ON (n.property, …)          -- or FOR ()-[r:TYPE]-() ON (r.property)

CREATE CONSTRAINT [name] [IF NOT EXISTS]
  FOR (n:Label) REQUIRE n.property IS UNIQUE  -- or REQUIRE (n.a, n.b) IS UNIQUE

DROP INDEX name [IF EXISTS]
DROP CONSTRAINT name [IF EXISTS]

SHOW [FULLTEXT | RANGE] INDEXES
SHOW CONSTRAINTS
```

- Indexes and constraints share one namespace of names. Without a name, `CREATE INDEX` and
  `CREATE CONSTRAINT` make one of what they are on (`index_Card_number`,
  `constraint_Door_building_number`).
- `IF NOT EXISTS` makes `CREATE` do nothing when the name is taken. Otherwise a taken name is an
  error. `IF EXISTS` does the same for `DROP`. `DROP INDEX` of a constraint (or `DROP CONSTRAINT`
  of an index) is an error.
- A full-text node index covers the nodes with any of the labels; a relationship index covers
  the relationships of any of the types. `CREATE` indexes what the graph holds already. From then
  on, every change keeps the index current, in the transaction that makes it.
  `fulltext.eventually_consistent` is accepted in `indexConfig` and has no effect, since acmedb's
  indexes are always current.
- A `RANGE` or `TEXT` index (or one with no kind) is recorded and listed, and every query runs as
  before: the property index already answers equality and range lookups. Its `OPTIONS` are
  ignored.
- **Uniqueness constraints** are on one node label, and one property or several together. A
  write that would give a node of that label the same values as another (by `CREATE`, `SET`,
  `MERGE`, a new label, or the Python and C write functions) fails with a constraint violation
  (`ConstraintViolationError` in Python, error code 10), and its query writes nothing. A node
  without one of the properties is not concerned. The check is made at each write, so swapping
  two nodes' values in one query fails. `CREATE CONSTRAINT` fails if the graph already has
  duplicates. Neo4j 4's `CREATE CONSTRAINT ON (n:Label) ASSERT n.p IS UNIQUE` is accepted too.
  Other constraints (`IS NOT NULL`, `IS NODE KEY`, on relationships) are not supported.
- `SHOW INDEXES` returns one row per index: `name`, `type` (`FULLTEXT` or `RANGE`), `entityType`
  (`NODE` or `RELATIONSHIP`), `labelsOrTypes`, `properties`, `options`. `SHOW CONSTRAINTS`
  returns `name`, `type` (`UNIQUENESS`), `entityType`, `labelsOrTypes`, `properties`.

## Full-text search

A full-text index keeps the words of a node's or relationship's text properties. A property is
indexed when it holds a string or a list of strings; other values are skipped.

**Analyzers** decide what the words are:

| Analyzer | Words |
| --- | --- |
| `standard` (the default) | split at anything not a letter, digit or mark; case-folded; accents and compatibility forms removed (`Contención` → `contencion`, `ﬁ` → `fi`, `ß` → `ss`) |
| `spanish` | as `standard`, without Spanish stop words (`de`, `la`, `los`…), each word reduced to its stem (`contenciones` → `contencion`) |
| `english` | as `standard`, without English stop words (`the`, `of`…), each word reduced to its stem (`running` → `run`) |

- An apostrophe between letters stays inside a word (`O'Neill`).
- The stemmers are Snowball's: Porter2 for English, and Snowball's Spanish algorithm.
- A query is analyzed with its index's analyzer.

**Query syntax** is the part of Lucene's that Neo4j accepts:

| Query | Matches |
| --- | --- |
| `contención biológica` | either word: clauses are optional by default |
| `"nivel 3"` | the phrase, its words in a row in one property (a stop word in it leaves its gap) |
| `conten*` | words that start with `conten` |
| `contencion~`, `contencion~1` | words up to 2 (or 1) edits away; compared stem to stem in a language index |
| `+bsl -animal` | `bsl` required, `animal` excluded |
| `a AND b`, `a OR b`, `NOT a` (also `&&`, `\|\|`, `!`) | the same with words |
| `title:contención` | in the property `title` only |
| `(a OR b) AND c` | a group |
| `contención^2` | the clause's score doubled |
| `\:`, `\"`, `\(`… | a special character as itself |

- Clauses combine as in Lucene's boolean queries. When the query has required clauses, a match
  has all of them, and the optional ones only add to its score. Otherwise a match has at least
  one optional clause. An excluded clause removes what it matches.
- A word the analyzer splits in two (`nivel-3`) is a phrase.
- `?` wildcards and wildcards inside a word are not supported. A query that does not parse fails
  with a message saying why.

**Scores** are BM25, with Lucene's parameters (k1 = 1.2, b = 0.75):

- a word counts more the rarer it is in the index, and the more often it occurs in the entity;
- a short entity scores higher than a long one with the same occurrences;
- a phrase scores as a word whose idf is the sum of its words';
- a prefix or fuzzy clause scores an entity by its best expansion, and a fuzzy one loses a share
  for each edit.

Results come best first.

## Not supported

acmedb does not implement these parts of openCypher (and of common Neo4j extensions):

- procedures other than those [listed](#procedures); `CALL { … } IN TRANSACTIONS`, and `UNION`
  inside `CALL { … }`; `LOAD CSV`;
- constraints other than uniqueness on nodes (`IS NOT NULL`, `IS NODE KEY`, relationship
  constraints); indexes other than full-text change nothing (every property is already indexed).

The openCypher Technology Compatibility Kit (TCK) measures everything else; `tests/tck/REPORT.md`
gives the current pass rate per area.
