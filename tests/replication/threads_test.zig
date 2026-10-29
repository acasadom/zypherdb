//! Replication's threads (replication/server.zig, follower.zig) over TCP
//! on the loopback: an empty replica gets a copy of its master and then
//! each change set as it is committed, resumes after the master restarts,
//! is turned away with the wrong token, and a read on it can wait to see a
//! write on the master.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Server = zypherdb.replication_server.Server;
const Follower = zypherdb.replication_follower.Follower;
const SystemClock = zypherdb.replication_clock.SystemClock;
const Tcp = zypherdb.replication_network.Tcp;
const max_address_bytes = zypherdb.replication_network.max_address_bytes;

const support = @import("../support.zig");
const testPath = support.testPath;
const contents = support.contents;

const token = "the master's token";
const millisecond = std.time.ns_per_ms;
/// Longer than any wait the tests expect to end on its own.
const patience = 20 * std.time.ns_per_s;

/// A master and a replica database in `tmp`, and what replication runs on.
const Setup = struct {
    tmp: testing.TmpDir,
    base: [128]u8 = undefined,
    clock: SystemClock = .{ .io = testing.io },
    tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator, .read_timeout_ns = 500 * millisecond },
    master: KeyValueStore = undefined,
    replica: KeyValueStore = undefined,

    fn init(self: *Setup) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}) };
        errdefer self.tmp.cleanup();
        self.master = try self.open("master");
        errdefer self.master.deinit();
        try self.master.startChangeLog();
        self.replica = try self.open("replica");
    }

    fn deinit(self: *Setup) void {
        self.replica.deinit();
        self.master.deinit();
        self.tmp.cleanup();
    }

    fn open(self: *Setup, name: []const u8) !KeyValueStore {
        try self.tmp.dir.createDirPath(testing.io, name);
        var buffer: [256]u8 = undefined;
        return KeyValueStore.open(testing.allocator, try self.path(name, &buffer));
    }

    fn path(self: *Setup, name: []const u8, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(&self.tmp, &self.base), name });
    }

    fn startServer(self: *Setup, address: []const u8, copies: []u8) !*Server {
        const server = try Server.start(testing.allocator, testing.io, self.clock.clock(), self.tcp.network(), &self.master, .{
            .address = address,
            .token = token,
            .copies_directory = try self.path("master-copies", copies),
            .heartbeat_ns = 50 * millisecond,
        });
        self.master.commit_listener = server.commitListener();
        return server;
    }

    fn startFollower(self: *Setup, server: *Server, with_token: []const u8, address: *[max_address_bytes]u8, copies: []u8) !*Follower {
        return Follower.start(testing.allocator, testing.io, self.clock.clock(), self.tcp.network(), &self.replica, .{
            .master_address = server.address(address),
            .token = with_token,
            .copies_directory = try self.path("replica-copies", copies),
            .first_retry_ns = 10 * millisecond,
            .longest_retry_ns = 100 * millisecond,
        });
    }

    /// Commits `count` keys from `first` on the master; returns its last LSN.
    fn write(self: *Setup, first: usize, count: usize) !u64 {
        for (first..first + count) |index| {
            var key: [32]u8 = undefined;
            try self.master.beginWrite();
            try self.master.put(try std.fmt.bufPrint(&key, "key {d}", .{index}), "value");
            try self.master.commitWrite();
        }
        return (try self.master.changeLogState()).?.next_lsn - 1;
    }

    /// Waits until the replica applied `lsn`, then checks it equals the master.
    fn expectCaughtUp(self: *Setup, follower: *Follower, lsn: u64) !void {
        const clock = self.clock.clock();
        try testing.expect(follower.waitApplied(lsn, clock.now() + patience).? >= lsn);
        try testing.expectEqual(try contents(&self.master), try contents(&self.replica));
    }
};

test "an empty replica gets a copy, then each change set committed" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    _ = try setup.write(0, 20);
    var copies: [2][256]u8 = undefined;
    const server = try setup.startServer("127.0.0.1:0", &copies[0]);
    defer server.stop();
    var address: [max_address_bytes]u8 = undefined;
    const follower = try setup.startFollower(server, token, &address, &copies[1]);
    defer follower.stop();
    try setup.expectCaughtUp(follower, (try setup.master.changeLogState()).?.next_lsn - 1);
    try setup.expectCaughtUp(follower, try setup.write(20, 30));
    // Writes on the replica are refused.
    try testing.expectError(error.ReadOnlyReplica, setup.replica.beginWrite());
}

test "a replica resumes after its master restarts" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var copies: [2][256]u8 = undefined;
    var server = try setup.startServer("127.0.0.1:0", &copies[0]);
    var address: [max_address_bytes]u8 = undefined;
    const follower = try setup.startFollower(server, token, &address, &copies[1]);
    defer follower.stop();
    try setup.expectCaughtUp(follower, try setup.write(0, 10));
    var listened: [max_address_bytes]u8 = undefined;
    const at = server.address(&listened);
    server.stop();
    setup.master.commit_listener = null;
    const last = try setup.write(10, 10);
    server = try setup.startServer(at, &copies[0]);
    defer server.stop();
    try setup.expectCaughtUp(follower, last);
    try setup.expectCaughtUp(follower, try setup.write(20, 5));
}

test "a replica with the wrong token is turned away" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    _ = try setup.write(0, 3);
    var copies: [2][256]u8 = undefined;
    const server = try setup.startServer("127.0.0.1:0", &copies[0]);
    defer server.stop();
    var address: [max_address_bytes]u8 = undefined;
    const follower = try setup.startFollower(server, "not the token", &address, &copies[1]);
    defer follower.stop();
    const clock = setup.clock.clock();
    const deadline = clock.now() + patience;
    while (follower.lastRefusal() == null and clock.now() < deadline) try testing.io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectEqual(zypherdb.replication_protocol.Refusal.token, follower.lastRefusal().?);
    try testing.expectEqual(@as(?u64, null), try setup.replica.appliedLsn());
}

test "a read on the replica waits to see a write committed on the master" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    var copies: [2][256]u8 = undefined;
    const server = try setup.startServer("127.0.0.1:0", &copies[0]);
    defer server.stop();
    var address: [max_address_bytes]u8 = undefined;
    const follower = try setup.startFollower(server, token, &address, &copies[1]);
    defer follower.stop();
    const clock = setup.clock.clock();
    for (0..20) |index| {
        var key: [32]u8 = undefined;
        const written = try std.fmt.bufPrint(&key, "written {d}", .{index});
        try setup.master.beginWrite();
        try setup.master.put(written, "value");
        try setup.master.commitWrite();
        const lsn = setup.master.last_committed_lsn.?;
        try testing.expect(follower.waitApplied(lsn, clock.now() + patience).? >= lsn);
        try setup.replica.beginRead();
        defer setup.replica.commitRead();
        try testing.expect(try setup.replica.exists(written));
    }
    // A change set never committed: the wait ends at its deadline.
    const last = setup.master.last_committed_lsn.?;
    const start = clock.now();
    try testing.expectEqual(@as(?u64, last), follower.waitApplied(last + 1, start + 50 * millisecond));
    try testing.expect(clock.now() >= start + 50 * millisecond);
}
