//! Subqueries: `EXISTS { ... }` with a whole read-only query inside (MATCH,
//! OPTIONAL MATCH, UNWIND, WITH, RETURN), the scope it sees and keeps, and
//! aggregates that belong to it.

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

fn string(s: []const u8) Value {
    return .{ .string = s };
}

fn boolean(b: bool) Value {
    return .{ .boolean = b };
}

/// Ana is in two groups, Bo in one, Cy in none; engineering may enter floor 3.
fn createGroups(ast: *Ast, g: *Graph) !void {
    try expectQuery(ast, g,
        \\CREATE (ana:Person {name: 'Ana', age: 40})-[:MEMBER_OF]->(eng:Group {name: 'engineering'}),
        \\       (ana)-[:MEMBER_OF]->(:Group {name: 'security'}),
        \\       (bo:Person {name: 'Bo', age: 25})-[:MEMBER_OF]->(:Group {name: 'visitors'}),
        \\       (eng)-[:MAY_ENTER]->(:Zone {name: 'floor 3'}), (:Person {name: 'Cy', age: 31})
    , &.{});
}

test "EXISTS runs a whole read-only query from the outer row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createGroups(&ast, &g);

    // WITH aggregates per outer row, and its WHERE filters the groups.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS {
        \\  MATCH (p)-[:MEMBER_OF]->(g)
        \\  WITH p, count(g) AS groups WHERE groups >= 2
        \\  RETURN true
        \\}
        \\RETURN p.name
    , &.{&.{string("Ana")}});
    // A RETURN that aggregates always has a row, even from no match.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:MEMBER_OF]->(g) RETURN count(g) AS n }
        \\RETURN p.name ORDER BY p.name
    , &.{ &.{string("Ana")}, &.{string("Bo")}, &.{string("Cy")} });
    // UNWIND, a WITH that filters, and a LIMIT that keeps no row.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS { UNWIND [30, 35] AS age WITH age WHERE p.age > age RETURN age }
        \\RETURN p.name ORDER BY p.name
    , &.{ &.{string("Ana")}, &.{string("Cy")} });
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE EXISTS { MATCH (p)-->(g) RETURN g LIMIT 0 } RETURN p.name", &.{});
    // OPTIONAL MATCH keeps the row; the WHERE after it decides.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS {
        \\  OPTIONAL MATCH (p)-[:MEMBER_OF]->(g)
        \\  WITH g WHERE g IS NULL
        \\  RETURN 1
        \\}
        \\RETURN p.name
    , &.{&.{string("Cy")}});
    // Two MATCHes, nested EXISTS, and EXISTS as a returned value.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS {
        \\  MATCH (p)-->(g) WHERE EXISTS { MATCH (g)-[:MAY_ENTER]->(z) RETURN z }
        \\}
        \\RETURN p.name
    , &.{&.{string("Ana")}});
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\RETURN p.name, EXISTS { MATCH (p)-->(g) WITH count(*) AS n WHERE n > 1 RETURN n } AS busy
        \\ORDER BY p.name
    , &.{ &.{ string("Ana"), boolean(true) }, &.{ string("Bo"), boolean(false) }, &.{ string("Cy"), boolean(false) } });
}

test "an EXISTS subquery's aggregates and variables stay inside it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createGroups(&ast, &g);

    // The outer RETURN does not aggregate because the subquery does: one
    // row per person, not one group.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\RETURN count(*) AS people, sum(CASE WHEN EXISTS { MATCH (p)-->(g) RETURN count(g) AS n } THEN 1 ELSE 0 END) AS counted
    , &.{&.{ .{ .int = 3 }, .{ .int = 3 } }});
    // A variable the subquery binds is unknown after it.
    try expectQueryError(&ast, &g, "MATCH (p:Person) WHERE EXISTS { MATCH (p)-->(g) RETURN g } RETURN g", error.InvalidExpression);
    // A WITH inside it hides the outer variables it does not project.
    try expectQueryError(&ast, &g, "MATCH (p:Person) WHERE EXISTS { MATCH (p)-->(g) WITH g RETURN p } RETURN p", error.InvalidExpression);
    // Writing is not allowed in it.
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (p) WHERE EXISTS { MATCH (p)-->(g) SET g.seen = true } RETURN p", null));
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (p) WHERE EXISTS { CREATE (x) } RETURN p", null));
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (p) WHERE EXISTS { } RETURN p", null));
    // Nothing above wrote.
    try expectQuery(&ast, &g, "MATCH (n) WHERE n.seen IS NOT NULL RETURN n", &.{});
}
