# Python reference

The `zypherdb` package: one class, `Database`, plus the types results are built with and the
exceptions errors are raised as. The [tutorial](../tutorial/01-getting-started) introduces all of
it by example; this page is the complete list.

```bash
pip install zypherdb
```

ZypherDB needs Python 3.10 or later. The package carries the engine as a native extension module
(see [the end of this page](#under-the-hood)).

## `Database`

```python
import zypherdb, tempfile

db = zypherdb.Database(tempfile.mkdtemp())
```

### `Database(path, durability="full", temporals="python", import_directory=None)`

Opens the database in directory `path`, creating the directory and the database if they do not
exist. A database is used as a context manager (`with Database(path) as db:`), which closes it on
exit, or closed with `close()`.

- `durability` — how much a commit waits for the disk:

  | Value | A commit returns when… | A power failure can lose… |
  | --- | --- | --- |
  | `"full"` | its data is on disk | nothing |
  | `"relaxed"` | its data is on disk; its bookkeeping follows with the next commit | the last commit |
  | `"deferred"` | it is in memory; the operating system writes it, or `sync()` | the commits since the last `sync()` |

  No mode can corrupt the database. `"deferred"` is hundreds of times faster for many small writes.
- `temporals` — how query results return temporal values: `"python"` as `datetime`-module values
  (see [values](#values)), or `"iso"` as their exact ISO 8601 text (`'09:30:00.123456789+01:00'`),
  which keeps the nanoseconds and the years the `datetime` module cannot hold.
- `import_directory` — the directory `LOAD CSV` reads from: a query's `file:///name.csv` is
  `name.csv` in it, and nothing outside it can be read. Without one, `LOAD CSV` raises
  `ExternalResourceError`. A path that is not a directory raises `ValueError`.

### `query(text, parameters=None, /, **named) -> list[list]`

Runs one openCypher query ([reference](cypher)) and returns its rows: a list with one list per
row, one value per `RETURN` item. A query without `RETURN` returns `[]`. Parameters (`$name` in the
query) come from a dict, keyword arguments, or both:

```python
db.query("CREATE (:Card {number: $number, holder: $holder})", number=123, holder="Ana")
print(db.query("MATCH (c:Card) WHERE c.number IN $numbers RETURN c.holder", {"numbers": [123, 456]}))
```

```text
[['Ana']]
```

A query is one transaction: if it fails, none of its writes are kept. It runs with Python's global
interpreter lock released.

A query is parsed, checked and planned the first time its text is run; the database keeps the
result for the 64 texts used most recently, so running the same text again (with other parameter
values) skips that work. Write parameters (`$number`), not values pasted into the text, for the
same text to come back.

### `prepare(text) -> PreparedQuery`

Parses, checks and plans a query once, to run it with `query(parameters=None, /, **named)` as
often as needed. It saves the lookup by text, and stays prepared for as long as the object lives.
`parameters` and `columns` name what it reads and returns:

```python
lookup = db.prepare("MATCH (c:Card {number: $number}) RETURN c.holder AS holder")
print(lookup.parameters, lookup.columns, lookup.query(number=123))
```

```text
('number',) ('holder',) [['Ana']]
```

A plan was made from the graph's label and relationship-type counts of the time. When a run finds
one of them grown or shrunk at least twofold (and by 100 or more), the query is planned again
before it runs; a prepared query, or a kept one, never runs on a plan made for a very different
graph.

### `explain(text, parameters=None, /, **named) -> dict`

Returns the plan of a query without running it ([EXPLAIN](cypher.md#explain-and-profile)), as a
tree of operators. Each operator is a dict:

- `operator` — its name (`"NodeIndexSeek"`, `"Expand(All)"`, `"Return"`, …);
- `details` — what it works on, as Cypher;
- `estimated_rows` — how many rows it makes per run of its chain, a guess from the label and
  relationship-type counts; `None` when they say nothing;
- `rows`, `time_ms` — `None` here (see `profile`);
- `children` — first the operator it gets its rows from, then the chains it runs (an
  `OPTIONAL MATCH`'s, a subquery's, a pattern's inside an expression).

```python
db.query("UNWIND range(1, 3) AS i CREATE (:Room {number: i})")
plan = db.explain("MATCH (r:Room {number: $number}) RETURN r", number=2)
print(plan["operator"], plan["children"][0]["operator"], plan["children"][0]["details"])
```

```text
Return NodeIndexSeek (r:Room {number: $number})
```

### `profile(text, parameters=None, /, **named) -> tuple[list[list], dict]`

Runs a query ([PROFILE](cypher.md#explain-and-profile)) and returns its rows, as `query` would,
and its plan, as `explain` would, with `rows` (how many rows each operator made) and `time_ms`
(the time spent in the operator itself, in milliseconds) filled in. Its writes commit.

```python
rows, plan = db.profile("MATCH (r:Room) WHERE r.number > 1 RETURN r.number ORDER BY r.number")
operator = plan
while operator:
    print(operator["operator"], operator["rows"])
    operator = operator["children"][0] if operator["children"] else None
print(rows)
```

```text
Return 2
Sort 2
Projection 2
Filter 2
NodeIndexRangeSeek 3
[[2], [3]]
```

`db.query("EXPLAIN " + text)` and `db.query("PROFILE " + text)` give the plan as rows instead.

### `write()`

A context manager that makes every mutator call inside it one transaction, committed when the
block ends and undone if it raises. Queries cannot run inside it.

```python
with db.write():
    for number in (1, 2, 3):
        node = db.allocate_node_id()
        db.add_node(node, "Card")
        db.set_property(node, "number", number)
print(db.query("MATCH (c:Card) RETURN count(c)"))
```

```text
[[4]]
```

### Mutators

Direct writes, each its own transaction unless inside `write()`:

- `allocate_node_id() -> int` — a fresh node id, never handed out before.
- `add_node(id, label="")` — a node with that id (and label), if it does not exist; adds the label
  if it does. Ids chosen by the caller are reserved: `allocate_node_id` will not return them.
- `add_edge(source, target, type) -> int` — a relationship from node `source` to node `target`,
  and its id; both must exist (`NodeNotFoundError` otherwise). Each call adds one, even between
  nodes already joined by a relationship of that type.
- `set_property(id, name, value)` — sets a node's property to any [storable value](#values);
  `None` removes it.

### Other methods

- `export_graph() -> dict` — the whole graph read straight from storage, as
  `{"nodes": [{"id", "labels", "properties"}], "relationships": [{"id", "source", "target", "type", "properties"}]}`.
  Meant for tests and debugging; it reads everything.
- `check() -> dict` — checks that every index and counter agrees with the stored records, and
  returns `{"ok": bool, "problem_count": int, "problems": [str]}` (`problems` describes the first
  32).

  > **Warning.** It is **a diagnostic, not a routine call**. Run it only with a reason: a query that misses
  > data it should find or counts that do not add up (a suspected bug in ZypherDB), to be sure after a
  > crash, or to attach its output to a bug report. It reads the whole database and holds memory in
  > proportion to it, so on a large database it is slow and heavy; it repairs nothing. A problem it
  > reports is a bug in ZypherDB: please report it with the output.
- `sync()` — writes every commit so far to disk (for `"deferred"` durability).
- `close()` — releases the database. Using it afterwards raises `ClosedError`.

## Values

How values cross between Python and Cypher, both ways:

| Cypher | Python |
| --- | --- |
| `null` | `None` |
| boolean | `bool` |
| integer (64-bit) | `int` (outside 64 bits: `OverflowError`) |
| float | `float` (`NaN` and infinities included) |
| string | `str` |
| list | `list` (a `tuple` is accepted as a parameter) |
| map | `dict` with `str` keys |
| date | `datetime.date` |
| local time | `datetime.time`, naive |
| time | `datetime.time` with a fixed-offset `datetime.timezone` |
| local date-time | `datetime.datetime`, naive |
| date-time | `datetime.datetime` in its `zoneinfo.ZoneInfo` zone, or at a fixed offset |
| duration | `datetime.timedelta`, or `zypherdb.Duration` when it has months |
| node | `zypherdb.Node` (results only) |
| relationship | `zypherdb.Relationship` (results only) |
| path | `zypherdb.Path` (results only) |

As **properties**, a node or relationship can store booleans, numbers, strings, temporal values,
lists of one of those types, and maps — documents, which may nest maps and lists of any values,
`null`s included (a ZypherDB extension to openCypher).

Python's `datetime` types hold microseconds and years 1 to 9999: nanoseconds are truncated, and a
value outside those years raises `ValueError` — open the database with `temporals="iso"` to get the
exact text. An aware `datetime` in a `ZoneInfo` zone keeps its zone as a parameter.

```python
import datetime
from zoneinfo import ZoneInfo

print(db.query("RETURN $at.timezone, $at + duration('P1D')", at=datetime.datetime(2025, 3, 30, 1, 30, tzinfo=ZoneInfo("Europe/Madrid"))))
```

```text
[['Europe/Madrid', datetime.datetime(2025, 3, 31, 1, 30, tzinfo=zoneinfo.ZoneInfo(key='Europe/Madrid'))]]
```

## Entities

`Node`, `Relationship` and `Path` are immutable values, equal when all their fields are:

- `Node(id, labels, properties)` — `id` is ZypherDB's id for the node; `labels` a tuple of strings
  in byte order; `properties` a dict.
- `Relationship(id, source, target, type, properties)` — `id` is ZypherDB's id for the relationship
  (counted apart from node ids); `source` and `target` are node ids.
- `Path(nodes, relationships)` — tuples; `relationships[i]` joins `nodes[i]` and `nodes[i + 1]`.

A node is hashed by its id and labels, a relationship by its id (two relationships may share
their ends and type), so they can be dict keys and set members.

```python
(node,), = db.query("MATCH (c:Card {number: 123}) RETURN c")
print(node.labels, node.properties)
```

```text
('Card',) {'holder': 'Ana', 'number': 123}
```

## `Duration`

`zypherdb.Duration(months=0, days=0, seconds=0, nanoseconds=0)` — a duration with a months part,
which `timedelta` cannot express (a month is not a fixed number of days). Its parts are separate:
`months`, `days`, `seconds` (rounded down) and `nanoseconds` (0 to 999,999,999). `str()` gives its
ISO 8601 text; `to_timedelta()` converts one without months. Equal to a `timedelta` of the same
length when it has no months.

```python
print(db.query("RETURN duration('P1M2DT3H')"), str(zypherdb.Duration(months=14, days=3)))
```

```text
[[Duration(months=1, days=2, seconds=10800, nanoseconds=0)]] P1Y2M3D
```

## Exceptions

Every exception is a `zypherdb.ZypherDBError`. A failed query raises a `QueryError`, with `code` and
`message` attributes:

| Exception | Code | Raised when |
| --- | --- | --- |
| `ParseError` | 1 | the query is not valid Cypher |
| `UnknownVariableError` | 2 | the query uses a variable it never bound |
| `TypeMismatchError` | 4 | an operator or function gets a value of the wrong type |
| `InvalidExpressionError` | 5 | an expression is not allowed where it is |
| `NodeStillConnectedError` | 6 | `DELETE` of a node that still has relationships |
| `ConstraintViolationError` | 10 | a write would break a uniqueness constraint (also from `add_node` / `set_property`) |
| `ExternalResourceError` | 11 | `LOAD CSV` could not read its file (off, outside the import directory, missing, or not CSV) |
| `ParameterMissingError` | 8 | a `$parameter` was not passed |
| `ArithmeticQueryError` | 9 | integer overflow or division by zero (also an `ArithmeticError`) |

and outside queries:

| Exception | Raised when |
| --- | --- |
| `StorageError` | the storage failed (a full disk, a broken file) |
| `NodeNotFoundError` | a mutator was given a node id that does not exist |
| `ClosedError` | a closed `Database` was used |

Values that cannot be converted raise Python's own `TypeError`, `OverflowError` or `ValueError`.
A mutator given a label, relationship type or property name that is empty or contains the
character U+0000 raises `ValueError` (a query with one raises `InvalidExpressionError`).

## Concurrency

- **Threads.** Share one `Database` among threads. Its calls take turns (one query at a time per
  `Database`), and a query releases the global interpreter lock while it runs, so the rest of the
  program carries on. A read query sees one consistent snapshot.
- **Processes.** Each process opens the database itself. Reads run in parallel across processes;
  writes are serialized, one write transaction at a time. Do not open the same directory twice in
  one process, and do not hand a `Database` to another process.

## Under the hood

The package's engine is `zypherdb._native`, an extension module written in Zig on the Python limited
C API (`python/native/module.zig`). It uses only the stable ABI of Python 3.10, so one build serves
every later Python version. It converts values directly — parameters into engine values, rows
into Python objects (entities without running their `__init__`, temporal values field by field in
`python/native/temporals.zig`) — runs the engine with the global interpreter lock released, and
pauses Python's cycle collector while it builds a large result. `zypherdb/db.py` adds the `Database`
class (locking, `write()` blocks, argument checks); `zypherdb/_engine.py` loads the module and
registers the classes and exceptions it builds with.

From a source checkout, `make python` builds the module into `zig-out/python/`, where the package
finds it. Measured costs are in `bench/RESULTS.md`. To embed ZypherDB from another language, see the
[C ABI](c-api).

```python
db.close()
```

## Why this way — and the alternatives

- **A native module, not `ctypes` over the C ABI.** The package first called the C library through
  `ctypes`, with results as JSON. Building Python objects straight from engine values, with no JSON
  in between, cut a point query's overhead from about 7 µs to about 1.4 µs, and returning 100,000
  rows from 65 ms to 41 ms (`bench/RESULTS.md`).
- **The limited C API, not the full one.** One `abi3` build serves Python 3.10 and every later
  version, so a release needs one wheel per platform, not one per platform and Python version. The
  full API would allow a few faster calls; none was needed.
- **Written in Zig, not Cython or pybind11.** The module lives in the same language and build as the
  engine, with no generator or C++ toolchain in between, and reads engine values without a copy
  into an intermediate form.
- **`datetime` types by default, ISO text on request.** Most programs want `datetime` values; the
  `datetime` module cannot hold nanoseconds or years beyond 9999, so `temporals="iso"` keeps the
  exact value for those that need it.
- **Results as lists, built whole.** A list is the simplest thing to use and to test. An iterator
  would let a large result arrive row by row, but the engine builds the whole result before the
  transaction ends anyway (see [performance](performance.md#python-bindings)).
