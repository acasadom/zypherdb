/* The access-control benchmark, natively, through each engine's C API.
 *
 *   cc -O2 bench.c -lzypherdb   -o bench-zypherdb            (zypherdb)
 *   cc -O2 -DLATTICE bench.c -llattice -o bench-lattice  (LatticeDB)
 *
 *   ./bench-X DIR PEOPLE RUNS [OPTION]
 *     zypherdb:    OPTION = full | relaxed | deferred   (durability, default full)
 *     LatticeDB: OPTION = cache                       (adjacency cache on)
 *
 * The same graph (same generator, same seed) and the same queries for both.
 * Parameters are drawn per query from their own seed, so both engines see the
 * same ones. Every cell of every result is read and folded into a checksum,
 * printed for the first runs, to compare the engines' answers.
 *
 * LatticeDB prepares each query once and reuses it (its best case); ZypherDB
 * parses each query every time and takes parameters as JSON (its only C path).
 */
#define _POSIX_C_SOURCE 200809L
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef LATTICE
#include "lattice.h"
#else
#include "zypherdb.h"
#endif

/* --- Generator ------------------------------------------------------------ */

static uint64_t rng_state;
static uint64_t next_random(void) {
    uint64_t z = (rng_state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static uint64_t below(uint64_t n) { return next_random() % n; }

static const char *departments[] = {"engineering", "sales", "support", "finance", "legal", "operations", "research", "security"};

typedef struct { uint32_t a, b; } Pair;
typedef struct {
    uint32_t people, groups, zones, doors;
    Pair *memberships; size_t membership_count;
    Pair *grants; size_t grant_count;
} Graph;

static Graph make_graph(uint32_t people) {
    Graph g = {people, people / 100 > 10 ? people / 100 : 10, people / 500 > 2 ? people / 500 : 2, people / 10 > 2 ? people / 10 : 2};
    rng_state = 7;
    g.memberships = malloc(sizeof(Pair) * people * 3);
    for (uint32_t i = 0; i < people; i++) {
        uint32_t count = 1 + (uint32_t)below(3), chosen[3]; uint32_t n = 0;
        for (uint32_t m = 0; m < count; m++) {
            uint32_t group = (uint32_t)((below(g.groups) + m * 7) % g.groups);
            bool seen = false;
            for (uint32_t k = 0; k < n; k++) seen |= chosen[k] == group;
            if (!seen) { chosen[n++] = group; g.memberships[g.membership_count++] = (Pair){i, group}; }
        }
    }
    g.grants = malloc(sizeof(Pair) * g.groups * 2);
    for (uint32_t i = 0; i < g.groups; i++) {
        uint32_t z0 = (i * 3) % g.zones, z1 = (i * 3 + 11) % g.zones;
        g.grants[g.grant_count++] = (Pair){i, z0};
        if (z1 != z0) g.grants[g.grant_count++] = (Pair){i, z1};
    }
    return g;
}

static double seconds_now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* --- Queries -------------------------------------------------------------- */

enum { P_CARD = 1, P_PERSON = 2, P_DOOR = 4 };
typedef struct { const char *name, *text; int parameters; bool heavy; } Query;

static const Query queries[] = {
    {"card lookup", "MATCH (c:Card {number: $card}) RETURN c.number", P_CARD, false},
    {"person's groups (1 hop)", "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g) RETURN g.name", P_PERSON, false},
    {"colleagues (2 hops, distinct)", "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g)<-[:MEMBER_OF]-(q) RETURN count(DISTINCT q)", P_PERSON, false},
    {"may this card open this door?",
     "MATCH (c:Card {number: $card})-[:HELD_BY]->(p)-[:MEMBER_OF*1..3]->(g)-[w:MAY_ENTER]->(z)<-[:LOCATED_IN]-(d:Door {id: $door}) "
     "WHERE 3 IN w.days AND w.from <= 10 AND 10 < w.until RETURN count(z)", P_CARD | P_DOOR, false},
    {"doors of a person's zones",
     "MATCH (p:Person {id: $person})-[:MEMBER_OF*1..3]->(x)-[:MAY_ENTER]->(z)<-[:LOCATED_IN]-(d) RETURN count(DISTINCT d)", P_PERSON, false},
    {"people over 60 (scan + filter)", "MATCH (p:Person) WHERE p.age > 60 RETURN count(p)", 0, true},
    {"oldest 10 (ORDER BY + LIMIT)", "MATCH (p:Person) RETURN p.name ORDER BY p.age DESC, p.id LIMIT 10", 0, true},
    {"group sizes (aggregate)", "MATCH (p:Person)-[:MEMBER_OF]->(g:Group) RETURN g.name, count(p) AS n ORDER BY n DESC, g.name LIMIT 10", 0, true},
    {"department counts", "MATCH (p:Person) RETURN p.department, count(p) ORDER BY p.department", 0, true},
    {"return all people (3 columns)", "MATCH (p:Person) RETURN p.id, p.name, p.age", 0, true},
    {"create one node (commit)", "CREATE (:Event {card: $card})", P_CARD, false},
    {"create 1000 nodes (UNWIND)", "UNWIND range(1, 1000) AS i CREATE (:Event {n: i})", 0, true},
};

typedef struct { int64_t card, person, door; } Parameters;

static uint64_t fold(uint64_t sum, uint64_t x) { return (sum ^ x) * 0x100000001B3ull; }

/* --- Engines -------------------------------------------------------------- */

#ifdef LATTICE

static lattice_database *db;

static void check(lattice_error code, const char *what) {
    if (code != LATTICE_OK) { fprintf(stderr, "%s failed: %d\n", what, code); exit(1); }
}

static void open_engine(const char *dir, const char *option) {
    char path[1024]; snprintf(path, sizeof path, "%s/bench.db", dir);
    lattice_open_options_v4 options = LATTICE_OPEN_OPTIONS_V4_DEFAULT;
    options.create = true;
    options.enable_adjacency_cache = option && strcmp(option, "cache") == 0;
    check(lattice_open_v4(path, &options, &db), "open");
}

static lattice_value int_value(int64_t x) { lattice_value v = {.type = LATTICE_VALUE_INT}; v.data.int_val = x; return v; }
static lattice_value string_value(const char *s) {
    lattice_value v = {.type = LATTICE_VALUE_STRING}; v.data.string_val.ptr = s; v.data.string_val.len = strlen(s); return v;
}

static void load(const Graph *g) {
    lattice_txn *txn; check(lattice_begin(db, LATTICE_TXN_READ_WRITE, &txn), "begin");
    lattice_node_id *person = malloc(8 * g->people), *group = malloc(8 * g->groups), *zone = malloc(8 * g->zones);
    char name[32];
    for (uint32_t i = 0; i < g->people; i++) {
        lattice_node_id card; lattice_edge_id edge; lattice_value v;
        check(lattice_node_create(txn, "Person", &person[i]), "node");
        v = int_value(i); lattice_node_set_property(txn, person[i], "id", &v);
        snprintf(name, sizeof name, "person-%u", i); v = string_value(name); lattice_node_set_property(txn, person[i], "name", &v);
        v = int_value(18 + i % 50); lattice_node_set_property(txn, person[i], "age", &v);
        v = string_value(departments[i % 8]); lattice_node_set_property(txn, person[i], "department", &v);
        check(lattice_node_create(txn, "Card", &card), "node");
        v = int_value(1000000 + i); lattice_node_set_property(txn, card, "number", &v);
        check(lattice_edge_create(txn, card, person[i], "HELD_BY", &edge), "edge");
    }
    for (uint32_t i = 0; i < g->groups; i++) {
        lattice_value v;
        check(lattice_node_create(txn, "Group", &group[i]), "node");
        v = int_value(i); lattice_node_set_property(txn, group[i], "id", &v);
        snprintf(name, sizeof name, "group-%u", i); v = string_value(name); lattice_node_set_property(txn, group[i], "name", &v);
    }
    for (uint32_t i = 0; i < g->zones; i++) {
        lattice_value v = int_value(i);
        check(lattice_node_create(txn, "Zone", &zone[i]), "node");
        lattice_node_set_property(txn, zone[i], "id", &v);
    }
    for (uint32_t i = 0; i < g->doors; i++) {
        lattice_node_id door; lattice_edge_id edge; lattice_value v = int_value(i);
        check(lattice_node_create(txn, "Door", &door), "node");
        lattice_node_set_property(txn, door, "id", &v);
        check(lattice_edge_create(txn, door, zone[i % g->zones], "LOCATED_IN", &edge), "edge");
    }
    lattice_edge_id edge;
    for (size_t i = 0; i < g->membership_count; i++)
        check(lattice_edge_create(txn, person[g->memberships[i].a], group[g->memberships[i].b], "MEMBER_OF", &edge), "edge");
    for (uint32_t i = 10; i < g->groups; i++) check(lattice_edge_create(txn, group[i], group[i / 10], "MEMBER_OF", &edge), "edge");
    lattice_value days_items[5]; for (int d = 0; d < 5; d++) days_items[d] = int_value(d + 1);
    lattice_list days_list = {days_items, 5};
    lattice_value days = {.type = LATTICE_VALUE_LIST}; days.data.list_val = &days_list;
    lattice_value from = int_value(9), until = int_value(18);
    for (size_t i = 0; i < g->grant_count; i++) {
        check(lattice_edge_create(txn, group[g->grants[i].a], zone[g->grants[i].b], "MAY_ENTER", &edge), "edge");
        lattice_edge_set_property(txn, edge, "days", &days);
        lattice_edge_set_property(txn, edge, "from", &from);
        lattice_edge_set_property(txn, edge, "until", &until);
    }
    check(lattice_commit(txn), "commit");
    const char *indexes[][2] = {{"Card", "number"}, {"Person", "id"}, {"Person", "age"}, {"Door", "id"}, {"Group", "id"}, {"Zone", "id"}};
    for (int i = 0; i < 6; i++) check(lattice_node_property_index_create(db, indexes[i][0], indexes[i][1]), "index");
}

typedef lattice_query *Prepared;

static Prepared prepare(const char *text, char *error, size_t error_size) {
    lattice_query *query = NULL;
    if (lattice_query_prepare(db, text, &query) != LATTICE_OK) {
        snprintf(error, error_size, "%s", query ? lattice_query_last_error_message(query) : "prepare failed");
        if (query) lattice_query_free(query);
        return NULL;
    }
    return query;
}

static uint64_t fold_value(uint64_t sum, const lattice_value *v) {
    switch (v->type) {
    case LATTICE_VALUE_INT: return fold(sum, (uint64_t)v->data.int_val);
    case LATTICE_VALUE_BOOL: return fold(sum, v->data.bool_val);
    case LATTICE_VALUE_FLOAT: return fold(sum, (uint64_t)v->data.float_val);
    case LATTICE_VALUE_STRING:
        for (size_t i = 0; i < v->data.string_val.len; i++) sum = fold(sum, (uint8_t)v->data.string_val.ptr[i]);
        return sum;
    default: return fold(sum, 0xdead);
    }
}

/* Runs one query; returns false with `error` set if it failed. */
static bool run(Prepared query, const Query *spec, const Parameters *p, uint64_t *checksum, size_t *rows, char *error, size_t error_size) {
    lattice_value v;
    if (spec->parameters & P_CARD) { v = int_value(p->card); lattice_query_bind(query, "card", &v); }
    if (spec->parameters & P_PERSON) { v = int_value(p->person); lattice_query_bind(query, "person", &v); }
    if (spec->parameters & P_DOOR) { v = int_value(p->door); lattice_query_bind(query, "door", &v); }
    bool writes = lattice_query_writes(query);
    lattice_txn *txn; check(lattice_begin(db, writes ? LATTICE_TXN_READ_WRITE : LATTICE_TXN_READ_ONLY, &txn), "begin");
    lattice_result *result;
    if (lattice_query_execute(query, txn, &result) != LATTICE_OK) {
        snprintf(error, error_size, "%s", lattice_query_last_error_message(query));
        lattice_rollback(txn);
        return false;
    }
    uint32_t columns = lattice_result_column_count(result);
    uint64_t sum = 0xcbf29ce484222325ull; size_t n = 0;
    while (lattice_result_next(result)) {
        n++;
        for (uint32_t c = 0; c < columns; c++) {
            lattice_value cell = {.type = LATTICE_VALUE_NULL};
            lattice_result_get(result, c, &cell);
            sum = fold_value(sum, &cell);
        }
    }
    lattice_result_free(result);
    if (writes) check(lattice_commit(txn), "commit"); else lattice_rollback(txn);
    /* Write queries return created ids, which differ between engines: compare row counts only. */
    *checksum = writes ? 0 : sum; *rows = writes ? 0 : n;
    return true;
}

static void finish(Prepared query) { lattice_query_free(query); }
static void close_engine(void) { lattice_close(db); }
static const char *engine_name(void) { return "latticedb"; }

#else /* zypherdb */

static zypherdb_context *db;
static const char *durability_name = "full";

static void open_engine(const char *dir, const char *option) {
    int mode = ZYPHERDB_DURABILITY_FULL;
    if (option && strcmp(option, "relaxed") == 0) mode = ZYPHERDB_DURABILITY_RELAXED, durability_name = "relaxed";
    if (option && strcmp(option, "deferred") == 0) mode = ZYPHERDB_DURABILITY_DEFERRED, durability_name = "deferred";
    db = zypherdb_open_with_durability(dir, strlen(dir), mode);
    if (!db) { fprintf(stderr, "open failed\n"); exit(1); }
}

#define S(x) x, strlen(x)

static void load(const Graph *g) {
    zypherdb_begin_write(db);
    uint64_t *person = malloc(8 * g->people), *group = malloc(8 * g->groups), *zone = malloc(8 * g->zones);
    char name[32];
    for (uint32_t i = 0; i < g->people; i++) {
        person[i] = zypherdb_allocate_node_id(db);
        zypherdb_add_node(db, person[i], S("Person"));
        zypherdb_set_property_int64(db, person[i], S("id"), i);
        snprintf(name, sizeof name, "person-%u", i); zypherdb_set_property_string(db, person[i], S("name"), S(name));
        zypherdb_set_property_int64(db, person[i], S("age"), 18 + i % 50);
        zypherdb_set_property_string(db, person[i], S("department"), S(departments[i % 8]));
        uint64_t card = zypherdb_allocate_node_id(db);
        zypherdb_add_node(db, card, S("Card"));
        zypherdb_set_property_int64(db, card, S("number"), 1000000 + i);
        zypherdb_add_edge(db, card, person[i], S("HELD_BY"));
    }
    for (uint32_t i = 0; i < g->groups; i++) {
        group[i] = zypherdb_allocate_node_id(db);
        zypherdb_add_node(db, group[i], S("Group"));
        zypherdb_set_property_int64(db, group[i], S("id"), i);
        snprintf(name, sizeof name, "group-%u", i); zypherdb_set_property_string(db, group[i], S("name"), S(name));
    }
    for (uint32_t i = 0; i < g->zones; i++) {
        zone[i] = zypherdb_allocate_node_id(db);
        zypherdb_add_node(db, zone[i], S("Zone"));
        zypherdb_set_property_int64(db, zone[i], S("id"), i);
    }
    for (uint32_t i = 0; i < g->doors; i++) {
        uint64_t door = zypherdb_allocate_node_id(db);
        zypherdb_add_node(db, door, S("Door"));
        zypherdb_set_property_int64(db, door, S("id"), i);
        zypherdb_add_edge(db, door, zone[i % g->zones], S("LOCATED_IN"));
    }
    for (size_t i = 0; i < g->membership_count; i++) zypherdb_add_edge(db, person[g->memberships[i].a], group[g->memberships[i].b], S("MEMBER_OF"));
    for (uint32_t i = 10; i < g->groups; i++) zypherdb_add_edge(db, group[i], group[i / 10], S("MEMBER_OF"));
    zypherdb_commit_write(db);
    /* Indexes are explicit: the same ones LatticeDB gets. */
    const char *indexes[] = {"CREATE INDEX FOR (n:Card) ON (n.number)", "CREATE INDEX FOR (n:Person) ON (n.id)", "CREATE INDEX FOR (n:Person) ON (n.age)",
                             "CREATE INDEX FOR (n:Door) ON (n.id)", "CREATE INDEX FOR (n:Group) ON (n.id)",
                             "CREATE INDEX FOR (n:Zone) ON (n.id)"};
    for (int i = 0; i < 6; i++) {
        zypherdb_result *ir = zypherdb_query(db, S(indexes[i]));
        if (!ir) { size_t n; fprintf(stderr, "index: %s\n", zypherdb_last_error(db, &n)); exit(1); }
        zypherdb_result_free(ir);
    }
    /* Edge properties have no C mutator: one UNWIND query with the grants as a parameter. */
    size_t size = 32 + g->grant_count * 24; char *json = malloc(size); size_t at = 0;
    at += snprintf(json + at, size - at, "{\"grants\": [");
    for (size_t i = 0; i < g->grant_count; i++)
        at += snprintf(json + at, size - at, "%s[%u, %u]", i ? ", " : "", g->grants[i].a, g->grants[i].b);
    at += snprintf(json + at, size - at, "]}");
    const char *text = "UNWIND $grants AS grant MATCH (g:Group {id: grant[0]}), (z:Zone {id: grant[1]}) "
                       "CREATE (g)-[:MAY_ENTER {days: [1, 2, 3, 4, 5], from: 9, until: 18}]->(z)";
    zypherdb_result *r = zypherdb_query_with_parameters(db, S(text), json, at);
    if (!r) { size_t n; fprintf(stderr, "grants: %s\n", zypherdb_last_error(db, &n)); exit(1); }
    zypherdb_result_free(r);
}

typedef const char *Prepared; /* no prepared queries: the text itself */

static Prepared prepare(const char *text, char *error, size_t error_size) { (void)error; (void)error_size; return text; }

static bool run(Prepared text, const Query *spec, const Parameters *p, uint64_t *checksum, size_t *rows, char *error, size_t error_size) {
    char json[128]; size_t at = 0;
    at += snprintf(json + at, sizeof json - at, "{");
    if (spec->parameters & P_CARD) at += snprintf(json + at, sizeof json - at, "\"card\": %lld,", (long long)p->card);
    if (spec->parameters & P_PERSON) at += snprintf(json + at, sizeof json - at, "\"person\": %lld,", (long long)p->person);
    if (spec->parameters & P_DOOR) at += snprintf(json + at, sizeof json - at, "\"door\": %lld,", (long long)p->door);
    if (json[at - 1] == ',') at--;
    at += snprintf(json + at, sizeof json - at, "}");
    zypherdb_result *result = zypherdb_query_with_parameters(db, text, strlen(text), json, at);
    if (!result) { size_t n; snprintf(error, error_size, "%s", zypherdb_last_error(db, &n)); return false; }
    size_t row_count = zypherdb_result_row_count(result), columns = zypherdb_result_column_count(result);
    uint64_t sum = 0xcbf29ce484222325ull;
    for (size_t r = 0; r < row_count; r++) {
        for (size_t c = 0; c < columns; c++) {
            switch (zypherdb_result_type(result, r, c)) {
            case ZYPHERDB_TYPE_INT64: sum = fold(sum, (uint64_t)zypherdb_result_int(result, r, c)); break;
            case ZYPHERDB_TYPE_BOOLEAN: sum = fold(sum, zypherdb_result_bool(result, r, c)); break;
            case ZYPHERDB_TYPE_FLOAT64: sum = fold(sum, (uint64_t)zypherdb_result_float(result, r, c)); break;
            case ZYPHERDB_TYPE_STRING: {
                size_t n; const char *s = zypherdb_result_string(result, r, c, &n);
                for (size_t i = 0; i < n; i++) sum = fold(sum, (uint8_t)s[i]);
                break;
            }
            default: sum = fold(sum, 0xdead);
            }
        }
    }
    zypherdb_result_free(result);
    bool writes = strncmp(text, "CREATE", 6) == 0 || strstr(text, " CREATE ") != NULL;
    *checksum = writes ? 0 : sum; *rows = writes ? 0 : row_count;
    return true;
}

static void finish(Prepared query) { (void)query; }
static void close_engine(void) { zypherdb_close(db); }
static const char *engine_name(void) { return durability_name; }

#endif

/* --- Measurement ---------------------------------------------------------- */

static int compare_doubles(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s DIR PEOPLE RUNS [OPTION]\n", argv[0]); return 2; }
    const char *dir = argv[1];
    uint32_t people = (uint32_t)atoi(argv[2]);
    int runs = atoi(argv[3]);
    open_engine(dir, argc > 4 ? argv[4] : NULL);

    Graph g = make_graph(people);
    double start = seconds_now();
    load(&g);
    printf("{\"engine\": \"%s\", \"query\": \"load\", \"seconds\": %.3f}\n", engine_name(), seconds_now() - start);
    fflush(stdout);

    for (size_t q = 0; q < sizeof queries / sizeof queries[0]; q++) {
        const Query *spec = &queries[q];
        int count = spec->heavy ? (runs / 20 > 5 ? runs / 20 : 5) : runs;
        char error[512] = "";
        Prepared prepared = prepare(spec->text, error, sizeof error);
        if (!prepared) {
            printf("{\"query\": \"%s\", \"error\": \"%s\"}\n", spec->name, error);
            continue;
        }
        double *times = malloc(sizeof(double) * count);
        uint64_t checksums[3] = {0}; size_t rows[3] = {0};
        rng_state = 1000 + q; /* the same parameters for both engines */
        bool failed = false;
        for (int i = 0; i <= count; i++) { /* run 0 warms up */
            Parameters p = {1000000 + (int64_t)below(people), (int64_t)below(people), (int64_t)below(g.doors)};
            uint64_t checksum; size_t row_count;
            double t0 = seconds_now();
            bool ok = run(prepared, spec, &p, &checksum, &row_count, error, sizeof error);
            double elapsed = seconds_now() - t0;
            if (!ok) { failed = true; break; }
            if (i > 0) times[i - 1] = elapsed;
            if (i < 3) { checksums[i] = checksum; rows[i] = row_count; }
        }
        finish(prepared);
        if (failed) {
            printf("{\"query\": \"%s\", \"error\": \"%s\"}\n", spec->name, error);
        } else {
            qsort(times, count, sizeof(double), compare_doubles);
            printf("{\"query\": \"%s\", \"median_us\": %.1f, \"p95_us\": %.1f, \"runs\": %d, \"answers\": \"%zu:%016llx %zu:%016llx %zu:%016llx\"}\n",
                   spec->name, times[count / 2] * 1e6, times[(int)(count * 0.95) - 1 < 0 ? 0 : (int)(count * 0.95) - 1] * 1e6, count,
                   rows[0], (unsigned long long)checksums[0], rows[1], (unsigned long long)checksums[1], rows[2], (unsigned long long)checksums[2]);
        }
        fflush(stdout);
        free(times);
    }
    close_engine();
    return 0;
}
