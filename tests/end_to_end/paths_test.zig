//! Variable-length relationships, relationship type alternatives and paths.

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

/// Ana is in Engineering, which is in Staff, which is in Everyone; groups
/// grant access to zones.
fn loadAccessGraph(ast: *Ast, g: *Graph) !void {
    try expectQuery(ast, g,
        \\CREATE (ana:Person {name: 'Ana'}),
        \\       (eng:Group {name: 'Engineering'}), (staff:Group {name: 'Staff'}), (all:Group {name: 'Everyone'}),
        \\       (ana)-[:MEMBER_OF]->(eng), (eng)-[:MEMBER_OF]->(staff), (staff)-[:MEMBER_OF]->(all),
        \\       (eng)-[:MAY_ENTER]->(:Zone {name: 'Lab'}),
        \\       (staff)-[:MAY_ENTER]->(:Zone {name: 'Office'}),
        \\       (all)-[:MAY_ENTER]->(:Zone {name: 'Hall'}),
        \\       (all)-[:DENIED]->(:Zone {name: 'Vault'})
    , &.{});
}

test "variable-length paths through a group hierarchy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try loadAccessGraph(&ast, &g);

    // Every group Ana belongs to, directly or not, and the zones they grant.
    try expectQuery(&ast, &g, "MATCH (:Person {name: 'Ana'})-[:MEMBER_OF*]->(group)-[:MAY_ENTER]->(zone) RETURN zone.name", &.{
        &.{string("Lab")},
        &.{string("Office")},
        &.{string("Hall")},
    });
    // Bounded hops.
    try expectQuery(&ast, &g, "MATCH (:Person)-[:MEMBER_OF*2]->(g) RETURN g.name", &.{&.{string("Staff")}});
    try expectQuery(&ast, &g, "MATCH (:Person)-[:MEMBER_OF*..2]->(g) RETURN count(*)", &.{&.{int(2)}});
    try expectQuery(&ast, &g, "MATCH (:Person)-[:MEMBER_OF*2..]->(g) RETURN count(*)", &.{&.{int(2)}});
    // Zero hops include the start node itself.
    try expectQuery(&ast, &g, "MATCH (e:Group {name: 'Engineering'})-[:MEMBER_OF*0..1]->(g) RETURN g.name", &.{
        &.{string("Engineering")},
        &.{string("Staff")},
    });
    // Backwards, from the far end: who reaches Everyone?
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:MEMBER_OF*]->(:Group {name: 'Everyone'}) RETURN p.name", &.{&.{string("Ana")}});
    // The variable is the list of relationships; type alternatives.
    try expectQuery(&ast, &g, "MATCH (:Person)-[r:MEMBER_OF*]->(:Group {name: 'Everyone'}) RETURN size(r), type(r[0])", &.{&.{ int(3), string("MEMBER_OF") }});
    try expectQuery(&ast, &g, "MATCH (:Group {name: 'Everyone'})-[:MAY_ENTER|DENIED]->(z) RETURN count(z)", &.{&.{int(2)}});
    // A created relationship has a fixed length.
    try expectQueryError(&ast, &g, "MATCH (a:Person) CREATE (a)-[:R*2]->(:X)", error.InvalidExpression);
}

test "path variables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try loadAccessGraph(&ast, &g);

    try expectQuery(&ast, &g, "MATCH p = (:Person)-[:MEMBER_OF*]->(:Group {name: 'Everyone'}) RETURN length(p), [n IN nodes(p) | n.name], size(relationships(p))", &.{&.{
        int(3),
        .{ .list = &.{ string("Ana"), string("Engineering"), string("Staff"), string("Everyone") } },
        int(3),
    }});
    // A fixed-length path, written right to left: still in pattern order.
    try expectQuery(&ast, &g, "MATCH p = (z:Zone {name: 'Lab'})<-[:MAY_ENTER]-(g) RETURN [n IN nodes(p) | n.name]", &.{&.{
        .{ .list = &.{ string("Lab"), string("Engineering") } },
    }});
}

test "static checks on path variables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQueryError(&ast, &g, "MATCH r = ()-->(), ()-[r]-() RETURN r", error.InvalidExpression);
    try expectQueryError(&ast, &g, "WITH true AS p MATCH p = ()-->() RETURN p", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH p = ()-->() WHERE p.name = 'x' RETURN p", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH p = ()-->() RETURN labels(p)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (n) RETURN length(n)", error.InvalidExpression);
}
