# Benchmark results

`zig build bench -Doptimize=ReleaseFast -- --people 100000 --runs 200` on an Apple-silicon
laptop (macOS, APFS SSD). The graph: 100,000 people and cards, 1,000 groups, 200 zones, 10,000
doors — 211,200 nodes, 313,199 relationships, 518,200 properties, 160 MB on disk. Times include
parsing the query. Medians; the p95 is noisy on a laptop.

| Query | First run | Now |
| --- | ---: | ---: |
| load (storage API, one transaction) | 1.67 s | 1.60 s |
| card lookup | 8.3 µs | 9 µs |
| person's groups (1 hop) | 11.6 µs | 12 µs |
| colleagues (2 hops, `count(DISTINCT)`) | 90 µs | 95 µs |
| may this card open this door? (MATCH) | 432 µs | 450 µs |
| same, with `EXISTS` | 36 µs | 39 µs |
| doors of a person's zones (`*1..3`) | 127 µs | 131 µs |
| people over 60 (scan + filter, 100k nodes) | 68 ms | 34 ms |
| oldest 10 (`ORDER BY … LIMIT`) | 176 ms | 107 ms |
| group sizes (expand 200k edges + aggregate) | 159 ms | 128 ms |
| department counts (scan + group) | 75 ms | 42 ms |
| create one node (one commit: fsync) | 8.1 ms | 8.1 ms |
| create 1000 nodes (`UNWIND`, one commit) | 14 ms | 15 ms |

What changed: the label index's own label is no longer re-checked for each node it yields;
`ORDER BY … LIMIT k` sorts partially (O(n log k)); a read-only query remembers the labels it
checked; property reads decode in place instead of copying out of LMDB.

Where the time goes now (profiled with `sample`): about one B-tree search per property read
(each property is its own key), and one per label check. See the notes in the commit history for
the options considered.
