//! The change log (change_log.zig): applying a database's change sets in
//! order to an empty database makes the same database, and a replica
//! applies each exactly once.

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
const contents = support.contents;

/// The replica `target` applies the change sets `first` up to, not
/// including, `end` of `source`.
fn replay(source: *KeyValueStore, target: *KeyValueStore, first: u64, end: u64) !void {
    for (first..end) |lsn| {
        const bytes = (try source.changeSet(lsn)) orelse return error.MissingChangeSet;
        defer testing.allocator.free(bytes);
        try testing.expectEqual(.applied, try target.applyChangeSet(lsn, bytes));
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

/// The replica `target` applies change set `lsn` of `source` chunk by
/// chunk, as a master sends it, up to (not including) chunk `stop` if given;
/// returns the chunks applied.
fn replayChunks(source: *KeyValueStore, target: *KeyValueStore, lsn: u64, stop: ?u32) !u32 {
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(testing.allocator);
    var number: u32 = 0;
    while (stop == null or number < stop.?) : (number += 1) {
        const final = (try source.changeSetChunk(lsn, number, &chunk)) orelse return error.MissingChangeSet;
        try testing.expect(chunk.items.len <= change_log.chunk_bytes);
        const applied = try target.applyChangeSetPart(lsn, chunk.items, final);
        try testing.expectEqual(final, applied != null);
        if (final) return number + 1;
    }
    return number;
}

test "a change set is applied chunk by chunk, writes cut between chunks included, or not at all" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_path: [256]u8 = undefined;
    var source = try openAt(&tmp, "source", &source_path);
    defer source.deinit();
    var target_path: [256]u8 = undefined;
    var target = try openAt(&tmp, "target", &target_path);
    defer target.deinit();

    try source.startChangeLog();
    try source.put("before", "1");
    try replay(&source, &target, 1, 2);
    // Values longer than a chunk and odd sizes: most writes are cut.
    const value = try testing.allocator.alloc(u8, change_log.chunk_bytes + change_log.chunk_bytes / 3);
    defer testing.allocator.free(value);
    try source.beginWrite();
    for (0..5) |i| {
        @memset(value, @intCast('a' + i));
        try source.put(&.{ 'k', @intCast('0' + i) }, value[0 .. value.len - i * 1000]);
        try source.put(&.{ 's', @intCast('0' + i) }, "small");
    }
    try source.commitWrite();

    // Abandoned halfway (a conversation ends), none of it is applied.
    try testing.expectEqual(@as(u32, 3), try replayChunks(&source, &target, 2, 3));
    target.abandonChangeSet();
    try testing.expectEqual(@as(?u64, 1), try target.appliedLsn());
    try testing.expect(!try target.exists("k0"));
    // A part of another change set before the last of this one fails, and
    // abandons it.
    try testing.expectEqual(@as(u32, 1), try replayChunks(&source, &target, 2, 1));
    try testing.expectError(error.ChangeSetOutOfOrder, target.applyChangeSetPart(3, "", true));
    try testing.expectEqual(@as(?u64, 1), try target.appliedLsn());

    // Applied whole from its start, it makes the same database.
    try testing.expect(try replayChunks(&source, &target, 2, null) > 6);
    try testing.expectEqual(@as(?u64, 2), try target.appliedLsn());
    try testing.expectEqual(try contents(&source), try contents(&target));
    // Sent again (a replica reconnects), it is skipped part by part.
    _ = try target.applyChangeSetPart(2, "not even a change set", false);
    try testing.expectEqual(@as(?change_log.Applied, .already_applied), try target.applyChangeSetPart(2, "", true));
}

test "a chunk tells whether it is its change set's last; a dropped one is gone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();
    try store.startChangeLog();
    const value = try testing.allocator.alloc(u8, change_log.chunk_bytes);
    defer testing.allocator.free(value);
    @memset(value, 'v');
    try store.put("big", value);
    try store.put("small", "v");
    var chunk: std.ArrayList(u8) = .empty;
    defer chunk.deinit(testing.allocator);
    try testing.expectEqual(@as(?bool, false), try store.changeSetChunk(1, 0, &chunk));
    try testing.expectEqual(change_log.chunk_bytes, chunk.items.len);
    try testing.expectEqual(@as(?bool, true), try store.changeSetChunk(1, 1, &chunk));
    try testing.expectEqual(@as(?bool, null), try store.changeSetChunk(1, 2, &chunk));
    try testing.expectEqual(@as(?bool, true), try store.changeSetChunk(2, 0, &chunk));
    store.change_log_limit = 100;
    try store.put("next", "v");
    try testing.expectEqual(@as(?bool, null), try store.changeSetChunk(1, 1, &chunk));
}

