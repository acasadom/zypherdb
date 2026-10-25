# C reference

The engine is a C library: `zig build` produces `zig-out/lib/libacmedb.a` (static),
`libacmedb.dylib` or `libacmedb.so` (shared), and the header `zig-out/include/acmedb.h`. C, C++ and
any language with a C foreign-function interface can embed acmedb through it. Python does not need
it, since the [Python package](python) has its own native module.

- Strings are passed as `(pointer, length)` pairs in UTF-8; they do not need a terminating NUL.
- A context (`acmedb_context *`) and a result (`acmedb_result *`) are opaque handles. Release them
  with `acmedb_close` and `acmedb_result_free`.

## A first program

```c
#include <acmedb.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "helix-db";
    acmedb_context *db = acmedb_open(path, strlen(path));
    if (db == NULL) return 1;

    const char *create = "CREATE (:Person {name: 'Ana', badge: 101}), (:Person {name: 'Luis', badge: 102})";
    acmedb_result *created = acmedb_query(db, create, strlen(create));
    acmedb_result_free(created);

    const char *find = "MATCH (p:Person) WHERE p.badge = $badge RETURN p.name, p.badge";
    const char *parameters = "{\"badge\": 102}";
    acmedb_result *found = acmedb_query_with_parameters(db, find, strlen(find), parameters, strlen(parameters));
    for (size_t row = 0; row < acmedb_result_row_count(found); row++) {
        size_t length;
        const char *name = acmedb_result_string(found, row, 0, &length);
        printf("%.*s has badge %lld\n", (int)length, name, (long long)acmedb_result_int(found, row, 1));
    }
    acmedb_result_free(found);

    const char *bad = "MATCH (p:Person) RETURN q";
    if (acmedb_query(db, bad, strlen(bad)) == NULL) {
        size_t length;
        const char *message = acmedb_last_error(db, &length);
        printf("error %d: %.*s\n", acmedb_error_code(db), (int)length, message);
    }

    acmedb_close(db);
    return 0;
}
```

```text
Luis has badge 102
error 2: unknown variable 'q'
```

Build it against the library (any C compiler works; `zig cc` is one):

```bash
zig cc -Izig-out/include first.c -Lzig-out/lib -lacmedb -o first
```

## Opening and closing

```c
acmedb_context *acmedb_open(const char *path, size_t path_len);
acmedb_context *acmedb_open_with_durability(const char *path, size_t path_len, int durability);
int acmedb_sync(acmedb_context *context);
int acmedb_set_import_directory(acmedb_context *context, const char *path, size_t path_len);
void acmedb_close(acmedb_context *context);
```

`acmedb_open` opens the database in directory `path`, creating the database if it does not exist;
the directory itself must exist. It returns `NULL` on failure. `acmedb_open` uses full durability,
and `acmedb_open_with_durability` chooses the mode:

| Mode | A commit returns when… | A power failure can lose… |
| --- | --- | --- |
| `ACMEDB_DURABILITY_FULL` (0) | its data is on disk | nothing |
| `ACMEDB_DURABILITY_RELAXED` (1) | its data is on disk; its bookkeeping follows with the next commit | the last commit |
| `ACMEDB_DURABILITY_DEFERRED` (2) | it is in memory; the operating system writes it, or `acmedb_sync` | the commits since the last `acmedb_sync` |

`acmedb_set_import_directory` sets the directory `LOAD CSV` reads from (`path_len` 0: none, which
turns `LOAD CSV` off, as it is after opening): a query's `file:///name.csv` is `name.csv` in it,
and nothing outside it can be read.

No mode can corrupt the database. `acmedb_sync` writes every commit so far to disk and returns
`ACMEDB_OK` or `ACMEDB_STORAGE_ERROR`.

## Errors

```c
const char *acmedb_last_error(acmedb_context *context, size_t *out_len);
int acmedb_error_code(acmedb_context *context);
```

When a query fails, these two functions describe the failure: the message, and its category. The
message stays valid until the next call on the context.

