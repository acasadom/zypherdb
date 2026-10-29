//! Replication's threads (replication/server.zig, follower.zig) over TCP
//! on the loopback: an empty replica gets a copy of its master and then
//! each change set as it is committed, resumes after the master restarts,
//! is turned away with the wrong token, and a read on it can wait to see a
//! write on the master. A silent replica or master is let go.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Server = zypherdb.replication_server.Server;
const Follower = zypherdb.replication_follower.Follower;
const SystemClock = zypherdb.replication_clock.SystemClock;
const Tcp = zypherdb.replication_tcp.Tcp;
const Connection = zypherdb.replication_network.Connection;
const Listener = zypherdb.replication_network.Listener;
const Watched = zypherdb.replication_network.Watched;
const max_address_bytes = zypherdb.replication_network.max_address_bytes;
const protocol = zypherdb.replication_protocol;

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
    tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator },
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
        return self.startServerFor(address, copies, 16);
    }

    fn startServerFor(self: *Setup, address: []const u8, copies: []u8, max_replicas: usize) !*Server {
        const server = try Server.start(testing.allocator, testing.io, self.clock.clock(), self.tcp.network(), &self.master, .{
            .address = address,
            .token = token,
            .copies_directory = try self.path("master-copies", copies),
            .heartbeat_ns = 50 * millisecond,
            .timeout_ns = 500 * millisecond,
            .max_replicas = max_replicas,
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
            .timeout_ns = 500 * millisecond,
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

    /// Waits for `watched` to be ready, failing once `deadline` passes.
    fn waitFor(self: *Setup, watched: *Watched, deadline: u64) !void {
        const now = self.clock.clock().now();
        if (now >= deadline) return error.TestTimedOut;
        try self.tcp.network().wait(watched[0..1], deadline - now);
    }

    /// The next connection to `listener`.
    fn accept(self: *Setup, listener: Listener) !Connection {
        const deadline = self.clock.clock().now() + patience;
        while (true) {
            if (try listener.accept()) |connection| return connection;
            var watched: Watched = .{ .source = .{ .listener = listener }, .wanted = .{ .readable = true } };
            try self.waitFor(&watched, deadline);
        }
    }

    /// The next bytes from `connection` into `buffer`: how many, or null
    /// once it ended.
    fn receive(self: *Setup, connection: Connection, buffer: []u8) !?usize {
        const deadline = self.clock.clock().now() + patience;
        while (true) {
            return connection.receive(buffer) catch |err| switch (err) {
                error.Closed => return null,
                error.WouldBlock => {
                    var watched: Watched = .{ .source = .{ .connection = connection }, .wanted = .{ .readable = true } };
                    try self.waitFor(&watched, deadline);
                    continue;
                },
            };
        }
    }

    /// The first message from `connection`, a frame read into `buffer`.
    fn receiveMessage(self: *Setup, connection: Connection, buffer: []u8) !protocol.Message {
        var filled: usize = 0;
        while (true) {
            if (try protocol.decode(buffer[0..filled])) |decoded| return decoded.message;
            filled += try self.receive(connection, buffer[filled..]) orelse return error.EndOfStream;
        }
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
    var stopped = false;
    defer if (!stopped) server.stop();
    var address: [max_address_bytes]u8 = undefined;
    const follower = try setup.startFollower(server, token, &address, &copies[1]);
    defer follower.stop();
    try setup.expectCaughtUp(follower, try setup.write(0, 10));
    var listened: [max_address_bytes]u8 = undefined;
    const at = server.address(&listened);
    setup.master.commit_listener = null;
    server.stop();
    stopped = true;
    const last = try setup.write(10, 10);
    server = try setup.startServer(at, &copies[0]);
    stopped = false;
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

test "a silent replica is let go and frees its place" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    _ = try setup.write(0, 3);
    var copies: [2][256]u8 = undefined;
    const server = try setup.startServerFor("127.0.0.1:0", &copies[0], 1);
    defer server.stop();
    var address: [max_address_bytes]u8 = undefined;
    // It takes the only place and says nothing.
    const silent = try setup.tcp.network().connect(server.address(&address));
    defer silent.close();
    const follower = try setup.startFollower(server, token, &address, &copies[1]);
    defer follower.stop();
    try setup.expectCaughtUp(follower, (try setup.master.changeLogState()).?.next_lsn - 1);
    // The master closed the silent one, having sent it nothing.
    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), try setup.receive(silent, &buffer));
}

test "a replica leaves a silent master and connects again" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    // A master that accepts and says nothing.
    const listener = try setup.tcp.network().listen("127.0.0.1:0");
    defer listener.close();
    var address: [max_address_bytes]u8 = undefined;
    var copies: [256]u8 = undefined;
    const follower = try Follower.start(testing.allocator, testing.io, setup.clock.clock(), setup.tcp.network(), &setup.replica, .{
        .master_address = listener.address(&address),
        .token = token,
        .copies_directory = try setup.path("replica-copies", &copies),
        .first_retry_ns = 10 * millisecond,
        .timeout_ns = 100 * millisecond,
    });
    defer follower.stop();
    const buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(buffer);
    const first = try setup.accept(listener);
    defer first.close();
    try testing.expectEqual(.hello, std.meta.activeTag(try setup.receiveMessage(first, buffer)));
    // Left after its timeout: the connection ends and another comes.
    try testing.expectEqual(@as(?usize, null), try setup.receive(first, buffer));
    const second = try setup.accept(listener);
    defer second.close();
    try testing.expectEqual(.hello, std.meta.activeTag(try setup.receiveMessage(second, buffer)));
}
