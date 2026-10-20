# Storage — the key encoding and the graph algebra

This is the theory of how the graph is stored. If you are going to add an index, change a property
type, or debug a traversal, start here. Everything lives in `src/storage/graph.zig` (the encoding)
and `src/storage/key_value_store.zig` (the LMDB wrapper).

## The model: everything is a key

There are **no tables and no schema**. LMDB keeps two B+trees in one file:

- the main one holds every fact as a key: edges, indexes, edge properties, counters;
- `#nodes` holds the node records, keyed by the node id as a native integer (`MDB_INTEGERKEY`).

LMDB iterates keys in **lexicographic byte order**, which is the whole trick: the layout is chosen
so that *the order you get for free is the order you want*.

Two rules make that work:

- All integers are **big-endian and fixed-width** (ids are `u64`, 8 bytes). So byte order equals
  numeric order, and no id is ever a prefix of another.
- A `0x00` byte separates variable-length parts (strings), because an openCypher identifier can
  never contain `0x00`.

## The key layout

(`|` = concatenation; `id` = 8-byte big-endian `u64`.)

| Key | Meaning | Answering |
| --- | --- | --- |
| `id` in `#nodes` | the node record: labels and properties | `hasNode`, `labelsOf`, `propertiesOf`, `getProperty` |
| `e \| id \| dir \| 0x00 \| type \| 0x00 \| neighbour` | one stored direction of a typed edge (`dir` = `'o'` out / `'i'` in) | `neighbours`, `hasEdge` |
| `f \| src \| dst \| 0x00 \| type \| 0x00 \| prop` | an edge property, in the **canonical** `src -> dst` orientation | `getEdgeProperty` |
| `l \| label \| 0x00 \| id` | label index | `nodesWithLabel` |
| `p \| prop \| 0x00 \| value \| id` | property index | `nodesByProperty` (an equality seek) |
| `g \| prop \| 0x00 \| value \| src \| dst \| 0x00 \| type` | edge-property index | `edgesByProperty` (an equality seek) |
| `t \| type` | edge-type cardinality counter | `edgeTypeCount` (anchor selection) |
| `!` | the next node id to allocate | `allocateNodeId` |

Every "index" is just more keys, maintained by the same `put`/`del` primitives. There is no
separate index structure — an index *is* a key range.

## Index-free adjacency (the core idea)

A graph database is traversed by following edges, not by joining tables, so the storage is arranged
so that **"give me the neighbours of X" is a single prefix scan**:

- Every directed, typed edge is stored **twice** — once keyed by its source (`'o'`) and once by its
  target (`'i'`). Both directions are therefore a prefix scan, with no reverse index to maintain
  separately.
- Because the neighbour id is the **trailing** fixed-width field, the prefix scan returns
  neighbours in ascending id order — the sort is free.

A traversal `(a)-[:ACTED_IN]->(b)` is literally: scan the range
`e | a | 'o' | 0x00 | ACTED_IN | 0x00` and read the last 8 bytes of each key. That is the
"index-free adjacency" (IFA) model — no pointer, no join, just locality in the key space.

## Value encoding

A property `Value` is a one-byte tag + payload (`src/storage/value_encoding.zig`), integers
big-endian:

| Tag | Value | Payload |
| --- | --- | --- |
| `0x01` | `int` | `i64` |
| `0x02` | `str` | raw bytes |
| `0x03` | `boolean` | one byte, `0` or `1` |
| `0x04` | `float` | IEEE 754 bits, `u64` |
| `0x05` | date | days since 1970-01-01, `i64` |
| `0x06` | local time | nanoseconds of the day, `i64` |
| `0x07` | time | nanoseconds of the day, `i64`; offset seconds, `i32` |
| `0x08` | local date-time | seconds, `i64`; nanoseconds, `u32` |
| `0x09` | date-time | UTC seconds, `i64`; nanoseconds, `u32`; offset, `i32`; zone name bytes |
| `0x0a` | duration | months, days, seconds, `i64`; nanoseconds, `u32` |
| `0x0b` | list | count, `u32`; per element its length, `u32`, and its encoding |
| `0x0c` | map | count, `u32`; per entry the key and the value, each as a list element |
| `0x0d` | null | nothing (only inside a map) |

