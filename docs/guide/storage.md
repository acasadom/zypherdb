# Storage — the key encoding and the graph algebra

This is the theory of how the graph is stored. If you are going to add an index, change a property
type, or debug a traversal, start here. Everything lives in `src/storage/graph.zig` (the encoding)
and `src/storage/key_value_store.zig` (the store over the storage engine).

## The model: everything is a key

There are **no tables and no schema**. The storage engine, libmdbx, keeps three B+trees in one
file:

- the main one holds every fact as a key: edges, indexes, edge properties, counters;
- `#nodes` holds the node records, keyed by the node id as a native integer (`MDBX_INTEGERKEY`);
- `#relationships` holds the relationship records (`src | dst | type`), keyed the same way by the
  relationship's id.

The engine iterates keys in **lexicographic byte order**, which is the whole trick: the layout is chosen
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
| `e \| id \| dir \| 0x00 \| type \| 0x00 \| neighbour \| rel` | one stored direction of relationship `rel` (`dir` = `'o'` out / `'i'` in); its value is the neighbour's labels | `neighbours`, `edgesOf`, `edgesBetween`, `hasEdge` |
| `rel` in `#relationships` | the relationship's record: `src \| dst \| type` | `relationship`, `hasRelationship` |
| `f \| rel \| prop` | a relationship property | `getEdgeProperty`, `edgePropertiesOf` |
| `l \| label \| 0x00 \| id` | label index | `nodesWithLabel` |
| `p \| prop \| 0x00 \| value \| id` | property index | `nodesByProperty` (an equality seek) |
| `g \| prop \| 0x00 \| value \| rel` | edge-property index | `edgesByProperty` (an equality seek) |
| `t \| type` | edge-type cardinality counter | `edgeTypeCount` (anchor selection) |
| `c \| label` | label cardinality counter (absent in databases written before it: the label index is counted) | `labelCount` (anchor selection) |
| `!` | the next node id to allocate | `allocateNodeId` |
| `!relationships` | the next relationship id to allocate | `addEdge` |

Every "index" is just more keys, maintained by the same `put`/`del` primitives. There is no
separate index structure — an index *is* a key range.

## Index-free adjacency (the core idea)

A graph database is traversed by following edges, not by joining tables, so the storage is arranged
so that **"give me the neighbours of X" is a single prefix scan**:

- Every directed, typed edge is stored **twice** — once keyed by its source (`'o'`) and once by its
  target (`'i'`). Both directions are therefore a prefix scan, with no reverse index to maintain
  separately.
- Because the neighbour id is the fixed-width field after the type, the prefix scan returns
  neighbours in ascending id order — the sort is free.
- The relationship's own id comes last. Two relationships of one type between the same nodes
  (parallel ones) are two keys that differ only there, so `e | a | 'o' | 0x00 | T | 0x00 | b` is
  the prefix of every relationship `T` from `a` to `b` (`edgesBetween`).

A traversal `(a)-[:ACTED_IN]->(b)` is literally: scan the range
`e | a | 'o' | 0x00 | ACTED_IN | 0x00` and read the neighbour's 8 bytes of each key. That is the
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
integer, so `{x: 2}` and `{x: 2.0}` find the same nodes, as `=` says they should. Integers,
floats and dates are written so that their bytes sort in their order:

- integers and dates (a day count) with the sign bit flipped;
- floats with negatives inverted and positives with the sign bit set.

A range of values is then a range of keys. `Graph.nodesInRange` reads a range of numbers as two
key ranges, integers and floats, from which NaN is excluded. It rounds fractional bounds
outwards, so it returns a superset of the matches, and the WHERE is still checked on each.

## The storage format

The key `!format` holds the format's version, `Graph.format_version` (1). When the C ABI or the
Python package opens a database, `Graph.checkFormat` stamps a new one with it, and refuses one
written in another format (`error.IncompatibleFormat`; in Python, a `StorageError`).

Until the first release there are no migrations: acmedb has no users yet, so a change to how keys
or values are written raises the version and earlier databases are not read. Migrations come with
the first release.

## The indexes, one by one

- **Node records** (a table of their own, `#nodes`, keyed by the id as an integer). A node's
  labels and properties are one value (`node_record.zig`):
  label count, then each label; property count, then each name and encoded value, both sorted.
  One B-tree search reads everything about a node, and a change rewrites the record. In a read
  transaction, three things make reading records cheaper:
  - **A reused cursor.** Records are looked up through one cursor. When the next id is at most
    four records ahead, the cursor steps forward (`MDBX_NEXT`) instead of searching. A scan's nodes
    come in id order, so a scan reads records almost sequentially.
  - **A record cache** (`RecordCache`). It keeps the records found in the transaction as the
    engine's views, which stay valid until the transaction ends. It is direct-mapped by id with 4096 slots,
    so a lookup or an insertion is one array access. A node reached many times (a team every
    member reaches) is searched for once, and a scan that reads each node once pays almost
    nothing for the cache.
  - **Generations.** Starting a read transaction moves the cache to a new generation, which
    empties it without touching it.
