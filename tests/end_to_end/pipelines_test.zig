//! Multi-stage queries: WITH, OPTIONAL MATCH, lists and UNWIND.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;

const support = @import("../support.zig");
const openStore = support.openStore;
const loadMoviesGraph = support.loadMoviesGraph;
const expectQuery = support.expectQuery;
const expectOrdered = support.expectOrdered;

test "WITH pipeline: aggregation, filter, passthrough and pagination" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // WITH aggregation + WHERE filter on the aggregate.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 RETURN p.name, cnt", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .int = 3 } },
    });

    // WITH passthrough + continued MATCH traversal.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 MATCH (p)-[:ACTED_IN]->(m2:Movie) RETURN m2.title", &.{
        &.{.{ .string = "The Matrix" }},
        &.{.{ .string = "The Matrix Reloaded" }},
        &.{.{ .string = "John Wick" }},
    });

    // WITH scalar alias projection.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) WITH p.name AS n RETURN n", &.{
        &.{.{ .string = "Keanu Reeves" }},
    });

    // WITH ORDER BY + SKIP + LIMIT (pagination mid-query).
    try expectOrdered(&ast, &g, "MATCH (p:Person) WITH p ORDER BY p.name SKIP 1 LIMIT 2 RETURN p.name", &.{
        &.{.{ .string = "Keanu Reeves" }},
        &.{.{ .string = "Lana Wachowski" }},
    });
}

test "OPTIONAL MATCH: outer join and nulls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Unmatched optional pattern yields a null title.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Lana Wachowski'}) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) RETURN p.name, m.title", &.{
        &.{ .{ .string = "Lana Wachowski" }, .{ .null = {} } },
    });

    // Full outer join: each person with every acted movie, or null when none.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) RETURN p.name, m.title", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .string = "The Matrix" } },
        &.{ .{ .string = "Keanu Reeves" }, .{ .string = "The Matrix Reloaded" } },
        &.{ .{ .string = "Keanu Reeves" }, .{ .string = "John Wick" } },
        &.{ .{ .string = "Carrie-Anne Moss" }, .{ .string = "The Matrix" } },
        &.{ .{ .string = "Laurence Fishburne" }, .{ .string = "The Matrix" } },
        &.{ .{ .string = "Lana Wachowski" }, .{ .null = {} } },
        &.{ .{ .string = "Tom Hanks" }, .{ .string = "Forrest Gump" } },
    });

    // count skips nulls: people with no DIRECTED movie count as 0.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m:Movie) RETURN p.name, count(m)", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .int = 0 } },
        &.{ .{ .string = "Carrie-Anne Moss" }, .{ .int = 0 } },
        &.{ .{ .string = "Laurence Fishburne" }, .{ .int = 0 } },
        &.{ .{ .string = "Lana Wachowski" }, .{ .int = 2 } },
        &.{ .{ .string = "Tom Hanks" }, .{ .int = 0 } },
    });

    // WHERE inside OPTIONAL MATCH: a person whose matches are all filtered out
    // still yields one null row (the outer-join fallback).
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2010 RETURN p.name, m.title", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .string = "John Wick" } },
        &.{ .{ .string = "Carrie-Anne Moss" }, .{ .null = {} } },
        &.{ .{ .string = "Laurence Fishburne" }, .{ .null = {} } },
        &.{ .{ .string = "Lana Wachowski" }, .{ .null = {} } },
        &.{ .{ .string = "Tom Hanks" }, .{ .null = {} } },
    });

    // A null comparison in a post-join filter (via WITH) drops the row.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) WITH p, m WHERE m.released >= 2010 RETURN p.name, m.title", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .string = "John Wick" } },
    });
}

test "lists: collect, size, list literals and UNWIND" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

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
            .{ .string = "The Matrix" },
            .{ .string = "The Matrix Reloaded" },
            .{ .string = "John Wick" },
            .{ .string = "Forrest Gump" },
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

test "any sequence of clauses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Writes, then WITH, then reading again in the same query.
    try expectQuery(&ast, &g,
        \\CREATE (w:Worker {name: 'Ana'}), (e:Group {name: 'Engineering'}), (s:Group {name: 'Staff'}),
        \\       (w)-[:MEMBER_OF]->(e), (w)-[:MEMBER_OF]->(s),
        \\       (e)-[:MAY_ENTER]->(:Zone {name: 'Lab', opens: 9, closes: 18}),
        \\       (s)-[:MAY_ENTER]->(:Zone {name: 'Hall', opens: 7, closes: 22})
        \\WITH w
        \\MATCH (w)-[:MEMBER_OF]->(g)
        \\RETURN count(g)
    , &.{&.{.{ .int = 2 }}});

    // Several WITH steps, MATCH after MATCH, UNWIND after WITH.
    try expectQuery(&ast, &g,
        \\MATCH (w:Worker {name: 'Ana'})-[:MEMBER_OF]->(g)
        \\WITH w, collect(g.name) AS groups
        \\UNWIND groups AS group_name
        \\MATCH (g:Group {name: group_name})-[:MAY_ENTER]->(z)
        \\WITH z WHERE z.opens <= 8
        \\RETURN z.name
    , &.{&.{.{ .string = "Hall" }}});

    // OPTIONAL MATCH after OPTIONAL MATCH, each an outer join of its own.
    try expectQuery(&ast, &g,
        \\MATCH (g:Group)
        \\OPTIONAL MATCH (g)-[:MAY_ENTER]->(z {opens: 9})
        \\OPTIONAL MATCH (g)<-[:MEMBER_OF]-(w)
        \\RETURN g.name, z.name, w.name
    , &.{
        &.{ .{ .string = "Engineering" }, .{ .string = "Lab" }, .{ .string = "Ana" } },
        &.{ .{ .string = "Staff" }, .{ .null = {} }, .{ .string = "Ana" } },
    });
}

test "clause order rules" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    const parse = acmedb.parser.parse;

    // Reading after an update needs a WITH; RETURN comes last; a query cannot
    // end with a reading clause.
    try testing.expectError(error.UnexpectedToken, parse(&ast, "CREATE (a) MATCH (b) RETURN b", null));
    _ = try parse(&ast, "CREATE (a) WITH a MATCH (b) RETURN b", null);
    try testing.expectError(error.UnexpectedToken, parse(&ast, "RETURN 1 MATCH (n)", null));
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (n)", null));
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (n) WITH n", null));
}
