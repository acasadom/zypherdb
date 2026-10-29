//! A replica's side of replication (replication/replica.zig): what it says
//! to its master, and that what it does with the answer makes it equal to
//! the master.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Graph = zypherdb.Graph;
const Ast = zypherdb.Ast;
const protocol = zypherdb.replication_protocol;
const master = zypherdb.replication_master;
const replica = zypherdb.replication_replica;

const support = @import("../support.zig");
const testPath = support.testPath;
const expectQuery = support.expectQuery;
const contents = support.contents;

const token = "the master's token";

/// The path of directory `name` in `tmp`, created.
fn directoryAt(tmp: *testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var base_buffer: [128]u8 = undefined;
    try tmp.dir.createDirPath(testing.io, name);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(tmp, &base_buffer), name });
}

/// The master's answer to `hello`, as the replica reads it.
fn answerOf(store: *KeyValueStore, hello: protocol.Hello) !replica.Answer {
    var sent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sent.deinit();
    switch (try master.answer(store, hello, token)) {
        .refused => |reason| try protocol.write(&sent.writer, .{ .refused = reason }),
        .stream => |first| try protocol.write(&sent.writer, .{ .stream = first }),
        .snapshot => try protocol.write(&sent.writer, .{ .snapshot_part = "copy" }),
    }
    var reader: std.Io.Reader = .fixed(sent.written());
    return replica.receiveAnswer(&reader, hello.applied_lsn);
}

test "a replica introduces itself by what it holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;

    const empty = try replica.hello(null, token);
    try testing.expectEqual(@as(?protocol.DatabaseId, null), empty.database_id);
    try testing.expectEqual(@as(u64, 0), empty.applied_lsn);
    try testing.expectEqualStrings(zypherdb.storage_engine, empty.storage_engine);
    try testing.expectEqualStrings(token, empty.token);

    var store = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &path));
    defer store.deinit();
    // A database that is no replica yet has nothing to resume.
    try store.put("a", "value");
    try testing.expectEqual(@as(?protocol.DatabaseId, null), (try replica.hello(&store, token)).database_id);
    try store.startChangeLog();
    try testing.expectError(error.MasterDatabase, replica.hello(&store, token));
}

test "a replica reads what its master answers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &path));
    defer store.deinit();
    try store.startChangeLog();
    try store.put("a", "value");

    var hello = try replica.hello(null, token);
    hello.token = "a guess";
    try testing.expectEqual(replica.Answer{ .refused = .token }, try answerOf(&store, hello));

    // A stream from elsewhere than after its last change set.
    var sent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sent.deinit();
    try protocol.write(&sent.writer, .{ .stream = 3 });
    var reader: std.Io.Reader = .fixed(sent.written());
    try testing.expectError(error.UnexpectedMessage, replica.receiveAnswer(&reader, 1));
    reader = .fixed(sent.written());
    try testing.expectEqual(replica.Answer.stream, try replica.receiveAnswer(&reader, 2));

    // A copy's first part stays for receiveSnapshot.
    sent.clearRetainingCapacity();
    try protocol.write(&sent.writer, .{ .snapshot_part = "copy" });
    try protocol.write(&sent.writer, .{ .snapshot_end = 4 });
    reader = .fixed(sent.written());
    try testing.expectEqual(replica.Answer.snapshot, try replica.receiveAnswer(&reader, 0));
    var copy: std.Io.Writer.Allocating = .init(testing.allocator);
    defer copy.deinit();
    try testing.expectEqual(@as(u64, 4), try replica.receiveSnapshot(&reader, &copy.writer));
    try testing.expectEqualStrings("copy", copy.written());

    // A copy cut short, or followed by something else than its end.
    sent.clearRetainingCapacity();
    try protocol.write(&sent.writer, .{ .snapshot_part = "copy" });
    try protocol.write(&sent.writer, .{ .snapshot_end = 5 });
    reader = .fixed(sent.written());
    try testing.expectError(error.SnapshotSizeMismatch, replica.receiveSnapshot(&reader, &copy.writer));
    sent.clearRetainingCapacity();
    try protocol.write(&sent.writer, .{ .snapshot_part = "copy" });
    try protocol.write(&sent.writer, .{ .heartbeat = 1 });
    reader = .fixed(sent.written());
    try testing.expectError(error.UnexpectedMessage, replica.receiveSnapshot(&reader, &copy.writer));
    reader = .fixed(sent.written()[0 .. sent.written().len - 1]);
    _ = try protocol.read(&reader);
    try testing.expectError(error.EndOfStream, replica.receiveSnapshot(&reader, &copy.writer));
}

test "a replica gathers a change set's parts and refuses them mixed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var store = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "replica", &path));
    defer store.deinit();
    var receiver: replica.ChangeSetReceiver = .{};
    defer receiver.deinit(testing.allocator);

    try testing.expectEqual(replica.Received{ .heartbeat = 7 }, try receiver.receive(&store, .{ .heartbeat = 7 }));
    try testing.expectError(error.UnexpectedMessage, receiver.receive(&store, .{ .ack = 1 }));
    try testing.expectError(error.UnexpectedMessage, receiver.receive(&store, .{ .snapshot_part = "copy" }));
    try testing.expectEqual(replica.Received.part, try receiver.receive(&store, .{ .change_set_part = .{ .lsn = 1, .final = false, .bytes = "half" } }));
    try testing.expectError(error.UnexpectedMessage, receiver.receive(&store, .{ .change_set_part = .{ .lsn = 2, .final = true, .bytes = "" } }));
    try testing.expectError(error.MalformedChangeSet, receiver.receive(&store, .{ .change_set_part = .{ .lsn = 1, .final = true, .bytes = "half" } }));
    // Nothing gathered is kept after a change set fails.
    try testing.expectEqual(@as(?u64, null), receiver.lsn);
    try testing.expectEqual(@as(usize, 0), receiver.bytes.items.len);
}

