# Embedding from Python

acmedb ships as a shared library with a C ABI, so Python can drive it with `ctypes` — no
compilation of Python extensions required. The reference implementation is `examples/demo.py`.

## Build and load

```bash
zig build                                    # produces zig-out/lib/libacmedb.{dylib,so}
python3 examples/demo.py
```

Load the library and declare the signatures once:

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
```

## A read helper

The `acmedb_result_type` tag tells you how to read each cell:

```python
def run(ctx, query: str) -> list[list]:
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
                if t == INT:
                    row.append(lib.acmedb_result_int(result, r, c))
                elif t == STR:
                    n = ctypes.c_size_t(0)
                    p = lib.acmedb_result_str(result, r, c, ctypes.byref(n))
                    row.append(ctypes.string_at(p, n.value).decode())
                elif t == BOOL:
                    row.append(lib.acmedb_result_bool(result, r, c))
                else:
                    row.append(None)   # NULL (and, for now, LIST)
            out.append(row)
        return out
    finally:
        lib.acmedb_result_free(result)
```

## Load and query

```python
path = tempfile.mkdtemp()
ctx = lib.acmedb_open(path.encode(), len(path))

lib.acmedb_add_node(ctx, 1, b"Person", 6)
lib.acmedb_set_prop_str(ctx, 1, b"name", 4, b"Keanu Reeves", 13)
lib.acmedb_add_node(ctx, 100, b"Movie", 5)
lib.acmedb_set_prop_str(ctx, 100, b"title", 5, b"The Matrix", 10)
lib.acmedb_add_edge(ctx, 1, 100, b"ACTED_IN", 8)

print(run(ctx, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title"))
# [['The Matrix']]

lib.acmedb_close(ctx)
```

Node ids are caller-supplied and fixed here; write your own id allocator on top of the ABI, or
just use `acmedb_query` with `CREATE`, which allocates ids internally and answers with `RETURN`.
