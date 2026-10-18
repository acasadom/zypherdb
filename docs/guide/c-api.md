# C ABI

The engine is exposed as a shared library (`zig-out/lib/libacmedb.dylib` on macOS,
`libacmedb.so` on Linux) with a small C ABI in `src/capi.zig`. Strings are passed as
`(pointer, length)` pairs; handles are opaque pointers the caller must release.

Result cells are tagged by type:

| Tag | `acmedb_result_type` | Value |
| --- | --- | --- |
| `TYPE_INT` | `0` | `i64` |
| `TYPE_STR` | `1` | UTF-8 string |
| `TYPE_BOOL` | `2` | boolean |
| `TYPE_NULL` | `3` | null |
| `TYPE_LIST` | `4` | list (flat lists only) |

## Lifecycle

```c
typedef struct Context Context;   // opaque
typedef struct Result Result;     // opaque

Context* acmedb_open(const char* path, size_t path_len);   // NULL on failure
void     acmedb_close(Context*);
const char* acmedb_last_error(Context*, size_t* out_len);  // last error message
```

`acmedb_open` opens (or creates) an LMDB database at `path`; the directory must exist. Every other
function takes the returned `Context*`.

## Writing data

```c
int acmedb_add_node(Context*, uint64_t id, const char* label, size_t label_len);
int acmedb_add_edge(Context*, uint64_t src, uint64_t dst, const char* type, size_t type_len);
int acmedb_set_prop_i64(Context*, uint64_t id, const char* name, size_t name_len, int64_t value);
int acmedb_set_prop_str(Context*, uint64_t id, const char* name, size_t name_len,
                        const char* value, size_t value_len);
```

Each returns `0` on success, non-zero on failure. `acmedb_add_node` takes a single label; node ids
are caller-supplied (fixed ids, as in `examples/demo.py`).

## Querying

```c
Result* acmedb_query(Context*, const char* query, size_t query_len);   // NULL on failure
void    acmedb_result_free(Result*);
size_t  acmedb_result_rows(const Result*);
size_t  acmedb_result_cols(const Result*);
int     acmedb_result_type(const Result*, size_t row, size_t col);   // -1 out of range
int64_t acmedb_result_int(const Result*, size_t row, size_t col);
bool    acmedb_result_bool(const Result*, size_t row, size_t col);
const char* acmedb_result_str(const Result*, size_t row, size_t col, size_t* out_len);
```

`acmedb_query` runs one query (any subset of the [language](cypher)) and returns a self-contained
`Result` that owns all its string cells; free it with `acmedb_result_free`. On failure it returns
`NULL` and `acmedb_last_error` describes why.

## From Python (ctypes)

The `examples/demo.py` file is the working reference. In short:

```python
import ctypes, tempfile

lib = ctypes.CDLL("zig-out/lib/libacmedb.dylib")   # or libacmedb.so
lib.acmedb_open.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_open.restype = ctypes.c_void_p
# … (set the remaining argtypes/restypes as in demo.py) …

ctx = lib.acmedb_open(path.encode(), len(path))
lib.acmedb_add_node(ctx, 1, b"Person", 6)
lib.acmedb_query(ctx, b"MATCH (n:Person) RETURN n", 26)
```

See [the Python guide](python) for a full worked example.
