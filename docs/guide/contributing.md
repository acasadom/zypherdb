# Contributing — how to extend the engine

The shape of the codebase makes each kind of change follow a fixed recipe. This page is that
recipe, the principles the code follows, the build/test loop, and the Zig 0.17 gotchas that have
already cost time.

## Build and test

```bash
zig build test    # unit tests in src/ + the suite in tests/
zig build         # static + shared libraries and acmedb.h into zig-out/
make python       # the Python extension module into zig-out/python/
make test-py      # Python tests and documentation tests (pip install -e "python[dev]" once)
make tck          # the openCypher TCK
make docs         # the HTML documentation
```

`make python` and the targets that use it find the Python headers through `PYTHON` (default
`python3`); point it at a virtual environment with `make test-py PYTHON=.venv/bin/python`.

`zig build test` runs two executables:

- **The suite, `tests/`.** It imports the `acmedb` module like any client and uses **only the
  public API**. It mirrors the source layers: `tests/storage/`, `tests/query/`,
  `tests/end_to_end/` (whole queries, one file per feature) and `tests/c_api_test.zig`.
  `tests/support.zig` holds the shared helpers: a temporary store, the "people and movies" fixture
  (`loadMoviesGraph`), and `expectQuery`/`expectOrdered`/`expectQueryError`. Most feature work is
  verified with a few `expectQuery` calls, not mocks.
- **Unit tests in `src/`.** A `test` block stays next to its code only when it checks something
  private and small: the key encoding round trip, the laws of `Value`'s order and hash, the generic
  algorithms, diagnostic truncation.

- **The Python tests, `python/tests/`**, check the extension module: value conversion both ways,
  entities, errors, threads.
- **The documentation tests, `python/tests/test_docs.py`**, run every example in `docs/`. The
  tutorial runs as one session, page after page; each other page runs on its own. A `text` block
  right after an example is its expected output and must match exactly. C examples with a `main`
  are compiled with `zig cc` and run. So a change that alters an output shown in the documentation
  fails until the page is updated, and every page states what the engine actually does.

A bug fix comes with a regression test that fails without the fix.

### The openCypher TCK

