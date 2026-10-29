//! The master's side of replication (replication/master.zig): whom it
//! serves and how, and that what it sends makes a replica equal to it.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Graph = zypherdb.Graph;
const Ast = zypherdb.Ast;
const protocol = zypherdb.replication_protocol;
const master = zypherdb.replication_master;

const support = @import("../support.zig");
const testPath = support.testPath;
const expectQuery = support.expectQuery;
const contents = support.contents;

const token = "the master's token";

fn openAt(tmp: *testing.TmpDir, name: []const u8, buffer: []u8) !KeyValueStore {
    var base_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(tmp, &base_buffer), name });
    try tmp.dir.createDirPath(testing.io, name);
    return KeyValueStore.open(testing.allocator, path);
}

/// A hello from a replica of `store` that applied up to `applied_lsn`.
fn helloFrom(store: *KeyValueStore, applied_lsn: u64) !protocol.Hello {
    return .{
        .storage_format = Graph.format_version,
        .storage_engine = zypherdb.storage_engine,
        .database_id = try store.databaseId(),
        .applied_lsn = applied_lsn,
        .token = token,
    };
}

fn put(store: *KeyValueStore, key: []const u8) !void {
    try store.put(key, "value");
}

test "a master refuses whom it must not serve, telling nothing before the token" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var store = try openAt(&tmp, "master", &path);
    defer store.deinit();

    // Not a master yet.
    try testing.expectEqual(master.Answer{ .refused = .not_master }, try master.answer(&store, try helloFrom(&store, 0), token));
    try store.startChangeLog();
    try put(&store, "a");

    var hello = try helloFrom(&store, 1);
    try testing.expectEqual(master.Answer{ .stream = 2 }, try master.answer(&store, hello, token));

    hello.protocol_version = protocol.version + 1;
    try testing.expectEqual(master.Answer{ .refused = .protocol_version }, try master.answer(&store, hello, token));
    hello = try helloFrom(&store, 1);
    hello.token = "a guess";
    hello.storage_engine = "another";
    try testing.expectEqual(master.Answer{ .refused = .token }, try master.answer(&store, hello, token));
    hello = try helloFrom(&store, 1);
    hello.storage_format += 1;
    try testing.expectEqual(master.Answer{ .refused = .storage_format }, try master.answer(&store, hello, token));
    hello = try helloFrom(&store, 1);
    hello.storage_engine = "another";
    try testing.expectEqual(master.Answer{ .refused = .storage_engine }, try master.answer(&store, hello, token));
    hello = try helloFrom(&store, 1);
    hello.database_id.?[0] +%= 1;
    try testing.expectEqual(master.Answer{ .refused = .database_id }, try master.answer(&store, hello, token));
    // A replica with change sets this master never made.
    hello = try helloFrom(&store, 2);
    try testing.expectEqual(master.Answer{ .refused = .ahead }, try master.answer(&store, hello, token));
}

test "a replica resumes where it stopped, or starts from a copy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var store = try openAt(&tmp, "master", &path);
    defer store.deinit();
    try store.startChangeLog();
    store.change_log_limit = 300;
    var key: [100]u8 = @splat('k');
    for (0..10) |i| {
        key[0] = @intCast(i);
        try put(&store, &key);
    }
    const state = (try store.changeLogState()).?;
    try testing.expect(state.oldest_lsn > 2);

    // An empty replica, or one that missed change sets the log dropped.
    var hello = try helloFrom(&store, 0);
    hello.database_id = null;
    try testing.expectEqual(master.Answer.snapshot, try master.answer(&store, hello, token));
    try testing.expectEqual(master.Answer.snapshot, try master.answer(&store, try helloFrom(&store, state.oldest_lsn - 2), token));
    // One that has all it needs, or all there is.
    try testing.expectEqual(master.Answer{ .stream = state.oldest_lsn }, try master.answer(&store, try helloFrom(&store, state.oldest_lsn - 1), token));
    try testing.expectEqual(master.Answer{ .stream = state.next_lsn }, try master.answer(&store, try helloFrom(&store, state.next_lsn - 1), token));
    try testing.expectEqual(master.Answer{ .stream = state.next_lsn }, try master.resumeFrom(&store, state.next_lsn - 1));

    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    var next: u64 = state.oldest_lsn - 1;
    try testing.expectError(error.ChangeSetDropped, master.sendChangeSets(&store, &sink.writer, &next));
}

