//! FOREACH: updating clauses run once per element of a list.

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

test "FOREACH runs its updating clauses once per element" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // CREATE per element; the rows go on unchanged.
    try expectQuery(&ast, &g,
        \\CREATE (d:Door {name: 'main'})
        \\FOREACH (hour IN [8, 9, 10] | CREATE (d)-[:OPEN_AT]->(:Hour {value: hour}))
        \\RETURN d.name
    , &.{&.{string("main")}});
    try expectQuery(&ast, &g, "MATCH (:Door)-[:OPEN_AT]->(h:Hour) RETURN h.value ORDER BY h.value", &.{ &.{int(8)}, &.{int(9)}, &.{int(10)} });
    // SET from the elements, on nodes from the outer row; null is no element.
    try expectQuery(&ast, &g, "MATCH (h:Hour) WITH collect(h) AS hours FOREACH (h IN hours | SET h.checked = true)", &.{});
    try expectQuery(&ast, &g, "MATCH (h:Hour {checked: true}) RETURN count(h)", &.{&.{int(3)}});
    try expectQuery(&ast, &g, "FOREACH (x IN null | CREATE (:Never))", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Never) RETURN count(n)", &.{&.{int(0)}});
    // MERGE sees what earlier elements created; FOREACH nests.
    try expectQuery(&ast, &g, "FOREACH (name IN ['a', 'b', 'a'] | MERGE (:Tag {name: name}))", &.{});
    try expectQuery(&ast, &g, "MATCH (t:Tag) RETURN t.name ORDER BY t.name", &.{ &.{string("a")}, &.{string("b")} });
    try expectQuery(&ast, &g,
        \\FOREACH (row IN [[1, 2], [3]] | FOREACH (x IN row | CREATE (:Cell {value: x})))
    , &.{});
    try expectQuery(&ast, &g, "MATCH (c:Cell) RETURN sum(c.value)", &.{&.{int(6)}});
    // DELETE inside it.
    try expectQuery(&ast, &g, "MATCH (c:Cell) WITH collect(c) AS cells FOREACH (c IN cells | DELETE c)", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Cell) RETURN count(c)", &.{&.{int(0)}});

    // What it binds stays inside; its variable must be new; a list is needed.
    try expectQueryError(&ast, &g, "FOREACH (x IN [1] | CREATE (n:Made {x: x})) RETURN n", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (t:Tag) FOREACH (t IN [1] | CREATE (:Made)) RETURN 1", error.InvalidExpression);
    try expectQueryError(&ast, &g, "FOREACH (x IN 5 | CREATE (:Made))", error.TypeMismatch);
    // Only updating clauses go inside.
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "FOREACH (x IN [1] | MATCH (n) SET n.x = x)", null));
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "FOREACH (x IN [1] | )", null));
    try expectQuery(&ast, &g, "MATCH (m:Made) RETURN count(m)", &.{&.{int(0)}});
}
