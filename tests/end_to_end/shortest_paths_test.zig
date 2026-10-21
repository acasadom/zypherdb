//! shortestPath and allShortestPaths: only the shortest paths of a
//! variable-length pattern between its two ends.

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

fn strings(comptime items: []const []const u8) Value {
    const values = comptime values: {
        var list: [items.len]Value = undefined;
        for (items, 0..) |item, i| list[i] = .{ .string = item };
        break :values list;
    };
    return .{ .list = &values };
}

/// a→b→c→d (ROAD), a→e→d (ROAD), a→f→d (RAIL), d→g (ROAD); the doors on
/// b and e are locked.
fn createNetwork(ast: *Ast, g: *Graph) !void {
    try expectQuery(ast, g,
        \\CREATE (a:Place {name: 'a'}), (b:Place {name: 'b', locked: true}), (c:Place {name: 'c'}),
        \\       (d:Place {name: 'd'}), (e:Place {name: 'e', locked: true}), (f:Place {name: 'f'}),
        \\       (g:Place {name: 'g'}),
        \\       (a)-[:ROAD {km: 1}]->(b)-[:ROAD {km: 1}]->(c)-[:ROAD {km: 1}]->(d),
        \\       (a)-[:ROAD {km: 5}]->(e)-[:ROAD {km: 5}]->(d),
        \\       (a)-[:RAIL {km: 2}]->(f)-[:RAIL {km: 2}]->(d),
        \\       (d)-[:ROAD {km: 1}]->(g)
    , &.{});
}

test "shortestPath finds one shortest path, allShortestPaths every one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createNetwork(&ast, &g);

    // Two of length 2 by any type; one by ROAD only; none against the arrows.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = shortestPath((a)-[*]->(d))
        \\RETURN length(p)
    , &.{&.{int(2)}});
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = allShortestPaths((a)-[*]->(d))
        \\RETURN [n IN nodes(p) | n.name] AS route ORDER BY route
    , &.{ &.{strings(&.{ "a", "e", "d" })}, &.{strings(&.{ "a", "f", "d" })} });
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = allShortestPaths((a)-[:ROAD*]->(d))
        \\RETURN [n IN nodes(p) | n.name] AS route
    , &.{&.{strings(&.{ "a", "e", "d" })}});
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = shortestPath((d)-[*]->(a))
        \\RETURN p
    , &.{});
    // Undirected, and from the far end: the same length.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (g:Place {name: 'g'})
        \\MATCH p = shortestPath((g)-[*]-(a))
        \\RETURN length(p), [n IN nodes(p) | n.name][0] AS first
    , &.{&.{ int(3), string("g") }});
    // A maximum length: nothing within one hop.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = shortestPath((a)-[*..1]->(d))
        \\RETURN p
    , &.{});
    // The relationship list, and a property on the relationships searched.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH shortestPath((a)-[r:ROAD* {km: 1}]->(d))
        \\RETURN size(r)
    , &.{&.{int(3)}});
    // An unbound end: one shortest path to each place reached.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'})
        \\MATCH p = shortestPath((a)-[:ROAD*]->(x))
        \\RETURN x.name, length(p) ORDER BY x.name
    , &.{ &.{ string("b"), int(1) }, &.{ string("c"), int(2) }, &.{ string("d"), int(2) }, &.{ string("e"), int(1) }, &.{ string("g"), int(3) } });
    // Length 0 is allowed with *0..: the start itself.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'})
        \\MATCH p = shortestPath((a)-[*0..]->(a))
        \\RETURN length(p)
    , &.{&.{int(0)}});
}

test "a WHERE that reads the path picks the shortest path it keeps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createNetwork(&ast, &g);

    // Avoiding locked places: of the two shortest routes, the one through e
    // is out; the one through f stays.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = shortestPath((a)-[*]->(d))
        \\WHERE none(n IN nodes(p) WHERE coalesce(n.locked, false))
        \\RETURN [n IN nodes(p) | n.name] AS route
    , &.{&.{strings(&.{ "a", "f", "d" })}});
    // By ROAD only, every route has a locked place (e at length 2, b at
    // length 3): nothing.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = shortestPath((a)-[:ROAD*]->(d))
        \\WHERE none(n IN nodes(p) WHERE coalesce(n.locked, false))
        \\RETURN p
    , &.{});
    // A WHERE on the relationships: short hops only, so the 3-hop route.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (d:Place {name: 'd'})
        \\MATCH p = shortestPath((a)-[r*]->(d))
        \\WHERE all(x IN r WHERE x.km < 2)
        \\RETURN length(p)
    , &.{&.{int(3)}});
    // A WHERE that does not read the path filters the ends as usual.
    try expectQuery(&ast, &g,
        \\MATCH (a:Place {name: 'a'}), (x:Place)
        \\MATCH p = shortestPath((a)-[*]->(x))
        \\WHERE x.name IN ['c', 'g']
        \\RETURN x.name, length(p) ORDER BY x.name
    , &.{ &.{ string("c"), int(2) }, &.{ string("g"), int(3) } });
}

test "shortestPath takes one variable-length relationship" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    const invalid = [_][]const u8{
        "MATCH p = shortestPath((a)-[r]->(b)) RETURN p",
        "MATCH p = shortestPath((a)-[*2..5]->(b)) RETURN p",
        "MATCH p = shortestPath((a)-[*]->(b)-[*]->(c)) RETURN p",
        "MATCH p = allShortestPaths((a)) RETURN p",
    };
    for (invalid) |query| try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, query, null));
}
