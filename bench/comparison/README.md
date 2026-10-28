# ZypherDB compared with other embedded graph databases

In October 2026, before publishing, ZypherDB was measured against four other embedded graph
databases that speak Cypher, to check that ZypherDB's performance holds up against real
alternatives.

| Engine | Language | Version | Binding used |
| --- | --- | --- | --- |
| ZypherDB | Zig | 0.1.0 (October 2026) | native module (Zig, Python limited API) |
| [LatticeDB](https://github.com/jeffhajewski/latticedb) | Zig | 0.15.0 (commit 3f797d5) | ctypes; also its C API |
| [Kuzu](https://pypi.org/project/kuzu/) | C++ | 0.11.3 (archived October 2025) | pybind11 |
| [SparrowDB](https://github.com/ryaker/SparrowDB) | Rust | 0.1.27 (commit 479fb18) | PyO3, built from source |
| [GraphQLite](https://github.com/colliery-io/graphqlite) | C (SQLite extension) | 0.12.0 | its Python package over `sqlite3` |

All measurements were taken on one Apple-silicon laptop (macOS), with the page cache warm. Times
are medians.

## The workload

The workload is the access-control graph of `bench/access_control.zig`:

- people, each holding a card and belonging to one to three teams;
- a hierarchy of teams;
- team grants to zones, with days and hours;
- doors in zones.

Every engine gets the same generated graph, the same parameters and the same Cypher text. Names
are chosen so that no engine trips on a reserved word: `Team`, `opens`/`closes` and `LOCATED_IN`.

| Query | What it exercises |
| --- | --- |
| card lookup | an index seek |
| person's teams | one hop |
| colleagues | two hops, `count(DISTINCT)` |
| may this card open this door? | `*1..3`, relationship properties, a filter |
| same, with `EXISTS` | an existential subquery |
| doors of a person's zones | `*1..3`, then two more hops |
| people over 60 | a range on an indexed property, counted |
| oldest 10 | `ORDER BY … LIMIT` |
| team sizes, department counts | aggregation |
| return all people | result transfer |
| create one node | one commit |
| create 1000 nodes | `UNWIND` with `CREATE` |

Each engine is given its best case:

- it loads by its fastest bulk path:
  - ZypherDB: its mutators in one transaction;
  - Kuzu: `COPY` from CSV files, with writing the files counted in the load time;
  - SparrowDB: its Rust `BulkLoader`;
  - LatticeDB: its storage API in one transaction;
  - GraphQLite: its bulk inserts (`insert_nodes_bulk`, `insert_edges_bulk`), which bypass Cypher;
    they also store each node's external id as a text property `id`, so the benchmark removes
    those rows and keeps the graph's integer `id`;
- it has the indexes it needs: the engines with explicit indexes get one on each property the
  queries look up or filter on, `Person.age` included; GraphQLite indexes every property by
  itself; Kuzu indexes only primary keys;
- it reuses prepared statements where it has them;
- SparrowDB gets its parameters inlined as literals, because its index is used only with literal values.

ZypherDB is built with `-Doptimize=ReleaseFast`.

## Results

### Speed, from Python

These rows are for 100,000 people (2,000 for SparrowDB, whose load takes 43 s even at that size).

| Query | ZypherDB | Kuzu | GraphQLite | SparrowDB (2k) |
| --- | ---: | ---: | ---: | ---: |
| load | 2.7 s | **0.7 s** | 4.2 s | 43 s |
| card lookup | **5 µs** | 188 µs | 161 µs | 150 µs |
| person's teams | **8 µs** | 559 µs | 175 µs | 51 ms |
| colleagues | **61 µs** | 1.3 ms | 592 µs | 55 ms |
| may this card open this door? | **23 µs** | 261 ms | 1.7 s | not supported |
| same, with `EXISTS` | **34 µs** | 9.7 ms | 4.2 s | not supported |
| doors of a person's zones | **88 µs** | 2.5 ms | 1.4 ms | 56 ms |
| people over 60 | 0.32 ms | **0.31 ms** | 10 ms | 7.8 ms |
| oldest 10 | 19 ms | **3.8 ms** | 280 ms | 73 ms |
| team sizes | 28 ms | **21 ms** | 317 ms | 178 ms |
| department counts | 14 ms | **4.1 ms** | 89 ms | 64 ms |
| return all people | **25 ms** | 71 ms | 423 ms | 168 ms |
| create one node | 9 ms | **4 ms** | 13 ms | 9 ms |

GraphQLite ran each query 20 times at this size instead of 200, because the access check takes
seconds.

For SparrowDB the ZypherDB numbers at the same size are in `results/python-zypherdb-2k.jsonl`, for
example 5.5 µs for a person's teams.

LatticeDB was measured at 10,000 people: its load is quadratic, and 100,000 people did not finish
loading within 15 minutes. The table below is natively from C, which removes its ctypes overhead
(`native/bench.c`):

| Query | ZypherDB | LatticeDB |
| --- | ---: | ---: |
| load | 0.25 s | 25 s |
| card lookup | 4 µs | 108 µs |
| colleagues | 66 µs | 221 µs |
| may this card open this door? | 19 µs | 4.0 ms |
| people over 60 | 39 µs | 406 ms |
| oldest 10 | 2.1 ms | 8.6 s |
| create one node | 7.1 ms (24 µs with `deferred` durability) | 107 µs |

### Commits are compared at equal durability

On macOS, ZypherDB's `full` durability flushes the drive's cache with `F_FULLFSYNC`, twice per
commit (data and metadata), so a commit survives a power cut. LatticeDB syncs with a plain
`fsync`, which does not flush that cache. ZypherDB's `relaxed` mode needs one flush, about 4 ms, the
same as Kuzu. Its `deferred` mode needs none: 24 µs. GraphQLite runs with `PRAGMA fullfsync = ON`,
the same flush as ZypherDB's `full`.

## What this says

- On transactional work (lookups, traversals, access decisions, results to Python), ZypherDB is
  faster than all three: 3–210× faster than LatticeDB, 20–11000× than Kuzu, 45–9000× than
  SparrowDB.
- On analytics over the whole graph (sorts, aggregates), Kuzu is 1.3–4.9× faster than ZypherDB.
  Counting a range of an indexed property is as fast in both (0.3 ms), as ZypherDB counts it from
  the index.
  The reason is its columnar storage, not parallelism: with one thread it is as fast. Kuzu also
  loads in bulk 4× faster. These are ZypherDB's known gaps (see `docs/guide/performance.md`).
- On features, LatticeDB and SparrowDB have full-text search, and LatticeDB has vector search.
  ZypherDB has had full-text search (BM25) since; it has no vector search yet.
- GraphQLite: ZypherDB is 10–125,000× faster on transactional work and 6–17× on sorts, aggregates
  and returning rows. GraphQLite has graph algorithms (PageRank, Louvain, Dijkstra) and plain SQL
  access to the same SQLite file; ZypherDB has neither.

## Reproducing

From the repository root, with ZypherDB built optimized
(`zig build python -Doptimize=ReleaseFast -Dpython-include=…`). Each engine is installed in its own
virtual environment. Kuzu has wheels up to Python 3.13.

```bash
# docs-test: skip
pip install kuzu==0.11.3 latticedb==0.15.0 graphqlite==0.12.0
python bench/comparison/bench_python.py --engine zypherdb --people 100000 --dir /tmp/b-zypherdb --runs 200
python bench/comparison/bench_python.py --engine kuzu --people 100000 --dir /tmp/b-kuzu --runs 200 [--threads 1]
python bench/comparison/bench_python.py --engine graphqlite --people 100000 --dir /tmp/b-graphqlite --runs 20
python bench/comparison/table.py bench/comparison/results/python-zypherdb-100k.jsonl bench/comparison/results/python-kuzu-100k.jsonl
```

SparrowDB is not on PyPI; the package named `sparrowdb` there is an unrelated project. It needs
Rust 1.89 or later:

```bash
# docs-test: skip
git clone https://github.com/ryaker/SparrowDB && cd SparrowDB && git checkout 479fb18
(cd crates/sparrowdb-python && maturin build --release --features python) && pip install target/wheels/*.whl
cargo build --release --manifest-path bench/comparison/sparrow-loader/Cargo.toml
python bench/comparison/bench_python.py --engine sparrowdb --people 2000 --dir /tmp/b-sparrow --runs 20
```

The native benchmark builds against each engine's C library and header:

```bash
# docs-test: skip
cc -O2 -Izig-out/include bench/comparison/native/bench.c -Lzig-out/lib -lzypherdb -o bench-zypherdb
cc -O2 -DLATTICE -I<latticedb>/include bench/comparison/native/bench.c -L<dir of liblattice> -llattice -o bench-lattice
./bench-zypherdb /tmp/n-zypherdb 10000 100 [full|relaxed|deferred]
./bench-lattice /tmp/n-lattice 10000 100
```

