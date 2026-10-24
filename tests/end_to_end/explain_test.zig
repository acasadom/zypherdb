//! EXPLAIN and PROFILE: the plan as rows `[depth, operator, details,
//! estimated_rows, rows, time_ms]`, from the result down to the scans.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const Value = acmedb.Value;
const Executor = acmedb.Executor;

const support = @import("../support.zig");
const openStore = support.openStore;
const loadMoviesGraph = support.loadMoviesGraph;
const expectQuery = support.expectQuery;

/// One line of a plan, as a test expects it.
const Line = struct { depth: i64, operator: []const u8, details: []const u8, estimated_rows: ?i64 = null, rows: ?i64 = null };

/// Runs `src` (an EXPLAIN or PROFILE) and checks its lines in order. The
/// estimate is checked where the test gives one; the rows, in PROFILE.
fn expectPlan(ast: *Ast, g: *Graph, src: []const u8, expected: []const Line) !void {
    const query = try acmedb.parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    const rows = try executor.run(query);
    errdefer for (rows) |row| std.debug.print("{any}\n", .{row.items});
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |line, row| {
        const cells = row.items;
        try testing.expectEqual(@as(usize, 6), cells.len);
        try testing.expectEqual(line.depth, cells[0].int);
        try testing.expectEqualStrings(line.operator, cells[1].string);
        try testing.expectEqualStrings(line.details, cells[2].string);
        if (line.estimated_rows) |estimate| try testing.expectEqual(estimate, cells[3].int);
        if (line.rows) |made| {
            try testing.expectEqual(made, cells[4].int);
            try testing.expect(cells[5] == .float and cells[5].float >= 0);
        }
    }
}

test "EXPLAIN shows the plan from the result down to the anchor, with estimates" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // 4 movies, 5 people, 6 ACTED_IN: the movies are the anchor, each has
    // 1.5 actors on average.
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN m.title", &.{
        .{ .depth = 0, .operator = "Return", .details = "m.title", .estimated_rows = 6 },
        .{ .depth = 0, .operator = "Expand(All)", .details = "(m:Movie)<-[:ACTED_IN]-(p:Person)", .estimated_rows = 6 },
        .{ .depth = 0, .operator = "NodeByLabelScan", .details = "(m:Movie)", .estimated_rows = 4 },
    });
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person {name: $name}) WHERE p.born > 1960 RETURN count(*) AS n", &.{
        .{ .depth = 0, .operator = "Return", .details = "count(*) AS n", .estimated_rows = 1 },
        .{ .depth = 0, .operator = "Aggregation", .details = "count(*) AS n", .estimated_rows = 1 },
        .{ .depth = 0, .operator = "Filter", .details = "p.born > 1960", .estimated_rows = 1 },
        .{ .depth = 0, .operator = "NodeIndexSeek", .details = "(p:Person {name: $name})", .estimated_rows = 1 },
    });
    try expectPlan(&ast, &g, "EXPLAIN MATCH (m:Movie) WHERE m.released >= 2000 WITH m ORDER BY m.released LIMIT 2 RETURN m.title", &.{
        .{ .depth = 0, .operator = "Return", .details = "m.title", .estimated_rows = 1 },
        .{ .depth = 0, .operator = "Top", .details = "ORDER BY m.released LIMIT 2", .estimated_rows = 1 },
        .{ .depth = 0, .operator = "Projection", .details = "m", .estimated_rows = 1 },
        .{ .depth = 0, .operator = "Filter", .details = "m.released >= 2000", .estimated_rows = 1 },
        .{ .depth = 0, .operator = "NodeIndexRangeSeek", .details = "(m:Movie) WHERE 2000 <= m.released", .estimated_rows = 1 },
    });
}

