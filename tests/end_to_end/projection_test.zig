//! RETURN post-processing: DISTINCT, ORDER BY, SKIP and LIMIT.

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

test "ORDER BY, LIMIT and DISTINCT" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // ORDER BY ascending.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "John Wick" }},
    });

    // ORDER BY descending.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released DESC", &.{
        &.{.{ .str = "John Wick" }},
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "The Matrix" }},
    });

    // LIMIT after ORDER BY.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released LIMIT 2", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
    });

    // DISTINCT collapses duplicate projected rows.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie {title: 'The Matrix'}) RETURN DISTINCT m.title", &.{
        &.{.{ .str = "The Matrix" }},
    });
}

test "SKIP pagination in RETURN" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectOrdered(&ast, &g, "MATCH (m:Movie) RETURN m.title ORDER BY m.released SKIP 1 LIMIT 2", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
    });

    // SKIP without LIMIT.
    try expectOrdered(&ast, &g, "MATCH (m:Movie) RETURN m.title ORDER BY m.released SKIP 3", &.{
        &.{.{ .str = "John Wick" }},
    });
}

test "ORDER BY is stable: ties keep their match order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // People are matched in id order; the key only splits them in two.
    try expectOrdered(&ast, &g, "MATCH (p:Person) RETURN p.name ORDER BY p.born > 1962 DESC", &.{
        &.{.{ .str = "Keanu Reeves" }},
        &.{.{ .str = "Carrie-Anne Moss" }},
        &.{.{ .str = "Lana Wachowski" }},
        &.{.{ .str = "Laurence Fishburne" }},
        &.{.{ .str = "Tom Hanks" }},
    });
}
