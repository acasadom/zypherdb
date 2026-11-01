# C reference

The engine is a C library: `zig build` produces `zig-out/lib/libzypherdb.a` (static),
`libzypherdb.dylib` or `libzypherdb.so` (shared), and the header `zig-out/include/zypherdb.h`. C, C++ and
any language with a C foreign-function interface can embed ZypherDB through it. Python does not need
it, since the [Python package](python) has its own native module.

- Strings are passed as `(pointer, length)` pairs in UTF-8; they do not need a terminating NUL.
- A context (`zypherdb_context *`) and a result (`zypherdb_result *`) are opaque handles. Release them
  with `zypherdb_close` and `zypherdb_result_free`.

## A first program

```c
#include <zypherdb.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "helix-db";
    zypherdb_context *db = zypherdb_open(path, strlen(path));
    if (db == NULL) return 1;

    const char *create = "CREATE (:Person {name: 'Ana', badge: 101}), (:Person {name: 'Luis', badge: 102})";
    zypherdb_result *created = zypherdb_query(db, create, strlen(create));
    zypherdb_result_free(created);

    const char *find = "MATCH (p:Person) WHERE p.badge = $badge RETURN p.name, p.badge";
    const char *parameters = "{\"badge\": 102}";
    zypherdb_result *found = zypherdb_query_with_parameters(db, find, strlen(find), parameters, strlen(parameters));
    for (size_t row = 0; row < zypherdb_result_row_count(found); row++) {
        size_t length;
        const char *name = zypherdb_result_string(found, row, 0, &length);
        printf("%.*s has badge %lld\n", (int)length, name, (long long)zypherdb_result_int(found, row, 1));
    }
    zypherdb_result_free(found);

    const char *bad = "MATCH (p:Person) RETURN q";
    if (zypherdb_query(db, bad, strlen(bad)) == NULL) {
        size_t length;
        const char *message = zypherdb_last_error(db, &length);
        printf("error %d: %.*s\n", zypherdb_error_code(db), (int)length, message);
    }

    zypherdb_close(db);
    return 0;
}
```

```text
Luis has badge 102
error 2: unknown variable 'q'
```

Build it against the library (any C compiler works; `zig cc` is one):

```bash
zig cc -Izig-out/include first.c -Lzig-out/lib -lzypherdb -o first
```

## Opening and closing

```c
zypherdb_context *zypherdb_open(const char *path, size_t path_len);
zypherdb_context *zypherdb_open_with_durability(const char *path, size_t path_len, int durability);
int zypherdb_sync(zypherdb_context *context);
int zypherdb_set_import_directory(zypherdb_context *context, const char *path, size_t path_len);
void zypherdb_close(zypherdb_context *context);
```

`zypherdb_open` opens the database in directory `path`, creating the database if it does not exist;
the directory itself must exist. It returns `NULL` on failure. `zypherdb_open` uses full durability,
and `zypherdb_open_with_durability` chooses the mode:

| Mode | A commit returns when… | A power failure can lose… |
| --- | --- | --- |
| `ZYPHERDB_DURABILITY_FULL` (0) | its data is on disk | nothing |
| `ZYPHERDB_DURABILITY_RELAXED` (1) | its data is on disk; its bookkeeping follows with the next commit | the last commit |
| `ZYPHERDB_DURABILITY_DEFERRED` (2) | it is in memory; the operating system writes it, or `zypherdb_sync` | the commits since the last `zypherdb_sync` |

`zypherdb_set_import_directory` sets the directory `LOAD CSV` reads from (`path_len` 0: none, which
turns `LOAD CSV` off, as it is after opening): a query's `file:///name.csv` is `name.csv` in it,
and nothing outside it can be read.

No mode can corrupt the database. `zypherdb_sync` writes every commit so far to disk and returns
`ZYPHERDB_OK` or `ZYPHERDB_STORAGE_ERROR`.

## Errors

