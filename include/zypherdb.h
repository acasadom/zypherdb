/* ZypherDB — an embedded openCypher graph database. C interface.
 *
 * Strings are (pointer, length) pairs in UTF-8 and need not be NUL-terminated.
 * Handles are opaque: release a context with zypherdb_close and a result with
 * zypherdb_result_free. The functions are defined in src/c_api.zig; the
 * reference is docs/guide/c-api.md.
 */
#ifndef ZYPHERDB_H
#define ZYPHERDB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zypherdb_context zypherdb_context;
typedef struct zypherdb_result zypherdb_result;
typedef struct zypherdb_statement zypherdb_statement;

/* Durability modes for zypherdb_open_with_durability. */
#define ZYPHERDB_DURABILITY_FULL 0     /* each commit is on disk when it returns */
#define ZYPHERDB_DURABILITY_RELAXED 1  /* a power failure can lose the last commit */
#define ZYPHERDB_DURABILITY_DEFERRED 2 /* the OS or zypherdb_sync writes commits */

/* Replication roles for zypherdb_open_replicated. */
#define ZYPHERDB_ROLE_MASTER 0  /* serves replicas at the address */
#define ZYPHERDB_ROLE_REPLICA 1 /* follows the master at the address, refuses writes */

/* Mutator return codes. */
#define ZYPHERDB_OK 0
#define ZYPHERDB_STORAGE_ERROR 1
#define ZYPHERDB_NODE_NOT_FOUND 2
#define ZYPHERDB_CONSTRAINT_VIOLATION 3 /* zypherdb_last_error says which constraint */
#define ZYPHERDB_INVALID_NAME 4         /* an empty name, one over 1024 bytes, or one with a 0x00 byte */
#define ZYPHERDB_TOO_LARGE 5            /* a value over 4 GiB stored, or a node's 65536th label */

/* Error codes reported by zypherdb_error_code. */
#define ZYPHERDB_ERROR_NONE 0
#define ZYPHERDB_ERROR_PARSE 1
#define ZYPHERDB_ERROR_UNKNOWN_VARIABLE 2
#define ZYPHERDB_ERROR_TYPE_MISMATCH 4
#define ZYPHERDB_ERROR_INVALID_EXPRESSION 5
#define ZYPHERDB_ERROR_NODE_STILL_CONNECTED 6
#define ZYPHERDB_ERROR_STORAGE 7
#define ZYPHERDB_ERROR_PARAMETER_MISSING 8
#define ZYPHERDB_ERROR_ARITHMETIC 9
#define ZYPHERDB_ERROR_CONSTRAINT_VIOLATION 10
#define ZYPHERDB_ERROR_EXTERNAL_RESOURCE 11 /* LOAD CSV could not read its file */

/* Cell types reported by zypherdb_result_type and zypherdb_result_list_item_type. */
#define ZYPHERDB_TYPE_INT64 0
#define ZYPHERDB_TYPE_STRING 1
#define ZYPHERDB_TYPE_BOOLEAN 2
#define ZYPHERDB_TYPE_NULL 3
#define ZYPHERDB_TYPE_LIST 4
#define ZYPHERDB_TYPE_NODE 5
#define ZYPHERDB_TYPE_RELATIONSHIP 6
#define ZYPHERDB_TYPE_MAP 7
#define ZYPHERDB_TYPE_PATH 8
#define ZYPHERDB_TYPE_FLOAT64 9
#define ZYPHERDB_TYPE_DATE 10
#define ZYPHERDB_TYPE_LOCAL_TIME 11
#define ZYPHERDB_TYPE_TIME 12
#define ZYPHERDB_TYPE_LOCAL_DATE_TIME 13
#define ZYPHERDB_TYPE_DATE_TIME 14
#define ZYPHERDB_TYPE_DURATION 15

/* Lifecycle. */
zypherdb_context *zypherdb_open(const char *path, size_t path_len);
zypherdb_context *zypherdb_open_with_durability(const char *path, size_t path_len, int durability);
int zypherdb_sync(zypherdb_context *context);
/* Opens with a replication role; the token goes in clear: use a trusted network. A replica's name
 * (NULL: the host's) shows in its master's status. A replica with forward_writes sends the statements
 * that write to its master, each taking at most request_timeout_ms (0: 30 s). NULL on failure. */
