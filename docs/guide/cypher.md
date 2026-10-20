# Cypher reference

acmedb speaks **openCypher**, the query language of graph databases. It adds a few extensions and
leaves out a few features; both are listed below. This page is the complete reference, and the
[tutorial](../tutorial/01-getting-started) introduces each feature by example.

## Lexical structure

- **Keywords** are case-insensitive: `MATCH` and `match` are the same keyword. **Identifiers** are
  case-sensitive; that covers variables, labels, relationship types and property names. Write an
  identifier that has spaces or symbols between backticks: `` (`my node`:`Floor 3`) ``.
- **Strings** use single quotes, with backslash escapes (`'it\'s'`, `'\n'`).
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
| `WITH items [ORDER BY …] [SKIP n] [LIMIT n] [WHERE condition]` | projects the rows like `RETURN` (aggregating, sorting, paging) and continues; only the projected names remain |
| `CREATE pattern, …` | creates the nodes and relationships of the pattern; a node already bound is reused as it is |
| `MERGE pattern [ON CREATE SET …] [ON MATCH SET …]` | matches the whole pattern, and each match becomes a row (with `ON MATCH SET` applied); if nothing matches, creates the whole pattern (with `ON CREATE SET` applied) |
| `SET item, …` | `n.prop = v` sets one property; `n = map` replaces all properties; `n += map` adds and changes properties (a `null` entry removes one); `n:Label` adds labels |
| `REMOVE item, …` | removes a property (`n.prop`) or labels (`n:Label`) |
| `DELETE x, …` / `DETACH DELETE x, …` | deletes nodes and relationships; deleting a node that has relationships needs `DETACH`, which deletes those relationships too |
| `RETURN [DISTINCT] items [ORDER BY …] [SKIP n] [LIMIT n]` | produces the result of the query |
| `query UNION query`, `query UNION ALL query` | combines the rows of both parts (`UNION` drops duplicates, `UNION ALL` keeps them); both parts return the same column names |

- Clauses chain in any number and order, with these rules:
  - after a writing clause, a `WITH` must come before reading again (`MATCH`, `UNWIND`, `CALL`);
  - `RETURN` comes last;
  - a query ends with `RETURN` or with a writing clause;
  - a `CALL` without `YIELD` (or with `YIELD *`) ends the query, and its rows are the result. So
    does a `CALL … YIELD` that is the whole query. Inside a longer query, a `CALL` names the
    columns it uses with `YIELD`.
- The `WHERE` of a `WITH` filters the projected rows before `DISTINCT`, `ORDER BY`, `SKIP` and
  `LIMIT` apply. When the `WITH` does not aggregate, its `WHERE` can also use the variables from
  before the `WITH`.
- `ORDER BY x [ASC | DESC], …` sorts the rows, ascending by default. Ascending order puts `null`s
  last. `SKIP` and `LIMIT` take an integer expression or a parameter.
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
- acmedb keeps at most one relationship per source, target and type.

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
| `x[from..to]` | a list slice; either end may be left out, and negative values count from the end |

### Operators, by precedence (tightest first)

| Operators | Meaning |
| --- | --- |
| `.key`, `[…]` | access (see above) |
| unary `-`, `+` | sign |
| `^` | power; the result is always a float (`-2 ^ 2` is `4.0`) |
| `*`, `/`, `%` | arithmetic. Two integers give an integer: `/` truncates, and overflow or division by zero is an error. With a float operand the result is a float, following IEEE 754 (`1.0 / 0` is infinity) |
| `+`, `-` | arithmetic. `+` also joins strings (`'a' + 1` is `'a1'`), joins lists, and appends an element to a list. A temporal value `±` a duration gives a temporal value |
| `IS NULL`, `IS NOT NULL`, `STARTS WITH`, `ENDS WITH`, `CONTAINS`, `IN` | tests; `IN` is list membership and handles `null` |
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
| `EXISTS { pattern [WHERE cond] }`, `EXISTS { MATCH … [RETURN …] }` | true if the pattern has a match; variables it introduces stay inside it |
| `$name` | a parameter |

## Functions

Function names are case-insensitive. A function returns `null` when given a `null` argument,
unless noted otherwise. Calling an unknown function, or passing the wrong number of arguments, fails
before the query runs.

