# acmedb

Embedded graph database engine, written in Zig, speaking a subset of openCypher,
on top of LMDB as the storage layer.

## Architecture decisions (why this stack)

- **Zig 0.17.0** as the language. Pre-1.0 (breaking changes until 1.0) and a
  small ecosystem, but a fast single-binary toolchain with no external build
  system, and `comptime` generics that map cleanly to the generic-programming
  style we want.
- **LMDB** as the storage engine (not RocksDB, not SQLite): a graph is traversed
  by following adjacencies, not by joining tables. We encode our own keys
  (prefix per node + direction + edge type) and exploit LMDB's lexicographic
  iteration to answer "give me the neighbours of X" with a prefix scan — no joins.
- **Single-writer / multi-reader per node** fits the intended read-replication
  model (one process writes, applies to N replicas, each process reads its own
  replica). LMDB reads are ~6x faster than RocksDB.
- **No class hierarchies, no Visitor.** Generic programming (Stepanov/STL): data
  as concrete types, algorithms as free functions. The AST is modeled as an arena
  of nodes (`std.ArrayList` of nodes + child indices, no pointers, no
  inheritance), inspired by how compilers such as Zig's represent their AST.
- **Hand-written recursive-descent parser** for openCypher (subset), no ANTLR, no
  parser generator, to stay in control of the style and the dependencies.

## Building

Zig is a self-contained toolchain; nothing is installed system-wide beyond the
`zig` binary. From the project root:

```bash
zig build test    # build and run the test suite
zig build         # build the static + shared libraries (installed to zig-out/)
```

The LMDB C sources under `vendor/lmdb/` are vendored and compiled by the build.
No Docker, no CMake, no vcpkg. `zig build` also produces `libacmedb.dylib`
(`.so` on Linux), the shared library exposing the C ABI for embedding.

## Embedding from Python

The C ABI (`src/capi.zig`) is exposed through the shared library. A minimal
ctypes example lives in `examples/demo.py`:

```bash
zig build
python3 examples/demo.py
```

## Current status

First vertical slice complete: a subset of openCypher (`MATCH` with node/edge
patterns — including multiple comma-separated patterns, `WHERE` with
comparisons and `AND`/`OR`/`NOT`, `RETURN` with aliases plus `DISTINCT`/`ORDER
BY`/`LIMIT`, and `CREATE`/`MERGE`/`SET`/`DELETE` writes) is parsed, planned
(anchor selection + predicate pushdown) and executed over index-free adjacency
in LMDB. 30 tests cover the pipeline end to end.

## Roadmap (initial openCypher subset)

1. `MATCH` with simple node/edge patterns, `WHERE` with comparisons and basic
   booleans, `RETURN` with expressions and aliases. Out of scope for this first
   pass: `OPTIONAL MATCH`, chained `WITH`, `UNWIND`, aggregations,
   `MERGE`/`CREATE`/`SET`/`DELETE`, comprehensions, subqueries.
2. Hand-written recursive-descent parser -> AST as an arena of nodes by index
   (`NodeKind` + payload + child range).
3. AST -> logical plan translation (Scan/Expand/Filter/Produce operators).
4. Key encoding in LMDB for adjacency + a first naive Volcano-style executor
   (Open/Next/Close).
5. Basic statistics + pattern "anchor" selection (the highest-impact optimization
   in a graph engine).
