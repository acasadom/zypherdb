# Storage — the key encoding and the graph algebra

This is the theory of how the graph is stored. If you are going to add an index, change a property
type, or debug a traversal, start here. The encodings live in `src/storage/key_encoding.zig` (keys),
`value_encoding.zig` (values) and `node_record.zig` (node records); `graph.zig` maintains them, and
`key_value_store.zig` is the store over the storage engine.

## The model: everything is a key

There are **no tables and no schema**. The storage engine (LMDB by default, or libmdbx with
`-Dstorage-engine=mdbx`; see [the engines](#the-storage-engines)) keeps three B+trees in one file:

- the main one holds every fact as a key: edges, indexes, edge properties, counters;
- `#nodes` holds the node records, keyed by the node id as a native integer (an integer-key table);
- `#relationships` holds the relationship records (`src | dst | type`), keyed the same way by the
  relationship's id.

The engine iterates keys in **lexicographic byte order**, which is the whole trick: the layout is chosen
so that *the order you get for free is the order you want*.

Two rules make that work:

- All integers are **big-endian and fixed-width** (ids are `u64`, 8 bytes). So byte order equals
  numeric order, and no id is ever a prefix of another.
- A `0x00` byte separates variable-length parts (strings). A quoted openCypher name could contain
  `0x00`, so acmedb refuses labels, relationship types and property names that contain it or are
  empty (writes.zig `requireStorableName`; `ACMEDB_INVALID_NAME` in C, `ValueError` in Python), and
  the storage boundary asserts it (`layout.assertName`). A name with `0x00` in a key would end
  early: `A\0B` would read as `A`.

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
| `c \| label` | label cardinality counter (when absent, the label index is counted) | `labelCount` (anchor selection) |
| `!` | the next node id to allocate | `allocateNodeId` |
| `!relationships` | the next relationship id to allocate | `addEdge` |

Every "index" is just more keys, maintained by the same `put`/`del` primitives. There is no
separate index structure — an index *is* a key range.

How to read the table: the first byte of a main-table key is a letter (`e`, `f`, `l`, `p`, `g`,
`t`, `c`) that says which kind of key it is, so every kind occupies its own range of the key
space; the rest of the key is the fields of that kind, one after another. Most index keys have an
empty value: the key itself is the fact.

## A worked example

Take the smallest graph that uses every kind of key: two people and a relationship with a
property.

```text
CREATE (a:Person {name: 'Ana'})-[:KNOWS {since: 2020}]->(b:Person {name: 'Bob'})
```

Ana gets node id 0, Bob node id 1, and the relationship gets relationship id 0 (the two kinds of id
are counted apart). These are all the keys the database then holds, as the storage engine stores
them (bytes in hex, `"…"` for bytes that are text):

```text
#nodes — one record per node
  key 00 00 00 00 00 00 00 00    (id 0, as a native integer)
  val 00 01                      1 label
      00 06 "Person"               length 6, the label
      00 00 00 01                1 property
      00 04 "name"                 name length 4, the name
      00 00 00 04 02 "Ana"         value length 4: tag 02 (string), the bytes
  key 01 00 00 00 00 00 00 00    (id 1)
  val 00 01 00 06 "Person" 00 00 00 01 00 04 "name" 00 00 00 04 02 "Bob"

#relationships — one record per relationship
  key 00 00 00 00 00 00 00 00    (relationship id 0)
  val 00 00 00 00 00 00 00 00    src: node 0 (Ana)
      00 00 00 00 00 00 00 01    dst: node 1 (Bob)
      "KNOWS"                    type

main table, in the order the engine keeps it
  "!"                → 00 00 00 00 00 00 00 02    next node id: 2
  "!format"          → 00 00 00 02                format version 2
  "!relationships"   → 00 00 00 00 00 00 00 01    next relationship id: 1
  "c" "Person"       → 00 00 00 00 00 00 00 02    2 nodes are Person
  "e" 00×8 "o" 00 "KNOWS" 00 00×7 01 00×8         Ana -KNOWS-> Bob, relationship 0, seen from Ana
                     → 01 00 01 00 06 "Person"    version 1, then Bob's labels
  "e" 00×7 01 "i" 00 "KNOWS" 00 00×8 00×8         the same relationship, seen from Bob
                     → 01 00 01 00 06 "Person"    Ana's labels
  "f" 00×8 "since"   → 01 00 00 00 00 00 00 07 e4 relationship 0's since: tag 01 (integer), 2020
  "g" "since" 00 01 80 00 00 00 00 00 07 e4 00×8  index: since = 2020 → relationship 0
  "l" "Person" 00 00×8                            index: Person → node 0
  "l" "Person" 00 00×7 01                         index: Person → node 1
  "p" "name" 00 02 "Ana" 00 00×8                  index: name = 'Ana' → node 0
  "p" "name" 00 02 "Bob" 00 00×7 01               index: name = 'Bob' → node 1
  "t" "KNOWS"        → 00 00 00 00 00 00 00 01    1 relationship is KNOWS
```

(`00×8` is eight zero bytes: the id 0. The index keys have empty values. The `#nodes` and
`#relationships` keys are native integers, little-endian on the machine this ran on; the engine
orders them as numbers.)

A few things to see in it:

- **The record is the truth, the rest is derived.** Ana's labels and properties are in her record;
  `l`, `p` and `c` say the same things again, arranged for a different question. The
  [integrity checker](#checking-integrity) rebuilds them from the records and compares.
- **The relationship is stored three times**: its record (ends and type), and one `e` key from each
  end. The `e` keys differ in the node they start with and in the direction byte (`o` out, `i` in).
- **Index keys end with the id.** In `p`, the value comes before the id, and a string value ends
  with a `00`, so every node with `name = 'Ana'` is under the prefix `p name 00 02 Ana 00`, and
  `'An'` cannot match it.
- **Numbers in index keys are rewritten to sort.** In `f` the integer 2020 is stored as it is
  (`00 … 07 e4`); in the `g` index key its sign bit is flipped (`80 … 07 e4`), so that negative
  numbers sort before positive ones byte by byte.

And what each kind of question reads:

| Query | Plan (EXPLAIN) | What the engine does |
| --- | --- | --- |
| `MATCH (p:Person) RETURN count(p)` | `NodeByLabelScan` | Scans the prefix `l Person 00`: two keys, the last 8 bytes of each are an id. (The planner reads `c Person` to estimate this: 2.) |
| `MATCH (p {name: 'Bob'}) RETURN p` | `NodeIndexSeek` | Seeks the prefix `p name 00 02 Bob 00`: one key, id 1. Reads `#nodes` key 1: Bob's labels and properties, in one search. |
| `MATCH (a {name: 'Ana'})-[k:KNOWS]->(b:Person) RETURN b.name, k.since` | `NodeIndexSeek`, `Expand(All)` | Seeks `p name … Ana` → node 0. Scans the prefix `e 00×8 o 00 KNOWS 00`: one key, whose fields give the neighbour (1) and the relationship (0), and whose value says the neighbour is a `Person`, so `b`'s label is checked without reading its record. `b.name` reads `#nodes` key 1; `k.since` reads `f 00×8 since` → 2020. |
| `MATCH (b {name: 'Bob'})<-[:KNOWS]-(a) RETURN a` | `NodeIndexSeek`, `Expand(All)` | The same from the other end: the prefix `e 00×7 01 i 00 KNOWS 00` gives node 0. |
| `MATCH ()-[k:KNOWS {since: 2020}]->() RETURN k` | `RelationshipIndexSeek` | Seeks the prefix `g since 00 01 80 … 07 e4`: relationship 0. Reads `#relationships` key 0 for its ends and type. |
| `CREATE (:Person {name: 'Eva'})` | `Create` | Reads and increments `!` (id 2), writes the record under 2, then `l Person 00 …02`, `p name 00 02 Eva 00 …02`, and `c Person` = 3, all in one write transaction. |

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

The key `!format` holds the format's version, `Graph.format_version` (2). When the C ABI or the
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
    four records ahead, the cursor steps forward (a cursor `next`) instead of searching. A scan's nodes
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
  - A value without the version byte (an empty one) means the labels are unknown, and the record
    is read.
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

Every schema definition lives under `i | name` (`fulltext.zig`): its kind (a full-text index, a
declared range index, or a uniqueness constraint), whether it is on nodes or relationships, its
analyzer (full-text only), its labels or types, and its properties. `!schema` counts the changes
to the definitions. Every mutation asks for it, to know whether any index or constraint must
follow the change, so inside a write transaction it is read once
(`KeyValueStore.write_transaction_memo`): only that transaction could change it, and when it does
it updates the memo too. A database without definitions pays one read per write transaction.

A uniqueness constraint (`constraints.zig`) is checked before a node's new record is written
(`setProperty`, `addLabel`): the property index gives the other nodes with the first property's
value, and one with the label and every other value equal is a violation
(`error.ConstraintViolation`, `Graph.violationMessage`). Every property is compared as the index
compares it, so `1` and `1.0` are one value. Checking before writing keeps a refused write from
changing anything, also outside a transaction; it is also stricter than checking at commit:
swapping two nodes' values in one query fails.

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

Relationship ids come from their own counter, `!relationships`. Inside a write transaction it is
read once and kept in `KeyValueStore.write_transaction_memo`; `Graph.commitWrite` writes it back
with the commit, so a query that creates many relationships writes the counter once, and an
aborted one leaves it as it was.

## Transactions

- **Writes** are atomic: the executor opens one write transaction per query
  (`beginWrite`/`commitWrite`); every `put`/`del`/`get`/`scanPrefix` inside it routes through that
  transaction and sees its uncommitted writes. An aborted query rolls everything back, including the
  id counter.
- **Reads** are batched: a read-only query opens one read transaction (an MVCC snapshot,
  `beginRead`/`commitRead`) and all its reads run inside it — so a filtered scan is O(1)
  transactions, not one per `get`.
- Read transactions are not tied to a thread (LMDB's `MDB_NOTLS`, libmdbx's
  `MDBX_NOSTICKYTHREADS`), so a single thread may hold several at once — the executor needs that
  to run a scan, then a neighbour scan *inside* it.
- An ended read transaction is reset and kept (up to four per database) for the next one to
  renew (`Environment.endRead`): starting a read costs no allocation.
- A read transaction keeps the cursors of finished prefix scans (up to 16) for the next scans,
  last in, first out: a nested scan gets the cursor its depth used before, which is near where it
  starts now (the next node's edges), so the engine repositions it without searching from the root.
- An iterator returned by `scanPrefix` borrows its transaction; it must be `deinit`'d **before** the
  transaction ends (the cursor belongs to it). The executor scopes every iterator to the operator
  call that opened it, which is what makes this safe.

## Checking integrity

Everything but the records is derived: the label, property and edge-property indexes, both edge
keys of each relationship and the labels they keep, the counters, the full-text postings. The
integrity checker, `acmedb.integrity.check(graph, allocator)` (`src/storage/integrity.zig`),
rebuilds each of them from the primary data — the node and relationship records, the relationship
properties (`f`), the schema definitions (`i`) — and compares them with what is stored. It also
checks that every uniqueness constraint holds, that the id counters are above every id in use,
that each record and value is well formed (`layout.zig`), and that the main table holds no key of
any other kind. It returns a `Report` with the first problems found, described, and their count.

The same layout functions guard the storage boundary in Debug and ReleaseSafe builds: the writer
asserts the bytes it is about to store, and the reader the bytes it is about to trust (pair
assertions), so a malformed record stops the program where it appears. ReleaseFast compiles them
out.

Users can run it too, as `Database.check()` in Python and `acmedb_check` in C: a diagnostic for
a suspected bug, documented as such, not a routine call.

It runs in one read transaction, or in the active one (a write transaction is seen with its
uncommitted changes), in O(database) time and memory. Two differences are not problems: a counter
of something no longer there may stay at zero, and an edge key may keep a neighbour's labels as an
empty section or as a count of zero (both mean none).

The storage fuzzer checks the database with it after every commit and abort, and the fault and
crash fuzzers after every failure and crash (see [testing](testing.md#the-integrity-checker)).

## The storage engines

The rest of acmedb sees the engine only through `src/storage/engine/contract.zig`; the engine is
chosen at build time (`zig build -Dstorage-engine=lmdb|mdbx`), and both are kept until libmdbx
builds everywhere LMDB does:

| | LMDB (default) | libmdbx (`mdbx`) |
| --- | --- | --- |
| Sources | `vendor/lmdb/` | `vendor/libmdbx/` (0.14.4, local fixes in `PATCHES.md`) |
| Files in the database directory | `data.mdb`, `lock.mdb` | `mdbx.dat`, `mdbx.lck` |
| File size | grows as data is written, within a 1 TiB map; never shrinks | grows in 16 MiB steps, up to 1 TiB; gives back free space at its end past 64 MiB |
| A second open in one process | not safe | refused (`StorageError`) |
| Builds | every target | every target but Windows on ARM64 |
| Speed (`bench/RESULTS.md`) | | commits ~2x faster, point reads 5-15% faster, range-index scans 12-22% slower |

The two write different files, so a database belongs to the engine that created it.

## Durability

`KeyValueStore.openWithOptions` takes a durability mode, mapped to each engine's flags:

| Mode | LMDB flag | libmdbx flag | A commit returns when… |
| --- | --- | --- | --- |
| `full` | none | `MDBX_SYNC_DURABLE` | data and metadata are flushed (`fsync`; `F_FULLFSYNC` on macOS) |
| `relaxed` | `MDB_NOMETASYNC` | `MDBX_NOMETASYNC` | data is flushed; the metadata page follows with the next commit |
| `deferred` | `MDB_NOSYNC` | `MDBX_SAFE_NOSYNC` | the write is in the page cache; `sync()` or the OS flushes it |

With libmdbx, every process that opens a database at once must agree on `deferred`: it refuses to
open a database in `deferred` mode that another process has open in `full` or `relaxed`, and the
reverse.

Both engines are copy-on-write and never overwrite live pages, so no mode can corrupt the database: a
crash loses at most the commits that were not yet flushed, and the database opens at the last
flushed one.

## Why this way — and the alternatives

- **A key/value B+tree, not record files with pointers.** Neo4j stores nodes and relationships in
  fixed-size records that point at each other, so following a relationship is one pointer, without
  a search. acmedb pays a B+tree search instead (O(log n), mostly in cached pages), and gets in
  return transactions, crash safety and readers that never wait from an engine it does not have to
  write, and every index in the same structure. Writing a storage engine of its own was considered
  and rejected.
- **LMDB or libmdbx, not an LSM tree (RocksDB).** The project started on C++ and RocksDB. An LSM
  tree writes faster, but its reads go through several levels, and building it from source was
  most of the build time. A graph database reads far more than it writes, and LMDB's reads were
  about six times faster; its one writer and many readers across processes is also the model
  acmedb offers.
- **Each relationship stored twice.** Storing it once would halve the edge keys, but then one
  direction needs a separate reverse index, maintained the same way. Storing both directions makes
  either one a prefix scan.
- **Node records, not one key per property.** A record per node makes reading a node one search,
  at the cost of rewriting the record on every change to it. Graph queries read nodes far more than
  they change them.
- **Neighbour labels on edge keys.** They make `(a)-[:R]->(b:Person)` check `Person` without reading
  `b`, and cost O(degree) when a label is added or removed. Labels change rarely; expansions run in
  almost every query.
