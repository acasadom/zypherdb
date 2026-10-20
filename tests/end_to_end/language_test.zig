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
const expectQueryError = support.expectQueryError;

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

test "label predicates are expressions: nodes, relationships, null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Person:Admin {n: 1})-[:KNOWS]->(:Person {n: 2})", &.{});
    try expectQuery(&ast, &g, "MATCH (p) WHERE p:Admin RETURN p.n", &.{&.{.{ .int = 1 }}});
    try expectQuery(&ast, &g, "MATCH (p) WHERE NOT p:Admin RETURN p.n", &.{&.{.{ .int = 2 }}});
    try expectQuery(&ast, &g, "MATCH (p) RETURN p.n, p:Person:Admin ORDER BY p.n", &.{
        &.{ .{ .int = 1 }, .{ .boolean = true } },
        &.{ .{ .int = 2 }, .{ .boolean = false } },
    });
    try expectQuery(&ast, &g, "MATCH ()-[r]->() RETURN r:KNOWS, r:OTHER", &.{&.{ .{ .boolean = true }, .{ .boolean = false } }});
    try expectQuery(&ast, &g, "OPTIONAL MATCH (x:Nothing) RETURN x:Person", &.{&.{.null}});
    // A map literal's keys are not label predicates.
    try expectQuery(&ast, &g, "MATCH (p {n: 2}) RETURN {admin: p:Admin}", &.{&.{.{ .map = &.{.{ .key = "admin", .value = .{ .boolean = false } }} }}});
    try expectQueryError(&ast, &g, "RETURN 1:Person", error.TypeMismatch);
}

test "RETURN * and WITH * project every variable in scope, sorted by name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "UNWIND [1, 2] AS b WITH b, b * 10 AS a RETURN *", &.{
        &.{ .{ .int = 10 }, .{ .int = 1 } },
        &.{ .{ .int = 20 }, .{ .int = 2 } },
    });
    try expectQuery(&ast, &g, "WITH 1 AS x WITH *, x + 1 AS y RETURN *, y * 2 AS z", &.{&.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 4 } }});
    try expectQueryError(&ast, &g, "MATCH () RETURN *", error.InvalidExpression);
}

test "map projections build maps from nodes, relationships and maps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:P {name: 'Ana', age: 30})-[:R {since: 2020}]->(:P {name: 'Luis'})", &.{});
    const s = struct {
        fn str(text: []const u8) Value {
            return .{ .string = text };
        }
    }.str;
    try expectQuery(&ast, &g, "MATCH (p:P {name: 'Ana'}) RETURN p {.name, .missing, years: p.age + 1}", &.{&.{.{ .map = &.{
        .{ .key = "missing", .value = .null }, .{ .key = "name", .value = s("Ana") }, .{ .key = "years", .value = .{ .int = 31 } },
    } }}});
    // .* takes every property; a later key overrides; a variable selector keys itself.
    try expectQuery(&ast, &g, "MATCH (p:P {name: 'Ana'})-[r:R]->(q) WITH p, r, q.name AS friend RETURN p {.*, age: 0, friend}, r {.*}", &.{&.{
        .{ .map = &.{ .{ .key = "age", .value = .{ .int = 0 } }, .{ .key = "friend", .value = s("Luis") }, .{ .key = "name", .value = s("Ana") } } },
        .{ .map = &.{.{ .key = "since", .value = .{ .int = 2020 } }} },
    }});
    try expectQuery(&ast, &g, "WITH {a: 1, b: 2} AS m RETURN m {.a, c: 3}", &.{&.{.{ .map = &.{ .{ .key = "a", .value = .{ .int = 1 } }, .{ .key = "c", .value = .{ .int = 3 } } } }}});
    try expectQuery(&ast, &g, "OPTIONAL MATCH (x:Nothing) RETURN x {.name}", &.{&.{.null}});
}

test "WITH ORDER BY sees earlier variables, and projected parts by their names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:A {n: 3, m: 1}), (:A {n: 1, m: 9}), (:A {n: 2, m: 2})", &.{});
    // `a` is not projected, but a WITH without grouping can still sort by it.
    try expectQuery(&ast, &g, "MATCH (a:A) WITH a.m AS m ORDER BY a.n LIMIT 2 RETURN m", &.{ &.{.{ .int = 9 }}, &.{.{ .int = 2 }} });
    // After grouping, `a.n` is the projected column `n`.
    try expectQuery(&ast, &g, "MATCH (a:A) WITH a.n AS n, count(*) AS c ORDER BY a.n * -1 LIMIT 1 RETURN n, c", &.{&.{ .{ .int = 3 }, .{ .int = 1 } }});
}

test "variables of unknown type can be matched as nodes, and named paths are null when unmatched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:S)-[:R]->(:E)", &.{});
    try expectQuery(&ast, &g, "MATCH (s:S)-->(e) WITH collect(e) AS es UNWIND es AS x MATCH (y)-->(x) RETURN labels(y)", &.{&.{.{ .list = &.{.{ .string = "S" }} }}});
    try expectQuery(&ast, &g, "WITH null AS a OPTIONAL MATCH p = (a)-->() RETURN p, nodes(p)", &.{&.{ .null, .null }});
}
