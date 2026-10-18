# 1. Getting started

We build a small **people and movies** graph and answer our first query. By the end of this page
you will have built acmedb, loaded it from Python, written a few nodes and edges, and run a
`MATCH`.

## Build

acmedb needs the **Zig** toolchain (0.17.0) and nothing else — it vendors LMDB and compiles it
itself. From the project root:

```bash
zig build test    # build and run the test suite
zig build         # build the static + shared libraries into zig-out/
```

The shared library `zig-out/lib/libacmedb.dylib` (`.so` on Linux) exposes the C ABI we drive from
Python with `ctypes`.

## Load it from Python

Declare the C signatures and a small `run` helper (this is the code every later page reuses):

```python
import ctypes, platform, tempfile
from pathlib import Path

libname = "libacmedb.dylib" if platform.system() == "Darwin" else "libacmedb.so"
lib = ctypes.CDLL(str(Path("zig-out/lib") / libname))

lib.acmedb_open.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_open.restype = ctypes.c_void_p
lib.acmedb_close.argtypes = [ctypes.c_void_p]

lib.acmedb_add_node.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_add_edge.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_set_prop_i64.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int64]
lib.acmedb_set_prop_str.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]

lib.acmedb_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_query.restype = ctypes.c_void_p
lib.acmedb_result_free.argtypes = [ctypes.c_void_p]
lib.acmedb_result_rows.argtypes = [ctypes.c_void_p]
lib.acmedb_result_rows.restype = ctypes.c_size_t
lib.acmedb_result_cols.argtypes = [ctypes.c_void_p]
lib.acmedb_result_cols.restype = ctypes.c_size_t
lib.acmedb_result_type.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_type.restype = ctypes.c_int
lib.acmedb_result_int.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_int.restype = ctypes.c_int64
lib.acmedb_result_bool.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_bool.restype = ctypes.c_bool
lib.acmedb_result_str.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
lib.acmedb_result_str.restype = ctypes.c_void_p

INT, STR, BOOL, NULL, LIST = 0, 1, 2, 3, 4

def run(ctx, query):
    result = lib.acmedb_query(ctx, query.encode(), len(query))
    if not result:
        raise RuntimeError(query)
    try:
        rows, cols = lib.acmedb_result_rows(result), lib.acmedb_result_cols(result)
        out = []
        for r in range(rows):
            row = []
            for c in range(cols):
                t = lib.acmedb_result_type(result, r, c)
                if t == INT:      row.append(lib.acmedb_result_int(result, r, c))
                elif t == STR:
                    n = ctypes.c_size_t(0)
                    p = lib.acmedb_result_str(result, r, c, ctypes.byref(n))
                    row.append(ctypes.string_at(p, n.value).decode())
                elif t == BOOL:   row.append(lib.acmedb_result_bool(result, r, c))
                else:             row.append(None)   # NULL / LIST
            out.append(row)
        return out
    finally:
        lib.acmedb_result_free(result)
```

## Load the graph

Five people, four movies, and who acted in (or directed) what:

```python
path = tempfile.mkdtemp()
ctx = lib.acmedb_open(path.encode(), len(path))

people = [(1, "Keanu Reeves", 1964), (2, "Carrie-Anne Moss", 1967), (3, "Laurence Fishburne", 1961),
          (4, "Lana Wachowski", 1965), (5, "Tom Hanks", 1956)]
movies = [(100, "The Matrix", 1999), (101, "The Matrix Reloaded", 2003),
          (102, "John Wick", 2014), (103, "Forrest Gump", 1994)]
acted_in = [(1, 100), (1, 101), (1, 102), (2, 100), (3, 100), (5, 103)]
directed = [(4, 100), (4, 101)]

for pid, name, born in people:
    lib.acmedb_add_node(ctx, pid, b"Person", 6)
    lib.acmedb_set_prop_str(ctx, pid, b"name", 4, name.encode(), len(name))
    lib.acmedb_set_prop_i64(ctx, pid, b"born", 4, born)
for mid, title, released in movies:
    lib.acmedb_add_node(ctx, mid, b"Movie", 5)
    lib.acmedb_set_prop_str(ctx, mid, b"title", 5, title.encode(), len(title))
    lib.acmedb_set_prop_i64(ctx, mid, b"released", 8, released)
for a, m in acted_in:
    lib.acmedb_add_edge(ctx, a, m, b"ACTED_IN", 8)
for a, m in directed:
    lib.acmedb_add_edge(ctx, a, m, b"DIRECTED", 8)
```

Every later page assumes this `ctx` and this graph.

## Your first query

```python
print(run(ctx, "MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born"))
```

```text
[[1964]]
```

Read it left to right: match a node `p` with label `Person` whose `name` is `'Keanu Reeves'`, and
return its `born` property. The `{name: 'Keanu Reeves'}` is an equality that acmedb turns into an
index lookup, not a scan.

Next, [step 2](02-matching) follows an edge out of a node.