| Code | Constant | Meaning |
| --- | --- | --- |
| 0 | `ACMEDB_ERROR_NONE` | no error |
| 1 | `ACMEDB_ERROR_PARSE` | the query is not valid Cypher |
| 2 | `ACMEDB_ERROR_UNKNOWN_VARIABLE` | the query uses a variable it never bound |
| 4 | `ACMEDB_ERROR_TYPE_MISMATCH` | an operator or function got a value of the wrong type |
| 5 | `ACMEDB_ERROR_INVALID_EXPRESSION` | an expression is not allowed where it is |
| 6 | `ACMEDB_ERROR_NODE_STILL_CONNECTED` | `DELETE` of a node that still has relationships |
| 7 | `ACMEDB_ERROR_STORAGE` | the storage failed |
| 8 | `ACMEDB_ERROR_PARAMETER_MISSING` | a `$parameter` was not given |
| 9 | `ACMEDB_ERROR_ARITHMETIC` | integer overflow or division by zero |
| 10 | `ACMEDB_ERROR_CONSTRAINT_VIOLATION` | a write would break a uniqueness constraint |
| 11 | `ACMEDB_ERROR_EXTERNAL_RESOURCE` | `LOAD CSV` could not read its file |

Code 3 is reserved: it was once "missing property", and a missing property now reads as `null`.

## Queries

```c
acmedb_result *acmedb_query(acmedb_context *context, const char *query, size_t query_len);
acmedb_result *acmedb_query_with_parameters(acmedb_context *context, const char *query, size_t query_len,
                                            const char *parameters_json, size_t parameters_len);
void acmedb_result_free(acmedb_result *result);
```

A query runs one openCypher statement (see the [reference](cypher)) as one transaction, and returns
its result, or `NULL` if it fails. The result owns all of its values; it stays valid until
`acmedb_result_free`, whatever happens to the database meanwhile.

**Parameters** are a JSON object, one entry per `$name`:

```json
{"badge": 102, "zones": ["A", "B"], "limits": {"max": 4}, "at": {"~datetime": "2025-03-10T09:00+01:00[Europe/Madrid]"}}
```

