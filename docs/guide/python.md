# Embedding from Python

The `acmedb` package in `python/` runs the engine through a native extension module,
`acmedb._native`, written in Zig on the Python limited C API (`python/native/module.zig`). Values
cross between Python and the engine by direct conversion, without serializing them, and a query
runs with the GIL released. The module uses only the stable ABI of Python 3.10, so one build works
with every Python version from 3.10 on.

## Install and use

```bash
make python                                  # zig build python -Dpython-include=<Python.h dir>
pip install -e python/                       # or: export PYTHONPATH=python
```

```python
from acmedb import Database
import tempfile

with Database(tempfile.mkdtemp()) as db:
    nid = db.allocate_node_id()
    db.add_node(nid, "Person")
    db.set_property(nid, "name", "Keanu Reeves")
    db.add_node(100, "Movie")
    db.set_property(100, "title", "The Matrix")
    db.add_edge(nid, 100, "ACTED_IN")

    print(db.query("MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title"))
    # [['The Matrix']]
```

## The `Database` object

- `Database(path, durability="full")` opens (or creates) the database in directory `path`; use it
  as a context manager, or call `close()`. `durability` is how much a commit waits for the disk:
  `"full"` (each commit is on disk when it returns, about 8 ms), `"relaxed"` (a power failure can
  lose the last commit, never corrupt the database) or `"deferred"` (commits are written by the
  operating system or `sync()`; a power failure can lose the recent ones; tens of microseconds per
  commit). `sync()` writes every commit so far to disk.
- `query(text, parameters=None, /, **named) -> list[list]` runs one query, with its `$name`
  parameters from a dict and/or keyword arguments (`db.query("... {id: $card} ...", card=123)`;
  values: `int`, finite `float`, `str`, `bool`, `None`, lists, `str`-keyed dicts, and temporal
  values, below); maps come back as dicts; cells become `int`, `float`, `str`, `bool`, `None` (null), a
  `list`, a `dict`, a whole `Node(id, labels, properties)` / `Relationship(source, target, type,
  properties)`, a `Path(nodes, relationships)`, or a temporal value.
- Temporal results are `Date`, `LocalTime`, `Time`, `LocalDateTime`, `DateTime` and `Duration`:
  each keeps acmedb's exact value (nanoseconds, any year, the zone name) as its ISO 8601 text
  (`str(value)`), compares equal to the `datetime`-module value it represents, and converts to
  one with `to_native()` (truncating to microseconds). As parameters these and the `datetime`
  module's types are accepted: `date`, `time` and `datetime` (naive ones as local values; an
  aware `datetime` in a `zoneinfo.ZoneInfo` zone keeps the zone), and `timedelta`.
- `export_graph() -> dict` returns the whole graph, read straight from storage.
- `allocate_node_id()`, `add_node(id, label)`, `add_edge(src, dst, type)`, `set_property(id, name, value)`
  write data. `set_property` accepts `int`, `float` or `str` values.
- `write()` is a context manager that batches mutators into **one** write transaction (one fsync):
  the bulk-ingestion path. An exception inside the block aborts it.

  ```python
  with db.write():
      for i in range(100_000):
          nid = db.allocate_node_id()
          db.add_node(nid, "Person")
          db.set_property(nid, "name", f"p{i}")
  ```

  Each mutator on its own is a separate transaction (slow, durable); a `write()` block does one
  commit for the whole batch (~2000x faster for bulk loads). Don't run `query()` inside the block.
- Errors raise typed exceptions — `ParseError`, `UnknownVariableError`,
  `TypeMismatchError`, `InvalidExpressionError`, `NodeStillConnectedError`, `StorageError` — all
  subclasses of `AcmedbError`.

The library is located via the `ACMEDB_LIB` environment variable, then `zig-out/lib`, then a
standard install path.

## Concurrency

LMDB is **single-writer / multi-reader**. Reads (queries) can run concurrently, but writes are
serialized: the `Database` object holds a lock around every mutator (`add_node`, `add_edge`,
`set_property`, `allocate_node_id`). Do not share one `Database` across processes; the multi-process model
is read replication (a writer → N replicas), which is future work.

## Under the hood

`acmedb._native` (`python/native/module.zig`) opens the database, runs queries and writes, and
converts values directly: a query's parameters into engine values, its rows into Python objects
(nodes, relationships and paths are built without running `__init__`; temporal values through the
classes in `acmedb/temporal.py`). It runs the engine with the GIL released and pauses Python's
cycle collector while it builds a large result. `acmedb/db.py` adds the `Database` class:
locking, `write()` blocks, argument checks. `acmedb/_engine.py` loads the module and registers the
classes and exceptions it builds. Measured costs are in `bench/RESULTS.md`. To embed from another
language, see the [C ABI reference](c-api).
