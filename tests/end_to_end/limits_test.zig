//! Size limits: names, labels per node, values and full-text positions,
//! refused with an error (or stored) at the edges of what the storage
//! formats can count, never past them.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn expectSound(g: *Graph) !void {
    var report = try zypherdb.integrity.check(g, testing.allocator);
    defer report.deinit();
    for (report.problems.items) |problem| std.debug.print("integrity: {s}\n", .{problem});
    try testing.expect(report.ok());
}

test "a term may occur more often in a text than a u16 counts" {
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

    const occurrences = 70_000;
    const text = try allocator.alloc(u8, occurrences * 4);
    for (0..occurrences) |i| @memcpy(text[i * 4 ..][0..4], "dog ");
    try expectQuery(&ast, &g, "CREATE FULLTEXT INDEX notes FOR (n:Note) ON EACH [n.text]", &.{});
    try expectQuery(&ast, &g, try std.fmt.allocPrint(allocator, "CREATE (:Note {{id: 1, text: '{s}'}})", .{text}), &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('notes', '\"dog dog\"') YIELD node RETURN node.id", &.{&.{int(1)}});
    try expectSound(&g);
}

test "names longer than keys can hold are refused, the longest allowed are stored" {
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

    const longest: [zypherdb.layout.max_name_length]u8 = @splat('a');
    const too_long = longest ++ "a";
    for ([_][2][]const u8{
        .{ "CREATE (:", ")" },
        .{ "CREATE ()-[:", "]->()" },
        .{ "CREATE ({", ": 1})" },
        .{ "CREATE INDEX ", " FOR (n:Note) ON (n.text)" },
        .{ "CREATE INDEX text FOR (n:Note) ON (n.", ")" },
        .{ "CREATE FULLTEXT INDEX notes FOR (n:Note) ON EACH [n.", "]" },
    }) |around| {
        try expectQuery(&ast, &g, try std.mem.concat(allocator, u8, &.{ around[0], &longest, around[1] }), &.{});
        try expectQueryError(&ast, &g, try std.mem.concat(allocator, u8, &.{ around[0], too_long, around[1] }), error.InvalidExpression);
    }
    // A path of names each short enough is still one name in its index.
    try expectQueryError(&ast, &g, try std.fmt.allocPrint(allocator, "CREATE INDEX FOR (n:Note) ON (n.{s}.{s})", .{ longest[0..600], longest[0..600] }), error.InvalidExpression);
    try expectSound(&g);
}

test "a full-text index numbers at most 256 properties" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for ([_]usize{ 256, 257 }) |count| {
        var text = std.ArrayList(u8).empty;
        try text.print(allocator, "CREATE FULLTEXT INDEX notes_{d} FOR (n:Note) ON EACH [", .{count});
        for (0..count) |i| try text.print(allocator, "{s}n.p{d}", .{ if (i > 0) ", " else "", i });
        try text.append(allocator, ']');
        if (count == 256) try expectQuery(&ast, &g, text.items, &.{}) else try expectQueryError(&ast, &g, text.items, error.InvalidExpression);
    }
    try expectQuery(&ast, &g, "CREATE (:Note {p255: 'last property'})", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('notes_256', 'last') YIELD node RETURN node.p255", &.{&.{.{ .string = "last property" }}});
    try expectSound(&g);
}

test "a node holds at most 65535 labels" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Adding the labels one by one rewrites the record each time: the full
    // record is written whole instead (labels L00000.. sort as numbered).
    var record = std.ArrayList(u8).empty;
    try record.appendSlice(allocator, &.{ 0xff, 0xff });
    for (0..zypherdb.layout.max_labels) |i| try record.print(allocator, "\x00\x06L{d:0>5}", .{i});
    try record.appendSlice(allocator, &.{ 0, 0, 0, 0 });
    try g.beginWrite();
    defer g.abortWrite();
    try g.store.putNode(1, record.items);
    try g.addLabel(1, "L00007"); // has it already
    try testing.expectError(error.TooManyLabels, g.addLabel(1, "Z"));
}
