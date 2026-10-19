//! Aggregations and implicit grouping.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const NodeId = acmedb.NodeId;
const Value = acmedb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const loadSlice = support.loadMoviesGraph;
const expectQuery = support.expectQuery;
const expectOrdered = support.expectOrdered;
const expectQueryError = support.expectQueryError;

test "aggregations: count, sum, min and max with grouping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Count movies per actor (implicit GROUP BY p.name).
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN p.name, count(m)", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .int = 3 } },
        &.{ .{ .string = "Carrie-Anne Moss" }, .{ .int = 1 } },
        &.{ .{ .string = "Laurence Fishburne" }, .{ .int = 1 } },
        &.{ .{ .string = "Tom Hanks" }, .{ .int = 1 } },
    });

    // count(*) over all persons.
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN count(p)", &.{
        &.{.{ .int = 5 }},
    });

    // min/max released year.
    try expectQuery(&ast, &g, "MATCH (m:Movie) RETURN min(m.released), max(m.released)", &.{
        &.{ .{ .int = 1994 }, .{ .int = 2014 } },
    });

    // sum of birth years.
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN sum(p.born)", &.{
        &.{.{ .int = 9813 }},
    });
}

test "ungrouped aggregation over zero rows yields one row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "MATCH (x:Nope) RETURN count(*), count(x), sum(x.v), min(x.v), max(x.v)", &.{
        &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .null = {} }, .{ .null = {} } },
    });
    try expectQuery(&ast, &g, "MATCH (x:Nope) WITH count(x) AS c RETURN c", &.{
        &.{.{ .int = 0 }},
    });
    // With a grouping key, zero rows still yield zero groups.
    try expectQuery(&ast, &g, "MATCH (x:Nope) RETURN x.name, count(*)", &.{});
    try expectQuery(&ast, &g, "MATCH (x:Nope) WITH x.name AS n, count(*) AS c RETURN n, c", &.{});
}
