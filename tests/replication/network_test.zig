//! The network for an event loop (replication/network.zig), each
//! test on both backends: TCP on the loopback and the one in memory. What
//! one end sends the other receives, nothing blocks, a full connection
//! makes a send wait, a closed end is told, and `wait` says what is ready.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const network_module = zypherdb.replication_network;
const Network = network_module.Network;
const Connection = network_module.Connection;
const Listener = network_module.Listener;
const Readiness = network_module.Readiness;
const Source = network_module.Source;
const Watched = network_module.Watched;
const Tcp = zypherdb.replication_tcp.Tcp;
const MemoryNetwork = zypherdb.replication_memory_network.MemoryNetwork;
const SystemClock = zypherdb.replication_clock.SystemClock;

const loopback = "127.0.0.1:0";

/// Runs `body` on TCP and on a network in memory.
fn onEachNetwork(comptime body: fn (Network) anyerror!void) !void {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    try body(tcp.network());
    var memory: MemoryNetwork = .{ .allocator = testing.allocator, .capacity = 4096 };
    defer memory.deinit();
    try body(memory.network());
}

/// Waits until `source` is ready for `wanted` (some of it); fails if it
/// takes seconds (or, in memory, if it is not ready now).
fn waitFor(network: Network, source: Source, wanted: Readiness) !Readiness {
    var watched = [_]Watched{.{ .source = source, .wanted = wanted }};
    for (0..100) |_| {
        try network.wait(&watched, 100 * std.time.ns_per_ms);
        if (watched[0].ready.any()) return watched[0].ready;
    }
    return error.NeverReady;
}

/// What `source` is ready for now, without waiting.
fn readyNow(network: Network, source: Source, wanted: Readiness) !Readiness {
    var watched = [_]Watched{.{ .source = source, .wanted = wanted }};
    try network.wait(&watched, 0);
    return watched[0].ready;
}

/// A listener, a connection to it, and the connection accepted.
const Pair = struct {
    listener: Listener,
    client: Connection,
    server: Connection,

    fn open(network: Network) !Pair {
        const listener = try network.listen(loopback);
        errdefer listener.close();
        var buffer: [network_module.max_address_bytes]u8 = undefined;
        const client = try network.connect(listener.address(&buffer));
        errdefer client.close();
        _ = try waitFor(network, .{ .listener = listener }, .{ .readable = true });
        const server = try listener.accept() orelse return error.NothingAccepted;
        return .{ .listener = listener, .client = client, .server = server };
    }

    fn close(self: Pair) void {
        self.server.close();
        self.client.close();
        self.listener.close();
    }
};

fn sendAll(network: Network, connection: Connection, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += connection.send(bytes[sent..]) catch |err| switch (err) {
            error.WouldBlock => {
                _ = try waitFor(network, .{ .connection = connection }, .{ .writable = true });
                continue;
            },
            else => return err,
        };
    }
}

fn receiveAll(network: Network, connection: Connection, buffer: []u8) !void {
    var received: usize = 0;
    while (received < buffer.len) {
        received += connection.receive(buffer[received..]) catch |err| switch (err) {
            error.WouldBlock => {
                _ = try waitFor(network, .{ .connection = connection }, .{ .readable = true });
                continue;
            },
            else => return err,
        };
    }
}

/// The byte at `index` of a long stream, so order shows.
fn patternByte(index: usize) u8 {
    return @truncate(index % 251);
}

test "bytes sent at one end are received at the other, both ways" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const pair = try Pair.open(network);
            defer pair.close();
            try sendAll(network, pair.client, "hello ");
            try sendAll(network, pair.client, "master");
            var received: [12]u8 = undefined;
            try receiveAll(network, pair.server, &received);
            try testing.expectEqualStrings("hello master", &received);
            try sendAll(network, pair.server, "ack");
            try receiveAll(network, pair.client, received[0..3]);
            try testing.expectEqualStrings("ack", received[0..3]);
        }
    }.run);
}

