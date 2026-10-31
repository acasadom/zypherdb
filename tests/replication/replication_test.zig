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
const protocol = zypherdb.replication_protocol;

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
    const name = "eu \"1\"";
    var callers_name: [name.len]u8 = name.*;
    @memcpy(callers_address[0..address.len], address);
    const following = try Replication.start(testing.allocator, &replica, pathOf(&replica_path), .{ .replica = .{
        .master_address = callers_address[0..address.len],
        .token = &callers_token,
        .timeout_ns = 500 * std.time.ns_per_ms,
        .name = &callers_name,
    } });
    defer following.stop();
    @memset(&callers_address, 'x');
    @memset(&callers_token, 'x');
    @memset(&callers_name, 'x');
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
    try testing.expectEqualStrings(name, replica_status.name);
    try testing.expectEqualStrings(address, replica_status.master_address);
    try testing.expect(replica_status.last_heard.? <= replica_status.now);

    var buffer: [4]ReplicaState = undefined;
    const deadline = std.Io.Clock.awake.now(testing.io).nanoseconds + patience;
    while (true) : (try testing.io.sleep(.fromMilliseconds(5), .awake)) {
        const master_status = (try serving.status(&buffer)).master;
        try testing.expectEqual(lsn, master_status.last_lsn);
        // Applied before its node tells it streams.
        if (master_status.replicas.len == 1 and master_status.replicas[0].acked_lsn == lsn and (try following.status(&.{})).replica.phase == .streaming) {
            const served = &master_status.replicas[0];
            try testing.expectEqualStrings(name, served.name());
            try testing.expect(std.mem.startsWith(u8, served.address(), "127.0.0.1:"));
            try testing.expect(served.connected_at <= master_status.now);
            break;
        }
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline) return error.TestTimedOut;
    }

    // The same as JSON, the name escaped.
    const master_json = try serving.statusJson(testing.allocator);
    defer testing.allocator.free(master_json);
    const told = try std.json.parseFromSlice(std.json.Value, testing.allocator, master_json, .{});
    defer told.deinit();
    const served = told.value.object.get("replicas").?.array.items[0].object;
    try testing.expectEqualStrings(name, served.get("name").?.string);
    try testing.expectEqualStrings("streaming", served.get("phase").?.string);
    try testing.expectEqual(0, served.get("lag").?.integer);
    try testing.expect(served.get("connected_ms").?.integer >= 0);
    const replica_json = try following.statusJson(testing.allocator);
    defer testing.allocator.free(replica_json);
    const following_told = try std.json.parseFromSlice(std.json.Value, testing.allocator, replica_json, .{});
    defer following_told.deinit();
    const replica_told = following_told.value.object;
    try testing.expectEqualStrings(name, replica_told.get("name").?.string);
    try testing.expectEqualStrings(address, replica_told.get("master_address").?.string);
    try testing.expectEqualStrings("streaming", replica_told.get("phase").?.string);
    try testing.expect(replica_told.get("last_contact_ms").?.integer >= 0);
}

test "a replica's name is its host's unless given, and no longer than a hello carries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var replica_path = std.mem.zeroes([256]u8);
    var replica = try open(&tmp, "replica", &replica_path);
    defer replica.deinit();

    const long_name: [protocol.max_name_bytes + 1]u8 = @splat('n');
    try testing.expectError(error.NameTooLong, Replication.start(testing.allocator, &replica, pathOf(&replica_path), .{ .replica = .{
        .master_address = "127.0.0.1:1",
        .token = token,
        .name = &long_name,
    } }));

    const following = try Replication.start(testing.allocator, &replica, pathOf(&replica_path), .{ .replica = .{
        .master_address = "127.0.0.1:1",
        .token = token,
    } });
    defer following.stop();
    const status = (try following.status(&.{})).replica;
    try testing.expect(status.name.len > 0);
    try testing.expectEqual(null, status.last_heard);
    const json = try following.statusJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"last_contact_ms\":null") != null);
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
    const status = (try following.status(&.{})).replica;
    try testing.expectEqual(.token, status.halted.?);
    try testing.expectEqual(.halted, status.phase);
}