test "no value longer than the limit is stored, nor applied from a change set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();
    const value = try testing.allocator.alloc(u8, zypherdb.layout.max_value_length + 1);
    defer testing.allocator.free(value);
    @memset(value, 'v');
    try testing.expectError(error.ValueTooLarge, store.put("k", value));
    try store.put("k", value[1..]);
    try testing.expect(try store.exists("k"));

    // A replica waits for the rest of a write cut by a part's end, unless
    // it says it is longer than any master writes.
    var header: [11]u8 = .{ 0x01, @backingInt(change_log.Table.main), 0, 0, 0, 1, 'k', 0, 0, 0, 0 };
    std.mem.writeInt(u32, header[7..11], @intCast(zypherdb.layout.max_value_length), .big);
    var cut = change_log.Iterator{ .bytes = &header, .partial = true };
    try testing.expect(try cut.next() == null);
    try testing.expectEqual(header.len, cut.rest().len);
    std.mem.writeInt(u32, header[7..11], @intCast(zypherdb.layout.max_value_length + 1), .big);
    var too_long = change_log.Iterator{ .bytes = &header, .partial = true };
    try testing.expectError(error.MalformedChangeSet, too_long.next());
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

test "a full log drops several change sets at once, not one at each commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();

    try store.startChangeLog();
    store.change_log_limit = 16 << 10; // drops 1 KiB under it: about 10 change sets
    var value: [90]u8 = @splat('v');
    var drops: usize = 0;
    var oldest: u64 = 1;
    for (0..400) |i| {
        value[0] = @intCast(i % 256);
        try store.put("key", &value);
        const state = (try store.changeLogState()).?;
        try testing.expect(state.bytes <= store.change_log_limit);
        if (state.oldest_lsn != oldest) drops += 1;
        oldest = state.oldest_lsn;
    }
    // Full after about 160 commits: the other 240 drop in about 24 goes.
    try testing.expect(oldest > 1);
    try testing.expect(drops <= 40);
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

test "a replica applies each change set once, in order, and keeps its place across a reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_path: [256]u8 = undefined;
    var source = try openAt(&tmp, "source", &source_path);
    defer source.deinit();
    var target_path: [256]u8 = undefined;
    var target = try openAt(&tmp, "target", &target_path);

    try source.startChangeLog();
    for (0..5) |i| try source.put(&.{ 'k', @intCast('0' + i) }, "value");
    try source.del("k2");
    try testing.expect(try target.appliedLsn() == null);
    try replay(&source, &target, 1, 4);
    try testing.expectEqual(@as(?u64, 3), try target.appliedLsn());

    // Sent again (a reconnection): skipped. Past a missing one: refused.
    const first = (try source.changeSet(1)).?;
    defer testing.allocator.free(first);
    try testing.expectEqual(.already_applied, try target.applyChangeSet(1, first));
    const fifth = (try source.changeSet(5)).?;
    defer testing.allocator.free(fifth);
    try testing.expectError(error.ChangeSetOutOfOrder, target.applyChangeSet(5, fifth));
    try testing.expectEqual(@as(?u64, 3), try target.appliedLsn());

    // A replica writes nothing but its master's change sets.
    try testing.expectError(error.ReadOnlyReplica, target.put("mine", "value"));
    try testing.expectError(error.ReadOnlyReplica, target.beginWrite());
    try testing.expectError(error.ReadOnlyReplica, target.startChangeLog());

    // Reopened (as after a crash), it resumes where it stopped, still a replica.
    target.deinit();
    var base_buffer: [128]u8 = undefined;
    var reopen_buffer: [256]u8 = undefined;
    target = try KeyValueStore.open(testing.allocator, try std.fmt.bufPrint(&reopen_buffer, "{s}/target", .{testPath(&tmp, &base_buffer)}));
    defer target.deinit();
    try testing.expectEqual(@as(?u64, 3), try target.appliedLsn());
    try testing.expectError(error.ReadOnlyReplica, target.put("mine", "value"));
    const state = (try source.changeLogState()).?;
    try replay(&source, &target, 4, state.next_lsn);
    try testing.expectEqual(try contents(&source), try contents(&target));
}

