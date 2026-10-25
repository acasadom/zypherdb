# Architecture

This is the entry point to the **technical** documentation: the design decisions, the components,
how they interact, and how a query flows through them. It is for reading and maintaining the code.
For the *how to use it* side, start with the [tutorial](../tutorial/01-getting-started); the deeper
pages — [storage](storage), [the language](language), [planning & execution](planning-execution) —
grow out of this one.

## Why it is shaped this way

ZypherDB is deliberately small and generic. Five decisions explain almost every file:

- **Zig, not C++.** The project started as C++/RocksDB and pivoted. The reasons were pragmatic:
  embeddable in Python, real performance, fast builds on an 8 GB M1, and a single-binary toolchain
  (no CMake, no vcpkg, no Docker). Zig 0.17 is pre-1.0, but `comptime` generics map cleanly onto the
  generic-programming style the project wants.
- **No class hierarchies, no Visitor.** The style is Stepanov/STL: **data as concrete types,
  algorithms as free functions, errors as values** (Zig `error union`s, the analogue of
  `std::expected`). You will not find `interface`/`abstract class` anywhere — the AST is not a tree
  of `Node` subclasses but a flat arena, and a plan is not a tree of `Operator` objects but chains
  of operators, each a value of one tagged union, that free functions feed rows through.
- **An arena AST.** Nodes live in one `std.ArrayList`, children are a separate index array, and
  strings are interned into the arena. No pointers, no inheritance, one `deinit` frees the whole
  tree. This is the same shape Zig itself uses for its AST.
- **Regular types and generic algorithms.** `Value`, `Relationship` and `Path` define equality, a
  total order (where meaningful) and a hash that obey their laws, checked by property tests.
  Algorithms that apply to more than one type — deduplication, pagination, sorting by key,
  grouping — are written once over those operations (`sequence_algorithms.zig`,
  `aggregation.Grouping`, `projection.sortByKey`), never copied per type.