zypherdb_context *zypherdb_open_replicated(const char *path, size_t path_len, int durability, int role,
                                           const char *address, size_t address_len, const char *token,
                                           size_t token_len, const char *name, size_t name_len,
                                           bool forward_writes, uint64_t request_timeout_ms);
/* The last change set this database has (master: committed, replica: applied), with or without a role. */
uint64_t zypherdb_last_lsn(zypherdb_context *context);
/* Waits until the master's change set lsn is applied here, at most timeout_ms; whether it is. */
bool zypherdb_wait_for(zypherdb_context *context, uint64_t lsn, uint64_t timeout_ms);
/* How replication goes, as JSON; the buffer belongs to the context. NULL without replication. */
const char *zypherdb_replication_status(zypherdb_context *context, size_t *out_len);
/* The directory LOAD CSV reads from; path_len 0 turns LOAD CSV off (as after opening). */
int zypherdb_set_import_directory(zypherdb_context *context, const char *path, size_t path_len);
void zypherdb_close(zypherdb_context *context);
const char *zypherdb_last_error(zypherdb_context *context, size_t *out_len);
int zypherdb_error_code(zypherdb_context *context);

/* Direct writes. */
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

/* Queries. */
zypherdb_result *zypherdb_query(zypherdb_context *context, const char *query, size_t query_len);
zypherdb_result *zypherdb_query_with_parameters(zypherdb_context *context, const char *query, size_t query_len,
                                            const char *parameters_json, size_t parameters_len);
void zypherdb_result_free(zypherdb_result *result);
/* False for a write forwarded to the master that the replica had not applied in time. */
bool zypherdb_result_visible(const zypherdb_result *result);

/* Prepared statements: a query parsed, checked and planned once, run again
 * and again with new parameters (zypherdb_query keeps the ones it prepares, by
 * text, too). NULL on failure, with the context's error set. Free each one
 * before closing its context. parameters_json may be NULL (no parameters). */
zypherdb_statement *zypherdb_prepare(zypherdb_context *context, const char *query, size_t query_len);
zypherdb_result *zypherdb_statement_query(zypherdb_context *context, zypherdb_statement *statement,
                                      const char *parameters_json, size_t parameters_len);
void zypherdb_statement_free(zypherdb_statement *statement);
size_t zypherdb_statement_column_count(const zypherdb_statement *statement);
const char *zypherdb_statement_column_name(const zypherdb_statement *statement, size_t column, size_t *out_len);
size_t zypherdb_statement_parameter_count(const zypherdb_statement *statement);
const char *zypherdb_statement_parameter_name(const zypherdb_statement *statement, size_t parameter, size_t *out_len);
size_t zypherdb_result_row_count(const zypherdb_result *result);
size_t zypherdb_result_column_count(const zypherdb_result *result);
int zypherdb_result_type(const zypherdb_result *result, size_t row, size_t col);
int64_t zypherdb_result_int(const zypherdb_result *result, size_t row, size_t col);
double zypherdb_result_float(const zypherdb_result *result, size_t row, size_t col);
bool zypherdb_result_bool(const zypherdb_result *result, size_t row, size_t col);
const char *zypherdb_result_string(const zypherdb_result *result, size_t row, size_t col, size_t *out_len);
const char *zypherdb_result_to_json(const zypherdb_result *result, size_t *out_len);

size_t zypherdb_result_list_length(const zypherdb_result *result, size_t row, size_t col);
int zypherdb_result_list_item_type(const zypherdb_result *result, size_t row, size_t col, size_t index);
int64_t zypherdb_result_list_item_int(const zypherdb_result *result, size_t row, size_t col, size_t index);
double zypherdb_result_list_item_float(const zypherdb_result *result, size_t row, size_t col, size_t index);
bool zypherdb_result_list_item_bool(const zypherdb_result *result, size_t row, size_t col, size_t index);
const char *zypherdb_result_list_item_string(const zypherdb_result *result, size_t row, size_t col, size_t index,
                                           size_t *out_len);

/* The whole graph as JSON; the buffer belongs to the context. */
const char *zypherdb_export_json(zypherdb_context *context, size_t *out_len);

/* A diagnostic, not a routine call: checks that every index and counter agrees with the stored
 * records, reading the whole database. JSON {"ok", "problem_count", "problems"}; the buffer
 * belongs to the context. See docs/guide/c-api.md. */
const char *zypherdb_check(zypherdb_context *context, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* ZYPHERDB_H */
