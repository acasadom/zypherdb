//! The change log (change_log.zig): applying a database's change sets in
//! order to an empty database makes the same database.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Graph = zypherdb.Graph;
const Ast = zypherdb.Ast;
const change_log = zypherdb.change_log;

const support = @import("../support.zig");
const testPath = support.testPath;
const expectQuery = support.expectQuery;

/// A digest of every key and value of the graph's tables (not the log's,
/// nor the engine's catalog of tables in the main one), and how many there are.
const Contents = struct { digest: u64, entries: usize };

fn contents(store: *KeyValueStore) !Contents {
    var hasher = std.hash.Wyhash.init(0);
    var entries: usize = 0;
    try store.beginRead();
    defer store.abortRead();
    inline for (.{ "main", "nodes", "relationships" }) |table| {
        var scan = if (comptime std.mem.eql(u8, table, "main")) try store.scanAll() else if (comptime std.mem.eql(u8, table, "nodes")) try store.scanNodes() else try store.scanRelationships();
        defer scan.deinit();
        while (try scan.next()) |entry| {
            if (comptime std.mem.eql(u8, table, "main")) if (entry.key.len > 0 and entry.key[0] == '#') continue;
            hasher.update(table);
            hasher.update(std.mem.asBytes(&entry.key.len));
            hasher.update(entry.key);
            hasher.update(std.mem.asBytes(&entry.value.len));
            hasher.update(entry.value);
            entries += 1;
        }
    }
    return .{ .digest = hasher.final(), .entries = entries };
}

/// Applies the change sets `first` up to, not including, `end` of `source`
/// to `target`, each in a transaction of its own.
fn replay(source: *KeyValueStore, target: *KeyValueStore, first: u64, end: u64) !void {
    for (first..end) |lsn| {
        const bytes = (try source.changeSet(lsn)) orelse return error.MissingChangeSet;
        defer testing.allocator.free(bytes);
        const transaction = try target.environment.beginWrite();
        errdefer transaction.abort();
        try change_log.apply(transaction, bytes);
        try transaction.commit();
    }
}

fn openAt(tmp: *testing.TmpDir, name: []const u8, buffer: []u8) !KeyValueStore {
    var base_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(tmp, &base_buffer), name });
    try tmp.dir.createDirPath(testing.io, name);
    return KeyValueStore.open(testing.allocator, path);
}

test "replaying the change log makes the same database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_path: [256]u8 = undefined;
    var source = try openAt(&tmp, "source", &source_path);
    defer source.deinit();
    var target_path: [256]u8 = undefined;
    var target = try openAt(&tmp, "target", &target_path);
    defer target.deinit();

    try testing.expect(try source.changeLogState() == null);
    try source.startChangeLog();
    var g = Graph.init(&source, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    // Every kind of write: nodes, labels, properties, relationships and
    // theirs, indexes (built from the data and kept current), full-text,
    // constraints, deletes, and keys written alone.
    try expectQuery(&ast, &g, "UNWIND range(1, 50) AS i CREATE (:Person {id: i, name: 'p' + i, age: i % 90, bio: 'likes graphs and ' + i})", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX FOR (p:Person) ON (p.age)", &.{});
    try expectQuery(&ast, &g, "CREATE CONSTRAINT FOR (p:Person) REQUIRE p.id IS UNIQUE", &.{});
    try expectQuery(&ast, &g, "CREATE FULLTEXT INDEX bios FOR (p:Person) ON EACH [p.bio]", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person), (b:Person) WHERE b.id = a.id + 1 CREATE (a)-[:KNOWS {since: a.id}]->(b)", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id % 3 = 0 SET p:Admin, p.age = p.age + 1 REMOVE p.bio", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person)-[r:KNOWS]->() WHERE p.id % 5 = 0 SET r.since = null, r.weight = 1.5", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id % 7 = 0 DETACH DELETE p", &.{});
    try source.put("alone", "a key written outside a transaction");
    try source.del("alone");
    // A read and an aborted write log nothing.
    const before = (try source.changeLogState()).?;
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN count(p)", &.{&.{.{ .int = 43 }}});
    try source.beginWrite();
    try source.put("never", "committed");
    source.abortWrite();
    try testing.expectEqual(before, (try source.changeLogState()).?);

    const state = (try source.changeLogState()).?;
    try testing.expectEqual(@as(u64, 1), state.oldest_lsn);
    try replay(&source, &target, state.oldest_lsn, state.next_lsn);
    try testing.expectEqual(try contents(&source), try contents(&target));
    try testing.expect(try source.changeSet(state.next_lsn) == null);
}

test "a large transaction's change set is cut into chunks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_path: [256]u8 = undefined;
    var source = try openAt(&tmp, "source", &source_path);
    defer source.deinit();
    var target_path: [256]u8 = undefined;
    var target = try openAt(&tmp, "target", &target_path);
    defer target.deinit();

    try source.startChangeLog();
    const value = try testing.allocator.alloc(u8, change_log.chunk_bytes / 3);
    defer testing.allocator.free(value);
    try source.beginWrite();
    for (0..7) |i| {
        @memset(value, @intCast('a' + i));
        try source.put(&.{ 'k', @intCast('0' + i) }, value);
    }
    try source.commitWrite();
    const state = (try source.changeLogState()).?;
    try testing.expectEqual(@as(u64, 2), state.next_lsn);
    try testing.expect(state.bytes > 2 * change_log.chunk_bytes);
    try replay(&source, &target, 1, 2);
    try testing.expectEqual(try contents(&source), try contents(&target));
}

test "the log keeps at most its limit, dropping the oldest change sets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();

    try store.startChangeLog();
    store.change_log_limit = 1000;
    var value: [90]u8 = @splat('v');
    for (0..100) |i| {
        value[0] = @intCast(i);
        try store.put("key", &value);
    }
    const state = (try store.changeLogState()).?;
    try testing.expectEqual(@as(u64, 101), state.next_lsn);
    try testing.expect(state.bytes <= 1000);
    try testing.expect(state.oldest_lsn > 1);
    try testing.expect(try store.changeSet(state.oldest_lsn - 1) == null);
    for (state.oldest_lsn..state.next_lsn) |lsn| {
        const bytes = (try store.changeSet(lsn)).?;
        testing.allocator.free(bytes);
    }

    // The newest change set stays even when it alone is past the limit.
    store.change_log_limit = 10;
    try store.put("key", &value);
    const after = (try store.changeLogState()).?;
    try testing.expectEqual(after.next_lsn - 1, after.oldest_lsn);
}

test "without the change log nothing is logged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();
    try store.put("key", "value");
    try testing.expect(try store.changeLogState() == null);
    try testing.expect(try store.changeSet(1) == null);
}

test "a change set that is not one is refused" {
    var changes = change_log.Iterator{ .bytes = &.{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x05, 'a' } };
    try testing.expectError(error.MalformedChangeSet, changes.next());
    var to_the_log = change_log.Iterator{ .bytes = &.{ 0x02, @backingInt(change_log.Table.changes), 0, 0, 0, 0 } };
    try testing.expectError(error.MalformedChangeSet, to_the_log.next());
}