/// What a replica does with the frames `reader` holds: makes the copy of
/// the master its database in `directory` (named `name` in `tmp`) and
/// applies the change sets after it. Returns the open replica.
fn receive(tmp: *testing.TmpDir, name: []const u8, directory: []const u8, reader: *std.Io.Reader) !KeyValueStore {
    var copy: std.ArrayList(u8) = .empty;
    defer copy.deinit(testing.allocator);
    while (true) switch (try protocol.read(reader)) {
        .snapshot_part => |bytes| try copy.appendSlice(testing.allocator, bytes),
        .snapshot_end => |size| {
            try testing.expectEqual(@as(u64, copy.items.len), size);
            break;
        },
        else => return error.TestUnexpectedResult,
    };
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ name, KeyValueStore.data_file_name });
    defer testing.allocator.free(file_path);
    try tmp.dir.createDirPath(testing.io, name);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = file_path, .data = copy.items });
    var replica = try KeyValueStore.open(testing.allocator, directory);
    errdefer replica.deinit();
    _ = try replica.becomeReplica();

    var change_set: std.ArrayList(u8) = .empty;
    defer change_set.deinit(testing.allocator);
    var parts_lsn: ?u64 = null;
    while (true) {
        const message = protocol.read(reader) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        switch (message) {
            .change_set_part => |part| {
                if (parts_lsn) |lsn| try testing.expectEqual(lsn, part.lsn);
                parts_lsn = part.lsn;
                try change_set.appendSlice(testing.allocator, part.bytes);
                if (!part.final) continue;
                _ = try replica.applyChangeSet(part.lsn, change_set.items);
                change_set.clearRetainingCapacity();
                parts_lsn = null;
            },
            .heartbeat => |last| try testing.expectEqual(try replica.appliedLsn(), last),
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expect(parts_lsn == null);
    return replica;
}

test "a copy and the change sets after it make a replica equal to its master" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;
    var source = try openAt(&tmp, "master", &path);
    defer source.deinit();
    try source.startChangeLog();
    var g = Graph.init(&source, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try expectQuery(&ast, &g, "UNWIND range(1, 40) AS i CREATE (:Person {id: i, name: 'p' + i})", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX FOR (p:Person) ON (p.id)", &.{});

    var base_buffer: [128]u8 = undefined;
    var copy_path: [256]u8 = undefined;
    try tmp.dir.createDirPath(testing.io, "copy");
    try source.copyDatabase(try std.fmt.bufPrint(&copy_path, "{s}/copy", .{testPath(&tmp, &base_buffer)}));
    // Written after the copy: they follow it.
    try expectQuery(&ast, &g, "MATCH (a:Person), (b:Person) WHERE b.id = a.id + 1 CREATE (a)-[:KNOWS]->(b)", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id % 4 = 0 DETACH DELETE p", &.{});
    // A change set larger than a part, and an empty value.
    const large = try testing.allocator.alloc(u8, 2 * protocol.part_bytes + 10);
    defer testing.allocator.free(large);
    @memset(large, 'x');
    try source.put("large", large);
    try source.put("empty", "");

    var sent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sent.deinit();
    const file_path = "copy/" ++ KeyValueStore.data_file_name;
    var file = try tmp.dir.openFile(testing.io, file_path, .{});
    var file_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(testing.io, &file_buffer);
    try master.sendSnapshot(&sent.writer, &file_reader.interface);
    file.close(testing.io);

    // The replica acks the copy's last LSN; the master goes on after it.
    var copied = try KeyValueStore.open(testing.allocator, copy_path[0 .. testPath(&tmp, &base_buffer).len + "/copy".len]);
    const copy_state = (try copied.changeLogState()).?;
    copied.deinit();
    const answer = try master.resumeFrom(&source, copy_state.next_lsn - 1);
    var next = answer.stream;
    const state = (try source.changeLogState()).?;
    try testing.expectEqual(state.next_lsn - next, try master.sendChangeSets(&source, &sent.writer, &next));
    try testing.expectEqual(state.next_lsn, next);
    try testing.expectEqual(@as(u64, 0), try master.sendChangeSets(&source, &sent.writer, &next));
    try master.sendHeartbeat(&source, &sent.writer);

    var reader: std.Io.Reader = .fixed(sent.written());
    var replica_path: [256]u8 = undefined;
    var replica = try receive(&tmp, "replica", try std.fmt.bufPrint(&replica_path, "{s}/replica", .{testPath(&tmp, &base_buffer)}), &reader);
    defer replica.deinit();
    try testing.expectEqual(@as(?u64, state.next_lsn - 1), try replica.appliedLsn());
    try testing.expectEqual(try contents(&source), try contents(&replica));
}
