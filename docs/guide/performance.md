# Performance: known risks

What is known to be slow, or could become slow, and is not fixed yet. Each entry says what
happens, when it matters, and the fix being considered. Measured numbers are in
`bench/RESULTS.md` (`zig build bench -Doptimize=ReleaseFast`).

## Execution

- **Queries that write materialize rows between clauses.** Read-only queries stream rows through
  their clauses (`pipeline.zig`). A query with a writing clause still makes each clause produce
  all its rows before the next starts, so its memory grows with the intermediate result. Fix:
  stream the clauses before the first write, and materialize only there (an "eager" boundary).
- **Some stages still need every row:**
  - `RETURN` holds all the rows it returns, so the caller gets nothing until the query ends.
    Fix: hand rows to the caller as they come (an iterator in the bindings).
  - A `WITH` that sorts, pages or removes duplicates keeps copies of every row.
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
- **Each property read decodes from the record.** A record is found once per node, through the
  record cache (see [storage](storage)). But each `n.prop` still walks the record's property list
  and decodes its value.

## Planning

- **Ranges are for numbers and dates only.** Comparisons on strings, times and date-times,
  `STARTS WITH` and `IN` still scan every node of the label. Fix: ordered encodings for those
  types (strings already sort by bytes), and seeks for `STARTS WITH` (a prefix range) and `IN`
  (one seek per element).
- **The property index is shared by every label.** A range lookup returns nodes of any label,
  and each one's record is read to check its label, in the order of the values, not of the ids.
  This is the largest part of a range query's time. Fix: index keys per label and property.
- **A range's selectivity is a guess** (a quarter of the label). Fix: statistics per property.
- **Each label change reads and writes the label's counter** (`c | label`, kept for the
  planner). Creating many labeled nodes in one transaction pays one counter update per node,
  about 2 µs. Fix: keep the transaction's counter changes in memory and write them at commit.
- **Anchor choice is per node, greedy.** Joins of several patterns are matched in written order,
  with no reordering by selectivity.
- **Edge keys carry the neighbour's labels as text** (about 11 bytes for one short label). Fewer
  keys fit in a page, so expansions that need no label check are about 10% slower than with empty
  values. Loading is about 30% slower, because each new edge reads both ends' records. Fix: label
  ids (a dictionary of labels) instead of names, and a bulk loader that knows the labels.

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

- **A returned node costs about 1 µs in Python** (its labels tuple and properties dict, with a new
  key string per property). Fix if it matters: reuse the key strings of a result (property names
  repeat across rows).
- **Results are built whole.** A query returns a list of every row; a large result is all in
  memory at once. Fix: return an iterator that converts rows as they are read (needs the pipelined
  executor above to pay off fully).