test "a long stream sent and received in pieces of odd sizes arrives whole and in order" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const pair = try Pair.open(network);
            defer pair.close();
            const total = 200_000;
            var piece: [1500]u8 = undefined;
            var sent: usize = 0;
            var received: usize = 0;
            var round: usize = 0;
            while (received < total) : (round += 1) {
                if (sent < total) {
                    const size = @min(1 + round * 7 % piece.len, total - sent);
                    for (piece[0..size], 0..) |*byte, index| byte.* = patternByte(sent + index);
                    sent += pair.client.send(piece[0..size]) catch |err| switch (err) {
                        error.WouldBlock => 0,
                        else => return err,
                    };
                }
                const size = 1 + round * 13 % 997;
                const count = pair.server.receive(piece[0..size]) catch |err| switch (err) {
                    error.WouldBlock => {
                        if (sent == total) _ = try waitFor(network, .{ .connection = pair.server }, .{ .readable = true });
                        continue;
                    },
                    else => return err,
                };
                for (piece[0..count], 0..) |byte, index| try testing.expectEqual(patternByte(received + index), byte);
                received += count;
            }
        }
    }.run);
}

test "with nothing there, a receive or an accept would block and a wait says not ready" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const pair = try Pair.open(network);
            defer pair.close();
            var buffer: [8]u8 = undefined;
            try testing.expectError(error.WouldBlock, pair.server.receive(&buffer));
            try testing.expect(!(try readyNow(network, .{ .connection = pair.server }, .{ .readable = true })).any());
            try testing.expectEqual(null, try pair.listener.accept());
            try testing.expect(!(try readyNow(network, .{ .listener = pair.listener }, .{ .readable = true })).any());
            try testing.expect((try readyNow(network, .{ .connection = pair.server }, .{ .writable = true })).writable);
        }
    }.run);
}

test "a closed end is told to the other, after what it sent" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const listener = try network.listen(loopback);
            defer listener.close();
            var buffer: [network_module.max_address_bytes]u8 = undefined;
            const client = try network.connect(listener.address(&buffer));
            _ = try waitFor(network, .{ .listener = listener }, .{ .readable = true });
            const server = try listener.accept() orelse return error.NothingAccepted;
            defer server.close();
            try sendAll(network, client, "bye");
            client.close();
            var received: [3]u8 = undefined;
            try receiveAll(network, server, &received);
            try testing.expectEqualStrings("bye", &received);
            _ = try waitFor(network, .{ .connection = server }, .{ .readable = true });
            try testing.expectError(error.Closed, server.receive(&received));
            // TCP may take a send or two before it knows the other end is gone.
            for (0..100) |_| {
                _ = server.send("more") catch |err| switch (err) {
                    error.Closed => return,
                    error.WouldBlock => {},
                };
                _ = try waitFor(network, .{ .connection = server }, .{ .writable = true });
            }
            return error.NeverClosed;
        }
    }.run);
}

test "a send would block once the other end stops receiving, and goes on when it receives" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const pair = try Pair.open(network);
            defer pair.close();
            var chunk: [4096]u8 = undefined;
            var sent: usize = 0;
            while (true) {
                for (&chunk, 0..) |*byte, index| byte.* = patternByte(sent + index);
                sent += pair.client.send(&chunk) catch |err| switch (err) {
                    error.WouldBlock => break,
                    else => return err,
                };
            }
            try testing.expect(sent > 0);
            try testing.expect(!(try readyNow(network, .{ .connection = pair.client }, .{ .writable = true })).writable);
            var received: usize = 0;
            while (received < sent) {
                const count = pair.server.receive(&chunk) catch |err| switch (err) {
                    error.WouldBlock => {
                        _ = try waitFor(network, .{ .connection = pair.server }, .{ .readable = true });
                        continue;
                    },
                    else => return err,
                };
                for (chunk[0..count], 0..) |byte, index| try testing.expectEqual(patternByte(received + index), byte);
                received += count;
            }
            try testing.expectEqual(sent, received);
            try testing.expect((try waitFor(network, .{ .connection = pair.client }, .{ .writable = true })).writable);
        }
    }.run);
}

