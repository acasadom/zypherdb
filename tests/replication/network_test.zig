//! The network replication runs on (replication/network.zig), over TCP on
//! the loopback: what one end writes the other reads, a shut down listener
//! or connection wakes the thread blocked on it, and a watchdog shuts down
//! a connection that went quiet.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const network_module = zypherdb.replication_network;
const protocol = zypherdb.replication_protocol;
const Tcp = network_module.Tcp;
const Connection = network_module.Connection;
const Listener = network_module.Listener;
const Watchdog = zypherdb.replication_watchdog.Watchdog;
const SystemClock = zypherdb.replication_clock.SystemClock;

const loopback = "127.0.0.1:0";

/// A listener on the loopback, a connection to it, and the connection
/// accepted.
const Pair = struct {
    listener: Listener,
    client: Connection,
    server: Connection,

    fn open(tcp: *Tcp) !Pair {
        const listener = try tcp.network().listen(loopback);
        errdefer listener.close();
        var buffer: [network_module.max_address_bytes]u8 = undefined;
        const client = try tcp.network().connect(listener.address(&buffer));
        errdefer client.close();
        return .{ .listener = listener, .client = client, .server = try listener.accept() };
    }

    fn close(self: Pair) void {
        self.server.close();
        self.client.close();
        self.listener.close();
    }
};

test "frames written at one end are read at the other" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const pair = try Pair.open(&tcp);
    defer pair.close();
    try protocol.write(pair.client.writer(), .{ .ack = 41 });
    try protocol.write(pair.client.writer(), .{ .snapshot_part = "bytes" });
    try pair.client.writer().flush();
    try testing.expectEqual(@as(u64, 41), (try protocol.read(pair.server.reader())).ack);
    try testing.expectEqualStrings("bytes", (try protocol.read(pair.server.reader())).snapshot_part);
    try protocol.write(pair.server.writer(), .{ .heartbeat = 7 });
    try pair.server.writer().flush();
    try testing.expectEqual(@as(u64, 7), (try protocol.read(pair.client.reader())).heartbeat);
}

test "a frame bigger than a read is read whole" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const pair = try Pair.open(&tcp);
    defer pair.close();
    const part = try testing.allocator.alloc(u8, protocol.part_bytes);
    defer testing.allocator.free(part);
    for (part, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    const Writing = struct {
        fn run(connection: Connection, bytes: []const u8) void {
            protocol.write(connection.writer(), .{ .snapshot_part = bytes }) catch return;
            connection.writer().flush() catch return;
        }
    };
    const thread = try std.Thread.spawn(.{}, Writing.run, .{ pair.client, part });
    defer thread.join();
    try testing.expectEqualSlices(u8, part, (try protocol.read(pair.server.reader())).snapshot_part);
}

test "a read ends when the other end closes" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const listener = try tcp.network().listen(loopback);
    defer listener.close();
    var buffer: [network_module.max_address_bytes]u8 = undefined;
    const client = try tcp.network().connect(listener.address(&buffer));
    const server = try listener.accept();
    defer server.close();
    client.close();
    try testing.expectError(error.EndOfStream, protocol.read(server.reader()));
}

fn shutDownLater(comptime What: type, what: What) void {
    testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
    what.shutdown();
}

test "a shutdown wakes a read blocked in another thread" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const pair = try Pair.open(&tcp);
    defer pair.close();
    const thread = try std.Thread.spawn(.{}, shutDownLater, .{ Connection, pair.server });
    defer thread.join();
    if (protocol.read(pair.server.reader())) |_| return error.TestUnexpectedResult else |_| {}
    // And so does every read after it.
    if (protocol.read(pair.server.reader())) |_| return error.TestUnexpectedResult else |_| {}
}

test "a shutdown wakes an accept blocked in another thread" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const listener = try tcp.network().listen(loopback);
    defer listener.close();
    const thread = try std.Thread.spawn(.{}, shutDownLater, .{ Listener, listener });
    defer thread.join();
    try testing.expectError(error.ListenerShutDown, listener.accept());
    try testing.expectError(error.ListenerShutDown, listener.accept());
}

test "connecting where no one listens fails" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const listener = try tcp.network().listen(loopback);
    var buffer: [network_module.max_address_bytes]u8 = undefined;
    const address = try testing.allocator.dupe(u8, listener.address(&buffer));
    defer testing.allocator.free(address);
    listener.close();
    try testing.expectError(error.NetworkFailed, tcp.network().connect(address));
    try testing.expectError(error.NetworkFailed, tcp.network().connect("no port"));
}

/// Whether a frame written at one end of `pair` is read at the other.
fn stillOpen(pair: Pair) bool {
    protocol.write(pair.client.writer(), .{ .ack = 1 }) catch return false;
    pair.client.writer().flush() catch return false;
    const message = protocol.read(pair.server.reader()) catch return false;
    return message == .ack;
}

test "a watchdog shuts down a connection quiet for longer than its timeout" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const pair = try Pair.open(&tcp);
    defer pair.close();
    var system: SystemClock = .{ .io = testing.io };
    const clock = system.clock();
    var watchdog: Watchdog = .{ .clock = clock, .connection = pair.server, .timeout_ns = 30 * std.time.ns_per_ms };
    try watchdog.start();
    defer watchdog.stop();
    const start = clock.now();
    if (protocol.read(pair.server.reader())) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expect(clock.now() >= start + 30 * std.time.ns_per_ms);
}

test "a watchdog fed in time, or allowed longer, leaves the connection open" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const pair = try Pair.open(&tcp);
    defer pair.close();
    var system: SystemClock = .{ .io = testing.io };
    var watchdog: Watchdog = .{ .clock = system.clock(), .connection = pair.server, .timeout_ns = 50 * std.time.ns_per_ms };
    try watchdog.start();
    defer watchdog.stop();
    for (0..10) |_| {
        try testing.io.sleep(.fromMilliseconds(10), .awake);
        watchdog.fed();
    }
    try testing.expect(stillOpen(pair));
    watchdog.allow(400 * std.time.ns_per_ms);
    try testing.io.sleep(.fromMilliseconds(120), .awake);
    try testing.expect(stillOpen(pair));
}

test "a feeding writer feeds the watchdog with each write" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const pair = try Pair.open(&tcp);
    defer pair.close();
    var system: SystemClock = .{ .io = testing.io };
    var watchdog: Watchdog = .{ .clock = system.clock(), .connection = pair.server, .timeout_ns = 50 * std.time.ns_per_ms };
    try watchdog.start();
    defer watchdog.stop();
    var sink: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sink.deinit();
    var feeding = watchdog.feedingWriter(&sink.writer);
    for (0..10) |_| {
        try testing.io.sleep(.fromMilliseconds(10), .awake);
        try feeding.interface.writeAll("part");
    }
    try testing.expectEqualStrings("part" ++ "part" ++ "part" ++ "part" ++ "part" ++ "part" ++ "part" ++ "part" ++ "part" ++ "part", sink.written());
    try testing.expect(stillOpen(pair));
}