A list is stored only when its elements share one storable type (integers and floats count as
one). A map — a document, an acmedb extension — holds any of these values, nested maps, lists of
any elements, and nulls. A null on its own is never stored: setting a property to null removes it.

Index keys use the same encoding except that variable-length parts (strings, zone names) end in
`0x00`, so a lookup prefix for `"X"` can't also match `"XY"`, and list elements carry no length.
Numbers are indexed canonically: a float that equals an integer (`2.0`) is indexed as that
integer, so `{x: 2}` and `{x: 2.0}` find the same nodes, as `=` says they should.

## The indexes, one by one

- **Node records** (a table of their own, `#nodes`, keyed by the id as an integer). A node's
  labels and properties are one value (`node_record.zig`):
  label count, then each label; property count, then each name and encoded value, both sorted.
  One B-tree search reads everything about a node, and a read transaction looks records up
  through one reused cursor, which LMDB repositions without searching from the root when the
  next key is near the last (a scan's nodes come in id order). A change rewrites the record.
- **Label index (`l`).** Answers "which nodes carry this label" (a prefix scan), maintained with
  the record.
- **Property index (`p`).** Maps `prop == value` to node ids, maintained by `setProperty`/`removeProperty`
  and `deleteNode`. This is what turns `MATCH (p:Person {name: 'Keanu'})` from a scan into a point
  lookup.
- **Edge-property index (`g`).** The same idea for edges, keyed `prop == value` then `(src, dst,
  type)`. It lets `MATCH (a)-[r:TYPE {weight: 5}]->(b)` anchor on the edge itself when the endpoints
  carry no selectivity.
- **Edge-type counter (`t`).** A per-type cardinality, bumped by `addEdge` and decremented on
  delete, used by the planner to cap a node's cost estimate by the rarest incident edge type.

## The id counter

`allocateNodeId` does a read-modify-write on the `!` key (8-byte counter): read, increment, write.
In a write transaction this is atomic with the rest of the query, so a `CREATE` that aborts rolls
the counter back too. `addNode` accepts an id chosen by the caller and moves the counter past it,
so the counter never hands out an id that is in use.

## Transactions

- **Writes** are atomic: the executor opens one write transaction per query
  (`beginWrite`/`commitWrite`); every `put`/`del`/`get`/`scanPrefix` inside it routes through that
  transaction and sees its uncommitted writes. An aborted query rolls everything back, including the
  id counter.
- **Reads** are batched: a read-only query opens one read transaction (an MVCC snapshot,
  `beginRead`/`commitRead`) and all its reads run inside it — so a filtered scan is O(1)
  transactions, not one per `get`.
- `MDB_NOTLS` is set on the environment, so a single thread may hold several read transactions at
  once — the executor needs that to run a scan, then a neighbour scan *inside* it.
- The environment maps up to 1 TiB of address space (`mdb_env_set_mapsize`); the file only grows
  as data is written.
- An iterator returned by `scanPrefix` borrows its transaction; it must be `deinit`'d **before** the
  transaction ends (the cursor belongs to it). The executor scopes every iterator to its `runStep`
  frame, which is what makes this safe.

## Durability

`KeyValueStore.openWithOptions` takes a durability mode, mapped to LMDB flags:

| Mode | LMDB flag | A commit returns when… |
| --- | --- | --- |
| `full` | none | data and metadata are flushed (`fsync`) |
| `relaxed` | `MDB_NOMETASYNC` | data is flushed; the metadata page follows with the next commit |
| `deferred` | `MDB_NOSYNC` | the write is in the page cache; `sync()` (`mdb_env_sync`) or the OS flushes it |

LMDB is copy-on-write and never overwrites live pages, so no mode can corrupt the database: a
crash loses at most the commits that were not yet flushed, and the database opens at the last
flushed one.
