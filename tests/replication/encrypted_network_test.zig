//! The encrypted network (replication/encrypted_network.zig), with a test in
//! the middle of each connection: it sees what travels and can change it.
//! tests/replication/network_test.zig runs the promises of any network on it.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const protocol = zypherdb.replication_protocol;
const network_module = zypherdb.replication_network;
const Connection = network_module.Connection;
const Listener = network_module.Listener;
const Network = network_module.Network;
const Watched = network_module.Watched;
const MemoryNetwork = zypherdb.replication_memory_network.MemoryNetwork;
const EncryptedNetwork = zypherdb.replication_encrypted_network.EncryptedNetwork;

const client_side = "client:1";
const server_side = "server:1";
const token = "the token that never travels";
const secret = "a secret change set, word for word";

/// A client and a server of encrypted networks, each of its own token,
/// joined through two plain connections the bench holds.
const Bench = struct {
    memory: MemoryNetwork,
    prng: std.Random.DefaultPrng,
    client_network: EncryptedNetwork,
    server_network: EncryptedNetwork,
    client_listener: Listener,
    server_listener: Listener,
    client: Connection,
    server: ?Connection = null,
    to_client: Connection,
    to_server: Connection,
    /// All that went from the client to the server, and back.
    upstream: std.ArrayList(u8) = .empty,
    downstream: std.ArrayList(u8) = .empty,

    fn init(self: *Bench, client_token: []const u8, server_token: []const u8) !void {
        self.memory = .{ .allocator = testing.allocator, .capacity = 1 << 20 };
        self.prng = .init(7);
        self.upstream = .empty;
        self.downstream = .empty;
        self.server = null;
        const memory = self.memory.network();
        self.client_network = .init(memory, testing.allocator, self.prng.random(), client_token);
        self.server_network = .init(memory, testing.allocator, self.prng.random(), server_token);
        self.client_listener = try memory.listen(client_side);
        self.server_listener = try self.server_network.network().listen(server_side);
        self.client = try self.client_network.network().connect(client_side);
        self.to_client = (try self.client_listener.accept()).?;
        self.to_server = try memory.connect(server_side);
    }

    fn deinit(self: *Bench) void {
        self.client.close();
        if (self.server) |server| server.close();
        self.to_client.close();
        self.to_server.close();
        self.client_listener.close();
        self.server_listener.close();
        self.memory.deinit();
        self.upstream.deinit(testing.allocator);
        self.downstream.deinit(testing.allocator);
    }

    /// Moves what waits on one plain connection to the other.
    fn carry(from: Connection, into: Connection, seen: *std.ArrayList(u8)) !void {
        var buffer: [1 << 16]u8 = undefined;
        while (true) {
            const count = from.receive(&buffer) catch |err| switch (err) {
                error.WouldBlock, error.Closed => return,
            };
            try seen.appendSlice(testing.allocator, buffer[0..count]);
            var sent: usize = 0;
            while (sent < count) sent += into.send(buffer[sent..count]) catch |err| switch (err) {
                error.WouldBlock, error.Closed => return,
            };
        }
    }

    /// Lets both ends go on until nothing more moves.
    fn settle(self: *Bench) !void {
        for (0..16) |_| {
            if (self.server == null) self.server = try self.server_listener.accept();
            try self.waitOn(self.client_network.network(), self.client);
            if (self.server) |server| try self.waitOn(self.server_network.network(), server);
            try carry(self.to_client, self.to_server, &self.upstream);
            try carry(self.to_server, self.to_client, &self.downstream);
        }
    }

    fn waitOn(_: *Bench, network: Network, connection: Connection) !void {
        var watched = [_]Watched{.{ .source = .{ .connection = connection }, .wanted = .{ .readable = false, .writable = false } }};
        try network.wait(&watched, 0);
    }
};

fn receiveAll(connection: Connection, buffer: []u8) ![]u8 {
    var length: usize = 0;
    while (length < buffer.len) {
        length += connection.receive(buffer[length..]) catch |err| switch (err) {
            error.WouldBlock => break,
            error.Closed => if (length > 0) break else return error.Closed,
        };
    }
    return buffer[0..length];
}

test "what travels is neither the token nor what was sent, and what comes out is what went in" {
    var bench: Bench = undefined;
    try bench.init(token, token);
    defer bench.deinit();
    try bench.settle();
    try testing.expectEqual(secret.len, try bench.client.send(secret));
    try testing.expectEqual(secret.len, try bench.server.?.send(secret));
    try bench.settle();
    var buffer: [secret.len]u8 = undefined;
    try testing.expectEqualStrings(secret, try receiveAll(bench.server.?, &buffer));
    try testing.expectEqualStrings(secret, try receiveAll(bench.client, &buffer));
    for ([_][]const u8{ bench.upstream.items, bench.downstream.items }) |travelled| {
        try testing.expect(travelled.len > secret.len);
        try testing.expect(std.mem.indexOf(u8, travelled, token) == null);
        try testing.expect(std.mem.indexOf(u8, travelled, secret) == null);
    }
}