JSON numbers without a fraction or exponent are integers; the rest are floats. Temporal values are
tagged objects, the same as in [JSON results](#results-as-json).

**Prepared statements.** `acmedb_query` keeps what it prepares (parse, checks, plan) for the 64
query texts used most recently, so a text run again with other parameters skips that work. To keep
one regardless, prepare it:

```c
acmedb_statement *acmedb_prepare(acmedb_context *context, const char *query, size_t query_len);
acmedb_result *acmedb_statement_query(acmedb_context *context, acmedb_statement *statement,
                                      const char *parameters_json, size_t parameters_len);
void acmedb_statement_free(acmedb_statement *statement);
size_t acmedb_statement_column_count(const acmedb_statement *statement);
const char *acmedb_statement_column_name(const acmedb_statement *statement, size_t column, size_t *out_len);
size_t acmedb_statement_parameter_count(const acmedb_statement *statement);
const char *acmedb_statement_parameter_name(const acmedb_statement *statement, size_t parameter, size_t *out_len);
```

`acmedb_prepare` returns `NULL` when the query does not parse or check (the error is the
context's). `acmedb_statement_query` runs it as `acmedb_query_with_parameters` would
(`parameters_json` may be `NULL`); a statement is planned again when the label or relationship-type
counts it was planned on change at least twofold (and by 100 or more). A statement belongs to the
context it was prepared with: free it before closing that context, and use it from one thread at a
time, as the context.

**Plans.** `EXPLAIN query` and `PROFILE query` are queries too: their result is the plan, one row
per operator, with the columns `depth`, `operator`, `details`, `estimated_rows`, `rows` and
`time_ms` (see [EXPLAIN and PROFILE](cypher.md#explain-and-profile)). `PROFILE` runs the query and
commits its writes; its own rows are not returned.

## Reading a result

### Cell by cell

```c
size_t acmedb_result_row_count(const acmedb_result *result);
size_t acmedb_result_column_count(const acmedb_result *result);
int acmedb_result_type(const acmedb_result *result, size_t row, size_t col);
int64_t acmedb_result_int(const acmedb_result *result, size_t row, size_t col);
double acmedb_result_float(const acmedb_result *result, size_t row, size_t col);
bool acmedb_result_bool(const acmedb_result *result, size_t row, size_t col);
const char *acmedb_result_string(const acmedb_result *result, size_t row, size_t col, size_t *out_len);
```

`acmedb_result_type` gives a cell's type, or -1 for a row or column out of range. Each reader
returns the cell's value when the cell has that type, and `0`, `false` or the empty string when it
has another. Unlike `acmedb_result_type`, the readers do not check the range: call them only with a
row and column inside the result.

| Type | Constant | Read with |
| --- | --- | --- |
| 0 | `ACMEDB_TYPE_INT64` | `acmedb_result_int` |
| 1 | `ACMEDB_TYPE_STRING` | `acmedb_result_string` |
| 2 | `ACMEDB_TYPE_BOOLEAN` | `acmedb_result_bool` |
| 3 | `ACMEDB_TYPE_NULL` | (no value) |
| 4 | `ACMEDB_TYPE_LIST` | the list readers below, or JSON |
| 5 | `ACMEDB_TYPE_NODE` | JSON |
| 6 | `ACMEDB_TYPE_RELATIONSHIP` | JSON |
| 7 | `ACMEDB_TYPE_MAP` | JSON |
| 8 | `ACMEDB_TYPE_PATH` | JSON |
| 9 | `ACMEDB_TYPE_FLOAT64` | `acmedb_result_float` |
| 10–15 | `ACMEDB_TYPE_DATE`, `_LOCAL_TIME`, `_TIME`, `_LOCAL_DATE_TIME`, `_DATE_TIME`, `_DURATION` | JSON |

The list readers read the elements of a list cell whose elements are integers, floats, booleans
or strings:

```c
size_t acmedb_result_list_length(const acmedb_result *result, size_t row, size_t col);
int acmedb_result_list_item_type(const acmedb_result *result, size_t row, size_t col, size_t index);
int64_t acmedb_result_list_item_int(const acmedb_result *result, size_t row, size_t col, size_t index);
double acmedb_result_list_item_float(const acmedb_result *result, size_t row, size_t col, size_t index);
bool acmedb_result_list_item_bool(const acmedb_result *result, size_t row, size_t col, size_t index);
const char *acmedb_result_list_item_string(const acmedb_result *result, size_t row, size_t col, size_t index,
                                           size_t *out_len);
```

### Results as JSON

```c
const char *acmedb_result_to_json(const acmedb_result *result, size_t *out_len);
```

This function returns the whole result as one JSON array of rows, each row an array of values. It
reads any value, and it is the fastest way to read a large result. The text belongs to the result.

```c
#include <acmedb.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    acmedb_context *db = acmedb_open(argv[1], strlen(argv[1]));
    const char *query = "CREATE (d:Door {name: 'Cleanroom', floors: [2, 3]}) RETURN d, $at + duration('PT30M'), 1.0";
    const char *parameters = "{\"at\": {\"~datetime\": \"2025-03-10T09:00+01:00[Europe/Madrid]\"}}";
    acmedb_result *result = acmedb_query_with_parameters(db, query, strlen(query), parameters, strlen(parameters));
    size_t length;
    const char *json = acmedb_result_to_json(result, &length);
    printf("%.*s\n", (int)length, json);
    acmedb_result_free(result);
    acmedb_close(db);
    return 0;
}
```

```text
[[{"~node":{"id":0,"labels":["Door"],"properties":{"floors":[2,3],"name":"Cleanroom"}}},{"~datetime":"2025-03-10T09:30+01:00[Europe/Madrid]"},1.0]]
```

Values that JSON has no form for are tagged objects, with a key that starts with `~`:

| Value | JSON |
| --- | --- |
| node | `{"~node": {"id": 0, "labels": [...], "properties": {...}}}` |
| relationship | `{"~relationship": {"id": 0, "source": 0, "target": 1, "type": "T", "properties": {...}}}` |
| path | `{"~path": {"nodes": [...], "relationships": [...]}}` |
| date, local time, time, local date-time, date-time, duration | `{"~date": "2025-03-10"}`, `{"~localtime": …}`, `{"~time": …}`, `{"~localdatetime": …}`, `{"~datetime": …}`, `{"~duration": "P1DT2H"}`, each with its ISO 8601 text |

- A float always has a `.` or an exponent (`1.0`), and its special values are written `NaN`,
  `Infinity` and `-Infinity`.
- A node or relationship shows its state when the query finished. A node the query deleted keeps
  its id but has no labels or properties.

## Direct writes

```c
uint64_t acmedb_allocate_node_id(acmedb_context *context);
int acmedb_add_node(acmedb_context *context, uint64_t id, const char *label, size_t label_len);
int acmedb_add_edge(acmedb_context *context, uint64_t source, uint64_t target, const char *type, size_t type_len);
int acmedb_set_property_int64(acmedb_context *context, uint64_t id, const char *name, size_t name_len, int64_t value);
int acmedb_set_property_float64(acmedb_context *context, uint64_t id, const char *name, size_t name_len, double value);
int acmedb_set_property_string(acmedb_context *context, uint64_t id, const char *name, size_t name_len,
                               const char *value, size_t value_len);
int acmedb_begin_write(acmedb_context *context);
int acmedb_commit_write(acmedb_context *context);
void acmedb_abort_write(acmedb_context *context);
```

These functions write without parsing a query, for loading data in bulk:

- `acmedb_allocate_node_id` returns a node id never handed out before, or `UINT64_MAX` on failure.
- `acmedb_add_node` creates a node with that id and label if it does not exist, and adds the label
  if it does. An empty label adds none. Ids chosen by the caller are reserved, so
  `acmedb_allocate_node_id` never returns them.
- `acmedb_add_edge` adds a relationship from `source` to `target`; each call adds one, even
  between nodes already joined by a relationship of that type.
- `acmedb_set_property_*` set a node's property.

Each function returns `ACMEDB_OK`, `ACMEDB_STORAGE_ERROR`, `ACMEDB_CONSTRAINT_VIOLATION` when a
uniqueness constraint refuses the write (`acmedb_last_error` says which), `ACMEDB_INVALID_NAME`
when a label, relationship type or property name is empty or contains a 0x00 byte (an empty label
in `acmedb_add_node` means none), or `ACMEDB_NODE_NOT_FOUND` when a node it names does not exist.

On its own, each call is a transaction that waits for the disk. Between `acmedb_begin_write` and
`acmedb_commit_write`, all the calls form one transaction instead, committed at the end with a
single disk write; `acmedb_abort_write` undoes it. Do not run queries while such a transaction is
open.

## Exporting the graph

```c
const char *acmedb_export_json(acmedb_context *context, size_t *out_len);
```

This function returns the whole graph as JSON, read straight from storage, or `NULL` on failure:

```json
{"nodes": [{"id": 0, "labels": ["Door"], "properties": {"name": "Cleanroom"}}],
 "relationships": [{"id": 0, "source": 0, "target": 1, "type": "LEADS_TO", "properties": {}}]}
```

The text belongs to the context, and stays valid until the next export or `acmedb_close`. It is
meant for tests and debugging, since it reads everything.

## Checking the database

```c
const char *acmedb_check(acmedb_context *context, size_t *out_len);
```

This function checks that every index, adjacency key and counter agrees with the stored records
(see [storage](storage.md#checking-integrity)), and returns the report as JSON, or `NULL` on
failure:

```json
{"ok": false, "problem_count": 1, "problems": ["missing key lDoor\\x00..."]}
```

`problems` describes the first 32 problems found. The text belongs to the context, and stays
valid until the next check or `acmedb_close`.

> **Warning.** It is **a diagnostic, not a routine call**. Run it only with a reason: a query that misses
> data it should find or counts that do not add up (a suspected bug in acmedb), to be sure after a
> crash, or to attach its output to a bug report. It reads the whole database and holds memory in
> proportion to it, so on a large database it is slow and heavy; it repairs nothing. A problem it
> reports is a bug in acmedb: please report it with the output.

## Threads and processes

A context is not thread-safe, so serialize the calls on one context. Each process opens the
database itself: reads run in parallel across processes, and writes take turns, one write
transaction at a time. Do not open the same directory twice in one process.
