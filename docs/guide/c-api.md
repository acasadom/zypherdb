# C ABI

The engine is exposed as a shared library (`zig-out/lib/libacmedb.dylib` on macOS,
`libacmedb.so` on Linux) with a small C ABI in `src/c_api.zig`. Strings are passed as
`(pointer, length)` pairs; handles are opaque pointers the caller must release.

Result cells are tagged by type:

| Tag | `acmedb_result_type` | Value |
| --- | --- | --- |
| `TYPE_INT64` | `0` | `i64` |
| `TYPE_STRING` | `1` | UTF-8 string |
| `TYPE_BOOLEAN` | `2` | boolean |
| `TYPE_NULL` | `3` | null |
| `TYPE_LIST` | `4` | list (the per-item readers cover flat lists; JSON covers any) |
| `TYPE_NODE` | `5` | a whole node — read it through the JSON result |
| `TYPE_RELATIONSHIP` | `6` | a whole relationship — read it through the JSON result |
| `TYPE_MAP` | `7` | a map — a JSON object in the JSON result |
| `TYPE_PATH` | `8` | a path — `{"~path": {"nodes": [...], "relationships": [...]}}` in the JSON result |
| `TYPE_FLOAT64` | `9` | `f64`; in JSON always with a `.` or an exponent (`1.0`), and `NaN` / `Infinity` / `-Infinity` for the special values |
| `TYPE_DATE` … `TYPE_DURATION` | `10` – `15` | date, local time, time, local date-time, date-time, duration — in JSON a tagged ISO 8601 string: `{"~date": "2024-07-02"}`, `{"~localtime": …}`, `{"~time": …}`, `{"~localdatetime": …}`, `{"~datetime": "2024-07-02T09:30+02:00[Europe/Madrid]"}`, `{"~duration": "P1DT2H"}` |

## Lifecycle

```c
typedef struct Context Context;   // opaque
typedef struct Result Result;     // opaque

Context* acmedb_open(const char* path, size_t path_len);   // NULL on failure
// durability: 0 full (default: each commit on disk when it returns), 1 relaxed (a power
// failure can lose the last commit, never corrupt), 2 deferred (the OS or acmedb_sync writes)
Context* acmedb_open_with_durability(const char* path, size_t path_len, int durability);
int      acmedb_sync(Context*);                             // write every commit so far to disk
void     acmedb_close(Context*);
const char* acmedb_last_error(Context*, size_t* out_len);  // last error message
int      acmedb_error_code(Context*);                       // last error code (0 = none)
```

`acmedb_open` opens (or creates) an LMDB database at `path`; the directory must exist. Every other
function takes the returned `Context*`. Error codes (from `diagnostics.zig`):

| Code | Meaning |
| --- | --- |
| `0` | no error |
| `1` | parse error |
| `2` | unknown variable |
| `3` | reserved (a missing property reads as `null`) |
| `4` | type mismatch |
| `5` | invalid expression (e.g. `WITH` without an alias) |
| `6` | node still connected (`DELETE` without `DETACH`) |
| `7` | storage error |
| `8` | a `$name` parameter was not given |
| `9` | arithmetic error: integer overflow or division by zero |

## Writing data

```c
uint64_t acmedb_allocate_node_id(Context*);   // fresh id; maxInt(u64) on failure
int acmedb_add_node(Context*, uint64_t id, const char* label, size_t label_len);
int acmedb_add_edge(Context*, uint64_t src, uint64_t dst, const char* type, size_t type_len);
int acmedb_set_property_int64(Context*, uint64_t id, const char* name, size_t name_len, int64_t value);
int acmedb_set_property_float64(Context*, uint64_t id, const char* name, size_t name_len, double value);
int acmedb_set_property_string(Context*, uint64_t id, const char* name, size_t name_len,
                        const char* value, size_t value_len);

// batch writes into one transaction (one fsync):
int  acmedb_begin_write(Context*);
int  acmedb_commit_write(Context*);
void acmedb_abort_write(Context*);
```

Each mutator returns `0` on success, non-zero on failure. `acmedb_allocate_node_id` allocates a
never-used id atomically; `acmedb_add_node` also accepts caller-supplied ids. `acmedb_add_node`
takes a single label (add more with `acmedb_query` `CREATE`, or `SET`).

`acmedb_begin_write` … `acmedb_commit_write` wrap mutators in one write transaction: everything in
between commits atomically at the end (one fsync), and `acmedb_abort_write` rolls it back. This is
the bulk-ingestion path — individual mutators each commit on their own and are fsync-bound.

## Querying

```c
Result* acmedb_query(Context*, const char* query, size_t query_len);   // NULL on failure
// with `$name` parameters as a JSON object, e.g. {"card": 123, "zones": ["A"], "m": {"k": 1}};
// a temporal parameter is tagged as in results: {"at": {"~datetime": "2024-07-02T07:30Z"}}
Result* acmedb_query_with_parameters(Context*, const char* query, size_t query_len,
                                     const char* parameters_json, size_t parameters_len);
void    acmedb_result_free(Result*);
size_t  acmedb_result_row_count(const Result*);
size_t  acmedb_result_column_count(const Result*);
int     acmedb_result_type(const Result*, size_t row, size_t col);   // -1 out of range
int64_t acmedb_result_int(const Result*, size_t row, size_t col);
double  acmedb_result_float(const Result*, size_t row, size_t col);
bool    acmedb_result_bool(const Result*, size_t row, size_t col);
const char* acmedb_result_string(const Result*, size_t row, size_t col, size_t* out_len);
const char* acmedb_result_to_json(const Result*, size_t* out_len);   // whole result as JSON

// list cells (TYPE_LIST) — flat lists only:
size_t acmedb_result_list_length(const Result*, size_t row, size_t col);
int    acmedb_result_list_item_type(const Result*, size_t row, size_t col, size_t idx);
int64_t acmedb_result_list_item_int(const Result*, size_t row, size_t col, size_t idx);
double acmedb_result_list_item_float(const Result*, size_t row, size_t col, size_t idx);
bool   acmedb_result_list_item_bool(const Result*, size_t row, size_t col, size_t idx);
const char* acmedb_result_list_item_string(const Result*, size_t row, size_t col, size_t idx, size_t* out_len);
```

`acmedb_query` runs one query (any subset of the [language](cypher)) and returns a self-contained
`Result` that owns all its string cells; free it with `acmedb_result_free`. On failure it returns
`NULL`; `acmedb_last_error` carries the message and `acmedb_error_code` the category. A runtime
error that never set a specific message gets a generic `"query failed: <ErrorName>"`.

`acmedb_result_to_json` serializes the whole result to a JSON array of arrays (`[[…], […]]`) in one
call — the recommended way to read a large result. The returned pointer lives until
`acmedb_result_free`. The per-cell and per-list-item readers above stay available for languages
without a JSON parser.

Nodes and relationships appear in the JSON as tagged objects, with their state when the query
finished (a node the query deleted keeps its id but has no labels or properties):

```json
{"~node": {"id": 0, "labels": ["Person"], "properties": {"name": "Ana"}}}
{"~relationship": {"source": 0, "target": 1, "type": "KNOWS", "properties": {"since": 2020}}}
```

`acmedb_export_json` returns the whole graph (`{"nodes": [...], "relationships": [...]}`) read
straight from storage; the buffer belongs to the context until the next export or close.

## From Python (ctypes)

The `examples/demo.py` file is the working reference. In short:

```python
# docs-test: skip
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