test "EXPLAIN shows DISTINCT, ORDER BY, SKIP and LIMIT as stages of their own" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // ORDER BY with a LIMIT keeps SKIP + LIMIT rows (Top), then SKIP drops
    // some: no Limit is left to apply.
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) RETURN DISTINCT p.name ORDER BY p.name SKIP 1 LIMIT 2", &.{
        .{ .depth = 0, .operator = "Return", .details = "p.name", .estimated_rows = 2 },
        .{ .depth = 0, .operator = "Skip", .details = "SKIP 1", .estimated_rows = 2 },
        .{ .depth = 0, .operator = "Top", .details = "ORDER BY p.name LIMIT 1 + 2", .estimated_rows = 3 },
        .{ .depth = 0, .operator = "Distinct", .details = "p.name", .estimated_rows = 5 },
        .{ .depth = 0, .operator = "Projection", .details = "p.name", .estimated_rows = 5 },
        .{ .depth = 0, .operator = "NodeByLabelScan", .details = "(p:Person)", .estimated_rows = 5 },
    });
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) WITH p SKIP 1 LIMIT 2 RETURN p.name ORDER BY p.name", &.{
        .{ .depth = 0, .operator = "Return", .details = "p.name", .estimated_rows = 2 },
        .{ .depth = 0, .operator = "Sort", .details = "ORDER BY p.name", .estimated_rows = 2 },
        .{ .depth = 0, .operator = "Projection", .details = "p.name", .estimated_rows = 2 },
        .{ .depth = 0, .operator = "Limit", .details = "LIMIT 2", .estimated_rows = 2 },
        .{ .depth = 0, .operator = "Skip", .details = "SKIP 1", .estimated_rows = 4 },
        .{ .depth = 0, .operator = "Projection", .details = "p", .estimated_rows = 5 },
        .{ .depth = 0, .operator = "NodeByLabelScan", .details = "(p:Person)", .estimated_rows = 5 },
    });
}

test "EXPLAIN shows the chains an operator runs one level deeper" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m) RETURN p.name, m.title", &.{
        .{ .depth = 0, .operator = "Return", .details = "p.name, m.title" },
        .{ .depth = 0, .operator = "Optional", .details = "(p)-[:DIRECTED]->(m)" },
        .{ .depth = 1, .operator = "Expand(All)", .details = "(p)-[:DIRECTED]->(m)" },
        .{ .depth = 1, .operator = "BoundNode", .details = "(p)" },
        .{ .depth = 0, .operator = "NodeByLabelScan", .details = "(p:Person)" },
    });
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:ACTED_IN]->(:Movie {released: 1999}) } RETURN p.name", &.{
        .{ .depth = 0, .operator = "Return", .details = "p.name" },
        .{ .depth = 0, .operator = "Filter", .details = "EXISTS {…}" },
        .{ .depth = 1, .operator = "Exists", .details = "EXISTS {…}" },
        .{ .depth = 2, .operator = "Expand(All)", .details = "(p)-[:ACTED_IN]->(:Movie {released: 1999})" },
        .{ .depth = 2, .operator = "BoundNode", .details = "(p)" },
        .{ .depth = 0, .operator = "NodeByLabelScan", .details = "(p:Person)" },
    });
    try expectPlan(&ast, &g, "EXPLAIN MATCH (m:Movie) RETURN m.title AS name UNION ALL MATCH (p:Person) RETURN p.name AS name", &.{
        .{ .depth = 0, .operator = "UnionAll", .details = "" },
        .{ .depth = 1, .operator = "Return", .details = "m.title AS name" },
        .{ .depth = 1, .operator = "NodeByLabelScan", .details = "(m:Movie)" },
        .{ .depth = 1, .operator = "Return", .details = "p.name AS name" },
        .{ .depth = 1, .operator = "NodeByLabelScan", .details = "(p:Person)" },
    });
}