test "more than a record's bytes, sent whole and received whole" {
    var bench: Bench = undefined;
    try bench.init(token, token);
    defer bench.deinit();
    try bench.settle();
    const bytes = try testing.allocator.alloc(u8, 3 * protocol.part_bytes / 2);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    const received = try testing.allocator.alloc(u8, bytes.len);
    defer testing.allocator.free(received);
    var sent: usize = 0;
    var taken: usize = 0;
    while (taken < bytes.len) {
        if (sent < bytes.len) sent += bench.client.send(bytes[sent..]) catch |err| switch (err) {
            error.WouldBlock => 0,
            error.Closed => return err,
        };
        try bench.settle();
        taken += (try receiveAll(bench.server.?, received[taken..])).len;
    }
    try testing.expectEqualSlices(u8, bytes, received);
}

test "a wrong token is refused as such, in a frame the refused side reads" {
    var bench: Bench = undefined;
    try bench.init("not the token", token);
    defer bench.deinit();
    try bench.settle();
    var buffer: [protocol.max_frame_bytes]u8 = undefined;
    const refusal = try receiveAll(bench.client, &buffer);
    const decoded = (try protocol.decode(refusal)).?;
    try testing.expectEqual(protocol.Refusal.token, decoded.message.refused);
    try testing.expectError(error.Closed, bench.client.receive(&buffer));
    try testing.expectError(error.Closed, bench.client.send("nothing"));
    try testing.expectError(error.Closed, bench.server.?.receive(&buffer));
}

test "before there are keys, a refusal that would stop a replica for good is not believed" {
    var bench: Bench = undefined;
    try bench.init(token, token);
    defer bench.deinit();
    var frame: [protocol.max_frame_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&frame);
    try protocol.write(&writer, .{ .refused = .database_id });
    _ = try bench.to_client.send(writer.buffered());
    var buffer: [protocol.max_frame_bytes]u8 = undefined;
    try testing.expectError(error.Closed, bench.client.receive(&buffer));
}

test "a side that does not encrypt is refused for that" {
    var bench: Bench = undefined;
    try bench.init(token, token);
    defer bench.deinit();
    // A hello in clear reaches the server in place of the client's handshake.
    var frame: [protocol.max_frame_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&frame);
    try protocol.write(&writer, .{ .ack = 1 });
    _ = try bench.to_server.send(writer.buffered());
    bench.server = (try bench.server_listener.accept()).?;
    var watched = [_]Watched{.{ .source = .{ .connection = bench.server.? }, .wanted = .{ .readable = true } }};
    try bench.server_network.network().wait(&watched, 0);
    var answer: [64]u8 = undefined;
    const count = try bench.to_server.receive(&answer);
    const decoded = (try protocol.decode(answer[0..count])).?;
    try testing.expectEqual(protocol.Refusal.encryption, decoded.message.refused);
    var buffer: [8]u8 = undefined;
    try testing.expectError(error.Closed, bench.server.?.receive(&buffer));
}

test "a changed bit in a record ends the connection, and nothing of it is told" {
    var bench: Bench = undefined;
    try bench.init(token, token);
    defer bench.deinit();
    try bench.settle();
    _ = try bench.client.send(secret);
    var record: [1024]u8 = undefined;
    const count = try bench.to_client.receive(&record);
    record[count - 1] ^= 1;
    _ = try bench.to_server.send(record[0..count]);
    try bench.waitOn(bench.server_network.network(), bench.server.?);
    var buffer: [secret.len]u8 = undefined;
    try testing.expectError(error.Closed, bench.server.?.receive(&buffer));
}

test "a record sent again ends the connection" {
    var bench: Bench = undefined;
    try bench.init(token, token);
    defer bench.deinit();
    try bench.settle();
    _ = try bench.client.send(secret);
    var record: [1024]u8 = undefined;
    const count = try bench.to_client.receive(&record);
    _ = try bench.to_server.send(record[0..count]);
    _ = try bench.to_server.send(record[0..count]);
    var buffer: [secret.len]u8 = undefined;
    try testing.expectEqualStrings(secret, try receiveAll(bench.server.?, &buffer));
    try testing.expectError(error.Closed, bench.server.?.receive(&buffer));
}

test "a client's first message replayed on a new connection learns nothing and is let go" {
    var bench: Bench = undefined;
    try bench.init(token, token);
    defer bench.deinit();
    try bench.settle();
    _ = try bench.client.send(secret);
    var record: [1024]u8 = undefined;
    const count = try bench.to_client.receive(&record);

    // The replayer has the first message and the record, and no keys.
    const replay = try bench.memory.network().connect(server_side);
    defer replay.close();
    const handshake_frame = bench.upstream.items[0 .. protocol.frame_header_bytes + protocol.handshake_bytes];
    _ = try replay.send(handshake_frame);
    const server = (try bench.server_listener.accept()).?;
    defer server.close();
    var buffer: [secret.len]u8 = undefined;
    try testing.expectError(error.WouldBlock, server.receive(&buffer));
    // The server answered with keys of its own: the old record fails.
    _ = try replay.send(record[0..count]);
    try testing.expectError(error.Closed, server.receive(&buffer));
}