/// Writes `count` keys of `bytes` bytes each to `store`, from `first`.
fn putKeys(store: *KeyValueStore, first: u8, count: u8, bytes: usize) !void {
    const value = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(value);
    @memset(value, 'v');
    for (first..first + count) |i| try store.put(&.{ 'k', @intCast(i) }, value);
}

/// Sends what the master owes a replica from `next.*`, and has the replica
/// apply it; returns the replica's ack.
fn stream(source: *KeyValueStore, target: *KeyValueStore, receiver: *replica.ChangeSetReceiver, next: *u64) !u64 {
    var sent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sent.deinit();
    _ = try master.sendChangeSets(source, &sent.writer, next);
    try master.sendHeartbeat(source, &sent.writer);
    var reader: std.Io.Reader = .fixed(sent.written());
    var acked: ?u64 = null;
    while (true) switch (try receiver.receive(target, try protocol.read(&reader))) {
        .part => {},
        .change_set => |lsn| acked = lsn,
        .heartbeat => |last| {
            try testing.expectEqual(try target.appliedLsn(), last);
            break;
        },
    };
    try testing.expectEqual(@as(usize, 0), reader.bufferedLen());
    return acked orelse (try target.appliedLsn()).?;
}

test "a replica made from its master's copy, then streamed to, equals its master across restarts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var source = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &master_path));
    defer source.deinit();
    try source.startChangeLog();
    var g = Graph.init(&source, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try expectQuery(&ast, &g, "UNWIND range(1, 40) AS i CREATE (:Person {id: i})", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX FOR (p:Person) ON (p.id)", &.{});

    // An empty replica says hello and is sent a copy.
    var hello = try replica.hello(null, token);
    try testing.expectEqual(master.Answer.snapshot, try master.answer(&source, hello, token));
    var copy_path: [256]u8 = undefined;
    try source.copyDatabase(try directoryAt(&tmp, "copy", &copy_path));
    var sent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sent.deinit();
    {
        var file = try tmp.dir.openFile(testing.io, "copy/" ++ KeyValueStore.data_file_name, .{});
        defer file.close(testing.io);
        var file_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(testing.io, &file_buffer);
        try master.sendSnapshot(&sent.writer, &file_reader.interface);
    }
    // Written after the copy: they follow it.
    try expectQuery(&ast, &g, "MATCH (a:Person), (b:Person) WHERE b.id = a.id + 1 CREATE (a)-[:KNOWS]->(b)", &.{});

    var replica_path: [256]u8 = undefined;
    const replica_directory = try directoryAt(&tmp, "replica", &replica_path);
    var reader: std.Io.Reader = .fixed(sent.written());
    try testing.expectEqual(replica.Answer.snapshot, try replica.receiveAnswer(&reader, hello.applied_lsn));
    {
        var file = try tmp.dir.createFile(testing.io, "replica/" ++ KeyValueStore.data_file_name, .{});
        defer file.close(testing.io);
        var file_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(testing.io, &file_buffer);
        _ = try replica.receiveSnapshot(&reader, &file_writer.interface);
        try file_writer.interface.flush();
    }
    try testing.expectEqual(@as(usize, 0), reader.bufferedLen());

    var target = try KeyValueStore.open(testing.allocator, replica_directory);
    var receiver: replica.ChangeSetReceiver = .{};
    defer receiver.deinit(testing.allocator);
    {
        defer target.deinit();
        const copied = try target.becomeReplica();
        sent.clearRetainingCapacity();
        try replica.sendAck(&sent.writer, copied);
        reader = .fixed(sent.written());
        var next = switch (try master.resumeFrom(&source, (try protocol.read(&reader)).ack)) {
            .stream => |first| first,
            else => return error.TestUnexpectedResult,
        };
        // A change set larger than a part, and deletes.
        try putKeys(&source, 0, 3, protocol.part_bytes + 1);
        try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id % 4 = 0 DETACH DELETE p", &.{});
        const state = (try source.changeLogState()).?;
        try testing.expectEqual(state.next_lsn - 1, try stream(&source, &target, &receiver, &next));
        try testing.expectEqual(try contents(&source), try contents(&target));
    }

    // Restarted, the replica resumes where it stopped.
    try putKeys(&source, 10, 2, 10);
    target = try KeyValueStore.open(testing.allocator, replica_directory);
    defer target.deinit();
    hello = try replica.hello(&target, token);
    try testing.expectEqual(try source.databaseId(), hello.database_id);
    try testing.expectEqual(replica.Answer.stream, try answerOf(&source, hello));
    var next = hello.applied_lsn + 1;
    try testing.expectEqual((try source.changeLogState()).?.next_lsn - 1, try stream(&source, &target, &receiver, &next));
    try testing.expectEqual(try contents(&source), try contents(&target));
}