- **LMDB or libmdbx as the storage engine, behind a contract.** A graph is traversed by following
  adjacencies, not by joining tables, so the storage is a key/value B+tree and *"neighbours of X"
  is one prefix scan*. Both engines are single-writer / multi-reader across processes, and their
  lexicographic key order is what the adjacency encoding exploits. The rest of ZypherDB sees the
  engine only through its contract (`storage/engine/contract.zig`); the engine is chosen at build
  time (`-Dstorage-engine=lmdb`, the default, or `mdbx`), and another one would be a new file next
  to `engine/lmdb.zig` and `engine/mdbx.zig`. Every change goes through the write transaction of
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
  subgraph statement["statement/ — prepared statements"]
    Prepared["Statement.zig + Cache.zig — planned once, run many times"]
  end
  subgraph query["query/ — text to AST"]
    Lexer["lexer.zig — tokens"]
    Parser["parser.zig + expression_parser.zig — grammar"]
    AST["ast.zig — arena AST"]
    Semantics["semantics.zig — static checks"]
  end
  subgraph planning["planning/ — AST to plan"]
    Builder["builder.zig + patterns.zig — clauses and patterns to operators"]
    PlanIR["Plan.zig — operators in chains"]
  end
  subgraph execution["execution/ — plan to rows"]
    Executor["Executor.zig — state, run()"]
    Steps["operators · pattern_matching · expressions · aggregation · projection · writes"]
  end
  subgraph storage["storage/ — graph on a key-value engine"]
    Graph["graph.zig — graph operations and indexes"]
    Keys["key_encoding.zig + node_record.zig — key and record layout"]
    KV["key_value_store.zig — transactions, prefix scans"]
    Engine["engine.zig + engine/ — the engine contract, LMDB, libmdbx, C bindings"]
    Integrity["integrity.zig + layout.zig — the checker, the layout assertions"]
  end
  Shared["value.zig · temporal/ · text/ · sequence_algorithms.zig · diagnostics.zig"]

  CAPI --> Prepared
  CAPI --> Graph
  PyNative --> Prepared
  PyNative --> Graph
  Prepared --> Parser
  Prepared --> Executor
  Integrity --> Graph
  Semantics --> AST
  Executor --> Builder
  Builder --> PlanIR
  Builder --> AST
  Executor --> Steps
  Steps --> PlanIR
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
| `src/storage/engine.zig` | The engine chosen at build time (`-Dstorage-engine=lmdb\|mdbx`): the only place that names one. |
| `src/storage/engine/lmdb.zig` | The LMDB engine (the default): map size, durability flags, renewed read transactions. |
| `src/storage/engine/lmdb_bindings.zig` | Hand-written C bindings for LMDB (`MDB_env`/`MDB_txn`/`MDB_cursor`, `MDB_val`, the functions and constants used). |
| `src/storage/engine/mdbx.zig` | The libmdbx engine: file geometry, durability flags, renewed read transactions. |
| `src/storage/engine/faulty.zig` | An engine that wraps the chosen one and fails at the N-th operation, or kills the process at a chosen crash point; used only by the fault and crash tests and the fuzzers (see [testing](testing.md#the-fault-fuzzer)). |
| `src/storage/engine/mdbx_bindings.zig` | Hand-written C bindings for libmdbx: `opaque {}` handles for `MDBX_env`/`MDBX_txn`/`MDBX_cursor`, `extern struct MDBX_val`, the `extern "c" fn`s and constants. |
| `src/storage/key_value_store.zig` | `KeyValueStore`, the graph's view of the engine: `put`/`get`/`exists`/`del`/`scanPrefix`/`countPrefix`, explicit write/read transactions, pooled cursors and the record cache. `scanPrefix` returns an **iterator**, not a callback. |
| `src/storage/key_encoding.zig` | The byte layout of every key (markers, node ids, edge keys, index keys). The only place that knows the key layout. |
| `src/storage/value_encoding.zig` | How a property value is stored, and written in index keys. |
| `src/storage/node_record.zig` | The node record: a node's labels and properties in one stored value, read with one B-tree search. |
| `src/storage/layout.zig` | What a well-formed record, value, edge key and name are, as functions that say why some bytes are not; the checker reports with them, and the storage boundary asserts them in pairs (Debug and ReleaseSafe). |
| `src/storage/integrity.zig`, `integrity_fulltext.zig` | The integrity checker: rebuilds every derived key from the records and compares (see [storage](storage.md#checking-integrity)). |
| `src/storage/constraints.zig` | Uniqueness constraints, checked against the property index before a write is made. |
| `src/storage/fulltext.zig` | The schema definitions (`i \| name`: full-text indexes, declared range indexes, uniqueness constraints) and the schema version that says when they changed. |
| `src/storage/fulltext_postings.zig` | Full-text postings, entity lengths, term counts and index totals, and how graph mutations keep them current. |
| `src/storage/fulltext_search.zig` | A full-text query against the postings: boolean clauses, phrases, prefix and fuzzy expansions, BM25. |
| `src/text/` | Text for full-text search: Unicode tables generated from the Unicode Character Database (`unicode_tables.zig`, by `tools/unicode_tables.py`), the analyzers (`analyzer.zig`), stop words, the Snowball stemmers (`snowball.zig`, `stem_english.zig`, `stem_spanish.zig`) and the query syntax (`query.zig`); also the case mappings of `toUpper`/`toLower` (`unicode.zig`), regular expressions for `=~` (`regex.zig`, a Pike VM: no pattern can make a query hang) and CSV for LOAD CSV (`csv.zig`). |
| `src/storage/graph.zig` | `Graph`: nodes, labels, typed edges, properties and their indexes, built on the key encoding. Each operation documents its cost. |
| `src/query/lexer.zig` | `tokenize`: query text to tokens (UTF-8 and backtick-quoted identifiers). |
| `src/query/parser.zig` | The `Parser` and the clause/pattern grammar. |
| `src/query/expression_parser.zig` | The expression grammar, by precedence. |
| `src/query/ast.zig` | The arena AST: `NodeKind` tags, a `Data` payload union, `addNode`/`nodeChildren`/`intern`, `sameExpression`. |
| `src/query/call_parser.zig`, `src/query/schema_parser.zig` | The CALL clause, and the schema commands (`CREATE FULLTEXT INDEX`, `DROP INDEX`, `SHOW INDEXES`). |
| `src/query/procedures.zig` | The procedures' signatures (arguments, columns and their kinds), shared by the semantic checks and the executor. |
| `src/query/printer.zig` | Cypher text of an expression, a pattern or a clause's items (EXPLAIN's details). |
| `src/query/semantics.zig` | Static checks before a query runs: each variable is used as one kind (node, relationship or value), literal operands have types their operators accept, no aggregates inside comprehensions. |
| `src/planning/Plan.zig` | The plan: operators (a tagged union) in chains, and each pattern's planned nodes and edges. Built once, never changed while it runs. |
| `src/planning/builder.zig` | Builds the plan: each clause's operators, the chains of subqueries and of patterns in expressions, the variables in scope. |
| `src/planning/patterns.zig` | Pattern planning: predicate pushdown (seeks and ranges), the estimates, anchor choice, the pattern's operators. |
| `src/planning/scope.zig` | The variables in scope at a point of a query, as the planner knows them. |
| `src/planning/expression_program.zig` | The query's expressions compiled with its plan: one instruction per AST node (a constant's value, a variable's slot, a parameter's index, a resolved function, a compiled constant regex). |
| `src/planning/statistics.zig` | The label and relationship-type counts the planner reads, once per plan, recorded in the plan. |
| `src/planning/explain.zig` | A plan as EXPLAIN's lines: the result first, inner chains one level deeper, with estimated rows. |
| `src/execution/Executor.zig` | The executor's state and `run()`: one transaction, the plan, then its main chains. |
| `src/execution/profiling.zig` | EXPLAIN and PROFILE: plans (and runs) the query, measures each operator's rows and exclusive time, returns the plan's lines as rows. |
| `src/execution/operators.zig` | Runs a plan's chains: `feed` hands a row to an operator, which passes its rows on to the next one; the operators that keep rows pass them on when their chain is done. |
| `src/execution/procedures.zig` | The procedures CALL runs, and how their rows extend the query's (YIELD, WHERE). |
| `src/execution/schema.zig` | The schema commands, each a statement of its own. |
| `src/execution/clauses.zig` | What the writing clauses do to one row, and the null bindings of an unmatched OPTIONAL MATCH. |
| `src/execution/pattern_matching.zig` | The pattern operators (`checkBoundNode`, `scanNodes`, `scanEdgeIndex`, `expand`, `projectPath`). |
| `src/execution/shortest_paths.zig` | `shortestPath` and `allShortestPaths`: breadth-first, or by increasing length when the WHERE reads the path. |
| `src/execution/expressions.zig` | Expression evaluation and operators, with three-valued null logic. |
| `src/execution/aggregation.zig` | Aggregate states and the generic `Grouping(Key, KeyContext)`. |
| `src/execution/projection.zig` | WITH and RETURN: projection, DISTINCT, ORDER BY, SKIP, LIMIT (`Sortable(T)`, `sortByKey`). |
| `src/execution/functions.zig` | The built-in functions, as one table. |
| `src/execution/comparison.zig` | `=` and the ordering operators: three-valued comparability, as opposed to `Value.order`. |
| `src/execution/temporal_functions.zig` | The temporal functions, components and arithmetic, on `Value`s. |
| `src/temporal/` | The calendar (`calendar.zig`), time zones (`zones.zig`), the temporal types (`types.zig`), ISO 8601 parsing (`parse.zig`), durations (`durations.zig`) and building values from fields (`selection.zig`). |
| `src/execution/writes.zig` | CREATE, MERGE, SET, REMOVE and DELETE; refuses names that cannot be stored (empty, or with a `0x00` byte). |
| `src/execution/load_csv.zig` | LOAD CSV: a CSV file's records as rows, read only from the import directory the database was opened with (none: LOAD CSV is off). |
| `src/execution/bindings.zig` | `Bindings`: a row, one value per slot (each query variable's place, given by the planner), with a trail so `restore` undoes a branch; `SlotsContext` compares rows by some slots. |
| `src/execution/entities.zig` | `EntitySnapshot`: the labels and properties of every node and relationship a result mentions, read before the transaction ends. |
| `src/statement/Statement.zig` | A prepared statement: parsed, checked and planned once; each run binds the parameters and plans again if the counts drifted. |
| `src/statement/Cache.zig` | The statements `query` calls prepared, by text, least recently used out first. |
| `src/c_api.zig` | The C ABI (`export fn`): a `Context` (store + graph) and a self-contained `Result`. Declared in `include/zypherdb.h`. |
| `python/native/module.zig` | The Python extension module, on the limited C API: converts parameters and rows directly, runs queries with the GIL released. See [the Python reference](python.md#under-the-hood). |
| `python/native/temporals.zig` | Converts temporal values to and from Python's `datetime` types. |
| `src/root.zig` | The library root: re-exports the public surface. |
| `tests/` | The test suite, through the public API only (see [contributing](contributing)). |

## The lifecycle of a query

A query is text in, rows out, through five stages. Each stage is a separate file. A query sent as
text (`zypherdb_query`, `Database.query`) is first looked up in the database's cache of prepared
statements (`statement/Cache.zig`, by text, 64 entries): a statement found there was parsed,
checked and planned before, so its run starts at stage 4, after reading the graph's counts again
to see whether the plan must be built again.

```{mermaid}
sequenceDiagram
  autonumber
  participant C as caller (C ABI or Python)
  participant T as statement/
  participant P as query/
  participant E as execution/ + planning/
  participant G as storage/graph.zig
  participant S as storage/key_value_store.zig

  C->>T: "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN m.title"
  T->>T: cached statement for this text?
  T->>P: (not cached) tokenize, recursive descent → arena AST
  T->>E: (not cached) check, plan: choose anchors, pull seeks out of WHERE, chain operators
  T->>E: run: bind parameters, open the transaction, replan if the counts drifted
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
2. **Check** — `Executor.check` rejects queries that are well-formed but meaningless:
   `semantics.check` (a node used as a relationship, `1 IN true`) and `functions.checkCalls` (an
   unknown function, a wrong number of arguments). Nothing has touched storage yet.
3. **Plan** — `planning/builder.zig` turns the checked AST into a plan: chains of operators, one
   or more per clause, with each `MATCH` pattern planned (equalities and ranges of the WHERE as
   seeks, an anchor chosen from the graph's counts). This is where the optimizations live. See [planning & execution](planning-execution).
4. **Execute** — `operators.feed` pushes rows through the chains; each pattern operator is a graph
   operation (a scan or an expansion) backed by a `scanPrefix` iterator. See [storage](storage)
   for what those operations *mean*.
5. **Return** — rows are projected; before the transaction ends, `EntitySnapshot.capture` reads
   the nodes and relationships the rows mention; then the rows are handed back, through the C ABI
   or the Python module.

The plan is built once per statement and does not change while it runs: what a run needs besides
it (parameters, rows, the transaction) is the executor's. A prepared statement keeps its plan
between runs and builds it again only when the counts it was planned on have drifted. See [planning & execution](planning-execution) for its operators, and *why there
is no cost-based optimizer yet*.