test "a change set that fails to apply leaves the replica as it was" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();

    const first = [_]u8{ 0x01, @backingInt(change_log.Table.main), 0, 0, 0, 1, 'a', 0, 0, 0, 1, '1' };
    try testing.expectEqual(.applied, try store.applyChangeSet(1, &first));
    // A whole put, then a cut one.
    const second = [_]u8{ 0x01, @backingInt(change_log.Table.main), 0, 0, 0, 1, 'b', 0, 0, 0, 1, '2', 0x01 };
    try testing.expectError(error.MalformedChangeSet, store.applyChangeSet(2, &second));
    try testing.expectEqual(@as(?u64, 1), try store.appliedLsn());
    try testing.expect(!try store.exists("b"));
    const a = (try store.get("a")).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("1", a);
}

test "a master applies no change sets" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();
    try store.startChangeLog();
    try testing.expectError(error.WriteFailed, store.applyChangeSet(1, ""));
    try testing.expect(try store.appliedLsn() == null);
}

/// A copy of `source` as it is now (`writeCopy`), owned by the caller.
fn writeCopy(source: *KeyValueStore, lsn: *u64) ![]u8 {
    var copy: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer copy.deinit();
    lsn.* = try source.writeCopy(&copy.writer);
    return copy.toOwnedSlice();
}

/// Loads `copy` into `target` in parts of `part_bytes`, the last empty and
/// final, as a replica gets them; returns the copy's LSN.
fn loadCopy(target: *KeyValueStore, copy: []const u8, part_bytes: usize) !u64 {
    var position: usize = 0;
    while (position < copy.len) : (position += part_bytes) {
        try testing.expect(try target.applyCopyPart(copy[position..@min(copy.len, position + part_bytes)], false) == null);
    }
    return (try target.applyCopyPart("", true)).?;
}

test "a copy of a master makes a replica that follows it from where the copy was made" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_path: [256]u8 = undefined;
    var source = try openAt(&tmp, "source", &source_path);
    defer source.deinit();

    try testing.expect(try source.databaseId() == null);
    try source.startChangeLog();
    const id = (try source.databaseId()).?;
    var g = Graph.init(&source, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try expectQuery(&ast, &g, "UNWIND range(1, 20) AS i CREATE (:Person {id: i})-[:KNOWS]->(:Person {id: -i})", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX FOR (p:Person) ON (p.id)", &.{});
    const copied = (try source.changeLogState()).?;
    var lsn: u64 = undefined;
    const copy = try writeCopy(&source, &lsn);
    defer testing.allocator.free(copy);
    try testing.expectEqual(copied.next_lsn - 1, lsn);
    // Written after the copy: the replica gets them from the log.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id > 10 SET p.old = true", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id < 5 DETACH DELETE p", &.{});

    // Parts of any size: one byte cuts the header and every entry.
    for ([_]usize{ 1, 7, 100, copy.len }) |part_bytes| {
        var name_buffer: [32]u8 = undefined;
        var target_path: [256]u8 = undefined;
        var target = try openAt(&tmp, try std.fmt.bufPrint(&name_buffer, "target-{d}", .{part_bytes}), &target_path);
        defer target.deinit();
        try testing.expectEqual(lsn, try loadCopy(&target, copy, part_bytes));
        try testing.expectEqual(@as(?u64, lsn), try target.appliedLsn());
        try testing.expectEqual(@as(?change_log.DatabaseId, id), try target.databaseId());
        // A replica keeps no log.
        try testing.expect(try target.changeLogState() == null);
        try testing.expect(try target.changeSet(copied.oldest_lsn) == null);
        try testing.expectError(error.ReadOnlyReplica, target.put("mine", "value"));

        const state = (try source.changeLogState()).?;
        try replay(&source, &target, lsn + 1, state.next_lsn);
        try testing.expectEqual(try contents(&source), try contents(&target));
    }
    // Started again, the log keeps its id.
    try source.startChangeLog();
    try testing.expectEqual(@as(?change_log.DatabaseId, id), try source.databaseId());
}

test "a copy cut short, or that is not one, changes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_path: [256]u8 = undefined;
    var source = try openAt(&tmp, "source", &source_path);
    defer source.deinit();
    try source.startChangeLog();
    try source.put("key", "value");
    var lsn: u64 = undefined;
    const copy = try writeCopy(&source, &lsn);
    defer testing.allocator.free(copy);

    var target_path: [256]u8 = undefined;
    var target = try openAt(&tmp, "target", &target_path);
    defer target.deinit();
    try target.put("mine", "value");
    const before = try contents(&target);
    // Its header cut; an entry cut; abandoned halfway.
    try testing.expectError(error.MalformedChangeSet, target.applyCopyPart(copy[0..10], true));
    try testing.expectError(error.MalformedChangeSet, target.applyCopyPart(copy[0 .. copy.len - 1], true));
    try testing.expect(try target.applyCopyPart(copy[0 .. copy.len / 2], false) == null);
    target.abandonChangeSet();
    // A delete, or a write to the engine's catalog: no master copies one.
    var not_one: std.ArrayList(u8) = .empty;
    defer not_one.deinit(testing.allocator);
    try not_one.appendSlice(testing.allocator, copy[0..zypherdb.database_copy.header_bytes]);
    try not_one.appendSlice(testing.allocator, &.{ 0x02, @backingInt(change_log.Table.main), 0, 0, 0, 1, 'k' });
    try testing.expectError(error.MalformedChangeSet, target.applyCopyPart(not_one.items, true));
    not_one.shrinkRetainingCapacity(zypherdb.database_copy.header_bytes);
    try not_one.appendSlice(testing.allocator, &.{ 0x01, @backingInt(change_log.Table.main), 0, 0, 0, 1, '#', 0, 0, 0, 0 });
    try testing.expectError(error.MalformedChangeSet, target.applyCopyPart(not_one.items, true));
    try testing.expectEqual(before, try contents(&target));
    try testing.expect(try target.appliedLsn() == null);
    // Nothing is left open: the whole copy loads.
    try testing.expectEqual(lsn, try loadCopy(&target, copy, 3));
    try testing.expectEqual(try contents(&source), try contents(&target));
    // A master loads none.
    try testing.expectError(error.WriteFailed, source.applyCopyPart(copy, true));
}

