# Architecture — how acmedb works

This is the contributor-level deep dive: the layering, how the graph is encoded into LMDB keys,
how adjacency is stored so a traversal is a single prefix scan, and how a query goes from text to
rows.

If you only want to *write data and run queries*, the [tutorial](../tutorial/01-getting-started)
and the [openCypher reference](cypher) are enough. This page is for changing the engine.

## The shape of the design

acmedb is five layers, each a plain Zig module with a small, concrete interface:

```{mermaid}
flowchart TB
  subgraph L1["Storage"]
    KV["kv_store.zig<br/>KvStore over LMDB"]
    LMDB["lmdb.zig<br/>hand-written C bindings"]
    Graph["graph.zig<br/>key encoding + index-free adjacency"]
  end
  subgraph L2["Language"]
    AST["ast.zig<br/>arena AST (no pointers)"]
    Parser["parser.zig<br/>recursive descent, openCypher subset"]
  end
  subgraph L3["Execution"]
    Exec["exec.zig<br/>Volcano executor (anchor + pushdown)"]
  end
  subgraph L4["Embedding"]
    CAPI["capi.zig<br/>C ABI (export fn)"]
  end

  Parser --> AST
  Exec --> AST
  Exec --> Graph
  Graph --> KV
  KV --> LMDB
  CAPI --> Exec
  CAPI --> Graph
```

The dependency rule is strict and one-way: the executor talks only to `Graph`, `Graph` talks only
to `KvStore`, and `KvStore` talks only to LMDB through the hand-written bindings. Nothing above
the storage layer touches LMDB directly.

## Storage: LMDB and the key encoding

LMDB is a **single-writer, multi-reader** B+tree key/value store. acmedb opens the environment with
`MDB_NOTLS`, so a single thread may hold several read transactions at once — the executor needs
that to run nested prefix scans (a node scan, then a neighbour scan inside it). See
[transactions](#transactions) below.

There is exactly one unnamed database, and **everything is a key**. All integers are big-endian and
fixed-width, so lexicographic byte order equals numeric order and no id is ever a prefix of
another. The keys (with `|` = concatenation and `0x00` a separator byte):

| Key | Meaning |
| --- | --- |
| `n \| id` | a node exists |
| `n \| id \| 0x00 \| prop` | a node property (value = encoded `Value`) |
| `e \| id \| dir \| 0x00 \| type \| 0x00 \| neighbour` | one stored direction of a typed edge (`dir` is `'o'` out / `'i'` in) |
| `f \| src \| dst \| 0x00 \| type \| 0x00 \| prop` | an edge property, in the canonical `src -> dst` orientation |
| `l \| label \| 0x00 \| id` | forward label index: which nodes carry `label` |
| `L \| id \| 0x00 \| label` | reverse label index: which labels `id` carries (for delete) |
| `p \| prop \| 0x00 \| value \| id` | property index: nodes whose `prop == value` |
| `g \| prop \| 0x00 \| value \| src \| dst \| 0x00 \| type` | edge-property index: edges whose `prop == value` |
| `t \| type` | edge-type cardinality counter (for anchor selection) |
| `!` | the next node id to allocate (a persistent counter) |

A `Value` is encoded as a one-byte tag plus a payload: `0x01` + 8-byte big-endian `i64` for
integers, `0x02` + bytes for strings. Booleans, nulls and lists are produced during evaluation but
are never stored as properties.

### Index-free adjacency

The whole point of this layout is that **"give me the neighbours of node X" is a single LMDB
prefix scan** — no joins, no secondary lookup:

- every directed typed edge is stored **twice** — keyed by its source (`'o'`) and by its target
  (`'i'`) — so both directions are a prefix scan;
- because the neighbour id is the trailing fixed-width field, LMDB's lexicographic iteration
  returns neighbours in ascending id order for free.

A traversal like `(a)-[:ACTED_IN]->(b)` is therefore: scan `e | a | 'o' | 0x00 | ACTED_IN | 0x00`
and read the trailing 8 bytes of each key. That is the "index-free adjacency" (IFA) model.

## The executor: a Volcano pipeline

The executor is a small Volcano engine — `Open`/`Next`/`Close`-style operators over iterators —
with three ideas worth knowing:

1. **Anchor selection.** For a pattern, pick the cheapest starting point. A node is ranked by:
   an equality seek on a property (`1`), otherwise its smallest label count, capped by the rarest
   incident edge type. A single edge whose only selectivity is an inline property seek is anchored
   directly on the edge-property index. The traversal then expands bidirectionally from the anchor.
2. **Predicate pushdown.** Equality predicates (`=`, inline `{prop: value}`) are turned into index
   seeks before the scan runs; the rest of the `WHERE` is evaluated per row.
3. **Batched reads.** A read-only query runs inside one LMDB read transaction (an MVCC snapshot),
   so a filtered scan is O(1) transactions rather than one per read.

The clause pipeline is: `MATCH` → `OPTIONAL MATCH` (an outer join) → `UNWIND` → `WITH`
(project/aggregate/filter/sort/paginate, then re-bind) → writes (`CREATE`/`MERGE`/`SET`/`DELETE`/
`REMOVE`) → `RETURN` (project, `DISTINCT`, `ORDER BY`, `SKIP`, `LIMIT`).

```{mermaid}
sequenceDiagram
  autonumber
  participant P as parser
  participant E as executor
  participant G as graph
  participant S as KvStore / LMDB

  P->>E: query AST
  E->>E: plan: choose anchor (label count / seek / edge index)
  E->>S: begin read txn (snapshot)
  loop scan / expand
    E->>G: nodesWithLabel / neighbours / nodesByProp
    G->>S: scanPrefix(...)
    S-->>G: iterator (LMDB cursor)
    G-->>E: node ids
  end
  E->>E: WHERE / projection / aggregation
  E->>S: commit/abort read txn
  E-->>P: rows
```

## The AST and the parser

The AST is an **arena**: a flat `std.ArrayList` of nodes plus a child-index array, no pointers, no
inheritance, no Visitor. Each node is a `NodeKind` tag and a small tagged-union payload; strings
are interned into the arena so the whole tree is freed with one `deinit`. This is the generic
(Stepanov/STL) style the project uses throughout: data as concrete types, algorithms as free
functions, errors as values (`error union`s, the analogue of `std::expected`).

The parser is a hand-written recursive-descent parser for the openCypher subset — no ANTLR, no
generator — producing that arena AST directly.

## Transactions

- **Writes** are atomic: the executor wraps every query's writes in one write transaction
  (`KvStore.beginWrite` / `commitWrite`); a `MERGE` or `CREATE` that fails mid-way aborts cleanly.
  Inside it, all reads see the uncommitted writes.
- **Reads** are batched: a read-only query opens one read transaction (an MVCC snapshot) and every
  `get`/`exists`/`scanPrefix` runs inside it. Iterators created under a transaction must be
  `deinit`'d before the transaction ends (the cursor belongs to it).

## Recap

- **Everything is a key** in one LMDB database; fixed-width big-endian integers make lexicographic
  order the order you want.
- **Index-free adjacency**: edges are stored twice, so a traversal is a prefix scan.
- **Indexes** are themselves keys: label, property, edge-property, plus a cardinality counter for
  planning.
- **The executor plans, then runs**: anchor selection + predicate pushdown, one read transaction
  per query, one write transaction per writing query.
