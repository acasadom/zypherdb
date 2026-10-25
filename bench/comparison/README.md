# ZypherDB compared with other embedded graph databases

In October 2026, before publishing, ZypherDB was measured against three other embedded graph
databases that speak Cypher. The goal was to check two things: that ZypherDB's performance holds up
against real alternatives, and that its answers are correct.

| Engine | Language | Version | Binding used |
| --- | --- | --- | --- |
| ZypherDB | Zig | `main`, October 2026 | native module (Zig, Python limited API) |
| [LatticeDB](https://github.com/jeffhajewski/latticedb) | Zig | 0.15.0 (commit 3f797d5) | ctypes; also its C API |
| [Kuzu](https://pypi.org/project/kuzu/) | C++ | 0.11.3 (archived October 2025) | pybind11 |
| [SparrowDB](https://github.com/ryaker/SparrowDB) | Rust | 0.1.27 (commit 479fb18) | PyO3, built from source |

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
| people over 60 | a scan of every person, with a filter |
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
- it has the indexes it needs;
- it reuses prepared statements where it has them;
- SparrowDB gets its parameters inlined as literals, because it ignores its index for `$parameters`.

ZypherDB is built with `-Doptimize=ReleaseFast`.

## Results

### Speed, from Python

These rows are for 100,000 people (2,000 for SparrowDB, whose load takes 41 s even at that size).

| Query | ZypherDB | Kuzu | SparrowDB (2k) |
| --- | ---: | ---: | ---: |
| load | 2.5 s | **0.7 s** | 41 s |
| card lookup | **8 µs** | 181 µs | 94 µs |
| person's teams | **11 µs** | 516 µs | 52 ms |
| colleagues | **79 µs** | 2.8 ms | 57 ms |
| may this card open this door? | **33 µs** | 263 ms | not supported |
| same, with `EXISTS` | **36 µs** | 10 ms | not supported |
| doors of a person's zones | **119 µs** | 2.7 ms | 62 ms |
| people over 60 | 17 ms | **0.3 ms** | 8 ms |
| oldest 10 | 44 ms | **3.6 ms** | 75 ms (wrong order) |
| team sizes | 118 ms | **21 ms** | 197 ms |
| department counts | 26 ms | **3.4 ms** | 69 ms |
| return all people | **52 ms** | 78 ms | 179 ms |
| create one node | 8 ms | **4 ms** | 10 ms |

For SparrowDB the ZypherDB numbers at the same size are in `results/python-zypherdb-2k.jsonl`, and
they are lower still: for example 6 µs for a person's teams.

LatticeDB was measured at 10,000 people: its load is quadratic, and 100,000 people did not finish
loading within 15 minutes. The table below is natively from C, which removes its ctypes overhead
(`native/bench.c`):

| Query | ZypherDB | LatticeDB |
| --- | ---: | ---: |
| load | 0.20 s | 27 s |
| card lookup | 6 µs | 118 µs |
| colleagues | 79 µs | 215 µs |
| may this card open this door? | 22 µs | 4.1 ms |
| people over 60 | 1.6 ms | 426 ms |
| oldest 10 | 3.4 ms | 9.5 s |
| create one node | 8.1 ms (23 µs with `deferred` durability) | 100 µs |

### Commits are compared at equal durability

On macOS, ZypherDB's `full` durability flushes the drive's cache with `F_FULLFSYNC`, twice per
commit (data and metadata), so a commit survives a power cut. LatticeDB syncs with a plain
`fsync`, which does not flush that cache. ZypherDB's `relaxed` mode needs one flush, about 4 ms, the
same as Kuzu. Its `deferred` mode needs none: 23 µs.

### Correctness

openCypher matches each relationship at most once in a pattern. So in
`(p)-[:MEMBER_OF]->(g)<-[:MEMBER_OF]-(q)`, `q` is never `p`. ZypherDB follows that rule. The other
three count the person among their own colleagues:

- Kuzu does it by design (walk semantics);
- LatticeDB and SparrowDB do not document it.

Answers were cross-checked engine against engine, and against a computation in plain Python.
Other wrong results:

- **SparrowDB:**
  - `ORDER BY` on a property that is not returned gives the wrong order;
  - a 3-hop pattern gives 0 where the equivalent `EXISTS` gives true;
  - `MATCH … CREATE` with parameters silently creates nothing;
  - it cannot read relationship properties (its issue #248).
- **LatticeDB:** `RETURN n` returns an id, not the node.

### Coverage of the openCypher TCK

The TCK was run in results-only mode: rows and errors are checked, side effects are not, because
LatticeDB has no storage-level export to count them with. The result is 3000/3202 positive
scenarios for ZypherDB (93.7%) and 210/3202 for LatticeDB (6.6%). Most of LatticeDB's failures are
queries it rejects:

- `OPTIONAL MATCH`;
- `RETURN` without `MATCH`;
- map literals and temporal values;
- `UNION`, paths and `count(*)`;
- `IN` as a relationship type.

The full reports are in `results/tck-*.md`. Kuzu needs a schema declared before any data, so the
TCK cannot run on it unchanged. SparrowDB was not run.

## What this says

- On transactional work (lookups, traversals, access decisions, results to Python), ZypherDB is
  faster than all three: 3–200× faster than LatticeDB, 15–8000× than Kuzu, 20–8000× than
  SparrowDB.
- On analytics over the whole graph (scans, sorts, aggregates), Kuzu is 5–50× faster than ZypherDB.
  The reason is its columnar storage, not parallelism: with one thread it is as fast. Kuzu also
  loads in bulk 3.5× faster. These are ZypherDB's known gaps (see `docs/guide/performance.md`).
- On features, LatticeDB and SparrowDB have full-text search, and LatticeDB has vector search.
  ZypherDB has neither.

## Reproducing

From the repository root, with ZypherDB built optimized
(`zig build python -Doptimize=ReleaseFast -Dpython-include=…`). Each engine is installed in its own
virtual environment. Kuzu has wheels up to Python 3.13.

```bash
# docs-test: skip
pip install kuzu==0.11.3 latticedb==0.15.0
python bench/comparison/bench_python.py --engine zypherdb --people 100000 --dir /tmp/b-zypherdb --runs 200
python bench/comparison/bench_python.py --engine kuzu --people 100000 --dir /tmp/b-kuzu --runs 200 [--threads 1]
python bench/comparison/table.py bench/comparison/results/python-zypherdb-100k.jsonl bench/comparison/results/python-kuzu-100k.jsonl
python bench/comparison/tck_compare.py --engine latticedb --report /tmp/tck-latticedb.md
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

`results/python-latticedb-10k.jsonl` comes from an earlier version of the Python script, with
`Group` for `Team` and different parameter draws. Its times are comparable; its answers are not.
