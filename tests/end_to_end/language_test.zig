//! UNION, simple CASE, XOR, chained comparisons, and patterns inside
//! expressions (pattern predicates, pattern comprehensions, EXISTS).

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const Value = acmedb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn string(s: []const u8) Value {
    return .{ .string = s };
}

fn boolean(b: bool) Value {
    return .{ .boolean = b };
}

const null_value: Value = .{ .null = {} };

test "UNION removes duplicate rows, UNION ALL keeps them, columns must agree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN 1 AS x UNION RETURN 2 AS x UNION RETURN 1 AS x", &.{ &.{int(1)}, &.{int(2)} });
    try expectQuery(&ast, &g, "RETURN 1 AS x UNION ALL RETURN 1 AS x", &.{ &.{int(1)}, &.{int(1)} });
    // Each part reads with the writes of the parts before it.
    try expectQuery(&ast, &g, "CREATE (:Door {name: 'a'}) RETURN 'created' AS x UNION MATCH (d:Door) RETURN d.name AS x", &.{ &.{string("created")}, &.{string("a")} });
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "RETURN 1 AS a UNION RETURN 2 AS b", null));
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "RETURN 1 AS a UNION RETURN 2 AS a UNION ALL RETURN 3 AS a", null));
}

test "simple CASE, XOR and chained comparisons" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\UNWIND [1, 2, 3, null] AS level
        \\RETURN level, CASE level WHEN 1 THEN 'visitor' WHEN 2 THEN 'staff' ELSE 'other' END
    , &.{
        &.{ int(1), string("visitor") }, &.{ int(2), string("staff") },
        &.{ int(3), string("other") },   &.{ null_value, string("other") },
    });
    try expectQuery(&ast, &g, "RETURN true XOR false, true XOR true, null XOR true, true OR true XOR true", &.{
        &.{ boolean(true), boolean(false), null_value, boolean(true) },
    });
    // `a < b <= c` is `a < b AND b <= c`; IS NULL binds tighter than `=`.
    try expectQuery(&ast, &g, "RETURN 1 < 2 <= 2, 1 < 3 < 2, 1 = 1 = true, null IS NULL = true", &.{
        &.{ boolean(true), boolean(false), boolean(false), boolean(true) },
    });
}

test "patterns in expressions: predicates, comprehensions and EXISTS" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\CREATE (ana:Person {name: 'Ana'})-[:MEMBER_OF]->(eng:Group {name: 'engineering'}),
        \\       (bo:Person {name: 'Bo'})-[:MEMBER_OF]->(:Group {name: 'visitors'}),
        \\       (eng)-[:MAY_ENTER]->(:Zone {name: 'floor 3'}), (:Person {name: 'Cy'})
    , &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE (p)-[:MEMBER_OF]->() RETURN p.name", &.{ &.{string("Ana")}, &.{string("Bo")} });
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE NOT (p)-->() RETURN p.name", &.{&.{string("Cy")}});
    try expectQuery(&ast, &g,
        \\MATCH (p:Person {name: 'Ana'})
        \\RETURN [(p)-[:MEMBER_OF]->(g)-[:MAY_ENTER]->(z) | z.name] AS zones
    , &.{&.{.{ .list = &.{string("floor 3")} }}});
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\WHERE EXISTS { (p)-[:MEMBER_OF]->(g) WHERE g.name = 'visitors' }
        \\RETURN p.name
    , &.{&.{string("Bo")}});
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\WHERE exists { MATCH (p)-->(g) MATCH (g)-[:MAY_ENTER]->(z) RETURN z }
        \\RETURN p.name
    , &.{&.{string("Ana")}});
    // A pattern predicate cannot introduce variables.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const query = try acmedb.parser.parse(&ast, "MATCH (p:Person) WHERE (p)-->(other) RETURN p", null);
    var executor = acmedb.Executor.init(&ast, &g, arena.allocator());
    try testing.expectError(error.InvalidExpression, executor.run(query));
    // Outside a WHERE, a pattern is not an expression.
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (p) RETURN (p)-->()", null));
}

test "a WITH's WHERE also sees the variables from before it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\WITH ['a', 'b', 'c'] AS letters UNWIND range(0, 2) AS i
        \\WITH letters[i] AS letter WHERE i > 0
        \\RETURN letter
    , &.{ &.{string("b")}, &.{string("c")} });
}