- **Neighbour labels on edges.** The value of each edge key is the labels of the node at the other
  end: a version byte, then the label section of that node's record. An expansion such as
  `(g)<-[:MEMBER_OF]-(p:Person)` checks `Person` without reading `p`'s record.
  - `addEdge` writes the value.
  - `addLabel` and `removeLabel` rewrite it in every neighbour's key, which costs O(degree).
  - An empty value, from a key written before this format, means the labels are unknown, and the
    record is read.
- **Label index (`l`).** Answers "which nodes carry this label" (a prefix scan), maintained with
  the record.
- **Property index (`p`).** Maps `prop == value` to node ids, maintained by `setProperty`/`removeProperty`
  and `deleteNode`. This is what turns `MATCH (p:Person {name: 'Keanu'})` from a scan into a point
  lookup.
- **Edge-property index (`g`).** The same idea for relationships, keyed `prop == value` then the
  relationship's id, whose record gives its ends and type. It lets `MATCH (a)-[r:TYPE {weight: 5}]->(b)` anchor on the edge itself when the endpoints
  carry no selectivity.
- **Edge-type counter (`t`).** A per-type cardinality, bumped by `addEdge` and decremented on
  delete, used by the planner to cap a node's cost estimate by the rarest incident edge type.

## Full-text indexes

A full-text index's definition lives under `i | name`: whether it indexes nodes or
relationships, its analyzer, its labels or types, and its properties. `!schema` counts the changes
to the definitions. Every mutation asks for it, to know whether any index must follow the change,
so inside a write transaction it is read once (`KeyValueStore.write_transaction_memo`): only that
transaction could change it, and when it does it updates the memo too. A database without
full-text indexes pays one read per write transaction.

The postings live in four key spaces of their own, each after a marker byte, the index's name and a
`0x00`. An entity is a node's or a relationship's id (8 bytes; an index holds one kind).

| Key | Value |
| --- | --- |
| `w \| name \| term \| 0x00 \| entity` | the term's occurrences in the entity, per property: its ordinal (u8), a count (u16), the positions (u32 each) |
| `W \| name \| entity` | the entity's length in terms, per property (u32 each) |
| `v \| name \| term` | how many entities have the term (u64): BM25's document frequency, and the vocabulary that prefix and fuzzy queries expand over |
| `V \| name` | the index's entities and terms (u64 each): BM25's N and average length |

Each property is analyzed on its own. A change to one property touches only the postings of the
terms of its old and new text, and their counts. The changes come from three places:

- **Nodes.** The graph's mutators (`setProperty`, `removeProperty`, `addLabel`, `removeLabel`,
  `deleteNode`) hand `fulltext_postings.nodeChanged` the record before and after. The old record
  is copied first, since a write may move the page its view points into. The node enters or
  leaves an index as its labels do.
- **Relationships.** `setEdgeProperty`, `removeEdgeProperty` and `deleteEdge` report each
  property's old and new value.
- **Schema commands.** `CREATE FULLTEXT INDEX` indexes what exists (`populate`), and `DROP INDEX`
  removes every key of the index (`clear`).

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
- `MDBX_NOSTICKYTHREADS` is set on the environment, so a single thread may hold several read
  transactions at once — the executor needs that to run a scan, then a neighbour scan *inside* it.
- An ended read transaction is reset and kept (up to four per database) for the next one to
  renew (`Environment.endRead`): starting a read costs no allocation.
- The file grows as data is written, in steps of 16 MiB, up to 1 TiB of address space
  (`mdbx_env_set_geometry`), and gives the free space at its end back to the file system once it
  passes 64 MiB.
- An iterator returned by `scanPrefix` borrows its transaction; it must be `deinit`'d **before** the
  transaction ends (the cursor belongs to it). The executor scopes every iterator to its `runStep`
  frame, which is what makes this safe.

## Durability

`KeyValueStore.openWithOptions` takes a durability mode, mapped to libmdbx flags:

| Mode | libmdbx flag | A commit returns when… |
| --- | --- | --- |
| `full` | `MDBX_SYNC_DURABLE` | data and metadata are flushed (`fsync`; `F_FULLFSYNC` on macOS) |
| `relaxed` | `MDBX_NOMETASYNC` | data is flushed; the metadata page follows with the next commit |
| `deferred` | `MDBX_SAFE_NOSYNC` | the write is in the page cache; `sync()` (`mdbx_env_sync_ex`) or the OS flushes it |

Every process that opens a database at once must agree on `deferred`: libmdbx refuses to open a
database in `deferred` mode that another process has open in `full` or `relaxed`, and the reverse.

libmdbx is copy-on-write and never overwrites live pages, so no mode can corrupt the database: a
crash loses at most the commits that were not yet flushed, and the database opens at the last
flushed one.
