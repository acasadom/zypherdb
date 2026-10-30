//! Replication as a database opened with a role runs it
//! (replication/replication.zig): a replica refuses writes from the start,
//! gets the master's database, waits to see a write committed on the
//! master, and both tell how replication goes.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Replication = zypherdb.replication.Replication;
const ReplicaState = zypherdb.replication.ReplicaState;
const max_address_bytes = zypherdb.replication_network.max_address_bytes;

const support = @import("../support.zig");
const testPath = support.testPath;

const token = "the master's token";
const patience = 20 * std.time.ns_per_s;

fn open(tmp: *testing.TmpDir, name: []const u8, path: *[256]u8) !KeyValueStore {
    try tmp.dir.createDirPath(testing.io, name);
    var base: [128]u8 = undefined;
    const full = try std.fmt.bufPrint(path, "{s}/{s}", .{ testPath(tmp, &base), name });
    return KeyValueStore.open(testing.allocator, full);
}

fn pathOf(path: *const [256]u8) []const u8 {
    return std.mem.sliceTo(path, 0);
}

test "a replica opened with its role refuses writes, follows the master and waits to see its writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path = std.mem.zeroes([256]u8);
    var replica_path = std.mem.zeroes([256]u8);
    var master = try open(&tmp, "master", &master_path);
    defer master.deinit();
    var replica = try open(&tmp, "replica", &replica_path);
    defer replica.deinit();

    const serving = try Replication.start(testing.allocator, &master, pathOf(&master_path), .{ .master = .{
        .address = "127.0.0.1:0",
        .token = token,
        .heartbeat_ns = 50 * std.time.ns_per_ms,
        .timeout_ns = 500 * std.time.ns_per_ms,
    } });
    defer serving.stop();
    var address_buffer: [max_address_bytes]u8 = undefined;
    const address = serving.address(&address_buffer).?;

    // The caller's address and token may go once `start` returns.
    var callers_address: [max_address_bytes]u8 = undefined;
    var callers_token: [token.len]u8 = token.*;
    @memcpy(callers_address[0..address.len], address);
    const following = try Replication.start(testing.allocator, &replica, pathOf(&replica_path), .{ .replica = .{
        .master_address = callers_address[0..address.len],
        .token = &callers_token,
        .timeout_ns = 500 * std.time.ns_per_ms,
    } });
    defer following.stop();
    @memset(&callers_address, 'x');
    @memset(&callers_token, 'x');
    try testing.expectError(error.ReadOnlyReplica, replica.beginWrite());

    try master.beginWrite();
    try master.put("key", "value");
    try master.commitWrite();
    const lsn = master.last_committed_lsn.?;

    try testing.expect(following.waitFor(lsn, patience));
    const value = (try replica.get("key")).?;
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("value", value);
    try testing.expect(serving.waitFor(lsn, 0));

    const replica_status = (try following.status(&.{})).replica;
    try testing.expectEqual(lsn, replica_status.applied_lsn);
    try testing.expectEqual(null, replica_status.halted);

    var buffer: [4]ReplicaState = undefined;
    const deadline = std.Io.Clock.awake.now(testing.io).nanoseconds + patience;
    while (true) : (try testing.io.sleep(.fromMilliseconds(5), .awake)) {
        const master_status = (try serving.status(&buffer)).master;
        try testing.expectEqual(lsn, master_status.last_lsn);
        if (master_status.replicas.len == 1 and master_status.replicas[0].acked_lsn == lsn) break;
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline) return error.TestTimedOut;
    }
}

test "a replica told the wrong token halts, and says why" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path = std.mem.zeroes([256]u8);
    var replica_path = std.mem.zeroes([256]u8);
    var master = try open(&tmp, "master", &master_path);
    defer master.deinit();
    var replica = try open(&tmp, "replica", &replica_path);
    defer replica.deinit();

    const serving = try Replication.start(testing.allocator, &master, pathOf(&master_path), .{ .master = .{ .address = "127.0.0.1:0", .token = token } });
    defer serving.stop();
    var address_buffer: [max_address_bytes]u8 = undefined;
    const following = try Replication.start(testing.allocator, &replica, pathOf(&replica_path), .{ .replica = .{
        .master_address = serving.address(&address_buffer).?,
        .token = "another token",
    } });
    defer following.stop();

    try testing.expect(!following.waitFor(1, patience));
    try testing.expectEqual(.token, (try following.status(&.{})).replica.halted.?);
}
