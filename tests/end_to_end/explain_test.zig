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
const Snap = @import("../snapshot.zig").Snap;
const snap = @import("../snapshot.zig").snap;

/// Runs `src` (an EXPLAIN or PROFILE) and prints its plan, one operator per
/// line, indented by depth, with the estimate and, in PROFILE, the rows (the
/// time is only checked to be a number of milliseconds).
fn planText(ast: *Ast, g: *Graph, src: []const u8) ![]const u8 {
    const query = try acmedb.parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    const rows = try executor.run(query);
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer text.deinit();
    for (rows) |row| {
        const cells = row.items;
        try testing.expectEqual(@as(usize, 6), cells.len);
        for (0..@intCast(cells[0].int)) |_| try text.writer.writeAll("    ");
        try text.writer.writeAll(cells[1].string);
        if (cells[2].string.len > 0) try text.writer.print(" {s}", .{cells[2].string});
        if (cells[3] == .int) try text.writer.print("  [estimated {d}", .{cells[3].int}) else try text.writer.writeAll("  [estimated -");
        if (cells[4] == .int) {
            try testing.expect(cells[5] == .float and cells[5].float >= 0);
            try text.writer.print(", rows {d}", .{cells[4].int});
        }
        try text.writer.writeAll("]\n");
    }
    return text.toOwnedSlice();
}

/// Checks the plan of `src` against the snapshot.
fn expectPlan(ast: *Ast, g: *Graph, src: []const u8, expected: Snap) !void {
    const text = try planText(ast, g, src);
    defer testing.allocator.free(text);
    try expected.diff(text);
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
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN m.title", snap(@src(),
        \\Return m.title  [estimated 6]
        \\Expand(All) (m:Movie)<-[:ACTED_IN]-(p:Person)  [estimated 6]
        \\NodeByLabelScan (m:Movie)  [estimated 4]
    ));
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person {name: $name}) WHERE p.born > 1960 RETURN count(*) AS n", snap(@src(),
        \\Return count(*) AS n  [estimated 1]
        \\Aggregation count(*) AS n  [estimated 1]
        \\Filter p.born > 1960  [estimated 1]
        \\NodeIndexSeek (p:Person {name: $name})  [estimated 1]
    ));
    try expectPlan(&ast, &g, "EXPLAIN MATCH (m:Movie) WHERE m.released >= 2000 WITH m ORDER BY m.released LIMIT 2 RETURN m.title", snap(@src(),
        \\Return m.title  [estimated 1]
        \\Top ORDER BY m.released LIMIT 2  [estimated 1]
        \\Projection m  [estimated 1]
        \\Filter m.released >= 2000  [estimated 1]
        \\NodeIndexRangeSeek (m:Movie) WHERE 2000 <= m.released  [estimated 1]
    ));
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
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) RETURN DISTINCT p.name ORDER BY p.name SKIP 1 LIMIT 2", snap(@src(),
        \\Return p.name  [estimated 2]
        \\Skip SKIP 1  [estimated 2]
        \\Top ORDER BY p.name LIMIT 1 + 2  [estimated 3]
        \\Distinct p.name  [estimated 5]
        \\Projection p.name  [estimated 5]
        \\NodeByLabelScan (p:Person)  [estimated 5]
    ));
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) WITH p SKIP 1 LIMIT 2 RETURN p.name ORDER BY p.name", snap(@src(),
        \\Return p.name  [estimated 2]
        \\Sort ORDER BY p.name  [estimated 2]
        \\Projection p.name  [estimated 2]
        \\Limit LIMIT 2  [estimated 2]
        \\Skip SKIP 1  [estimated 4]
        \\Projection p  [estimated 5]
        \\NodeByLabelScan (p:Person)  [estimated 5]
    ));
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

    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m) RETURN p.name, m.title", snap(@src(),
        \\Return p.name, m.title  [estimated 5]
        \\Optional (p)-[:DIRECTED]->(m)  [estimated 5]
        \\    Expand(All) (p)-[:DIRECTED]->(m)  [estimated -]
        \\    BoundNode (p)  [estimated 1]
        \\NodeByLabelScan (p:Person)  [estimated 5]
    ));
    try expectPlan(&ast, &g, "EXPLAIN MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:ACTED_IN]->(:Movie {released: 1999}) } RETURN p.name", snap(@src(),
        \\Return p.name  [estimated 5]
        \\Filter EXISTS {…}  [estimated 5]
        \\    Exists EXISTS {…}  [estimated -]
        \\        Expand(All) (p)-[:ACTED_IN]->(:Movie {released: 1999})  [estimated -]
        \\        BoundNode (p)  [estimated 1]
        \\NodeByLabelScan (p:Person)  [estimated 5]
    ));
    try expectPlan(&ast, &g, "EXPLAIN MATCH (m:Movie) RETURN m.title AS name UNION ALL MATCH (p:Person) RETURN p.name AS name", snap(@src(),
        \\UnionAll  [estimated -]
        \\    Return m.title AS name  [estimated 4]
        \\    NodeByLabelScan (m:Movie)  [estimated 4]
        \\    Return p.name AS name  [estimated 5]
        \\    NodeByLabelScan (p:Person)  [estimated 5]
    ));
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

    try expectPlan(&ast, &g, "PROFILE MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released < 2000 RETURN DISTINCT p.name", snap(@src(),
        \\Return p.name  [estimated 2, rows 4]
        \\Distinct p.name  [estimated 2, rows 4]
        \\Projection p.name  [estimated 2, rows 4]
        \\Filter m.released < 2000  [estimated 2, rows 4]
        \\Expand(All) (m:Movie)<-[:ACTED_IN]-(p:Person)  [estimated 2, rows 4]
        \\NodeIndexRangeSeek (m:Movie) WHERE m.released <= 2000  [estimated 1, rows 2]
    ));
    try expectPlan(&ast, &g, "PROFILE MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m) RETURN count(m) AS directed", snap(@src(),
        \\Return count(m) AS directed  [estimated 1, rows 1]
        \\Aggregation count(m) AS directed  [estimated 1, rows 1]
        \\Optional (p)-[:DIRECTED]->(m)  [estimated 5, rows 6]
        \\    Expand(All) (p)-[:DIRECTED]->(m)  [estimated -, rows 2]
        \\    BoundNode (p)  [estimated 1, rows 5]
        \\NodeByLabelScan (p:Person)  [estimated 5, rows 5]
    ));
    // Each stage of a WITH counts the rows it keeps.
    try expectPlan(&ast, &g, "PROFILE MATCH (p:Person) WITH p ORDER BY p.name SKIP 1 LIMIT 2 RETURN p.name", snap(@src(),
        \\Return p.name  [estimated 2, rows 2]
        \\Skip SKIP 1  [estimated 2, rows 2]
        \\Top ORDER BY p.name LIMIT 1 + 2  [estimated 3, rows 3]
        \\Projection p  [estimated 5, rows 5]
        \\NodeByLabelScan (p:Person)  [estimated 5, rows 5]
    ));
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

    try expectPlan(&ast, &g, "EXPLAIN UNWIND [1, 2, 3] AS i CREATE (:Event {n: i})", snap(@src(),
        \\EmptyResult  [estimated 3]
        \\Create (:Event {n: i})  [estimated 3]
        \\Eager  [estimated 3]
        \\Unwind [1, 2, 3] AS i  [estimated 3]
    ));
    try expectQuery(&ast, &g, "MATCH (e:Event) RETURN count(e)", &.{&.{.{ .int = 0 }}});
    try expectPlan(&ast, &g, "PROFILE UNWIND [1, 2, 3] AS i CREATE (:Event {n: i})", snap(@src(),
        \\EmptyResult  [estimated 3, rows 3]
        \\Create (:Event {n: i})  [estimated 3, rows 3]
        \\Eager  [estimated 3, rows 3]
        \\Unwind [1, 2, 3] AS i  [estimated 3, rows 3]
    ));
    try expectQuery(&ast, &g, "MATCH (e:Event) RETURN count(e)", &.{&.{.{ .int = 3 }}});
}