test "a change set that is not one is refused" {
    var changes = change_log.Iterator{ .bytes = &.{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x05, 'a' } };
    try testing.expectError(error.MalformedChangeSet, changes.next());
    var to_the_log = change_log.Iterator{ .bytes = &.{ 0x02, @backingInt(change_log.Table.changes), 0, 0, 0, 0 } };
    try testing.expectError(error.MalformedChangeSet, to_the_log.next());
}

test "a database loads a copy of a master over what it held, while readers keep what they saw" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_path: [256]u8 = undefined;
    var source = try openAt(&tmp, "source", &source_path);
    defer source.deinit();
    try source.startChangeLog();
    var g = Graph.init(&source, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try expectQuery(&ast, &g, "UNWIND range(1, 20) AS i CREATE (:Person {id: i})-[:OWNS]->(:Thing)", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX FOR (p:Person) ON (p.id)", &.{});
    var lsn: u64 = undefined;
    const copy = try writeCopy(&source, &lsn);
    defer testing.allocator.free(copy);
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id < 5 DETACH DELETE p", &.{});

    // What the database held before: records, an index, keys of its own.
    var target_path: [256]u8 = undefined;
    var target = try openAt(&tmp, "target", &target_path);
    defer target.deinit();
    var target_graph = Graph.init(&target, testing.allocator);
    try expectQuery(&ast, &target_graph, "UNWIND range(1, 50) AS i CREATE (:Other {id: i})-[:R]->(:Other)", &.{});
    try expectQuery(&ast, &target_graph, "CREATE INDEX FOR (o:Other) ON (o.id)", &.{});
    try target.put("mine", "value");

    var reader = try target.share();
    errdefer reader.deinit();
    try reader.beginRead();
    try testing.expect(try target.applyCopyPart(copy[0 .. copy.len / 2], false) == null);
    // Halfway, a reader starting now sees the database as it was too.
    var halfway = try target.share();
    defer halfway.deinit();
    try testing.expect(try halfway.exists("mine"));
    const applied = (try target.applyCopyPart(copy[copy.len / 2 ..], true)).?;
    try testing.expectEqual(lsn, applied);
    try testing.expect(try reader.exists("mine"));
    reader.abortRead();
    try testing.expect(!try reader.exists("mine"));
    try testing.expectEqual(@as(?u64, applied), try target.appliedLsn());
    try testing.expectEqual(try source.databaseId(), try target.databaseId());
    try testing.expect(try target.get("mine") == null);
    try testing.expectError(error.ReadOnlyReplica, target.put("mine", "value"));

    const state = (try source.changeLogState()).?;
    try replay(&source, &target, applied + 1, state.next_lsn);
    try testing.expectEqual(try contents(&source), try contents(&target));
    try testing.expectEqual(try contents(&source), try contents(&reader));
    // Closing a share leaves the database open.
    reader.deinit();
    try testing.expectEqual(try contents(&source), try contents(&target));
}

test "a commit listener is told the LSN of each change set committed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var store = try openAt(&tmp, "master", &path);
    defer store.deinit();
    const Heard = struct {
        lsns: [4]u64 = undefined,
        count: usize = 0,
        fn committed(context: *anyopaque, lsn: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.lsns[self.count] = lsn;
            self.count += 1;
        }
    };
    var heard: Heard = .{};
    store.commit_listener = .{ .context = &heard, .committed = Heard.committed };
    // Before the change log starts, a commit has no LSN.
    try store.beginWrite();
    try store.put("before", "log");
    try store.commitWrite();
    try store.startChangeLog();
    for ([_][]const u8{ "one", "two" }) |key| {
        try store.beginWrite();
        try store.put(key, "value");
        try store.commitWrite();
    }
    // Neither does one that changed nothing, nor one aborted.
    try store.beginWrite();
    try store.commitWrite();
    try store.beginWrite();
    try store.put("aborted", "value");
    store.abortWrite();
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, heard.lsns[0..heard.count]);
    try testing.expectEqual(@as(?u64, 2), store.last_committed_lsn);
}

