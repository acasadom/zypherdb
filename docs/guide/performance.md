# Performance: known risks

What is known to be slow, or could become slow, and is not fixed yet. Each entry says what
happens, when it matters, and the fix being considered. Measured numbers are in
`bench/RESULTS.md` (`zig build bench -Doptimize=ReleaseFast`).

## Execution

- **Rows are materialized between clauses.** Each clause produces all its rows before the next
  starts. `MATCH … RETURN … LIMIT 10` finds every match first; memory grows with the
  intermediate result. Fix: a pipelined (pull-based) executor, so `LIMIT` stops the work early
  and rows stream to the caller.
- **`RETURN` projects every row before `ORDER BY … LIMIT`.** The partial sort keeps k rows, but
  every row's projected columns are computed first. Fix: compute the sort key first and the other
  columns only for the rows kept (late materialization).
- **Pattern predicates, `EXISTS` and pattern comprehensions collect every match.** A predicate
  needs only the first. Fix: stop at the first match for `EXISTS` and pattern predicates.
- **Unbounded variable-length paths (`-[*]->`)** enumerate every path, which grows exponentially
  on dense graphs. Fix: a bound or a warning; for reachability (`EXISTS`, `count(DISTINCT)`) a
  visited set instead of path enumeration; shortest paths as a separate algorithm.
- **Relationship uniqueness is a linear scan** of the edges used on the current branch: fine for
  short patterns, quadratic for long variable-length ones. Fix: a hash set past a few edges.
- **The property cache was removed.** Caching every property read in a read-only query halved a
  query that revisits nodes (group sizes) but slowed scans, where each node is read once. Only
  labels are cached. Fix: cache records per node, only for nodes reached by expansion, or a small
  bounded cache.

## Planning

- **The planner knows only equality.** `{name: 'x'}` and `n.x = $v` use the property index;
  `n.age > 60`, `STARTS WITH` and `IN` scan every node of the label. Fix: range-ordered index
  keys (integers are big-endian two's complement, so negatives sort after positives today) and
  range seeks.
- **Cost estimates count a label's nodes by scanning them** (`labelCount`) for every MATCH
  without a seek. Fix: per-label counters, like the edge-type counters.
- **Anchor choice is per node, greedy.** Joins of several patterns are matched in written order,
  with no reordering by selectivity.
- **Expansions check the target's labels with one random node lookup each** (the dominant cost of
  "group sizes" in the benchmark). Fix: keep the neighbour's labels with the edge key, or
  per-label bitmaps.

## Storage

- **Edge properties are one key each** (node properties are one record per node). A query that
  reads several properties of many relationships pays one B-tree search for each. Fix: an edge
  record, as for nodes.
- **Every node property is indexed**, which doubles the writes and the disk used. Fix: indexes
  declared per label and property (`CREATE INDEX`), the rest stored only in records.
- **One relationship per (source, target, type).** Not a performance issue but a model limit:
  parallel relationships need an edge id in the key.
- **A commit with `full` durability waits for the disk** (about 8 ms on macOS, which uses
  `F_FULLFSYNC`). Many small writes should be batched (`write()`, `UNWIND`) or use `relaxed` or
  `deferred` durability.
- **Node record rewrites**: setting one property rewrites the node's whole record. Fine for normal
  records; slow for nodes with very large documents (map properties) updated often.
- **Map properties (documents) are indexed whole.** A filter on a field inside one
  (`n.doc.city = 'x'`) reads every candidate's record. Fix: indexes on document paths.
- **Cold reads go to disk.** LMDB maps the file into memory; the first read of each page in a
  process whose file is not in the operating system's cache is a disk read (about 200 µs per
  point query on a laptop SSD, until the pages a query needs are cached). Normal for a disk
  database, but it makes the first queries after a start slow. Fix if needed: an optional warm-up
  (read the file, or `madvise`), documented for latency-sensitive uses.

## Python bindings

- **Results and parameters go through JSON.** Measured (`bench/RESULTS.md`): a point query costs
  13 µs from Python, 6 µs of it in Python (encoding parameters, copying and parsing the result);
  returning 100k rows spends about 30 of its 65 ms writing and parsing JSON. One `ctypes` call per
  write in the mutator API. The plan is a native extension module written in Zig on the Python C
  API that converts values directly.
