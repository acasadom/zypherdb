//! A replica's vector indexes: the change log does not carry their keys,
//! and a replica that applies its master's change sets builds the same
//! indexes, byte for byte, from the data they change.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const KeyValueStore = zypherdb.KeyValueStore;
const change_log = zypherdb.change_log;

const support = @import("../support.zig");
const testPath = support.testPath;
const expectQuery = support.expectQuery;
const contents = support.contents;

fn openAt(tmp: *testing.TmpDir, name: []const u8, buffer: []u8) !KeyValueStore {
    var base_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(tmp, &base_buffer), name });
    try tmp.dir.createDirPath(testing.io, name);
    return KeyValueStore.open(testing.allocator, path);
}

/// The replica `target` applies `source`'s change sets from `next.*` on,
/// none of which writes a vector index's key.
fn replay(source: *KeyValueStore, target: *KeyValueStore, next: *u64) !void {
    const end = (try source.changeLogState()).?.next_lsn;
    while (next.* < end) : (next.* += 1) {
        const bytes = (try source.changeSet(next.*)) orelse return error.MissingChangeSet;
        defer testing.allocator.free(bytes);
        var changes = change_log.Iterator{ .bytes = bytes };
        while (try changes.next()) |change| {
            if (change.table == .main and change.key.len > 0) try testing.expect(change.key[0] != 'h');
        }
        try testing.expectEqual(.applied, try target.applyChangeSet(next.*, bytes));
    }
}

/// As `replay`, but committing the change sets in one group, as a replica
/// behind its master does (`KeyValueStore.applyChangeSetPartInGroup`).
fn replayGrouped(source: *KeyValueStore, target: *KeyValueStore, next: *u64) !void {
    const end = (try source.changeLogState()).?.next_lsn;
    while (next.* < end) : (next.* += 1) {
        const bytes = (try source.changeSet(next.*)) orelse return error.MissingChangeSet;
        defer testing.allocator.free(bytes);
        try testing.expectEqual(.applied, (try target.applyChangeSetPartInGroup(next.*, bytes, true, next.* + 1 < end)).?);
    }
}

fn expectSound(g: *Graph) !void {
    var report = try zypherdb.integrity.check(g, testing.allocator);
    defer report.deinit();
    for (report.problems.items) |problem| std.debug.print("integrity: {s}\n", .{problem});
    try testing.expect(report.ok());
}

fn expectSame(source: *KeyValueStore, target: *KeyValueStore) !void {
    try testing.expectEqual(try contents(source), try contents(target));
}

const node_index = "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v OPTIONS {indexConfig: {`vector.dimensions`: 4}}";
const relationship_index = "CREATE VECTOR INDEX links FOR ()-[r:LINK]-() ON r.v OPTIONS {indexConfig: {`vector.dimensions`: 4, `vector.similarity_function`: 'euclidean'}}";

test "a replica builds its vector indexes as its master did: created over data, written, past a rebuild, dropped" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var master = try openAt(&tmp, "master", &master_path);
    defer master.deinit();
    try master.startChangeLog();
    var replica_path: [256]u8 = undefined;
    var replica = try openAt(&tmp, "replica", &replica_path);
    defer replica.deinit();
    // Each CREATE populates its index whole, on the master and on the
    // replica, so the two interleave writes and population alike.
    master.population_budget = .{ .nanoseconds = std.math.maxInt(u64) };
    replica.population_budget = master.population_budget;
    var g = Graph.init(&master, testing.allocator);
    try g.checkFormat();
    var replica_graph = Graph.init(&replica, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    var next: u64 = 1;

    var prng = std.Random.DefaultPrng.init(11);
    const random = prng.random();
    var text: [512]u8 = undefined;
    const node_count = 300;
    for (0..node_count) |i| {
        const query = try std.fmt.bufPrint(&text, "CREATE (:Doc {{id: {d}, v: [{d:.3}, {d:.3}, {d:.3}, 1.0]}})", .{ i, random.floatNorm(f64), random.floatNorm(f64), random.floatNorm(f64) });
        try expectQuery(&ast, &g, query, &.{});
    }
    try expectQuery(&ast, &g, "MATCH (a:Doc), (b:Doc) WHERE b.id = a.id + 1 CREATE (a)-[:LINK {v: [a.id, b.id, 1, 1]}]->(b)", &.{});
    // Populated in the transaction that creates them.
    try expectQuery(&ast, &g, node_index, &.{});
    try expectQuery(&ast, &g, relationship_index, &.{});
    try replay(&master, &replica, &next);
    try expectSame(&master, &replica);

    // Writes of every kind, a statement each, then most nodes gone: the
    // tombstones outnumber the living and the index is rebuilt.
    for (0..600) |_| {
        const id = random.uintLessThan(usize, node_count);
        const query = switch (random.uintLessThan(u8, 6)) {
            0 => try std.fmt.bufPrint(&text, "MATCH (d {{id: {d}}}) SET d.v = [{d:.3}, {d:.3}, 1.0, 0.5]", .{ id, random.floatNorm(f64), random.floatNorm(f64) }),
            1 => try std.fmt.bufPrint(&text, "MATCH (d {{id: {d}}}) REMOVE d.v", .{id}),
            2 => try std.fmt.bufPrint(&text, "MATCH (d {{id: {d}}}) REMOVE d:Doc", .{id}),
            3 => try std.fmt.bufPrint(&text, "MATCH (d {{id: {d}}}) SET d:Doc", .{id}),
            4 => try std.fmt.bufPrint(&text, "MATCH ({{id: {d}}})-[r:LINK]->() SET r.v = [{d:.3}, 0, 0, 1]", .{ id, random.floatNorm(f64) }),
            else => try std.fmt.bufPrint(&text, "MATCH ({{id: {d}}})-[r:LINK]->() DELETE r", .{id}),
        };
        try expectQuery(&ast, &g, query, &.{});
    }
    try replay(&master, &replica, &next);
    try expectSame(&master, &replica);
    try expectQuery(&ast, &g, "MATCH (d) WHERE d.id % 5 <> 0 DETACH DELETE d", &.{});
    try replay(&master, &replica, &next);
    try expectSame(&master, &replica);
    try expectSound(&replica_graph);

    // Dropped and created again, with writes after it, all in one group of
    // change sets.
    try expectQuery(&ast, &g, "CREATE (:Doc {id: 999, v: [4, 3, 2, 1]})", &.{});
    try expectQuery(&ast, &g, "DROP INDEX docs", &.{});
    try expectQuery(&ast, &g, node_index, &.{});
    try expectQuery(&ast, &g, "CREATE (:Doc {id: 1000, v: [1, 2, 3, 4]})", &.{});
    try expectQuery(&ast, &g, "DROP INDEX links", &.{});
    try replayGrouped(&master, &replica, &next);
    try expectSame(&master, &replica);
    try expectSound(&replica_graph);
}
