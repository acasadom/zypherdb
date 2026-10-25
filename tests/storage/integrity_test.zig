//! The integrity checker (`acmedb.integrity`): it passes on a sound
//! database, and finds each kind of damage done to one by hand.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");
const support = @import("../support.zig");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const integrity = acmedb.integrity;

/// Expects the check to fail with one problem whose text contains `needle`.
fn expectProblem(g: *Graph, needle: []const u8) !void {
    var report = try integrity.check(g, testing.allocator);
    defer report.deinit();
    for (report.problems.items) |problem| {
        if (std.mem.indexOf(u8, problem, needle) != null) return;
    }
    std.debug.print("no problem mentions '{s}'; {f}", .{ needle, report });
    return error.TestExpectedProblem;
}

fn appendId(key: *std.ArrayList(u8), id: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, id, .big);
    try key.appendSlice(testing.allocator, &bytes);
}

fn expectSound(g: *Graph) !void {
    var report = try integrity.check(g, testing.allocator);
    defer report.deinit();
    if (!report.ok()) {
        std.debug.print("{f}", .{report});
        return error.TestUnexpectedProblem;
    }
}

test "integrity: a sound database passes, inside and outside a transaction" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [256]u8 = undefined;
    var store = try support.openStore(&tmp, &buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try expectSound(&g); // empty
    try support.loadMoviesGraph(&g);
    try g.setEdgeProperty(0, "role", .{ .string = "Neo" });
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try support.expectQuery(&ast, &g, "CREATE FULLTEXT INDEX titles FOR (m:Movie|Person) ON EACH [m.title, m.name]", &.{});
    try support.expectQuery(&ast, &g, "CREATE CONSTRAINT FOR (p:Person) REQUIRE p.name IS UNIQUE", &.{});
    try expectSound(&g);

    try g.beginWrite();
    defer g.abortWrite();
    try g.removeLabel(100, "Movie");
    _ = try g.addEdge(5, 5, "LIKES");
    try expectSound(&g);
}

test "integrity: damage to each derived structure is found" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [256]u8 = undefined;
    var store = try support.openStore(&tmp, &buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try support.loadMoviesGraph(&g);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try support.expectQuery(&ast, &g, "CREATE FULLTEXT INDEX titles FOR (m:Movie) ON EACH [m.title]", &.{});

    // Each damage is done in a write transaction, checked, and undone.
    const Damage = struct { key: []const u8, value: ?[]const u8, problem: []const u8 };
    const label_key = "l" ++ "Movie\x00" ++ "\x00\x00\x00\x00\x00\x00\x00\x64";
    const damages = [_]Damage{
        .{ .key = label_key, .value = null, .problem = "missing key lMovie" },
        .{ .key = "lMovie\x00\x00\x00\x00\x00\x00\x00\x00\x01", .value = "", .problem = "unexpected key lMovie" },
        .{ .key = "tACTED_IN", .value = "\x00\x00\x00\x00\x00\x00\x00\x07", .problem = "key tACTED_IN holds" },
        .{ .key = "cPerson", .value = "\x00\x00\x00\x00\x00\x00\x00\x01", .problem = "key cPerson holds" },
        .{ .key = "tGONE", .value = "\x00\x00\x00\x00\x00\x00\x00\x00", .problem = "" }, // a stale zero counter is fine
        .{ .key = "zzz", .value = "", .problem = "unknown key zzz" },
        .{ .key = "!", .value = "\x00\x00\x00\x00\x00\x00\x00\x02", .problem = "is not below the node id counter" },
        .{ .key = "vtitles\x00matrix", .value = null, .problem = "missing key vtitles\\x00matrix" },
        .{ .key = "Vtitles\x00", .value = "\x00\x00\x00\x00\x00\x00\x00\x09\x00\x00\x00\x00\x00\x00\x00\x09", .problem = "key Vtitles\\x00 holds" },
    };
    for (damages) |damage| {
        try g.beginWrite();
        defer g.abortWrite();
        if (damage.value) |value| try store.put(damage.key, value) else try store.del(damage.key);
        if (damage.problem.len == 0) try expectSound(&g) else try expectProblem(&g, damage.problem);
    }

    // A neighbour's labels kept by an edge key, out of date.
    {
        try g.beginWrite();
        defer g.abortWrite();
        var edges = try g.edgesOf(1, .out);
        const edge = (try edges.next()).?;
        // `e | id | 'o' | 0x00 | type | 0x00 | neighbour | relationship`
        var key = std.ArrayList(u8).empty;
        defer key.deinit(testing.allocator);
        try key.append(testing.allocator, 'e');
        try appendId(&key, edge.id);
        try key.appendSlice(testing.allocator, "o\x00");
        try key.appendSlice(testing.allocator, edge.edge_type);
        try key.append(testing.allocator, 0);
        try appendId(&key, edge.neighbour);
        try appendId(&key, edge.relationship);
        edges.deinit();
        try store.put(key.items, "\x01");
        try expectProblem(&g, "expected");
    }
    // A relationship whose end node is gone, and a node record that is not one.
    {
        try g.beginWrite();
        defer g.abortWrite();
        try store.deleteNode(103);
        try store.putDamagedNode(7, "\x00\x05A");
        try expectProblem(&g, "node 103 does not exist");
        try expectProblem(&g, "node 7: malformed record");
    }
    try expectSound(&g);
}
