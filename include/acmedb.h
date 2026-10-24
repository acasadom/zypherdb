/* acmedb — an embedded openCypher graph database. C interface.
 *
 * Strings are (pointer, length) pairs in UTF-8 and need not be NUL-terminated.
 * Handles are opaque: release a context with acmedb_close and a result with
 * acmedb_result_free. The functions are defined in src/c_api.zig; the
 * reference is docs/guide/c-api.md.
 */
#ifndef ACMEDB_H
#define ACMEDB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct acmedb_context acmedb_context;
typedef struct acmedb_result acmedb_result;
typedef struct acmedb_statement acmedb_statement;

/* Durability modes for acmedb_open_with_durability. */
#define ACMEDB_DURABILITY_FULL 0     /* each commit is on disk when it returns */
#define ACMEDB_DURABILITY_RELAXED 1  /* a power failure can lose the last commit */
#define ACMEDB_DURABILITY_DEFERRED 2 /* the OS or acmedb_sync writes commits */

/* Mutator return codes. */
#define ACMEDB_OK 0
#define ACMEDB_STORAGE_ERROR 1
#define ACMEDB_NODE_NOT_FOUND 2
#define ACMEDB_CONSTRAINT_VIOLATION 3 /* acmedb_last_error says which constraint */

/* Error codes reported by acmedb_error_code. */
#define ACMEDB_ERROR_NONE 0
#define ACMEDB_ERROR_PARSE 1
#define ACMEDB_ERROR_UNKNOWN_VARIABLE 2
#define ACMEDB_ERROR_TYPE_MISMATCH 4
#define ACMEDB_ERROR_INVALID_EXPRESSION 5
#define ACMEDB_ERROR_NODE_STILL_CONNECTED 6
#define ACMEDB_ERROR_STORAGE 7
#define ACMEDB_ERROR_PARAMETER_MISSING 8
#define ACMEDB_ERROR_ARITHMETIC 9
#define ACMEDB_ERROR_CONSTRAINT_VIOLATION 10
#define ACMEDB_ERROR_EXTERNAL_RESOURCE 11 /* LOAD CSV could not read its file */

/* Cell types reported by acmedb_result_type and acmedb_result_list_item_type. */
#define ACMEDB_TYPE_INT64 0
#define ACMEDB_TYPE_STRING 1
#define ACMEDB_TYPE_BOOLEAN 2
#define ACMEDB_TYPE_NULL 3
#define ACMEDB_TYPE_LIST 4
#define ACMEDB_TYPE_NODE 5
#define ACMEDB_TYPE_RELATIONSHIP 6
#define ACMEDB_TYPE_MAP 7
#define ACMEDB_TYPE_PATH 8
#define ACMEDB_TYPE_FLOAT64 9
#define ACMEDB_TYPE_DATE 10
#define ACMEDB_TYPE_LOCAL_TIME 11
#define ACMEDB_TYPE_TIME 12
#define ACMEDB_TYPE_LOCAL_DATE_TIME 13
#define ACMEDB_TYPE_DATE_TIME 14
#define ACMEDB_TYPE_DURATION 15

/* Lifecycle. */
acmedb_context *acmedb_open(const char *path, size_t path_len);
acmedb_context *acmedb_open_with_durability(const char *path, size_t path_len, int durability);
int acmedb_sync(acmedb_context *context);
/* The directory LOAD CSV reads from; path_len 0 turns LOAD CSV off (as after opening). */
int acmedb_set_import_directory(acmedb_context *context, const char *path, size_t path_len);
void acmedb_close(acmedb_context *context);
const char *acmedb_last_error(acmedb_context *context, size_t *out_len);
int acmedb_error_code(acmedb_context *context);

/* Direct writes. */
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

/* Queries. */
acmedb_result *acmedb_query(acmedb_context *context, const char *query, size_t query_len);
acmedb_result *acmedb_query_with_parameters(acmedb_context *context, const char *query, size_t query_len,
                                            const char *parameters_json, size_t parameters_len);
void acmedb_result_free(acmedb_result *result);

/* Prepared statements: a query parsed, checked and planned once, run again
 * and again with new parameters (acmedb_query keeps the ones it prepares, by
 * text, too). NULL on failure, with the context's error set. Free each one
 * before closing its context. parameters_json may be NULL (no parameters). */
acmedb_statement *acmedb_prepare(acmedb_context *context, const char *query, size_t query_len);
acmedb_result *acmedb_statement_query(acmedb_context *context, acmedb_statement *statement,
                                      const char *parameters_json, size_t parameters_len);
void acmedb_statement_free(acmedb_statement *statement);
size_t acmedb_statement_column_count(const acmedb_statement *statement);
const char *acmedb_statement_column_name(const acmedb_statement *statement, size_t column, size_t *out_len);
size_t acmedb_statement_parameter_count(const acmedb_statement *statement);
const char *acmedb_statement_parameter_name(const acmedb_statement *statement, size_t parameter, size_t *out_len);
size_t acmedb_result_row_count(const acmedb_result *result);
size_t acmedb_result_column_count(const acmedb_result *result);
int acmedb_result_type(const acmedb_result *result, size_t row, size_t col);
int64_t acmedb_result_int(const acmedb_result *result, size_t row, size_t col);
double acmedb_result_float(const acmedb_result *result, size_t row, size_t col);
bool acmedb_result_bool(const acmedb_result *result, size_t row, size_t col);
const char *acmedb_result_string(const acmedb_result *result, size_t row, size_t col, size_t *out_len);
const char *acmedb_result_to_json(const acmedb_result *result, size_t *out_len);

size_t acmedb_result_list_length(const acmedb_result *result, size_t row, size_t col);
int acmedb_result_list_item_type(const acmedb_result *result, size_t row, size_t col, size_t index);
int64_t acmedb_result_list_item_int(const acmedb_result *result, size_t row, size_t col, size_t index);
double acmedb_result_list_item_float(const acmedb_result *result, size_t row, size_t col, size_t index);
bool acmedb_result_list_item_bool(const acmedb_result *result, size_t row, size_t col, size_t index);
const char *acmedb_result_list_item_string(const acmedb_result *result, size_t row, size_t col, size_t index,
                                           size_t *out_len);

/* The whole graph as JSON; the buffer belongs to the context. */
const char *acmedb_export_json(acmedb_context *context, size_t *out_len);

/* A diagnostic, not a routine call: checks that every index and counter agrees with the stored
 * records, reading the whole database. JSON {"ok", "problem_count", "problems"}; the buffer
 * belongs to the context. See docs/guide/c-api.md. */
const char *acmedb_check(acmedb_context *context, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif /* ACMEDB_H */
