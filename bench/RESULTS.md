# Benchmark results

`zig build bench -Doptimize=ReleaseFast -- --people 100000 --runs 200` on an Apple-silicon
laptop (macOS, APFS SSD). The graph: 100,000 people and cards, 1,000 groups, 200 zones, 10,000
doors — 211,200 nodes, 313,199 relationships, 518,200 properties (160 MB on disk at first,
128 MB with node records, 112 MB with their own table). Times include
parsing the query. Medians; the p95 is noisy on a laptop.

| Query | First run | 72d4455 | Node records | Node table, cursors, planner |
| --- | ---: | ---: | ---: | ---: |
| load (storage API, one transaction) | 1.67 s | 1.60 s | 1.72 s | 1.51 s |
| card lookup | 8.3 µs | 9 µs | 5.7 µs | 6.1 µs |
| person's groups (1 hop) | 11.6 µs | 12 µs | 8.8 µs | 8.8 µs |
| colleagues (2 hops, `count(DISTINCT)`) | 90 µs | 95 µs | 89 µs | 88 µs |
| may this card open this door? (MATCH) | 432 µs | 450 µs | 266 µs | 29 µs |
| same, with `EXISTS` | 36 µs | 39 µs | 36 µs | 36 µs |
| doors of a person's zones (`*1..3`) | 127 µs | 131 µs | 128 µs | 126 µs |
| people over 60 (scan + filter, 100k nodes) | 68 ms | 34 ms | 16 ms | 16 ms |
| oldest 10 (`ORDER BY … LIMIT`) | 176 ms | 107 ms | 44 ms | 39 ms |
| group sizes (expand 200k edges + aggregate) | 159 ms | 128 ms | 118 ms | 92 ms |
| department counts (scan + group) | 75 ms | 42 ms | 25 ms | 25 ms |
| create one node (one commit: fsync) | 8.1 ms | 8.1 ms | 8.0 ms | 8.2 ms (deferred durability: 20 µs) |
| create 1000 nodes (`UNWIND`, one commit) | 14 ms | 15 ms | 13 ms | 14 ms (deferred: 2.6 ms) |

What changed: the label index's own label is no longer re-checked for each node it yields;
`ORDER BY … LIMIT k` sorts partially (O(n log k)); a read-only query remembers the labels it
checked; property reads decode in place instead of copying out of LMDB.

Node records: a node's labels and properties are one stored value, looked up through a reused
read cursor (LMDB skips the descent from the root when the next key is near the last one).

Then: node records moved to a table of their own with integer keys (a smaller tree, integer
comparisons); finished scans give their cursors back to a pool, so a nested scan reuses the one
its depth used, positioned near where it starts; an expansion to a node found by an index seek
(`(:Door {id: $door})`) tests the edges to its few candidates instead of reading every
neighbour's properties (the access check, 266 → 29 µs). Durability modes: `full` (default),
`relaxed`, `deferred` (`--durability`).

Where the time goes now: random lookups of node records (checking the label of each node an
expansion reaches), and edge properties, still one key each.

## libmdbx instead of LMDB (October 2026)

The same code on each engine (`-Dstorage-engine`, before LMDB was removed), each loading its own
data; best median of four alternating rounds, `--people 100000 --runs 200`, full durability. The
queries that differed most were then run again alone, five rounds each.