`make tck` runs the [openCypher TCK](https://github.com/opencypher/openCypher/tree/main/tck)
(vendored in `tests/tck/`, see its README) and fails if a scenario in `tests/tck/baseline.txt` no
longer passes; CI does the same. Language work is measured there: pick a reason from
`tests/tck/REPORT.md`, implement it, run `make tck`, then record the newly passing scenarios with
`python -I tests/tck/runner.py --update-baseline --report tests/tck/REPORT.md` in the same commit.
`tests/tck/deviations.txt` lists the scenarios that acmedb answers differently on purpose (map
properties, for instance), each with its reason.

### Benchmarks

`zig build bench -Doptimize=ReleaseFast` measures the engine, and `bench/python_overhead.py` the
cost the Python layer adds. Results and their conditions are recorded in `bench/RESULTS.md`, and
known risks in [performance](performance). A change that claims a speed-up comes with numbers
from both runs.
A scenario that leaves the baseline needs an explanation in the commit message (for example, an
expected error that used to match only by accident).

## Principles

The style follows Alexander Stepanov's generic programming, within Zig's conventions.

- **Regular types.** A type that is compared, sorted, deduplicated or grouped defines `eql`, a total
  `order` when ordering is meaningful, and a `hash` consistent with `eql`, under the std names. Their
  laws (reflexive, antisymmetric, transitive, total; equal values hash equally) are checked by
  property tests over random values (see `src/value.zig`).
- **Write an algorithm once.** When the same algorithm appears for a second type, make it generic
  over the type (`comptime T: type`) and a context with the operations it needs, following the
  std.HashMap context protocol (`hash(ctx, T) u64`, `eql(ctx, T, T) bool`). Examples:
  `sequence_algorithms.removeDuplicates`, `aggregation.Grouping`, `projection.sortByKey`. Do not
  generalize before there are two concrete uses.
- **Costs are part of the interface.** A public storage operation states its complexity (see
  `src/storage/graph.zig`). A new operation states its own.
- **Ownership is part of the interface.** Say who owns returned memory: an owned copy (`getProperty`
  allocates with the caller's allocator) or a view (an iterator's slices are valid until the next
  `next`).
- **Errors are values** (`error union`s), never `catch unreachable` on I/O. Every error that reaches
  the C ABI or Python carries a `Diagnostic` message and code.
- **No class hierarchies, no Visitor.** Data as concrete types, algorithms as free functions. The
  AST is an arena: no pointers between nodes; build bottom-up and return indices.

## Layout and naming

- **One directory per layer**: `storage/` (LMDB, keys, graph), `query/` (text to AST), `execution/`
  (AST to rows), `temporal/` (calendar, zones, temporal types). Shared types and algorithms sit in
  `src/` (`value.zig`, `sequence_algorithms.zig`, `diagnostics.zig`). The embeddings sit apart:
  `src/c_api.zig` with `include/acmedb.h`, and `python/` (the native module in `python/native/`,
  the package in `python/acmedb/`).
- **One responsibility per file**, as a guide under ~500 lines of code; functions under ~60 lines.
  A large `switch` over token or node kinds (`tokenize`, `evaluate`) is the exception: it reads best
  in one place.
- **Zig's file convention**: a file that *is* a struct (top-level fields) is `TitleCase`
  (`Executor.zig`); any other file is `snake_case`. Zig cannot spread a struct's methods over files,
  so a large struct keeps its state and splits its logic into free functions in other files that
  take it as the first parameter (`expressions.evaluate(executor, …)`). Calls go through the module
  name, so a call site says where the code lives.
- **Descriptive names, no abbreviations** (`edge_type`, `variable_name`, `children`, `diagnostic`).
  Kept on purpose: `id`, `src`/`dst`, std's own names (`tmpDir`), the LMDB C API's own names inside
  the bindings, and one-letter names in short loops.

## The recipes

### Add a clause

A clause is a `NodeKind`, a parser rule, and an executor arm.

1. `src/query/ast.zig` — add a `NodeKind` value (and a `Data` payload if it carries state, e.g.
   `unwind.variable_name`). Document its children in the header comment.
2. `src/query/parser.zig` — add a `parse…Clause` function and call it from `parseQuery` in source
   order.
3. `src/execution/` — a case in `Executor.runClauses`, which turns the rows the clause receives
   into the rows it passes on. A writing clause goes through `clauses.runWrite` to `writes.zig`, and
   must be listed in `clauses.isWrite` so the query opens a write transaction.
4. `src/query/semantics.zig` — the variables it binds, if any, so later clauses see them in scope.
5. `tests/end_to_end/` — queries that use it, in the feature's file; then `make tck`.
6. `docs/guide/cypher.md` — its row in the clause table, and a tutorial step if users need it.

### Add an expression or operator

1. `src/query/ast.zig` — a `NodeKind` (expression) or a `BinaryOperator` value.
2. `src/query/expression_parser.zig` — a `parseAtom` branch (expression), or the loop of the
   precedence level where the operator belongs (see [the language](language)).
3. `src/execution/expressions.zig` — a case in `evaluate` (expression) or `applyBinaryOperator`
   (operator), with the null propagation of [planning and execution](planning-execution.md#nulls).
4. `docs/guide/cypher.md` — the operator table.

### Add a function

Functions need no parser change: a call is parsed by name.

1. `src/execution/functions.zig` — an implementation, `fn (*Executor, []const Value)
   ExecutionError!Value`, and an entry in `builtin_entries` with its number of arguments (`fixed(n,
   f)`, or a `Function` with a range). Temporal functions are implemented in
   `temporal_functions.zig` and listed in `temporal_table`.
   `checkCalls` then rejects wrong arities before the query runs.
2. `docs/guide/cypher.md` — its row in the function table.

### Add an index

Indexes are just more key ranges (see [storage](storage)):

1. `src/storage/key_encoding.zig` — an `append…Key`/`append…Prefix` pair for the new layout.
2. `src/storage/graph.zig` — maintain it in the right mutation (`setProperty`, `addEdge`, …) and
   cleanup (`deleteNodeOnly`, `deleteEdgesInDirection`), and expose a lookup that returns an
   iterator (`nodesByProperty`/`edgesByProperty` are the models). State its cost.
3. If it should drive planning, surface it in `planner.estimate`/`planner.shouldEdgeAnchor`.

## Zig 0.17 gotchas (rediscovered once, recorded here)

- `@cImport` is removed → hand-written bindings: `extern "c" fn` + `opaque {}` (see
  `src/storage/lmdb_bindings.zig`), or `b.addTranslateC` in `build.zig` for a large header (the
  Python module translates `python/native/python.h`).
- `@intFromEnum` became `@backingInt` (`zig fmt` rewrites it); a struct's field names are
  `@typeInfo(T).@"struct".field_names`.
- The clock and randomness come from `std.Io` (`std.Io.Threaded.global_single_threaded.io()` where
  no `Io` is passed in); `main` takes `std.process.Init`.
- `std.fmt.bufPrintZ` is gone; `std.heap.stackFallback` became `std.heap.BufferFirstAllocator`.
- `std.fs` was reorganized into `std.Io`; `makePath`/`realpathAlloc` no longer exist.
- `std.testing.tmpDir(.{})` returns a `TmpDir` (not an error union); clean up with `.cleanup()`.
- `Allocator.dupeZ` is gone → `dupeSentinel(u8, slice, 0)`.
- `std.ArrayList(T)` is now the *unmanaged* variant: init with `.empty`, and pass the allocator to
  `append(allocator, …)`/`deinit(allocator)`. `ArrayList.init(allocator)` no longer exists.
- Build API: `b.addModule`/`b.createModule`/`b.addLibrary`/`b.addTest`; `link_libc` lives in
  `Module.CreateOptions`.
- `str ** n` (comptime repetition) does not parse in this version; use `@splat` or `@memset`.
- macOS file systems are case-insensitive: renaming `foo.zig` to `Foo.zig` needs two `git mv` steps
  (through a temporary name), or git keeps the old case and Linux builds fail.
