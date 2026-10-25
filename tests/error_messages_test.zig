//! Error messages as a caller of the C ABI (and so of Python) reads them:
//! the code and the text of each failing query, as snapshots. A change to a
//! message shows up here; accept it with `SNAP_UPDATE=1` after reading it.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const c_api = zypherdb.c_api;
const ErrorCode = zypherdb.diagnostics.ErrorCode;
const snap = @import("snapshot.zig").snap;
const Snap = @import("snapshot.zig").Snap;
const testPath = @import("support.zig").testPath;

/// Runs each query in a fresh database and prints, for each, the query and
/// the error it ends with (or "ok" when it succeeds).
fn expectErrors(setup: []const u8, queries: []const []const u8, expected: Snap) !void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    const path = testPath(&tmp, &path_buffer);
    const context = c_api.zypherdb_open(path.ptr, path.len).?;
    defer c_api.zypherdb_close(context);
    if (setup.len > 0) c_api.zypherdb_result_free(c_api.zypherdb_query(context, setup.ptr, setup.len).?);

    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    for (queries) |query| {
        try text.writer.print("{s}\n", .{query});
        if (c_api.zypherdb_query(context, query.ptr, query.len)) |result| {
            c_api.zypherdb_result_free(result);
            try text.writer.writeAll("  ok\n");
            continue;
        }
        var len: usize = 0;
        const message = c_api.zypherdb_last_error(context, &len)[0..len];
        const code: ErrorCode = @enumFromInt(c_api.zypherdb_error_code(context));
        try text.writer.print("  {t}: {s}\n", .{ code, message });
    }
    try expected.diff(text.written());
}

