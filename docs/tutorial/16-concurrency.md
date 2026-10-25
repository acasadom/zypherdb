# 16. Errors, threads and processes

A door controller runs unattended, around the clock, with many readers talking to it at once. It
must handle bad input without falling over, keep the data consistent when something fails, and
serve many requests concurrently. This step covers how zypherdb reports errors, what a failed query
leaves behind, and how to use one database from many threads or processes.

## Typed errors

Every error is a `zypherdb.ZypherDBError`. A query that cannot run raises a `QueryError` subclass
that says why, with a message and a stable code:

| Exception | Raised when |
| --- | --- |
| `ParseError` | the query text is not valid Cypher |
| `UnknownVariableError` | the query uses a variable it never bound |
| `TypeMismatchError` | an operator or function gets a value of the wrong type |
| `InvalidExpressionError` | an expression is not allowed where it is (an aggregate inside an aggregate, …) |
| `ParameterMissingError` | a `$parameter` was not passed |
| `ArithmeticQueryError` | integer overflow or division by zero (also an `ArithmeticError`) |
| `NodeStillConnectedError` | `DELETE` of a node that still has relationships |
| `ConstraintViolationError` | a write would break a uniqueness constraint |

Outside queries there are `StorageError` (the disk), `NodeNotFoundError` (a mutator given an id
that does not exist) and `ClosedError` (a closed `Database`).

```python
from zypherdb import ParseError, TypeMismatchError, QueryError

for query in [
    "MATCH (p:Person RETURN p",
    "MATCH (p:Person) RETURN p.name - 1",
]:
    try:
        db.query(query)
    except QueryError as error:
        print(type(error).__name__, "-", error.message)
```

```text
ParseError - expected ')', found RETURN
TypeMismatchError - arithmetic needs numbers
```

`error.code` is the numeric code, `error.message` the text. Catch the specific classes where the
program can do something about them, and `QueryError` (or `ZypherDBError`) at the edge.

## A failed query writes nothing

Each query is one transaction. If it fails half-way — after creating some nodes, say — none of its
writes are kept:

```python
try:
    db.query("""
        UNWIND [1, 2, 0] AS n
        CREATE (:Probe {value: 10 / n})
    """)
except ArithmeticError as error:
    print("failed:", error.message)
print(db.query("MATCH (p:Probe) RETURN count(p)"))
```

```text
failed: division by zero
[[0]]
```

Two `Probe` nodes were created before the third row divided by zero; the whole query was undone.
The same holds for a `write()` block ([step 15](15-loading)) and a `UNION` of queries. This is what
lets the door controller log a swipe and update a position in one query without ever recording
one without the other.

## Many threads, one database

In a server, requests run in threads. Share one `Database` between them: it is safe to call from
any thread. Calls into it take turns — the database runs one query at a time per `Database` — but
while a query runs, the engine releases Python's global interpreter lock, so the rest of your
program (network I/O, other requests' Python code) keeps going.

```python
from concurrent.futures import ThreadPoolExecutor

swipes = [(70013, "D-Sequencing Lab"), (70004, "D-BSL-3 Lab"), (70007, "D-Airlock"),
          (80001, "D-Genomics Office"), (70006, "D-Vivarium Control"), (90001, "D-Lobby")] * 50
with ThreadPoolExecutor(max_workers=8) as pool:
    answers = list(pool.map(lambda swipe: may_enter(*swipe, monday_morning), swipes))
print(len(answers), sum(answers))
```

```text
300 250
```

Three hundred decisions from eight threads, each answered from the same consistent data. A read
query sees one snapshot of the database, as of when it started: a write that commits during it
does not change what it sees halfway through.

## Many processes, one database

Several processes can open the same database directory — a web server's workers, a nightly job,
a monitor. Each process opens it itself, with its own `Database`:

```python
# docs-test: skip
# in each worker process
db = Database("/srv/helix/db")
```

Reads in different processes run in parallel and never wait for each other or for a writer. Writes
are serialized across all processes: one write transaction at a time, the others wait their turn.
Three rules:

- **Open the database once per process.** The storage engine allows one open per process: with
  LMDB (the default) a second one is not safe, with libmdbx it raises `StorageError`. Share the
  one `Database` among the process's threads instead.
- **With libmdbx, agree on `deferred` durability.** A process cannot open the database with
  `durability="deferred"` while another has it open with `"full"` or `"relaxed"`, nor the
  reverse: the open raises `StorageError`.
- **Do not hand a `Database` to another process** (for example across `fork`): open it in the
  process that uses it.

Writes that are many and small — the swipe log — are where processes contend. Batching them
([step 15](15-loading)) keeps each writer's turn short.

The controller is correct and concurrent. [Next](17-performance), fast: what zypherdb does with a
query, and how to write the ones that must answer in microseconds.