| Query | LMDB | libmdbx | |
| --- | ---: | ---: | ---: |
| load (storage API, one transaction) | 2.32 s | 2.59 s | +11% |
| card lookup | 5.6 µs | 5.1 µs | −9% |
| person's groups (1 hop) | 8.6 µs | 7.5 µs | −13% |
| colleagues (2 hops, `count(DISTINCT)`) | 80 µs | 76 µs | −4% |
| may this card open this door? (MATCH) | 35 µs | 30 µs | −16% |
| same, with `EXISTS` | 37 µs | 38 µs | 0% |
| doors of a person's zones (`*1..3`) | 120 µs | 119 µs | 0% |
| people over 60 (range index + records) | 4.2 ms | 5.1 ms | +22% |
| oldest 10 (`ORDER BY … LIMIT`) | 24.5 ms | 25.2 ms | +3% |
| group sizes (expand 200k edges + aggregate) | 25.1 ms | 26.6 ms | +6% |
| department counts (scan + group) | 13.1 ms | 13.2 ms | +1% |
| return 100k rows (3 columns) | 16.9 ms | 17.3 ms | +2% |
| create one node (one commit) | 8.1 ms | 4.1 ms | −50% |
| create 1000 nodes (`UNWIND`, one commit) | 15.9 ms | 11.0 ms | −31% |

Both flush with `F_FULLFSYNC` on macOS; libmdbx's commit needs fewer flushes. What is slower is a
B-tree search of the integer-keyed node table, which the range-index scan does once per run of
ids (`p.age > 60` yields ids in age order): libmdbx's search costs more per seek. `-O3`,
`MDBX_DISABLE_VALIDATION` and 4, 8 or 16 KiB pages did not change it. `MDBX_WRITEMAP` made a
commit 10x faster, but on macOS it flushes with `msync` and no `F_FULLFSYNC`, which is not
durable: not used. `MDBX_LIFORECLAIM` changed nothing measurable. Renewing read transactions
instead of making them made short reads 2-3% faster.

## The Python bindings (ctypes and JSON)

`python bench/python_overhead.py --dir .bench-data` on the same graph, the database file read
first so it is in the OS page cache (as in a process that has been running a while; with
`--cold` the first reads of each page go to disk, about 200 µs per query until the pages a
query needs are cached). Medians:

| Query | Total | Parameters (`json.dumps`) | Native call (engine + JSON out) | Copy | Decode (`json.loads`) | Python's share |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| card lookup | 13.2 µs | 2.5 µs | 7.3 µs | 1.0 µs | 2.5 µs | 45% |
| person's groups (1 hop) | 15.8 µs | 2.3 µs | 10.0 µs | 1.0 µs | 2.5 µs | 37% |
| colleagues | 80 µs | 2.5 µs | 73 µs | 1.2 µs | 2.5 µs | 8% |
| may this card open this door? | 53 µs | 3.5 µs | 45 µs | 1.3 µs | 3.0 µs | 15% |
| people over 60 (scan) | 17 ms | – | 17 ms | – | – | 0% |
| return 100k rows (3 columns) | 65 ms | – | 43 ms | 0.2 ms | 22 ms | 34% |
| return 10k whole nodes | 37 ms | – | 17 ms | 0.1 ms | 19 ms | 53% |

The engine alone (`zig build bench`) takes 6 µs for the card lookup, 33 ms to produce the 100k
rows and 13 ms for the 10k nodes: writing the JSON costs about 10 ms of the native call for 100k
rows, and parsing it in Python twice that.

## The native extension module

The same benchmark (`python bench/python_overhead.py`) after the package moved to
`acmedb._native` (Zig on the Python limited API, no JSON). Medians, page cache warm:

| Query | Engine alone | ctypes + JSON | Native module |
| --- | ---: | ---: | ---: |
| card lookup | 6.0 µs | 13.2 µs | 7.4 µs |
| person's groups (1 hop) | 9.3 µs | 15.8 µs | 10.2 µs |
| colleagues | 87 µs | 80 µs | 77 µs |
| may this card open this door? | 28 µs | 53 µs | 30 µs |
| people over 60 (scan) | 16 ms | 17 ms | 16 ms |
| return 100k rows (3 columns) | 31 ms | 65 ms | 41 ms |
| return 10k whole nodes | 13 ms | 37 ms | 23 ms |

What Python adds now: about 1.4 µs per query, and about 35 ns per returned cell; a whole node
about 1 µs (its labels tuple and properties dict). The cycle collector is paused while a result is
built, and entities are built without running their `__init__`.