test "parse errors name what was expected and what was found" {
    try expectErrors("", &.{
        "MATCH (",
        "MATCH (n RETURN n",
        "MATCH (n) RETURN n.",
        "RETURN 1 +",
        "RETURN [1, 2",
        "RETURN 'unterminated",
        "MATCH (n) WHERE RETURN n",
        "MATCH (n) WITH n WHERE WITH n RETURN n",
        "WITH 1 AS return RETURN return",
        "MATCH (n)",
        "CREATE (a) MATCH (b) RETURN b",
        "RETURN 1 AS a UNION RETURN 2 AS b",
        "RETURN 9223372036854775808",
        "EXPLAIN SHOW INDEXES",
        "MATCH (n)-[*2..1]->(m) RETURN m",
        "FOREACH (x IN [1] | )",
    }, snap(@src(),
        \\MATCH (
        \\  parse: expected ')', found end of query
        \\MATCH (n RETURN n
        \\  parse: expected ')', found RETURN
        \\MATCH (n) RETURN n.
        \\  parse: expected an identifier, found end of query
        \\RETURN 1 +
        \\  parse: expected an expression, found end of query
        \\RETURN [1, 2
        \\  parse: expected ']', found end of query
        \\RETURN 'unterminated
        \\  parse: unterminated string literal
        \\MATCH (n) WHERE RETURN n
        \\  parse: expected an expression, found RETURN
        \\MATCH (n) WITH n WHERE WITH n RETURN n
        \\  parse: expected an expression, found WITH
        \\WITH 1 AS return RETURN return
        \\  ok
        \\MATCH (n)
        \\  parse: a query must end with RETURN or an updating clause
        \\CREATE (a) MATCH (b) RETURN b
        \\  parse: a WITH is needed between an updating clause and MATCH
        \\RETURN 1 AS a UNION RETURN 2 AS b
        \\  parse: the parts of a UNION must return the same columns
        \\RETURN 9223372036854775808
        \\  parse: integer literal 9223372036854775808 does not fit in 64 bits
        \\EXPLAIN SHOW INDEXES
        \\  parse: EXPLAIN and PROFILE take a query, not a schema command
        \\MATCH (n)-[*2..1]->(m) RETURN m
        \\  ok
        \\FOREACH (x IN [1] | )
        \\  parse: FOREACH needs an updating clause after '|'
    ));
}

test "semantic errors name the variable, function or clause at fault" {
    try expectErrors("", &.{
        "RETURN n.name",
        "MATCH (n) RETURN m",
        "MATCH (n) WITH n.x AS x RETURN n",
        "RETURN nosuchfunction(1)",
        "RETURN count(count(1))",
        "MATCH (n) RETURN n, count(*) ORDER BY m",
        "RETURN $missing",
        "MATCH (n) SET n = 1",
        "MATCH (n) SET n += 'x'",
        "MATCH (n) SET n = [1]",
        "MERGE (n:A) ON CREATE SET n = true",
        "MATCH (n) SET n = {a: 1}, n += $map",
        "CREATE (n)-[:A|B]->(m)",
        "CREATE (n)-[]->(m)",
        "MATCH (a) CREATE (a)",
    }, snap(@src(),
        \\RETURN n.name
        \\  unknown_variable: unknown variable 'n'
        \\MATCH (n) RETURN m
        \\  unknown_variable: unknown variable 'm'
        \\MATCH (n) WITH n.x AS x RETURN n
        \\  unknown_variable: unknown variable 'n'
        \\RETURN nosuchfunction(1)
        \\  invalid_expression: unknown function 'nosuchfunction'
        \\RETURN count(count(1))
        \\  invalid_expression: an aggregate cannot contain another aggregate
        \\MATCH (n) RETURN n, count(*) ORDER BY m
        \\  unknown_variable: unknown variable 'm'
        \\RETURN $missing
        \\  parameter_missing: missing parameter '$missing'
        \\MATCH (n) SET n = 1
        \\  invalid_expression: SET n = needs a map, a node or a relationship, not a literal integer
        \\MATCH (n) SET n += 'x'
        \\  invalid_expression: SET n += needs a map, a node or a relationship, not a literal string
        \\MATCH (n) SET n = [1]
        \\  invalid_expression: SET n = needs a map, a node or a relationship, not a literal list
        \\MERGE (n:A) ON CREATE SET n = true
        \\  invalid_expression: SET n = needs a map, a node or a relationship, not a literal boolean
        \\MATCH (n) SET n = {a: 1}, n += $map
        \\  parameter_missing: missing parameter '$map'
        \\CREATE (n)-[:A|B]->(m)
        \\  invalid_expression: CREATE needs a relationship with exactly one type
        \\CREATE (n)-[]->(m)
        \\  invalid_expression: CREATE needs a relationship with exactly one type
        \\MATCH (a) CREATE (a)
        \\  invalid_expression: CREATE of node 'a', which is already bound
    ));
}

test "run-time errors name the operation and the values" {
    try expectErrors("CREATE (:Person {name: 'Ann'})-[:KNOWS]->(:Person {name: 'Bob'})", &.{
        "RETURN size(1)",
        "RETURN 1 / 0",
        "RETURN 9223372036854775807 + 1",
        "RETURN 'a' + 1 - 2",
        "RETURN toInteger([1])",
        "RETURN [1, 2][true]",
        "RETURN date('2026-02-30')",
        "RETURN duration('P1X')",
        "RETURN date({year: 2026, month: 13})",
        "RETURN localtime('25:00')",
        "RETURN datetime('2026-10-24T12:00:00[Nowhere/City]')",
        "UNWIND [1, 2] AS x RETURN x.name",
        "MATCH (p:Person {name: 'Ann'}) DELETE p",
        "MATCH (p:Person) SET p.tags = [1, 'a']",
        "MATCH (p:Person) SET p.tags = [1, null]",
        "MATCH (p:Person)-[k:KNOWS]->() SET p.friend = k",
        "MATCH (p:Person) SET p.tags = [1, 2.5], p.at = date('2026-10-24'), p.doc = {a: [1, 'x', null]}",
        "LOAD CSV FROM 'file:///x.csv' AS row RETURN row",
    }, snap(@src(),
        \\RETURN size(1)
        \\  type_mismatch: size() expects a list or a string
        \\RETURN 1 / 0
        \\  arithmetic: division by zero
        \\RETURN 9223372036854775807 + 1
        \\  arithmetic: integer overflow: the result does not fit in 64 bits
        \\RETURN 'a' + 1 - 2
        \\  type_mismatch: arithmetic needs numbers
        \\RETURN toInteger([1])
        \\  type_mismatch: toInteger() expects a number or a string
        \\RETURN [1, 2][true]
        \\  type_mismatch: a list index must be an integer
        \\RETURN date('2026-02-30')
        \\  invalid_expression: date('2026-02-30'): not a valid date (written like '2026-10-24')
        \\RETURN duration('P1X')
        \\  invalid_expression: duration('P1X'): not a valid duration (written like 'P1Y2M3DT4H5M6S')
        \\RETURN date({year: 2026, month: 13})
        \\  invalid_expression: date(): the map's fields do not make a valid date (a field out of range, or a smaller unit without the larger one)
        \\RETURN localtime('25:00')
        \\  invalid_expression: localtime('25:00'): not a valid local time (written like '12:30:00')
        \\RETURN datetime('2026-10-24T12:00:00[Nowhere/City]')
        \\  invalid_expression: datetime('2026-10-24T12:00:00[Nowhere/City]'): unknown time zone
        \\UNWIND [1, 2] AS x RETURN x.name
        \\  type_mismatch: only nodes, relationships, maps and temporal values have properties
        \\MATCH (p:Person {name: 'Ann'}) DELETE p
        \\  node_still_connected: node 'p' still has relationships (use DETACH DELETE)
        \\MATCH (p:Person) SET p.tags = [1, 'a']
        \\  type_mismatch: property 'tags': this value cannot be stored (a list must hold values of one kind and no nulls; nodes, relationships and paths are never stored)
        \\MATCH (p:Person) SET p.tags = [1, null]
        \\  type_mismatch: property 'tags': this value cannot be stored (a list must hold values of one kind and no nulls; nodes, relationships and paths are never stored)
        \\MATCH (p:Person)-[k:KNOWS]->() SET p.friend = k
        \\  type_mismatch: property 'friend': this value cannot be stored (a list must hold values of one kind and no nulls; nodes, relationships and paths are never stored)
        \\MATCH (p:Person) SET p.tags = [1, 2.5], p.at = date('2026-10-24'), p.doc = {a: [1, 'x', null]}
        \\  ok
        \\LOAD CSV FROM 'file:///x.csv' AS row RETURN row
        \\  external_resource: LOAD CSV is off: it reads files only from an import directory given when the database is opened
    ));
}

test "constraint violations name the constraint and the value" {
    try expectErrors("CREATE CONSTRAINT person_name FOR (p:Person) REQUIRE p.name IS UNIQUE", &.{
        "CREATE (:Person {name: 'Ann'})",
        "CREATE (:Person {name: 'Ann'})",
        "MATCH (p:Person) SET p.name = 'Ann'",
        "CREATE (:Person {name: 'Bob'}), (:Person {name: 'Bob'})",
        "CREATE CONSTRAINT person_name FOR (p:Person) REQUIRE p.name IS UNIQUE",
    }, snap(@src(),
        \\CREATE (:Person {name: 'Ann'})
        \\  ok
        \\CREATE (:Person {name: 'Ann'})
        \\  constraint_violation: node 1 cannot have the same name as node 0: constraint 'person_name' makes it unique for :Person
        \\MATCH (p:Person) SET p.name = 'Ann'
        \\  ok
        \\CREATE (:Person {name: 'Bob'}), (:Person {name: 'Bob'})
        \\  constraint_violation: node 2 cannot have the same name as node 1: constraint 'person_name' makes it unique for :Person
        \\CREATE CONSTRAINT person_name FOR (p:Person) REQUIRE p.name IS UNIQUE
        \\  invalid_expression: a constraint named 'person_name' already exists
    ));
}
