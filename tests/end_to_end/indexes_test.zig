//! Property indexes (CREATE INDEX): made explicitly, kept current by every
//! write, used by the plans that can, dropped with their entries.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;
const Statement = zypherdb.Statement;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectRows = support.expectRows;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn expectSound(g: *Graph) !void {
    var report = try zypherdb.integrity.check(g, testing.allocator);
    defer report.deinit();
    for (report.problems.items) |problem| std.debug.print("integrity: {s}\n", .{problem});
    try testing.expect(report.ok());
}

/// How many entries the property indexes hold, all of them.
fn indexEntries(g: *Graph) !usize {
    return g.store.countPrefix(&.{zypherdb.property_indexes.marker});
}

test "an index follows labels, properties and deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // No index, no entries: properties cost nothing more than their record.
    try expectQuery(&ast, &g, "CREATE (:Card {number: 1}), (:Card {number: 2}), (:Badge {number: 1})", &.{});
    try testing.expectEqual(@as(usize, 0), try indexEntries(&g));

    // Built from the cards there are (not the badge), then kept current.
    try expectQuery(&ast, &g, "CREATE INDEX cards FOR (c:Card) ON (c.number)", &.{});
    try testing.expectEqual(@as(usize, 2), try indexEntries(&g));
    try expectQuery(&ast, &g, "MATCH (b:Badge) SET b:Card", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 1}) RETURN count(c)", &.{&.{int(2)}});
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 2}) SET c.number = 3", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 1}) REMOVE c:Card", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 3}) RETURN c.number", &.{&.{int(3)}});
    try expectQuery(&ast, &g, "MATCH (c:Card) WHERE c.number >= 1 RETURN count(c)", &.{&.{int(1)}});
    try testing.expectEqual(@as(usize, 1), try indexEntries(&g));
    try expectSound(&g);

    try expectQuery(&ast, &g, "MATCH (c:Card) DETACH DELETE c", &.{});
    try testing.expectEqual(@as(usize, 0), try indexEntries(&g));

    // Dropping it removes its entries; the queries still answer (by label).
    try expectQuery(&ast, &g, "CREATE (:Card {number: 5})", &.{});
    try expectQuery(&ast, &g, "DROP INDEX cards", &.{});
    try testing.expectEqual(@as(usize, 0), try indexEntries(&g));
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 5}) RETURN c.number", &.{&.{int(5)}});
    try expectSound(&g);
}

test "a relationship index follows its type" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE INDEX FOR ()-[r:HELD_BY]-() ON (r.since)", &.{});
    try expectQuery(&ast, &g, "CREATE (a)-[:HELD_BY {since: 2020}]->(b), (a)-[:SEEN_BY {since: 2020}]->(b)", &.{});
    try testing.expectEqual(@as(usize, 1), try indexEntries(&g));
    try expectQuery(&ast, &g, "MATCH ()-[r:HELD_BY {since: 2020}]->() RETURN count(r)", &.{&.{int(1)}});
    try expectQuery(&ast, &g, "MATCH ()-[r {since: 2020}]->() RETURN count(r)", &.{&.{int(2)}});
    try expectQuery(&ast, &g, "MATCH ()-[r:HELD_BY]->() SET r.since = 2021", &.{});
    try expectQuery(&ast, &g, "MATCH ()-[r:HELD_BY {since: 2021}]->() RETURN count(r)", &.{&.{int(1)}});
    try expectSound(&g);
    try expectQuery(&ast, &g, "MATCH ()-[r:HELD_BY]->() DELETE r", &.{});
    try testing.expectEqual(@as(usize, 0), try indexEntries(&g));
    try expectSound(&g);
}

test "long values keep a prefix in the index and are checked whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Longer than any storage engine's key (about 2 KB with 4 KB pages),
    // and alike for their first 3000 bytes.
    const shared = try allocator.alloc(u8, 3000);
    @memset(shared, 'x');
    try expectQuery(&ast, &g, "CREATE INDEX FOR (n:Note) ON (n.text)", &.{});
    for ([_][]const u8{ "a", "b" }, 1..) |tail, id| {
        const text = try std.mem.concat(allocator, u8, &.{ shared, tail });
        try expectQuery(&ast, &g, try std.fmt.allocPrint(allocator, "CREATE (:Note {{id: {d}, text: '{s}'}})", .{ id, text }), &.{});
    }
    var keys = try g.store.scanPrefix(&.{zypherdb.property_indexes.marker});
    while (try keys.next()) |entry| try testing.expect(entry.key.len < 600);
    keys.deinit();

    const wanted = try std.mem.concat(allocator, u8, &.{ shared, "b" });
    try expectQuery(&ast, &g, try std.fmt.allocPrint(allocator, "MATCH (n:Note {{text: '{s}'}}) RETURN n.id", .{wanted}), &.{&.{int(2)}});
    try expectQuery(&ast, &g, try std.fmt.allocPrint(allocator, "MATCH (n:Note) WHERE n.text = '{s}' RETURN n.id", .{wanted}), &.{&.{int(2)}});
    try expectQuery(&ast, &g, try std.fmt.allocPrint(allocator, "MATCH (n:Note {{text: '{s}c'}}) RETURN n.id", .{shared}), &.{});
    try expectSound(&g);
}

test "a uniqueness constraint keeps its index, and long values are compared whole" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const shared = try allocator.alloc(u8, 1000);
    @memset(shared, 'k');
    try expectQuery(&ast, &g, "CREATE CONSTRAINT keys FOR (k:Key) REQUIRE k.value IS UNIQUE", &.{});
    try expectQuery(&ast, &g, try std.fmt.allocPrint(allocator, "CREATE (:Key {{value: '{s}a'}}), (:Key {{value: '{s}b'}})", .{ shared, shared }), &.{});
    try support.expectQueryError(&ast, &g, try std.fmt.allocPrint(allocator, "CREATE (:Key {{value: '{s}a'}})", .{shared}), error.ConstraintViolation);
    // Its index serves lookups too.
    try expectQuery(&ast, &g, try std.fmt.allocPrint(allocator, "MATCH (k:Key {{value: '{s}b'}}) RETURN count(k)", .{shared}), &.{&.{int(1)}});
    try expectQuery(&ast, &g, "DROP CONSTRAINT keys", &.{});
    try testing.expectEqual(@as(usize, 0), try indexEntries(&g));
    try expectSound(&g);
}

test "a prepared statement plans again when an index is made or dropped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try expectQuery(&ast, &g, "CREATE (:Card {number: 1}), (:Card {number: 2})", &.{});

    const statement = try Statement.prepare(testing.allocator, "MATCH (c:Card {number: $number}) RETURN c.number", .{ .graph = &g });
    defer statement.destroy();
    for ([_]?[]const u8{ null, "CREATE INDEX cards FOR (c:Card) ON (c.number)", "DROP INDEX cards" }, 1..) |command, plans| {
        if (command) |text| try expectQuery(&ast, &g, text, &.{});
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var executor = statement.executorFor(&g, arena.allocator());
        try executor.parameters.put(arena.allocator(), "number", int(2));
        try expectRows(try statement.run(&executor), &.{&.{int(2)}});
        try testing.expectEqual(plans, @as(usize, statement.plans_made));
        try testing.expectEqual(command != null and plans == 2, statement.plan.?.patterns[0].nodes[0].seek_index != null);
    }
}