```c
const char *zypherdb_last_error(zypherdb_context *context, size_t *out_len);
int zypherdb_error_code(zypherdb_context *context);
```

When a query fails, these two functions describe the failure: the message, and its category. The
message stays valid until the next call on the context.

| Code | Constant | Meaning |
| --- | --- | --- |
| 0 | `ZYPHERDB_ERROR_NONE` | no error |
| 1 | `ZYPHERDB_ERROR_PARSE` | the query is not valid Cypher |
| 2 | `ZYPHERDB_ERROR_UNKNOWN_VARIABLE` | the query uses a variable it never bound |
| 4 | `ZYPHERDB_ERROR_TYPE_MISMATCH` | an operator or function got a value of the wrong type |
| 5 | `ZYPHERDB_ERROR_INVALID_EXPRESSION` | an expression is not allowed where it is |
| 6 | `ZYPHERDB_ERROR_NODE_STILL_CONNECTED` | `DELETE` of a node that still has relationships |
| 7 | `ZYPHERDB_ERROR_STORAGE` | the storage failed |
| 8 | `ZYPHERDB_ERROR_PARAMETER_MISSING` | a `$parameter` was not given |
| 9 | `ZYPHERDB_ERROR_ARITHMETIC` | integer overflow or division by zero |
| 10 | `ZYPHERDB_ERROR_CONSTRAINT_VIOLATION` | a write would break a uniqueness constraint |
| 11 | `ZYPHERDB_ERROR_EXTERNAL_RESOURCE` | `LOAD CSV` could not read its file |

Code 3 is reserved: it was once "missing property", and a missing property now reads as `null`.

## Queries

```c
zypherdb_result *zypherdb_query(zypherdb_context *context, const char *query, size_t query_len);
zypherdb_result *zypherdb_query_with_parameters(zypherdb_context *context, const char *query, size_t query_len,
                                            const char *parameters_json, size_t parameters_len);
void zypherdb_result_free(zypherdb_result *result);
```

A query runs one openCypher statement (see the [reference](cypher)) as one transaction, and returns
its result, or `NULL` if it fails. The result owns all of its values; it stays valid until
`zypherdb_result_free`, whatever happens to the database meanwhile.

**Parameters** are a JSON object, one entry per `$name`:

```json
{"badge": 102, "zones": ["A", "B"], "limits": {"max": 4}, "at": {"~datetime": "2025-03-10T09:00+01:00[Europe/Madrid]"}}
```

