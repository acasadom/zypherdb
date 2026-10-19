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

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // ORDER BY ascending.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released", &.{
        &.{.{ .string = "The Matrix" }},
        &.{.{ .string = "The Matrix Reloaded" }},
        &.{.{ .string = "John Wick" }},
    });

    // ORDER BY descending.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released DESC", &.{
        &.{.{ .string = "John Wick" }},
        &.{.{ .string = "The Matrix Reloaded" }},
        &.{.{ .string = "The Matrix" }},
    });

    // LIMIT after ORDER BY.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released LIMIT 2", &.{
        &.{.{ .string = "The Matrix" }},
        &.{.{ .string = "The Matrix Reloaded" }},
    });

    // DISTINCT collapses duplicate projected rows.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie {title: 'The Matrix'}) RETURN DISTINCT m.title", &.{
        &.{.{ .string = "The Matrix" }},
    });
}

test "SKIP pagination in RETURN" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectOrdered(&ast, &g, "MATCH (m:Movie) RETURN m.title ORDER BY m.released SKIP 1 LIMIT 2", &.{
        &.{.{ .string = "The Matrix" }},
        &.{.{ .string = "The Matrix Reloaded" }},
    });

    // SKIP without LIMIT.
    try expectOrdered(&ast, &g, "MATCH (m:Movie) RETURN m.title ORDER BY m.released SKIP 3", &.{
        &.{.{ .string = "John Wick" }},
    });
}

test "ORDER BY is stable: ties keep their match order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // People are matched in id order; the key only splits them in two.
    try expectOrdered(&ast, &g, "MATCH (p:Person) RETURN p.name ORDER BY p.born > 1962 DESC", &.{
        &.{.{ .string = "Keanu Reeves" }},
        &.{.{ .string = "Carrie-Anne Moss" }},
        &.{.{ .string = "Lana Wachowski" }},
        &.{.{ .string = "Laurence Fishburne" }},
        &.{.{ .string = "Tom Hanks" }},
    });
}

test "ORDER BY sees RETURN aliases, projected expressions and aggregates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // An alias of the RETURN clause.
    try expectOrdered(&ast, &g, "MATCH (m:Movie) RETURN m.title AS title ORDER BY title LIMIT 2", &.{
        &.{.{ .string = "Forrest Gump" }},
        &.{.{ .string = "John Wick" }},
    });
    // Aggregated rows ordered by an aggregate alias (used to crash) ...
    try expectOrdered(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN p.name, count(*) AS movies ORDER BY movies DESC, p.name", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .int = 3 } },
        &.{ .{ .string = "Carrie-Anne Moss" }, .{ .int = 1 } },
        &.{ .{ .string = "Laurence Fishburne" }, .{ .int = 1 } },
        &.{ .{ .string = "Tom Hanks" }, .{ .int = 1 } },
    });
    // ... and by a repeated aggregate expression.
    try expectOrdered(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN p.name, count(*) ORDER BY count(*) DESC LIMIT 1", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .int = 3 } },
    });
    // A variable that is not projected cannot order aggregated rows.
    try expectQueryError(&ast, &g, "MATCH (p:Person) RETURN count(*) ORDER BY p.born", error.UnknownVariable);
}
