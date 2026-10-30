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

test "a copy of a master becomes a replica that follows it from where the copy was made" {
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
    try expectQuery(&ast, &g, "UNWIND range(1, 20) AS i CREATE (:Person {id: i})", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX FOR (p:Person) ON (p.id)", &.{});
    const copied = (try source.changeLogState()).?;

    var base_buffer: [128]u8 = undefined;
    var target_buffer: [256]u8 = undefined;
    const target_path = try std.fmt.bufPrint(&target_buffer, "{s}/target", .{testPath(&tmp, &base_buffer)});
    try tmp.dir.createDirPath(testing.io, "target");
    try source.copyDatabase(target_path);
    // Written after the copy: the replica gets them from the log.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id > 10 SET p.old = true", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id < 5 DETACH DELETE p", &.{});

    var target = try KeyValueStore.open(testing.allocator, target_path);
    defer target.deinit();
    try testing.expectEqual(copied.next_lsn - 1, try target.becomeReplica());
    try testing.expectEqual(@as(?u64, copied.next_lsn - 1), try target.appliedLsn());
    try testing.expectEqual(@as(?change_log.DatabaseId, id), try target.databaseId());
    // The copied log is gone: a replica keeps none.
    try testing.expect(try target.changeLogState() == null);
    try testing.expect(try target.changeSet(copied.oldest_lsn) == null);
    try testing.expectError(error.ReadOnlyReplica, target.put("mine", "value"));

    const state = (try source.changeLogState()).?;
    try replay(&source, &target, copied.next_lsn, state.next_lsn);
    try testing.expectEqual(try contents(&source), try contents(&target));
    // Started again, the log keeps its id.
    try source.startChangeLog();
    try testing.expectEqual(@as(?change_log.DatabaseId, id), try source.databaseId());
}

test "only a copy of a master becomes a replica, once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [128]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, testPath(&tmp, &path_buffer));
    defer store.deinit();
    try store.put("key", "value");
    try testing.expectError(error.WriteFailed, store.becomeReplica());
    try store.startChangeLog();
    try store.put("key", "other");
    try testing.expectEqual(@as(u64, 1), try store.becomeReplica());
    try testing.expectError(error.WriteFailed, store.becomeReplica());
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
    var base_buffer: [128]u8 = undefined;
    var copy_buffer: [256]u8 = undefined;
    const copy_path = try std.fmt.bufPrint(&copy_buffer, "{s}/copy", .{testPath(&tmp, &base_buffer)});
    try tmp.dir.createDirPath(testing.io, "copy");
    try source.copyDatabase(copy_path);
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
    const applied = try target.loadCopy(copy_path);
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
    // A master loads no copy.
    try testing.expectError(error.WriteFailed, source.loadCopy(copy_path));
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