test "PROFILE runs the query and counts each operator's rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectPlan(&ast, &g, "PROFILE MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released < 2000 RETURN DISTINCT p.name", &.{
        .{ .depth = 0, .operator = "Return", .details = "p.name", .rows = 4 },
        .{ .depth = 0, .operator = "Distinct", .details = "p.name", .rows = 4 },
        .{ .depth = 0, .operator = "Projection", .details = "p.name", .rows = 4 },
        .{ .depth = 0, .operator = "Filter", .details = "m.released < 2000", .rows = 4 },
        .{ .depth = 0, .operator = "Expand(All)", .details = "(m:Movie)<-[:ACTED_IN]-(p:Person)", .rows = 4 },
        .{ .depth = 0, .operator = "NodeIndexRangeSeek", .details = "(m:Movie) WHERE m.released <= 2000", .rows = 2 },
    });
    try expectPlan(&ast, &g, "PROFILE MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m) RETURN count(m) AS directed", &.{
        .{ .depth = 0, .operator = "Return", .details = "count(m) AS directed", .rows = 1 },
        .{ .depth = 0, .operator = "Aggregation", .details = "count(m) AS directed", .rows = 1 },
        .{ .depth = 0, .operator = "Optional", .details = "(p)-[:DIRECTED]->(m)", .rows = 6 },
        .{ .depth = 1, .operator = "Expand(All)", .details = "(p)-[:DIRECTED]->(m)", .rows = 2 },
        .{ .depth = 1, .operator = "BoundNode", .details = "(p)", .rows = 5 },
        .{ .depth = 0, .operator = "NodeByLabelScan", .details = "(p:Person)", .rows = 5 },
    });
    // Each stage of a WITH counts the rows it keeps.
    try expectPlan(&ast, &g, "PROFILE MATCH (p:Person) WITH p ORDER BY p.name SKIP 1 LIMIT 2 RETURN p.name", &.{
        .{ .depth = 0, .operator = "Return", .details = "p.name", .rows = 2 },
        .{ .depth = 0, .operator = "Skip", .details = "SKIP 1", .rows = 2 },
        .{ .depth = 0, .operator = "Top", .details = "ORDER BY p.name LIMIT 1 + 2", .rows = 3 },
        .{ .depth = 0, .operator = "Projection", .details = "p", .rows = 5 },
        .{ .depth = 0, .operator = "NodeByLabelScan", .details = "(p:Person)", .rows = 5 },
    });
}

test "PROFILE commits what the query writes; EXPLAIN writes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectPlan(&ast, &g, "EXPLAIN UNWIND [1, 2, 3] AS i CREATE (:Event {n: i})", &.{
        .{ .depth = 0, .operator = "EmptyResult", .details = "", .estimated_rows = 3 },
        .{ .depth = 0, .operator = "Create", .details = "(:Event {n: i})", .estimated_rows = 3 },
        .{ .depth = 0, .operator = "Eager", .details = "", .estimated_rows = 3 },
        .{ .depth = 0, .operator = "Unwind", .details = "[1, 2, 3] AS i", .estimated_rows = 3 },
    });
    try expectQuery(&ast, &g, "MATCH (e:Event) RETURN count(e)", &.{&.{.{ .int = 0 }}});
    try expectPlan(&ast, &g, "PROFILE UNWIND [1, 2, 3] AS i CREATE (:Event {n: i})", &.{
        .{ .depth = 0, .operator = "EmptyResult", .details = "", .rows = 3 },
        .{ .depth = 0, .operator = "Create", .details = "(:Event {n: i})", .rows = 3 },
        .{ .depth = 0, .operator = "Eager", .details = "", .rows = 3 },
        .{ .depth = 0, .operator = "Unwind", .details = "[1, 2, 3] AS i", .rows = 3 },
    });
    try expectQuery(&ast, &g, "MATCH (e:Event) RETURN count(e)", &.{&.{.{ .int = 3 }}});
}

test "EXPLAIN takes a query, not a schema command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator());
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "EXPLAIN SHOW INDEXES", null));
}