/// Waits until `replication` runs replication (no longer stands by).
fn expectTakesOver(replication: *Replication) !void {
    const deadline = std.Io.Clock.awake.now(testing.io).nanoseconds + patience;
    while (switch (try replication.status(&.{})) {
        inline else => |either| either.standby,
    }) : (try testing.io.sleep(.fromMilliseconds(5), .awake)) {
        if (std.Io.Clock.awake.now(testing.io).nanoseconds > deadline) return error.TestTimedOut;
    }
}

fn commit(store: *KeyValueStore, key: []const u8) !u64 {
    try store.beginWrite();
    try store.put(key, "value");
    try store.commitWrite();
    return store.last_committed_lsn.?;
}

test "a process standing by takes over a master's replication when the one running it stops" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path = std.mem.zeroes([256]u8);
    var replica_path = std.mem.zeroes([256]u8);
    var master = try open(&tmp, "master", &master_path);
    defer master.deinit();
    // Another store on the database, as another process has.
    var other = try master.share();
    defer other.deinit();
    var replica = try open(&tmp, "replica", &replica_path);
    defer replica.deinit();

    const timing: zypherdb.replication.Role.Master = .{ .address = "127.0.0.1:0", .token = token, .heartbeat_ns = 50 * std.time.ns_per_ms, .timeout_ns = 500 * std.time.ns_per_ms };
    const first = try Replication.start(testing.allocator, &master, pathOf(&master_path), .{ .master = timing });
    var first_stopped = false;
    defer if (!first_stopped) first.stop();
    var address_buffer: [max_address_bytes]u8 = undefined;
    const address = first.address(&address_buffer).?;
    var second_role = timing;
    second_role.address = address;
    const second = try Replication.start(testing.allocator, &other, pathOf(&master_path), .{ .master = second_role });
    defer second.stop();
    try testing.expect((try second.status(&.{})).master.standby);
    try testing.expectEqual(null, second.address(&address_buffer));

    const following = try Replication.start(testing.allocator, &replica, pathOf(&replica_path), .{ .replica = .{
        .master_address = address,
        .token = token,
        .timeout_ns = 500 * std.time.ns_per_ms,
    } });
    defer following.stop();
    try testing.expect(following.waitFor(try commit(&master, "first"), patience));

    first.stop();
    first_stopped = true;
    try expectTakesOver(second);
    try testing.expect(following.waitFor(try commit(&other, "second"), patience));
}

test "a process standing by takes over a replica's replication when the one running it stops" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path = std.mem.zeroes([256]u8);
    var replica_path = std.mem.zeroes([256]u8);
    var master = try open(&tmp, "master", &master_path);
    defer master.deinit();
    var replica = try open(&tmp, "replica", &replica_path);
    defer replica.deinit();
    var other = try replica.share();
    defer other.deinit();

    const serving = try Replication.start(testing.allocator, &master, pathOf(&master_path), .{ .master = .{ .address = "127.0.0.1:0", .token = token, .heartbeat_ns = 50 * std.time.ns_per_ms } });
    defer serving.stop();
    var address_buffer: [max_address_bytes]u8 = undefined;
    const role: zypherdb.replication.Role = .{ .replica = .{ .master_address = serving.address(&address_buffer).?, .token = token, .timeout_ns = 500 * std.time.ns_per_ms } };
    const first = try Replication.start(testing.allocator, &replica, pathOf(&replica_path), role);
    var first_stopped = false;
    defer if (!first_stopped) first.stop();
    const second = try Replication.start(testing.allocator, &other, pathOf(&replica_path), role);
    defer second.stop();
    try testing.expect((try second.status(&.{})).replica.standby);
    try testing.expectError(error.ReadOnlyReplica, other.beginWrite());

    const lsn = try commit(&master, "first");
    try testing.expect(first.waitFor(lsn, patience));
    // Standing by, it waits by looking at the database.
    try testing.expect(second.waitFor(lsn, patience));

    first.stop();
    first_stopped = true;
    try expectTakesOver(second);
    try testing.expect(second.waitFor(try commit(&master, "second"), patience));
    try testing.expectEqual(null, (try second.status(&.{})).replica.halted);
}