test "a store that wrote before the change log started logs its writes once it is started" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var starter = try openAt(&tmp, "db", &path);
    defer starter.deinit();
    // Another store on the database, as another process has.
    var writer = try starter.share();
    defer writer.deinit();

    try writer.beginWrite();
    try writer.put("before", "1");
    try writer.commitWrite();
    try starter.startChangeLog();
    try writer.beginWrite();
    try writer.put("after", "2");
    try writer.commitWrite();

    try testing.expectEqual(@as(u64, 2), (try starter.changeLogState()).?.next_lsn);
    try testing.expectEqual(@as(?u64, 1), writer.last_committed_lsn);
}

test "a store that wrote before the database became a replica refuses writes once it is one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var master = try openAt(&tmp, "master", &master_path);
    defer master.deinit();
    try master.startChangeLog();
    try master.beginWrite();
    try master.put("key", "value");
    try master.commitWrite();

    var replica_path: [256]u8 = undefined;
    var replica = try openAt(&tmp, "replica", &replica_path);
    defer replica.deinit();
    // Another store on the database, as another process has.
    var writer = try replica.share();
    defer writer.deinit();
    try writer.beginWrite();
    try writer.put("local", "1");
    try writer.commitWrite();

    try replay(&master, &replica, 1, 2);
    try testing.expectError(error.ReadOnlyReplica, writer.beginWrite());
}

test "a transaction with a write the log could not record does not commit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var store = try openAt(&tmp, "database", &path);
    defer store.deinit();
    try store.startChangeLog();

    // The first allocation fails with nothing recorded, the second with a
    // write cut in the middle.
    const long_value: [4096]u8 = @splat('v');
    for ([_]usize{ 0, 1 }) |fail_index| {
        try store.beginWrite();
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        store.allocator = failing.allocator();
        try testing.expectError(error.OutOfMemory, store.put("key", &long_value));
        store.allocator = testing.allocator;
        try testing.expectError(error.WriteFailed, store.commitWrite());

        try testing.expectEqual(null, try store.get("key"));
        try testing.expectEqual(@as(u64, 1), (try store.changeLogState()).?.next_lsn);
    }

    // The store goes on as before.
    try store.beginWrite();
    try store.put("key", "value");
    try store.commitWrite();
    try testing.expectEqual(@as(u64, 2), (try store.changeLogState()).?.next_lsn);
}
