# Contributing — how to extend the engine

The shape of the codebase makes each kind of change follow a fixed recipe. This page is that
recipe, the principles the code follows, the build/test loop, and the Zig 0.17 gotchas that have
already cost time.

## Build and test

```bash
zig build test    # unit tests in src/ + the suite in tests/
zig build         # static + shared libraries into zig-out/
make test-py      # Python bindings (pip install -e "python[dev]" once)
```

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

A bug fix comes with a regression test that fails without the fix.

### The openCypher TCK

`make tck` runs the [openCypher TCK](https://github.com/opencypher/openCypher/tree/main/tck)
(vendored in `tests/tck/`, see its README) and fails if a scenario in `tests/tck/baseline.txt` no
longer passes; CI does the same. Language work is measured there: pick a reason from
`tests/tck/REPORT.md`, implement it, run `make tck`, then record the newly passing scenarios with
`python -I tests/tck/runner.py --update-baseline --report tests/tck/REPORT.md` in the same commit.
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
  the C ABI carries a `Diagnostic` message and code.
- **No class hierarchies, no Visitor.** Data as concrete types, algorithms as free functions. The
  AST is an arena: no pointers between nodes; build bottom-up and return indices.

## Layout and naming

- **One directory per layer**: `storage/` (LMDB, keys, graph), `query/` (text to AST), `execution/`
  (AST to rows). Shared types and algorithms sit in `src/` (`value.zig`, `sequence_algorithms.zig`,
  `diagnostics.zig`).
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
3. `src/execution/` — classify it in `Executor.classifyClauses`, then handle it where it runs: a
   read clause in the matching pipeline, a write clause in `Executor.finishBody` (dispatching to
   `writes.zig`).
4. `tests/end_to_end/` — queries that use it, in the feature's file.

### Add an expression or operator

1. `src/query/ast.zig` — a `NodeKind` (expression) or a `BinaryOperator` value.
2. `src/query/expression_parser.zig` — a `parsePrimary` branch (expression/function) or a
   `parseComparison` branch (infix operator).
3. `src/execution/expressions.zig` — a match arm in `evaluate` (expression) or
   `applyBinaryOperator` (operator), plus any null-propagation guard.

### Add a function

Same as an expression, but the parser branch is `name` followed by `(` — mirror `size`
(`parsePrimary` → `size_function`).

### Add an index

Indexes are just more key ranges (see [storage](storage)):

1. `src/storage/key_encoding.zig` — an `append…Key`/`append…Prefix` pair for the new layout.
2. `src/storage/graph.zig` — maintain it in the right mutation (`setProperty`, `addEdge`, …) and
   cleanup (`deleteNodeOnly`, `deleteEdgesInDirection`), and expose a lookup that returns an
   iterator (`nodesByProperty`/`edgesByProperty` are the models). State its cost.
3. If it should drive planning, surface it in `planner.estimate`/`planner.shouldEdgeAnchor`.

## Zig 0.17 gotchas (rediscovered once, recorded here)

- `@cImport` is removed → hand-written bindings: `extern "c" fn` + `opaque {}` (see
  `src/storage/lmdb_bindings.zig`).
- `std.fs` was reorganized into `std.Io`; `makePath`/`realpathAlloc` no longer exist.
- `std.testing.tmpDir(.{})` returns a `TmpDir` (not an error union); clean up with `.cleanup()`.
- `Allocator.dupeZ` is gone → `dupeSentinel(u8, slice, 0)`.
- `std.ArrayList(T)` is now the *unmanaged* variant: init with `.empty`, and pass the allocator to
  `append(allocator, …)`/`deinit(allocator)`. `ArrayList.init(allocator)` no longer exists.
- Build API: `b.addModule`/`b.createModule`/`b.addLibrary`/`b.addTest`; `link_libc` lives in
  `Module.CreateOptions`.
- `str ** n` (comptime repetition) does not parse in this version; build such buffers with
  `@memset`.
- macOS file systems are case-insensitive: renaming `foo.zig` to `Foo.zig` needs two `git mv` steps
  (through a temporary name), or git keeps the old case and Linux builds fail.
