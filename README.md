# acmedb

*An embedded graph database in Zig, speaking openCypher, on LMDB or libmdbx.*

A small, embeddable **graph database**: link it into your process, or load the shared library from
Python, write nodes and edges, and answer queries in a subset of **openCypher** — over an
**index-free adjacency** graph stored in **LMDB** (or **libmdbx**). No server, no configuration, one binary
toolchain.

---

## Why this stack

- **Zig 0.17.0** — a fast, self-contained, single-binary toolchain: no Docker, no CMake, no
  vcpkg. Pre-1.0 (breaking changes until 1.0) and a small ecosystem, but `comptime` generics map
  cleanly onto the generic-programming style the project uses throughout.
- **LMDB or libmdbx** as the storage engine — not RocksDB, not SQLite. A graph is traversed by
  following adjacencies, not by joining tables: acmedb encodes its own keys and exploits the
  engine's lexicographic iteration so *"give me the neighbours of X"* is one prefix scan. Both are
  single-writer / multi-reader across processes. The engine sits behind a contract
  (`src/storage/engine/contract.zig`) and is chosen at build time: `-Dstorage-engine=lmdb` (the
  default) or `mdbx` (libmdbx, a descendant of LMDB: faster commits, a file that grows and shrinks
  on its own; see [bench/RESULTS.md](bench/RESULTS.md)).
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

The LMDB and libmdbx C sources under `vendor/` are vendored; the build compiles the chosen one. `zig build` also
produces `libacmedb.dylib` (`.so` on Linux) and the header `zig-out/include/acmedb.h`, for embedding
acmedb from C, C++ or any language with a C FFI (see `docs/guide/c-api.md`).

## Quickstart (Python)

The Python package in `python/` runs the engine through a native extension module written in Zig
(`python/native/`). Build it, point `PYTHONPATH` at the package (or `pip install -e python/`) and
use the `Database` object:

```bash
make python
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

- **Using acmedb** — a step-by-step [tutorial](docs/tutorial/01-getting-started.md) (twenty
  steps building the access-control system of a biomedical lab, every example run by the tests)
  plus references for the
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

The source is laid out by layer — `src/storage/` (engine, key layout, graph), `src/query/` (lexer,
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
  an edge-type cardinality counter for planning — all as keys of the key-value store.
- **An executor that plans**: anchor selection (label counts, equality seeks, edge-type
  cardinality) with predicate pushdown, one read transaction per read query, one write transaction
  per writing query.
- **A Python package** whose engine is a native extension module written in Zig on the Python
  limited API (one build per platform for every Python from 3.10), and **a C ABI** for embedding
  from any language with an FFI.

## Status

acmedb is measured against the [openCypher TCK](tests/tck/README.md), the reference scenarios of
the language: **3201 of the 3202 scenarios that expect a result pass**, and all 694 that
expect an error — see [tests/tck/REPORT.md](tests/tck/REPORT.md) for the results by area. The
scenario left needs a `WITH` inside `EXISTS { … }`; the [Cypher reference](docs/guide/cypher.md#not-supported) lists
what acmedb does not implement. See `STATUS.md` (kept out of git) for the working notes and the roadmap.

## License

MIT (see [LICENSE](LICENSE)). acmedb includes LMDB, libmdbx and data and algorithms from Unicode and Snowball, under their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
