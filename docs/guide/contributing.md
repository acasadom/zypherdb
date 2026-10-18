# Contributing — how to extend the engine

The shape of the codebase makes each kind of change follow a fixed recipe. This page is that
recipe, plus the build/test loop and the Zig 0.17 gotchas that have already cost time.

## Build and test

```bash
zig build test    # build + run the whole suite (all `test` blocks in src/)
zig build         # static + shared libraries into zig-out/
```

Tests are Zig `test` blocks co-located with the code (one per concern: storage, parser, executor,
C ABI). The executor tests drive real queries end-to-end through a shared "people and movies"
dataset (`loadSlice`), so most feature work is verified with a few `expectQuery` calls, not mocks.

## The recipes

### Add a clause

A clause is a `NodeKind`, a parser rule, and an executor arm.

1. `src/ast/ast.zig` — add a `NodeKind` value (and a `Data` payload if it carries state, e.g.
   `unwind.var_name`). Document its children in the header comment.
2. `src/parser/parser.zig` — add a `parse…Clause` function and call it from `parseQuery` in source
   order.
3. `src/exec/exec.zig` — handle it in `run` (a read clause) or `finishBody` (a write clause).

### Add an expression or operator

1. `src/ast/ast.zig` — a `NodeKind` (expression) or a `BinOp` value.
2. `src/parser/parser.zig` — a `parsePrimary` branch (expression/function) or a `parseComparison`
   branch (infix operator).
3. `src/exec/exec.zig` — a match arm in `eval` (expression) or `applyBinOp` (operator), plus any
   null-propagation guard.

### Add a function

Same as an expression, but the parser branch is `name` followed by `(` — mirror `size`
(`parsePrimary` → `size_fn`).

### Add an index

Indexes are just more key ranges (see [storage](storage)):

1. `src/storage/graph.zig` — an `append…Key`/`append…Prefix` pair, and maintain it in the right
   mutation (`setProp`, `addEdge`, …) and cleanup (`deleteNodeOnly`, `deleteEdgesInDirection`).
2. Expose a lookup that returns an iterator (`nodesByProp`/`edgesByProp` are the models).
3. If it should drive planning, surface it in `estimate`/`shouldEdgeAnchor`.

## Style rules (non-negotiable, consistent with the whole codebase)

- **No class hierarchies, no Visitor.** Data as concrete types, algorithms as free functions.
- **Errors as values** (`error union`s), never exceptions, never `catch unreachable` on I/O.
- **The AST is an arena**: no pointers between nodes; build bottom-up and return indices.
- Everything below `graph.zig` talks to LMDB only through `KvStore`'s `scanPrefix` iterators.

## Zig 0.17 gotchas (rediscovered once, recorded here)

- `@cImport` is removed → hand-written bindings: `extern "c" fn` + `opaque {}` (see
  `src/storage/lmdb.zig`).
- `std.fs` was reorganized into `std.Io`; `makePath`/`realpathAlloc` no longer exist.
- `std.testing.tmpDir(.{})` returns a `TmpDir` (not an error union); clean up with `.cleanup()`.
- `Allocator.dupeZ` is gone → `dupeSentinel(u8, slice, 0)`.
- `std.ArrayList(T)` is now the *unmanaged* variant: init with `.empty`, and pass the allocator to
  `append(gpa, …)`/`deinit(gpa)`. `ArrayList.init(gpa)` no longer exists.
- Build API: `b.addModule`/`b.createModule`/`b.addLibrary`/`b.addTest`; `link_libc` lives in
  `Module.CreateOptions`.