test "connecting where nobody listens fails, at once or as a closed connection" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const listener = try network.listen(loopback);
            var buffer: [network_module.max_address_bytes]u8 = undefined;
            const address = listener.address(&buffer);
            listener.close();
            const client = network.connect(address) catch |err| switch (err) {
                error.NetworkFailed => return,
                else => return err,
            };
            defer client.close();
            const ready = try waitFor(network, .{ .connection = client }, .{ .readable = true, .writable = true });
            try testing.expect(ready.any());
            var received: [1]u8 = undefined;
            try testing.expectError(error.Closed, client.receive(&received));
        }
    }.run);
}

test "a raised wakeup is ready until cleared" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const wakeup = try network.wakeup();
            defer wakeup.close();
            try testing.expect(!(try readyNow(network, .{ .wakeup = wakeup }, .{ .readable = true })).any());
            wakeup.raise();
            wakeup.raise();
            try testing.expect((try waitFor(network, .{ .wakeup = wakeup }, .{ .readable = true })).readable);
            wakeup.clear();
            try testing.expect(!(try readyNow(network, .{ .wakeup = wakeup }, .{ .readable = true })).any());
        }
    }.run);
}

test "a wait says which of several is ready" {
    try onEachNetwork(struct {
        fn run(network: Network) !void {
            const pair = try Pair.open(network);
            defer pair.close();
            const wakeup = try network.wakeup();
            defer wakeup.close();
            try sendAll(network, pair.client, "x");
            _ = try waitFor(network, .{ .connection = pair.server }, .{ .readable = true });
            var watched = [_]Watched{
                .{ .source = .{ .listener = pair.listener }, .wanted = .{ .readable = true } },
                .{ .source = .{ .wakeup = wakeup }, .wanted = .{ .readable = true } },
                .{ .source = .{ .connection = pair.client }, .wanted = .{ .readable = true } },
                .{ .source = .{ .connection = pair.server }, .wanted = .{ .readable = true } },
            };
            try network.wait(&watched, 0);
            try testing.expect(!watched[0].ready.any());
            try testing.expect(!watched[1].ready.any());
            try testing.expect(!watched[2].ready.any());
            try testing.expect(watched[3].ready.readable);
            try testing.expect(!watched[3].ready.writable);
        }
    }.run);
}

test "a listener closed with connections not accepted closes them" {
    var memory: MemoryNetwork = .{ .allocator = testing.allocator };
    defer memory.deinit();
    const network = memory.network();
    const listener = try network.listen(loopback);
    var buffer: [network_module.max_address_bytes]u8 = undefined;
    const client = try network.connect(listener.address(&buffer));
    defer client.close();
    listener.close();
    var received: [1]u8 = undefined;
    try testing.expectError(error.Closed, client.receive(&received));
    try testing.expectError(error.Closed, client.send("x"));
}

test "a wakeup raised on another thread ends a wait with no time limit" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const network = tcp.network();
    const wakeup = try network.wakeup();
    defer wakeup.close();
    const Raising = struct {
        fn run(raised: network_module.Wakeup) void {
            testing.io.sleep(.fromMilliseconds(20), .awake) catch {};
            raised.raise();
        }
    };
    const thread = try std.Thread.spawn(.{}, Raising.run, .{wakeup});
    defer thread.join();
    var watched = [_]Watched{.{ .source = .{ .wakeup = wakeup }, .wanted = .{ .readable = true } }};
    try network.wait(&watched, null);
    try testing.expect(watched[0].ready.readable);
}

test "a wait with nothing ready ends after its timeout" {
    var tcp: Tcp = .{ .io = testing.io, .allocator = testing.allocator };
    const network = tcp.network();
    const pair = try Pair.open(network);
    defer pair.close();
    var system_clock: SystemClock = .{ .io = testing.io };
    const clock = system_clock.clock();
    var watched = [_]Watched{.{ .source = .{ .connection = pair.server }, .wanted = .{ .readable = true } }};
    const started = clock.now();
    try network.wait(&watched, 30 * std.time.ns_per_ms);
    try testing.expect(!watched[0].ready.any());
    try testing.expect(clock.now() - started >= 30 * std.time.ns_per_ms);
}
