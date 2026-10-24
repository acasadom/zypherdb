//! Prepared statements: parsed, checked and planned once, run with new
//! parameters, planned again when the graph's counts drift; and the cache
//! of statements `query` calls keep.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Graph = acmedb.Graph;
const Value = acmedb.Value;
const Statement = acmedb.Statement;
const StatementCache = acmedb.StatementCache;

const support = @import("../support.zig");
const openStore = support.openStore;
const loadMoviesGraph = support.loadMoviesGraph;
const expectRows = support.expectRows;

/// Runs `statement` with `parameters`, asserting its rows.
fn expectStatement(statement: *Statement, g: *Graph, parameters: []const struct { []const u8, Value }, expected: []const []const Value) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = statement.executorFor(g, arena.allocator());
    for (parameters) |parameter| try executor.parameters.put(arena.allocator(), parameter[0], parameter[1]);
    try expectRows(try statement.run(&executor), expected);
}

test "a prepared statement runs again with new parameters" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    const statement = try Statement.prepare(testing.allocator, "MATCH (p:Person {name: $name})-[:ACTED_IN]->(m:Movie) WHERE m.released > $after RETURN m.title, m.released AS year", .{ .graph = &g });
    defer statement.destroy();
    try testing.expectEqual(@as(usize, 2), statement.parameter_names.len);
    try testing.expectEqualStrings("name", statement.parameter_names[0]);
    try testing.expectEqualStrings("after", statement.parameter_names[1]);
    try testing.expectEqual(@as(usize, 2), statement.columns.len);
    try testing.expectEqualStrings("m.title", statement.columns[0]);
    try testing.expectEqualStrings("year", statement.columns[1]);

    try expectStatement(statement, &g, &.{ .{ "name", .{ .string = "Keanu Reeves" } }, .{ "after", .{ .int = 2000 } } }, &.{
        &.{ .{ .string = "The Matrix Reloaded" }, .{ .int = 2003 } },
        &.{ .{ .string = "John Wick" }, .{ .int = 2014 } },
    });
    try expectStatement(statement, &g, &.{ .{ "name", .{ .string = "Tom Hanks" } }, .{ "after", .{ .int = 1990 } } }, &.{
        &.{ .{ .string = "Forrest Gump" }, .{ .int = 1994 } },
    });
    try testing.expectEqual(@as(usize, 1), statement.plans_made);
}

test "a statement that writes commits each run, and sees the runs before it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    const create = try Statement.prepare(testing.allocator, "CREATE (:Event {n: $n})", .{ .graph = &g });
    defer create.destroy();
    const count = try Statement.prepare(testing.allocator, "MATCH (e:Event) RETURN count(e), sum(e.n)", .{ .graph = &g });
    defer count.destroy();
    try testing.expectEqual(@as(usize, 0), create.columns.len);
    for (1..4) |n| try expectStatement(create, &g, &.{.{ "n", .{ .int = @intCast(n) } }}, &.{});
    try expectStatement(count, &g, &.{}, &.{&.{ .{ .int = 3 }, .{ .int = 6 } }});
}

test "a statement plans again when a count it was planned on drifts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // Planned on an empty graph: Person and City counts are 0.
    const statement = try Statement.prepare(testing.allocator, "MATCH (p:Person)-[:LIVES_IN]->(c:City) RETURN count(*)", .{ .graph = &g });
    defer statement.destroy();
    try expectStatement(statement, &g, &.{}, &.{&.{.{ .int = 0 }}});
    try testing.expectEqual(@as(usize, 1), statement.plans_made);

    // A few nodes more: below the floor, the plan stays.
    try g.beginWrite();
    for (0..Statement.drift_floor - 1) |i| try g.addNode(@intCast(i), "City");
    try g.commitWrite();
    try expectStatement(statement, &g, &.{}, &.{&.{.{ .int = 0 }}});
    try testing.expectEqual(@as(usize, 1), statement.plans_made);

    try g.beginWrite();
    for (Statement.drift_floor..2 * Statement.drift_floor) |i| try g.addNode(@intCast(i), "City");
    _ = try g.addEdge(Statement.drift_floor, 0, "LIVES_IN");
    try g.addNode(Statement.drift_floor, "Person");
    try g.commitWrite();
    try expectStatement(statement, &g, &.{}, &.{&.{.{ .int = 1 }}});
    try testing.expectEqual(@as(usize, 2), statement.plans_made);
}

test "EXPLAIN and schema commands are parsed again on each run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    const explain = try Statement.prepare(testing.allocator, "EXPLAIN MATCH (m:Movie) RETURN m", .{ .graph = &g });
    defer explain.destroy();
    try testing.expect(!explain.is_query);
    for (0..2) |_| try expectStatement(explain, &g, &.{}, &.{
        &.{ .{ .int = 0 }, .{ .string = "Return" }, .{ .string = "m" }, .{ .int = 4 }, .null, .null },
        &.{ .{ .int = 0 }, .{ .string = "NodeByLabelScan" }, .{ .string = "(m:Movie)" }, .{ .int = 4 }, .null, .null },
    });
}

test "preparing a statement that does not parse or check fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var diagnostic = acmedb.Diagnostic.init();
    try testing.expectError(error.ParseFailed, Statement.prepare(testing.allocator, "MATCH (n RETURN n", .{ .graph = &g, .diagnostic = &diagnostic }));
    try testing.expect(diagnostic.message().len > 0);
    try testing.expectError(error.InvalidExpression, Statement.prepare(testing.allocator, "MATCH (n) RETURN m", .{ .graph = &g, .diagnostic = &diagnostic }));
}

test "the statement cache keeps the most recently used" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var cache = StatementCache.init(testing.allocator);
    defer cache.deinit();
    cache.capacity = 2;
    const texts = [_][]const u8{ "RETURN 1", "RETURN 2", "RETURN 3" };
    cache.put(try Statement.prepare(testing.allocator, texts[0], .{ .graph = &g }));
    cache.put(try Statement.prepare(testing.allocator, texts[1], .{ .graph = &g }));
    try testing.expect(cache.get(texts[0]) != null); // now the most recent
    cache.put(try Statement.prepare(testing.allocator, texts[2], .{ .graph = &g }));
    try testing.expect(cache.get(texts[0]) != null);
    try testing.expect(cache.get(texts[1]) == null);
    try testing.expect(cache.get(texts[2]) != null);
    cache.clear();
    try testing.expect(cache.get(texts[0]) == null);
}
