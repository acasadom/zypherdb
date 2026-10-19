//! Multi-stage queries: WITH, OPTIONAL MATCH, lists and UNWIND.

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

test "WITH pipeline: aggregation, filter, passthrough and pagination" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // WITH aggregation + WHERE filter on the aggregate.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 RETURN p.name, cnt", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .int = 3 } },
    });

    // WITH passthrough + continued MATCH traversal.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 MATCH (p)-[:ACTED_IN]->(m2:Movie) RETURN m2.title", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "John Wick" }},
    });

    // WITH scalar alias projection.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) WITH p.name AS n RETURN n", &.{
        &.{.{ .str = "Keanu Reeves" }},
    });

    // WITH ORDER BY + SKIP + LIMIT (pagination mid-query).
    try expectOrdered(&ast, &g, "MATCH (p:Person) WITH p ORDER BY p.name SKIP 1 LIMIT 2 RETURN p.name", &.{
        &.{.{ .str = "Keanu Reeves" }},
        &.{.{ .str = "Lana Wachowski" }},
    });
}

test "OPTIONAL MATCH: outer join and nulls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Unmatched optional pattern yields a null title.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Lana Wachowski'}) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) RETURN p.name, m.title", &.{
        &.{ .{ .str = "Lana Wachowski" }, .{ .null = {} } },
    });

    // Full outer join: each person with every acted movie, or null when none.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) RETURN p.name, m.title", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "The Matrix" } },
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "The Matrix Reloaded" } },
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "John Wick" } },
        &.{ .{ .str = "Carrie-Anne Moss" }, .{ .str = "The Matrix" } },
        &.{ .{ .str = "Laurence Fishburne" }, .{ .str = "The Matrix" } },
        &.{ .{ .str = "Lana Wachowski" }, .{ .null = {} } },
        &.{ .{ .str = "Tom Hanks" }, .{ .str = "Forrest Gump" } },
    });

    // count skips nulls: people with no DIRECTED movie count as 0.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m:Movie) RETURN p.name, count(m)", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .int = 0 } },
        &.{ .{ .str = "Carrie-Anne Moss" }, .{ .int = 0 } },
        &.{ .{ .str = "Laurence Fishburne" }, .{ .int = 0 } },
        &.{ .{ .str = "Lana Wachowski" }, .{ .int = 2 } },
        &.{ .{ .str = "Tom Hanks" }, .{ .int = 0 } },
    });

    // WHERE inside OPTIONAL MATCH: a person whose matches are all filtered out
    // still yields one null row (the outer-join fallback).
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2010 RETURN p.name, m.title", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "John Wick" } },
        &.{ .{ .str = "Carrie-Anne Moss" }, .{ .null = {} } },
        &.{ .{ .str = "Laurence Fishburne" }, .{ .null = {} } },
        &.{ .{ .str = "Lana Wachowski" }, .{ .null = {} } },
        &.{ .{ .str = "Tom Hanks" }, .{ .null = {} } },
    });

    // A null comparison in a post-join filter (via WITH) drops the row.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) WITH p, m WHERE m.released >= 2010 RETURN p.name, m.title", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "John Wick" } },
    });
}

test "lists: collect, size, list literals and UNWIND" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // size of a list literal.
    try expectQuery(&ast, &g, "RETURN size([1, 2, 3])", &.{
        &.{.{ .int = 3 }},
    });

    // size of a string.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) RETURN size(p.name)", &.{
        &.{.{ .int = 12 }},
    });

    // collect every movie title (scan order = ascending id).
    try expectQuery(&ast, &g, "MATCH (m:Movie) RETURN collect(m.title)", &.{
        &.{.{ .list = &.{
            .{ .str = "The Matrix" },
            .{ .str = "The Matrix Reloaded" },
            .{ .str = "John Wick" },
            .{ .str = "Forrest Gump" },
        } }},
    });

    // collect then size through WITH.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WITH collect(m.title) AS titles RETURN size(titles)", &.{
        &.{.{ .int = 4 }},
    });

    // UNWIND a list literal (no MATCH).
    try expectQuery(&ast, &g, "UNWIND [1, 2, 3] AS x RETURN x", &.{
        &.{.{ .int = 1 }},
        &.{.{ .int = 2 }},
        &.{.{ .int = 3 }},
    });

    // UNWIND after MATCH.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) UNWIND [1, 2] AS x RETURN x", &.{
        &.{.{ .int = 1 }},
        &.{.{ .int = 2 }},
    });
}
