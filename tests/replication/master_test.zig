//! The master's decisions (replication/master.zig): whom it serves, and
//! from where a replica goes on.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Graph = zypherdb.Graph;
const protocol = zypherdb.replication_protocol;
const master = zypherdb.replication_master;

const support = @import("../support.zig");
const testPath = support.testPath;

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
}