test "EXPLAIN takes a query, not a schema command" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator());
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "EXPLAIN SHOW INDEXES", null));
}

/// The operators of `query`'s plan with `options`, one per line.
fn operatorNames(ast: *Ast, g: *Graph, query: []const u8, options: acmedb.PlanOptions, allocator: std.mem.Allocator) ![]const u8 {
    const root = try acmedb.parser.parse(ast, try std.fmt.allocPrint(allocator, "EXPLAIN {s}", .{query}), null);
    var executor = Executor.init(ast, g, allocator);
    executor.plan_options = options;
    var names = std.ArrayList(u8).empty;
    for (try executor.run(root)) |row| try names.print(allocator, "{s}\n", .{row.items[1].string});
    return names.items;
}

/// The rows of `query` with `options`, printed and sorted.
fn sortedRows(ast: *Ast, g: *Graph, query: []const u8, options: acmedb.PlanOptions, allocator: std.mem.Allocator) ![]const []const u8 {
    var executor = Executor.init(ast, g, allocator);
    executor.plan_options = options;
    const rows = try executor.run(try acmedb.parser.parse(ast, query, null));
    const printed = try allocator.alloc([]const u8, rows.len);
    for (printed, rows) |*text, row| text.* = try std.fmt.allocPrint(allocator, "{any}", .{row.items});
    std.mem.sort([]const u8, printed, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return printed;
}

test "planner options change the plan, not the rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { query: []const u8, options: acmedb.PlanOptions, missing: []const u8 }{
        .{ .query = "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title", .options = .{ .index_lookups = false }, .missing = "NodeIndexSeek" },
        .{ .query = "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title", .options = .{ .anchor = .{ .position = 1 } }, .missing = "NodeIndexSeek" },
        .{ .query = "MATCH (m:Movie) WHERE m.released > 2000 RETURN m.title", .options = .{ .where_seeks = false }, .missing = "NodeIndexRangeSeek" },
        .{ .query = "MATCH (p:Person) RETURN p.name ORDER BY p.name SKIP 1 LIMIT 2", .options = .{ .top = false }, .missing = "Top" },
    };
    for (cases) |case| {
        const optimized = try operatorNames(&ast, &g, case.query, .{}, allocator);
        const plain = try operatorNames(&ast, &g, case.query, case.options, allocator);
        try testing.expect(std.mem.indexOf(u8, optimized, case.missing) != null);
        try testing.expect(std.mem.indexOf(u8, plain, case.missing) == null);
        const expected = try sortedRows(&ast, &g, case.query, .{}, allocator);
        const actual = try sortedRows(&ast, &g, case.query, case.options, allocator);
        try testing.expectEqual(expected.len, actual.len);
        for (expected, actual) |a, b| try testing.expectEqualStrings(a, b);
    }
}
