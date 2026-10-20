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
