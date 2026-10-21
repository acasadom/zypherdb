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
- **Regular types and generic algorithms.** `Value`, `Binding` and `Bindings` define equality, a
  total order (where meaningful) and a hash that obey their laws, checked by property tests.
  Algorithms that apply to more than one type — deduplication, pagination, sorting by key,
  grouping — are written once over those operations (`sequence_algorithms.zig`,
  `aggregation.Grouping`, `projection.sortByKey`), never copied per type.
- **libmdbx as the storage engine, behind a contract.** A graph is traversed by following
  adjacencies, not by joining tables, so the storage is a key/value B+tree and *"neighbours of X"
  is one prefix scan*. libmdbx (a descendant of LMDB) is single-writer / multi-reader across
  processes, its lexicographic key order is what the adjacency encoding exploits, and its file
  grows and shrinks on its own. The rest of acmedb sees it only through the engine contract
  (`storage/engine/contract.zig`): another engine would be a new file next to `engine/mdbx.zig`,
  chosen at build time (`-Dstorage-engine`). Every change goes through the write transaction of
  that contract, the one place a change log (for replication) would be taken.

## The components

Three layers, one directory each, plus a few cross-cutting files and the two embeddings. Dependencies
point one way: the embeddings use execution and storage, execution uses the query AST and storage,
and nothing below reaches up.

```{mermaid}
flowchart TB
  subgraph embed["Embeddings"]
    CAPI["c_api.zig — C ABI (export fn)"]
    PyNative["python/native/ — Python extension module"]
  end
  subgraph query["query/ — text to AST"]
    Lexer["lexer.zig — tokens"]
    Parser["parser.zig + expression_parser.zig — grammar"]
    AST["ast.zig — arena AST"]
    Semantics["semantics.zig — static checks"]
  end
  subgraph execution["execution/ — AST to rows"]
    Executor["Executor.zig — state, run(), phases"]
    Steps["planner · pattern_matching · expressions · aggregation · projection · writes"]
  end
  subgraph storage["storage/ — graph on a key-value engine"]
    Graph["graph.zig — graph operations and indexes"]
    Keys["key_encoding.zig + node_record.zig — key and record layout"]
    KV["key_value_store.zig — transactions, prefix scans"]
    Engine["engine.zig + engine/ — the engine contract, libmdbx and its C bindings"]
  end
  Shared["value.zig · temporal/ · sequence_algorithms.zig · diagnostics.zig"]

  CAPI --> Executor
  CAPI --> Graph
  PyNative --> Executor
  PyNative --> Graph
  Semantics --> AST
  Executor --> Steps
  Steps --> AST
  Steps --> Graph
  Parser --> Lexer
  Parser --> AST
  Graph --> Keys
  Graph --> KV
  KV --> Engine
```

