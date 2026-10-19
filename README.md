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
- **Generic programming (Stepanov).** Data as concrete types, algorithms as free functions, errors
  as values. The core types are *regular* (equality, a total order and a hash, with their laws
  tested), and algorithms shared by several types — deduplication, sorting, grouping, pagination —
  are written once, generically. No class hierarchies, no Visitor; the AST is an arena of nodes
  with child indices.
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

There is a thin Python package in `python/` over the C ABI. Point `PYTHONPATH` at it (or
`pip install -e python/`) and use the `Database` object:

```bash
zig build
PYTHONPATH=python python3 - <<'PY'
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
PY
```

A query looks like openCypher:

```text
MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title
```

Cells come back as Python values (`int`/`str`/`bool`/`None`/`list`); errors raise typed
exceptions (`ParseError`, `UnknownVariableError`, `TypeMismatchError`, …). See the
[Python guide](docs/guide/python.md) and the raw [C ABI](docs/guide/c-api.md) for the layer
underneath.

## Documentation

Read the docs at [`docs/`](docs/) — two tracks:

- **Using acmedb** — a step-by-step [tutorial](docs/tutorial/01-getting-started.md) (eight steps
  growing a "people and movies" graph) plus references for the
  [openCypher subset](docs/guide/cypher.md), the [C ABI](docs/guide/c-api.md), and
  [Python](docs/guide/python.md).
- **How it works inside** — the [architecture](docs/guide/architecture.md) (design decisions,
  components, query lifecycle), the [storage encoding](docs/guide/storage.md) (keys, index-free
  adjacency, indexes), the [lexer/parser](docs/guide/language.md), and
  [planning & execution](docs/guide/planning-execution.md) (anchor selection, pushdown, the
  volcano translation), plus [contributing](docs/guide/contributing.md).

Build the HTML locally:

```bash
make docs    # or: sphinx-build -b html docs docs/_build/html
```

(requires `pip install -r docs/requirements.txt` — Sphinx + MyST + mermaid.)

## Development

```bash
zig build test    # unit tests in src/ + the suite in tests/
zig build         # static + shared libraries into zig-out/
make docs         # build the HTML documentation
make test-py      # Python bindings (pip install -e "python[dev]" once)
```

The source is laid out by layer — `src/storage/` (LMDB, key layout, graph), `src/query/` (lexer,
parser, AST) and `src/execution/` (planning, matching, projection, writes) — with the test suite in
`tests/`, which uses only the public API. The [architecture](docs/guide/architecture.md) guide maps
every file; [contributing](docs/guide/contributing.md) has the principles and the recipes.

See `STATUS.md` (kept out of git) for the working notes and the roadmap.

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

acmedb is measured against the [openCypher TCK](tests/tck/README.md), the reference scenarios of
the language: **175 of 3202 scenarios that expect a result pass (5.5%)** — see
[tests/tck/REPORT.md](tests/tck/REPORT.md) for the results by area and what is missing. The
supported subset above works and is covered by `zig build test`; the TCK shows how far that subset
is from openCypher. See `STATUS.md` (kept out of git) for the working notes and the roadmap.
