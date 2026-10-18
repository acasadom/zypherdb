# Architecture

This is the entry point to the **technical** documentation: the design decisions, the components,
how they interact, and how a query flows through them. It is for reading and maintaining the code.
For the *how to use it* side, start with the [tutorial](../tutorial/01-getting-started); the deeper
pages — [storage](storage), [the language](language), [planning & execution](planning-execution) —
grow out of this one.

## Why it is shaped this way

acmedb is deliberately small and generic. Four decisions explain almost every file:

- **Zig, not C++.** The project started as C++/RocksDB and pivoted. The reasons were pragmatic:
  embeddable in Python, real performance, fast builds on an 8 GB M1, and a single-binary toolchain
  (no CMake, no vcpkg, no Docker). Zig 0.17 is pre-1.0, but `comptime` generics map cleanly onto the
  generic-programming style the project wants.
- **No class hierarchies, no Visitor.** The style is Stepanov/STL: **data as concrete types,
  algorithms as free functions, errors as values** (Zig `error union`s, the analogue of
  `std::expected`). You will not find `interface`/`abstract class` anywhere — the AST is not a tree
  of `Node` subclasses but a flat arena, and the executor is not a tree of `Operator` objects but a
  recursive function over a small set of step tags.
- **An arena AST.** Nodes live in one `std.ArrayList`, children are a separate index array, and
  strings are interned into the arena. No pointers, no inheritance, one `deinit` frees the whole
  tree. This is the same shape Zig itself uses for its AST.
- **LMDB as the storage engine.** A graph is traversed by following adjacencies, not by joining
  tables, so the storage is a single key/value B+tree and *"neighbours of X" is one prefix scan*.
  LMDB is single-writer / multi-reader, which is exactly the intended read-replication model, and
  its lexicographic key order is what the adjacency encoding exploits.

## The components

Ten files, five layers, with a strict one-way dependency rule (a layer talks only to the one below
it):

```{mermaid}
flowchart TB
  subgraph embed["Embedding"]
    CAPI["capi.zig — C ABI (export fn)"]
  end
  subgraph lang["Language"]
    Parser["parser.zig — lexer + recursive descent"]
    AST["ast.zig — arena AST"]
  end
  subgraph exec["Execution"]
    Exec["exec.zig — Volcano executor"]
    Diag["diag.zig — error messages + offsets"]
  end
  subgraph storage["Storage"]
    Graph["graph.zig — key encoding, indexes, adjacency"]
    KV["kv_store.zig — KvStore over LMDB"]
    LMDB["lmdb.zig — hand-written C bindings"]
  end

  CAPI --> Exec
  CAPI --> Graph
  Exec --> AST
  Exec --> Graph
  Parser --> AST
  Parser --> Diag
  Graph --> KV
  KV --> LMDB
```

| File | What it is |
| --- | --- |
| `src/storage/lmdb.zig` | Hand-written C bindings: `opaque {}` handles for `MDB_env`/`MDB_txn`/`MDB_cursor`, an `extern struct MDB_val`, ~15 `extern "c" fn`, and the constants (`MDB_RDONLY`, `MDB_NOTLS`, `MDB_NOTFOUND`, `MDB_NEXT`, `MDB_SET_RANGE`). |
| `src/storage/kv_store.zig` | `KvStore`, a RAII wrapper over LMDB: `put`/`get`/`exists`/`del`/`scanPrefix`/`countPrefix`, plus explicit write and read transactions. `scanPrefix` returns an **iterator**, not a callback — the composable abstraction the executor needs. |
| `src/storage/graph.zig` | `Graph`: the key encoding, index-free adjacency, the label/property/edge indexes, and value encoding. It is the only place that knows the key layout. |
| `src/ast/ast.zig` | The arena AST: `NodeKind` tags, a `Data` payload union, and `addNode`/`nodeChildren`/`intern`. |
| `src/parser/parser.zig` | The lexer (`tokenize`) and the recursive-descent parser (`Parser`), text → arena AST. |
| `src/exec/exec.zig` | The Volcano executor: planning (anchor selection, predicate pushdown) and execution (nested-loop scans/expansions), plus writes, aggregation and the `WITH` pipeline. |
| `src/diag.zig` | `Diagnostic`: a message + byte offset, the error-reporting seam. |
| `src/capi.zig` | The C ABI (`export fn`) for embedding; a `Context` (store + graph) and a self-contained `Result`. |
| `src/root.zig` | The library root: re-exports the public surface. |
| `build.zig` | One module + static library + shared library (C ABI) + test step; compiles the vendored LMDB C. |

## The lifecycle of a query

A query is text in, rows out, through four stages. Each stage is a separate file:

```{mermaid}
sequenceDiagram
  autonumber
  participant C as caller (capi)
  participant P as parser.zig
  participant A as ast.zig
  participant E as exec.zig
  participant G as graph.zig
  participant S as kv_store.zig

  C->>P: "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN m.title"
  P->>P: tokenize → tokens
  P->>A: recursive descent → arena AST
  P-->>C: AST (root query node)
  C->>E: exec.run(query AST)
  E->>E: plan: choose anchor, push predicates, build steps
  loop scan / expand
    E->>G: nodesWithLabel / neighbours / nodesByProp
    G->>S: scanPrefix(...)
    S-->>G: iterator (LMDB cursor)
    G-->>E: node ids
  end
  E->>E: WHERE / projection / aggregation
  E-->>C: rows
```

1. **Lex + parse** — `tokenize` turns the text into a token array; the recursive-descent `Parser`
   walks it into the arena AST. See [the language](language).
2. **Plan** — the executor reads the AST and, for each `MATCH` pattern, builds a plan: a chain of
   `ChainNode`s/`ChainEdge`s, an anchor choice, and a list of `BindStep`s. This is where the
   optimizations live. See [planning & execution](planning-execution).
3. **Execute** — a recursive function (`execStep`) walks the steps; each step is a graph operation
   (a scan or an expansion) backed by a `scanPrefix` iterator. See [storage](storage) for what those
   operations *mean*.
4. **Return** — rows are projected and handed back through the C ABI.

There is deliberately **no intermediate representation** between the AST and the plan: the plan
structures are built directly inside the executor, and the optimizations are the anchor selection
and the predicate pushdown, applied inline. See [planning & execution](planning-execution) for *why
that's fine at the current language surface* and *when a real IR would start to pay*.