| File | What it is |
| --- | --- |
| `src/value.zig` | `Value`, the typed value of properties and expressions, as a *regular type*: `eql`, a total `order` (openCypher's global sort order) and `hash`, with property tests of their laws. |
| `src/sequence_algorithms.zig` | Generic algorithms written once for any regular element type: `removeDuplicates`, `dropFirst`, `truncate`, and the hash-map contexts `ElementContext`/`SequenceContext`. |
| `src/diagnostics.zig` | `Diagnostic`: an error code, a message and a byte offset — the error-reporting seam. |
| `src/storage/engine/contract.zig` | What a storage engine provides: environment, read and write transactions, cursors, the three tables, and the rules every engine keeps (zero-copy reads, one writer, several processes). |
| `src/storage/engine.zig` | The engine chosen at build time (`-Dstorage-engine`, `mdbx`): the only place that names one. |
| `src/storage/engine/mdbx.zig` | The libmdbx engine: file geometry, durability flags, renewed read transactions. |
| `src/storage/engine/mdbx_bindings.zig` | Hand-written C bindings for libmdbx: `opaque {}` handles for `MDBX_env`/`MDBX_txn`/`MDBX_cursor`, `extern struct MDBX_val`, the `extern "c" fn`s and constants. |
| `src/storage/key_value_store.zig` | `KeyValueStore`, the graph's view of the engine: `put`/`get`/`exists`/`del`/`scanPrefix`/`countPrefix`, explicit write/read transactions, pooled cursors and the record cache. `scanPrefix` returns an **iterator**, not a callback. |
| `src/storage/key_encoding.zig` | The byte layout of every key (markers, node ids, edge keys, index keys). The only place that knows the key layout. |
| `src/storage/value_encoding.zig` | How a property value is stored, and written in index keys. |
| `src/storage/node_record.zig` | The node record: a node's labels and properties in one stored value, read with one B-tree search. |
| `src/storage/fulltext.zig` | Full-text index definitions (`i \| name`) and the schema version that says when they changed. |
| `src/storage/fulltext_postings.zig` | Full-text postings, entity lengths, term counts and index totals, and how graph mutations keep them current. |
| `src/storage/fulltext_search.zig` | A full-text query against the postings: boolean clauses, phrases, prefix and fuzzy expansions, BM25. |
| `src/text/` | Text for full-text search: Unicode tables generated from the Unicode Character Database (`unicode_tables.zig`, by `tools/unicode_tables.py`), the analyzers (`analyzer.zig`), stop words, the Snowball stemmers (`snowball.zig`, `stem_english.zig`, `stem_spanish.zig`) and the query syntax (`query.zig`). |
| `src/storage/graph.zig` | `Graph`: nodes, labels, typed edges, properties and their indexes, built on the key encoding. Each operation documents its cost. |
| `src/query/lexer.zig` | `tokenize`: query text to tokens (UTF-8 and backtick-quoted identifiers). |
| `src/query/parser.zig` | The `Parser` and the clause/pattern grammar. |
| `src/query/expression_parser.zig` | The expression grammar, by precedence. |
| `src/query/ast.zig` | The arena AST: `NodeKind` tags, a `Data` payload union, `addNode`/`nodeChildren`/`intern`, `sameExpression`. |
| `src/query/call_parser.zig`, `src/query/schema_parser.zig` | The CALL clause, and the schema commands (`CREATE FULLTEXT INDEX`, `DROP INDEX`, `SHOW INDEXES`). |
| `src/query/procedures.zig` | The procedures' signatures (arguments, columns and their kinds), shared by the semantic checks and the executor. |
| `src/query/semantics.zig` | Static checks before a query runs: each variable is used as one kind (node, relationship or value), literal operands have types their operators accept, no aggregates inside comprehensions. |
| `src/execution/Executor.zig` | The executor's state and `run()`: one transaction, then the clauses as a pipeline of rows. |
| `src/execution/procedures.zig` | The procedures CALL runs, and how their rows extend the query's (YIELD, WHERE). |
| `src/execution/schema.zig` | The schema commands, each a statement of its own. |
| `src/execution/pipeline.zig` | Streaming execution of read-only queries: rows go through the clauses one at a time, and a `LIMIT` stops the work early. |
| `src/execution/clauses.zig` | The pipeline's MATCH / OPTIONAL MATCH, UNWIND and write clauses: rows in, rows out. |
| `src/execution/planner.zig` | Pattern planning: the chain of `PatternNode`s/`PatternEdge`s, predicate pushdown, anchor choice, `PlanStep`s. |
| `src/execution/pattern_matching.zig` | Runs the steps (`scanNodes`, `scanEdgeIndex`, `expandEdge`) of one pattern. |
| `src/execution/expressions.zig` | Expression evaluation and operators, with three-valued null logic. |
| `src/execution/aggregation.zig` | Aggregate states and the generic `Grouping(Key, KeyContext)`. |
| `src/execution/projection.zig` | WITH and RETURN: projection, DISTINCT, ORDER BY, SKIP, LIMIT (`Sortable(T)`, `sortByKey`). |
| `src/execution/functions.zig` | The built-in functions, as one table. |
| `src/execution/comparison.zig` | `=` and the ordering operators: three-valued comparability, as opposed to `Value.order`. |
| `src/execution/temporal_functions.zig` | The temporal functions, components and arithmetic, on `Value`s. |
| `src/temporal/` | The calendar (`calendar.zig`), time zones (`zones.zig`), the temporal types (`types.zig`), ISO 8601 parsing (`parse.zig`), durations (`durations.zig`) and building values from fields (`selection.zig`). |
| `src/execution/writes.zig` | CREATE, MERGE, SET, REMOVE and DELETE. |
| `src/execution/bindings.zig` | `Binding`/`Bindings`: what each query variable is bound to (regular types). |
| `src/execution/entities.zig` | `EntitySnapshot`: the labels and properties of every node and relationship a result mentions, read before the transaction ends. |
| `src/c_api.zig` | The C ABI (`export fn`): a `Context` (store + graph) and a self-contained `Result`. Declared in `include/acmedb.h`. |
| `python/native/module.zig` | The Python extension module, on the limited C API: converts parameters and rows directly, runs queries with the GIL released. See [the Python reference](python.md#under-the-hood). |
| `python/native/temporals.zig` | Converts temporal values to and from Python's `datetime` types. |
| `src/root.zig` | The library root: re-exports the public surface. |
| `tests/` | The test suite, through the public API only (see [contributing](contributing)). |

## The lifecycle of a query

A query is text in, rows out, through five stages. Each stage is a separate file:

```{mermaid}
sequenceDiagram
  autonumber
  participant C as caller (capi)
  participant P as query/
  participant A as query/ast.zig
  participant E as execution/
  participant G as storage/graph.zig
  participant S as storage/key_value_store.zig

  C->>P: "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN m.title"
  P->>P: tokenize → tokens
  P->>A: recursive descent → arena AST
  P-->>C: AST (root query node)
  C->>E: Executor.run(query AST)
  E->>E: plan: choose anchor, push predicates, build steps
  loop scan / expand
    E->>G: nodesWithLabel / neighbours / nodesByProperty
    G->>S: scanPrefix(...)
    S-->>G: iterator (engine cursor)
    G-->>E: node ids
  end
  E->>E: WHERE / projection / aggregation
  E-->>C: rows
```

1. **Lex + parse** — `tokenize` turns the text into a token array; the recursive-descent `Parser`
   walks it into the arena AST. See [the language](language).
2. **Check** — `Executor.run` first rejects queries that are well-formed but meaningless:
   `semantics.check` (a node used as a relationship, `1 IN true`) and `functions.checkCalls` (an
   unknown function, a wrong number of arguments). Nothing has touched storage yet.
3. **Plan** — the executor reads the AST and, for each `MATCH` pattern, builds a plan: a chain of
   `PatternNode`s/`PatternEdge`s, an anchor choice, and a list of `PlanStep`s. This is where the
   optimizations live. See [planning & execution](planning-execution).
4. **Execute** — a recursive function (`runStep`) walks the steps; each step is a graph operation
   (a scan or an expansion) backed by a `scanPrefix` iterator. See [storage](storage) for what those
   operations *mean*.
5. **Return** — rows are projected; before the transaction ends, `EntitySnapshot.capture` reads
   the nodes and relationships the rows mention; then the rows are handed back, through the C ABI
   or the Python module.

There is deliberately **no intermediate representation** between the AST and the plan: the plan
structures are built directly inside the executor, and the optimizations are the anchor selection
and the predicate pushdown, applied inline. See [planning & execution](planning-execution) for *why
that's fine at the current language surface* and *when a real IR would start to pay*.