| Group | Functions |
| --- | --- |
| Lists | `size(list)`, `head`, `last`, `tail`, `reverse`, `range(start, end[, step])`, `keys(map or entity)` |
| Strings | `size(text)` (counts code points), `toLower`, `toUpper` (ASCII letters only), `trim`, `lTrim`, `rTrim`, `replace(text, search, replacement)`, `substring(text, start[, length])`, `split(text, delimiter)`, `reverse` |
| Conversion | `toString`, `toInteger` (truncates a float; `null` for a string that is not a number), `toFloat`, `toBoolean` |
| Numbers | `abs`, `sign`, `round` (a float; halves round up), `floor`, `ceil`, `sqrt`, `exp`, `log`, `log10`, `sin`, `cos`, `tan`, `cot`, `asin`, `acos`, `atan`, `atan2`, `degrees`, `radians`, `haversin`, `pi()`, `e()`, `rand()` |
| Null | `coalesce(x, …)` returns the first argument that is not `null` |
| Graph | `id(node)`, `labels(node)`, `type(relationship)`, `properties(entity)` (a map), `startNode(r)`, `endNode(r)` |
| Paths | `length(path)`, `nodes(path)`, `relationships(path)` |
| Temporal | see [Temporal values](#temporal-values) |

`id()` of a relationship is an error, because a relationship is identified by its source, target
and type rather than by an id.

## Aggregation

The aggregates are:

- `count(x)` and `count(*)`;
- `sum(x)`, an integer unless a float is summed;
- `avg(x)`, `min(x)`, `max(x)`;
- `collect(x)`, which builds a list;
- `stDev(x)` and `stDevP(x)`, the sample and population standard deviation.

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

## Schema commands

Every property is indexed for equality and ranges without being asked. The one kind of index a
command creates is a full-text index. Each schema command is a statement of its own:

```text
CREATE FULLTEXT INDEX name [IF NOT EXISTS]
  FOR (n:Label1|Label2) ON EACH [n.property1, n.property2]
  [OPTIONS {indexConfig: {`fulltext.analyzer`: 'spanish'}}]

CREATE FULLTEXT INDEX name [IF NOT EXISTS]
  FOR ()-[r:TYPE1|TYPE2]-() ON EACH [r.property]
  [OPTIONS {...}]

DROP INDEX name [IF EXISTS]

SHOW [FULLTEXT] INDEXES
```

- A node index covers the nodes with any of the labels. A relationship index covers the
  relationships of any of the types.
- `CREATE` indexes what the graph holds already. From then on, every change keeps the index
  current, in the transaction that makes it.
- `IF NOT EXISTS` makes `CREATE` do nothing when the name is taken. Otherwise a taken name is an
  error. `IF EXISTS` does the same for `DROP`.
- `SHOW INDEXES` returns one row per index: `name`, `type` (`FULLTEXT`), `entityType` (`NODE` or
  `RELATIONSHIP`), `labelsOrTypes`, `properties`, `options`.
- `fulltext.eventually_consistent` is accepted in `indexConfig` and has no effect, since acmedb's
  indexes are always current.

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

- `CALL { … }` subqueries and procedures other than those [listed](#procedures); `LOAD CSV` and
  `FOREACH`;
- `shortestPath` and `allShortestPaths`;
- label tests as expressions (`WHERE n:Label`); use `'Label' IN labels(n)` instead;
- `RETURN *` and `WITH *`;
- map projections (`n {.name, .age}`);
- `COUNT { … }` subqueries; use `size([(a)-->(b) | b])` instead;
- the regular-expression operator `=~`;
- `percentileCont` and `percentileDisc`;
- the function `exists(n.property)`; use `n.property IS NOT NULL` instead;
- the long sort keywords `ASCENDING` and `DESCENDING`; use `ASC` and `DESC` instead;
- schema commands other than full-text indexes (`CREATE INDEX`, constraints): every property is
  already indexed for equality and ranges;
- parallel relationships of the same type between the same two nodes.

The openCypher Technology Compatibility Kit (TCK) measures everything else; `tests/tck/REPORT.md`
gives the current pass rate per area.