JSON numbers without a fraction or exponent are integers; the rest are floats. Temporal values are
tagged objects, the same as in [JSON results](#results-as-json).

**Prepared statements.** `zypherdb_query` keeps what it prepares (parse, checks, plan) for the 64
query texts used most recently, so a text run again with other parameters skips that work. To keep
one regardless, prepare it:

```c
zypherdb_statement *zypherdb_prepare(zypherdb_context *context, const char *query, size_t query_len);
zypherdb_result *zypherdb_statement_query(zypherdb_context *context, zypherdb_statement *statement,
                                      const char *parameters_json, size_t parameters_len);
void zypherdb_statement_free(zypherdb_statement *statement);
size_t zypherdb_statement_column_count(const zypherdb_statement *statement);
const char *zypherdb_statement_column_name(const zypherdb_statement *statement, size_t column, size_t *out_len);
size_t zypherdb_statement_parameter_count(const zypherdb_statement *statement);
const char *zypherdb_statement_parameter_name(const zypherdb_statement *statement, size_t parameter, size_t *out_len);
```

`zypherdb_prepare` returns `NULL` when the query does not parse or check (the error is the
context's). `zypherdb_statement_query` runs it as `zypherdb_query_with_parameters` would
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
size_t zypherdb_result_row_count(const zypherdb_result *result);
size_t zypherdb_result_column_count(const zypherdb_result *result);
int zypherdb_result_type(const zypherdb_result *result, size_t row, size_t col);
int64_t zypherdb_result_int(const zypherdb_result *result, size_t row, size_t col);
double zypherdb_result_float(const zypherdb_result *result, size_t row, size_t col);
bool zypherdb_result_bool(const zypherdb_result *result, size_t row, size_t col);
const char *zypherdb_result_string(const zypherdb_result *result, size_t row, size_t col, size_t *out_len);
```

`zypherdb_result_type` gives a cell's type, or -1 for a row or column out of range. Each reader
returns the cell's value when the cell has that type, and `0`, `false` or the empty string when it
has another. Unlike `zypherdb_result_type`, the readers do not check the range: call them only with a
row and column inside the result.

| Type | Constant | Read with |
| --- | --- | --- |
| 0 | `ZYPHERDB_TYPE_INT64` | `zypherdb_result_int` |
| 1 | `ZYPHERDB_TYPE_STRING` | `zypherdb_result_string` |
| 2 | `ZYPHERDB_TYPE_BOOLEAN` | `zypherdb_result_bool` |
| 3 | `ZYPHERDB_TYPE_NULL` | (no value) |
| 4 | `ZYPHERDB_TYPE_LIST` | the list readers below, or JSON |
| 5 | `ZYPHERDB_TYPE_NODE` | JSON |
| 6 | `ZYPHERDB_TYPE_RELATIONSHIP` | JSON |
| 7 | `ZYPHERDB_TYPE_MAP` | JSON |
| 8 | `ZYPHERDB_TYPE_PATH` | JSON |
| 9 | `ZYPHERDB_TYPE_FLOAT64` | `zypherdb_result_float` |
| 10–15 | `ZYPHERDB_TYPE_DATE`, `_LOCAL_TIME`, `_TIME`, `_LOCAL_DATE_TIME`, `_DATE_TIME`, `_DURATION` | JSON |

The list readers read the elements of a list cell whose elements are integers, floats, booleans
or strings:

```c
size_t zypherdb_result_list_length(const zypherdb_result *result, size_t row, size_t col);
int zypherdb_result_list_item_type(const zypherdb_result *result, size_t row, size_t col, size_t index);
int64_t zypherdb_result_list_item_int(const zypherdb_result *result, size_t row, size_t col, size_t index);
double zypherdb_result_list_item_float(const zypherdb_result *result, size_t row, size_t col, size_t index);
bool zypherdb_result_list_item_bool(const zypherdb_result *result, size_t row, size_t col, size_t index);
const char *zypherdb_result_list_item_string(const zypherdb_result *result, size_t row, size_t col, size_t index,
                                           size_t *out_len);
```

### Results as JSON

```c
const char *zypherdb_result_to_json(const zypherdb_result *result, size_t *out_len);
```

This function returns the whole result as one JSON array of rows, each row an array of values. It
reads any value, and it is the fastest way to read a large result. The text belongs to the result.

```c
#include <zypherdb.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    zypherdb_context *db = zypherdb_open(argv[1], strlen(argv[1]));
    const char *query = "CREATE (d:Door {name: 'Cleanroom', floors: [2, 3]}) RETURN d, $at + duration('PT30M'), 1.0";
    const char *parameters = "{\"at\": {\"~datetime\": \"2025-03-10T09:00+01:00[Europe/Madrid]\"}}";
    zypherdb_result *result = zypherdb_query_with_parameters(db, query, strlen(query), parameters, strlen(parameters));
    size_t length;
    const char *json = zypherdb_result_to_json(result, &length);
    printf("%.*s\n", (int)length, json);
    zypherdb_result_free(result);
    zypherdb_close(db);
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
uint64_t zypherdb_allocate_node_id(zypherdb_context *context);
int zypherdb_add_node(zypherdb_context *context, uint64_t id, const char *label, size_t label_len);
int zypherdb_add_edge(zypherdb_context *context, uint64_t source, uint64_t target, const char *type, size_t type_len);
int zypherdb_set_property_int64(zypherdb_context *context, uint64_t id, const char *name, size_t name_len, int64_t value);
int zypherdb_set_property_float64(zypherdb_context *context, uint64_t id, const char *name, size_t name_len, double value);
int zypherdb_set_property_string(zypherdb_context *context, uint64_t id, const char *name, size_t name_len,
                               const char *value, size_t value_len);
int zypherdb_begin_write(zypherdb_context *context);
int zypherdb_commit_write(zypherdb_context *context);
void zypherdb_abort_write(zypherdb_context *context);
```

These functions write without parsing a query, for loading data in bulk:

- `zypherdb_allocate_node_id` returns a node id never handed out before, or `UINT64_MAX` on failure.
- `zypherdb_add_node` creates a node with that id and label if it does not exist, and adds the label
  if it does. An empty label adds none. Ids chosen by the caller are reserved, so
  `zypherdb_allocate_node_id` never returns them.
- `zypherdb_add_edge` adds a relationship from `source` to `target`; each call adds one, even
  between nodes already joined by a relationship of that type.
- `zypherdb_set_property_*` set a node's property.

Each function returns `ZYPHERDB_OK`, `ZYPHERDB_STORAGE_ERROR`, `ZYPHERDB_CONSTRAINT_VIOLATION` when a
uniqueness constraint refuses the write (`zypherdb_last_error` says which), `ZYPHERDB_INVALID_NAME`
when a label, relationship type or property name is empty, longer than 1024 bytes or contains a 0x00
byte (an empty label in `zypherdb_add_node` means none), `ZYPHERDB_TOO_LARGE` when a value is over
4 GiB stored or a node would have more than 65535 labels, or `ZYPHERDB_NODE_NOT_FOUND` when a node it
names does not exist.

On its own, each call is a transaction that waits for the disk. Between `zypherdb_begin_write` and
`zypherdb_commit_write`, all the calls form one transaction instead, committed at the end with a
single disk write; `zypherdb_abort_write` undoes it. Do not run queries while such a transaction is
open.

## Exporting the graph

```c
const char *zypherdb_export_json(zypherdb_context *context, size_t *out_len);
```

This function returns the whole graph as JSON, read straight from storage, or `NULL` on failure:

```json
{"nodes": [{"id": 0, "labels": ["Door"], "properties": {"name": "Cleanroom"}}],
 "relationships": [{"id": 0, "source": 0, "target": 1, "type": "LEADS_TO", "properties": {}}]}
```

The text belongs to the context, and stays valid until the next export or `zypherdb_close`. It is
meant for tests and debugging, since it reads everything.

## Checking the database

```c
const char *zypherdb_check(zypherdb_context *context, size_t *out_len);
```

This function checks that every index, adjacency key and counter agrees with the stored records
(see [storage](storage.md#checking-integrity)), and returns the report as JSON, or `NULL` on
failure:

```json
{"ok": false, "problem_count": 1, "problems": ["missing key lDoor\\x00..."]}
```

`problems` describes the first 32 problems found. The text belongs to the context, and stays
valid until the next check or `zypherdb_close`.

> **Warning.** It is **a diagnostic, not a routine call**. Run it only with a reason: a query that misses
> data it should find or counts that do not add up (a suspected bug in ZypherDB), to be sure after a
> crash, or to attach its output to a bug report. It reads the whole database and holds memory in
> proportion to it, so on a large database it is slow and heavy; it repairs nothing. A problem it
> reports is a bug in ZypherDB: please report it with the output.

## Replication

```c
zypherdb_context *zypherdb_open_replicated(const char *path, size_t path_len, int durability, int role,
                                           const char *address, size_t address_len, const char *token,
                                           size_t token_len, const char *name, size_t name_len,
                                           bool forward_writes, uint64_t request_timeout_ms);
bool zypherdb_result_visible(const zypherdb_result *result);
uint64_t zypherdb_last_lsn(zypherdb_context *context);
bool zypherdb_wait_for(zypherdb_context *context, uint64_t lsn, uint64_t timeout_ms);
const char *zypherdb_replication_status(zypherdb_context *context, size_t *out_len);
```

`zypherdb_open_replicated` opens the database with a replication role (see
[replication](replication.md)): `ZYPHERDB_ROLE_MASTER` (0) serves replicas at `address`
(`"host:port"`), and `ZYPHERDB_ROLE_REPLICA` (1) follows the master at `address` and refuses
writes. `token` is the secret a replica sends. `name` (at most 255 bytes) is what a replica calls
itself in its master's status; `NULL` takes the name of its host, and a master ignores it. A
replica opened with `forward_writes` sends the statements that write to its master instead of
refusing them, each taking at most `request_timeout_ms` (0: 30 s); `zypherdb_result_visible` is
false for a forwarded write the replica had not applied in that time. The
context keeps its own copy of `address`, `token` and `name`. It returns `NULL` when the database cannot be opened or replication cannot start (the
address is taken, a database that was a master is opened as a replica, or the name is too long). While another process
runs replication on the database the context stands by (`"standby": true` in its status) and
takes over when that process closes it or dies. Closing the context
stops replication.

> **Warning.** Replication is not encrypted: the token and the data travel in clear. Run it only
> on a trusted network.

`zypherdb_last_lsn` is the number of the last change the database has: on a master the last
committed, on a replica the last applied, also in a context opened without a role; 0 on a
database that is neither. `zypherdb_wait_for` waits until the master's change `lsn` is applied, at
most `timeout_ms`, and returns whether it is: to read on a replica a write made on the master, pass
it the master's `zypherdb_last_lsn` after the write. It works in a context opened without a role
too, and returns `true` at once on a database that is no replica.

`zypherdb_replication_status` returns how replication goes as JSON, or `NULL` without replication.
A master's:

```json
{"role": "master", "standby": false, "address": "0.0.0.0:7000", "last_lsn": 120,
 "replicas": [{"name": "eu-1", "address": "10.0.0.7:51234", "connected_ms": 86400000,
               "phase": "streaming", "acked_lsn": 118, "lag": 2}]}
```

A replica's (`phase` is `"connecting"`, `"copying"`, `"streaming"` or `"halted"`;
`last_contact_ms` is how long ago the master was last heard from, `null` if never; `halted` and
`last_refusal` are a reason's name, such as `"token"`, or `null`):

```json
{"role": "replica", "standby": false, "name": "eu-1", "master_address": "10.0.0.5:7000",
 "phase": "streaming", "last_contact_ms": 120, "applied_lsn": 118, "master_lsn": 120, "lag": 2,
 "last_refusal": null, "halted": null}
```

The text belongs to the context, and stays valid until the next status or `zypherdb_close`.

## Threads and processes

A context is not thread-safe, so serialize the calls on one context. Each process opens the
database itself: reads run in parallel across processes, and writes take turns, one write
transaction at a time. Do not open the same directory twice in one process.

## Why this way — and the alternatives

- **A C ABI, not a C++ or Rust API.** Every language can call C, and a C ABI does not change with
  the compiler that built the library. The header is written by hand, so it says exactly what is
  promised.
- **Strings as pointer and length.** Callers in most languages hold strings with a length and no
  terminating NUL; requiring one would mean a copy per call, and a NUL inside a string could not be
  passed at all.
- **A result that owns its values.** A result is copied out of the database before the transaction
  ends, so it stays valid whatever the database does next, and the caller never holds a pointer
  into storage. The price is the copy; the gain is that no misuse of a result can corrupt or block
  the database.
- **JSON for structured values**, not a C struct per type. Nodes, maps, paths and temporals would
  need many structs and functions to walk them; JSON is one function and every language reads it.
  The common scalar types still have direct readers, which avoid the JSON round trip.
- **Status codes and a context's last error**, not callbacks or `errno`: every function says
  whether it failed in its return value, and the message is there to read, in the context, until
  the next call.
