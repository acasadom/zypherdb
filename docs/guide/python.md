# Embedding from Python

There is a thin, pure-Python package in `python/` over the C ABI. It needs no build — just the
compiled shared library.

## Install and use

```bash
zig build                                    # produces zig-out/lib/libacmedb.{dylib,so}
pip install -e python/                       # or: export PYTHONPATH=python
```

```python
from acmedb import Database
import tempfile

with Database(tempfile.mkdtemp()) as db:
    nid = db.alloc_node_id()
    db.add_node(nid, "Person")
    db.set_prop(nid, "name", "Keanu Reeves")
    db.add_node(100, "Movie")
    db.set_prop(100, "title", "The Matrix")
    db.add_edge(nid, 100, "ACTED_IN")

    print(db.query("MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title"))
    # [['The Matrix']]
```

## The `Database` object

- `Database(path)` opens (or creates) the database; use it as a context manager, or call `close()`.
- `query(text) -> list[list]` runs one query; cells become `int`, `str`, `bool`, `None` (null) or a
  `list`.
- `alloc_node_id()`, `add_node(id, label)`, `add_edge(src, dst, type)`, `set_prop(id, name, value)`
  write data. `set_prop` accepts `int` or `str` values.
- `write()` is a context manager that batches mutators into **one** write transaction (one fsync):
  the bulk-ingestion path. An exception inside the block aborts it.

  ```python
  with db.write():
      for i in range(100_000):
          nid = db.alloc_node_id()
          db.add_node(nid, "Person")
          db.set_prop(nid, "name", f"p{i}")
  ```

  Each mutator on its own is a separate transaction (slow, durable); a `write()` block does one
  commit for the whole batch (~2000x faster for bulk loads). Don't run `query()` inside the block.
- Errors raise typed exceptions — `ParseError`, `UnknownVariableError`, `MissingPropertyError`,
  `TypeMismatchError`, `InvalidExpressionError`, `NodeStillConnectedError`, `StorageError` — all
  subclasses of `AcmedbError`.

The library is located via the `ACMEDB_LIB` environment variable, then `zig-out/lib`, then a
standard install path.

## Concurrency

LMDB is **single-writer / multi-reader**. Reads (queries) can run concurrently, but writes are
serialized: the `Database` object holds a lock around every mutator (`add_node`, `add_edge`,
`set_prop`, `alloc_node_id`). Do not share one `Database` across processes; the multi-process model
is read replication (a writer → N replicas), which is future work.

## Under the hood

The package is a thin `ctypes` wrapper (`acmedb/_ffi.py` declares the signatures once;
`acmedb/db.py` decodes results and maps error codes to exceptions). `query` reads the whole result
in **one** call via `acmedb_result_to_json` (a JSON serialization of the rows), so a large result
costs one FFI call plus a `json.loads` — not one call per cell. If you need the raw layer — or want
to embed from another language — see the [C ABI reference](c-api).
