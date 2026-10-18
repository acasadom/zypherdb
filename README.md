# acmedb

*An embedded graph database in Zig, speaking openCypher, on LMDB.*

A small, embeddable **graph database**: link it into your process, or load the shared library from
Python, write nodes and edges, and answer queries in a subset of **openCypher** — over an
**index-free adjacency** graph stored in **LMDB**. No server, no configuration, one binary
toolchain.

---

## Why this stack

- **Zig 0.17.0** — a fast, self-contained, single-binary toolchain: no Docker, no CMake, no
  vcpkg. Pre-1.0 (breaking changes until 1.0) and a small ecosystem, but `comptime` generics map
  cleanly onto the generic-programming style the project uses throughout.
- **LMDB** as the storage engine — not RocksDB, not SQLite. A graph is traversed by following
  adjacencies, not by joining tables: acmedb encodes its own keys and exploits LMDB's lexicographic
  iteration so *"give me the neighbours of X"* is one prefix scan. LMDB is single-writer /
  multi-reader, which matches the intended read-replication model, and reads are ~6x faster than
  RocksDB.
- **No class hierarchies, no Visitor.** Generic programming (Stepanov/STL): data as concrete
  types, algorithms as free functions, errors as values. The AST is an arena of nodes — a flat
  `std.ArrayList` plus child indices, no pointers, no inheritance.
- **A hand-written recursive-descent parser** for the openCypher subset — no ANTLR, no generator.

## Building

```bash
zig build test    # build and run the test suite
zig build         # build the static + shared libraries into zig-out/
```

The LMDB C sources under `vendor/lmdb/` are vendored and compiled by the build. `zig build` also
produces `libacmedb.dylib` (`.so` on Linux) — the shared library that exposes the C ABI for
embedding.

## Quickstart (Python)

The engine is a shared library with a small C ABI, driven here with `ctypes`:

```bash
zig build
python3 examples/demo.py
```

```python
import ctypes, tempfile
from pathlib import Path

lib = ctypes.CDLL(str(next(Path("zig-out/lib").glob("libacmedb.*"))))
# … declare the C signatures (see examples/demo.py) …

ctx = lib.acmedb_open(b"/tmp/acmedb-demo", 15)   # path + length

lib.acmedb_add_node(ctx, 1, b"Person", 6)
lib.acmedb_set_prop_str(ctx, 1, b"name", 4, b"Keanu Reeves", 13)
lib.acmedb_add_node(ctx, 100, b"Movie", 5)
lib.acmedb_set_prop_str(ctx, 100, b"title", 5, b"The Matrix", 10)
lib.acmedb_add_edge(ctx, 1, 100, b"ACTED_IN", 8)

# MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title
```

A query looks like openCypher:

```text
MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title
```

## Documentation

Read the docs at [`docs/`](docs/) — a step-by-step **tutorial** (eight steps that grow a "people
and movies" graph from a first `MATCH` to `OPTIONAL MATCH` and lists) plus guides for the
architecture, the openCypher subset, and the C ABI. Build the HTML locally:

```bash
pip install -r docs/requirements.txt
sphinx-build -b html docs docs/_build/html
```

- **[Tutorial](docs/tutorial/01-getting-started.md)** — start here; the language, one feature at a time.
- **[Architecture](docs/guide/architecture.md)** — how the keys are laid out, index-free adjacency, and how the executor plans.
- **[openCypher subset](docs/guide/cypher.md)** — the full reference of what the language supports.
- **[C ABI](docs/guide/c-api.md)** · **[Python](docs/guide/python.md)** — embedding reference.

## What's in the box

- **The openCypher subset**: `MATCH` (chains, multi-pattern, `WHERE`), `OPTIONAL MATCH` (outer
  join + nulls), `WITH` (pipelines), `UNWIND`, `RETURN` (`DISTINCT` / `ORDER BY` / `SKIP` /
  `LIMIT`), and the writes `CREATE` / `MERGE` (with `ON CREATE/MATCH SET`) / `SET` / `DELETE`
  (`DETACH DELETE`) / `REMOVE`.
- **Expressions**: comparisons, `AND`/`OR`/`NOT`, `STARTS WITH`/`ENDS WITH`/`CONTAINS`, `IN`,
  `CASE`, `size`, list literals.
- **Aggregations** with implicit grouping: `count` (and `count(*)`), `sum`, `min`, `max`, `collect`.
- **A typed value model**: `int`, `str`, `boolean`, `null`, `list`.
- **Storage**: index-free adjacency, a property index, an edge-property index, label indexes, and
  an edge-type cardinality counter for planning — all as LMDB keys.
- **An executor that plans**: anchor selection (label counts, equality seeks, edge-type
  cardinality) with predicate pushdown, one read transaction per read query, one write transaction
  per writing query.
- **A C ABI** for embedding from any language with an FFI (the reference client is Python via
  `ctypes`).

## Status

The openCypher functional surface and the performance work are complete, covered by a test suite
that runs the whole pipeline end to end (`zig build test`). See `STATUS.md` (kept out of git) for
the working notes and the roadmap.
