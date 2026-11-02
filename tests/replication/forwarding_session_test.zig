//! A replica's conversation with its master for forwarded writes
//! (replication/forwarding_session.zig), with no network: its frames go
//! to a master's writer session (writer_session.zig) and back, or are
//! made by hand, on a clock of the test's own. A request goes in parts and
//! its answer comes back joined; heartbeats are acked; a request may be
//! sent again until its final part is out; a silent master is given up on.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const protocol = zypherdb.replication_protocol;
const MasterSession = zypherdb.replication_master_session.MasterSession;
const WriterSession = zypherdb.replication_writer_session.WriterSession;
const ForwardingSession = zypherdb.replication_forwarding_session.ForwardingSession;
const Instant = zypherdb.replication_clock.Instant;

const support = @import("../support.zig");

const token = "the master's token";
const ms = std.time.ns_per_ms;
const heartbeat_ns = 100 * ms;
const timeout_ns = 500 * ms;

/// A replica's forwarding session and the master's writer session it
/// talks to.
const Pair = struct {
    tmp: testing.TmpDir,
    store: KeyValueStore,
    buffers: []u8,
    replica: ForwardingSession = undefined,
    master: WriterSession = undefined,
    now: Instant = 0,

    fn init(self: *Pair) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var buffer: [256]u8 = undefined;
        self.store = try support.openStore(&self.tmp, &buffer);
        errdefer self.store.deinit();
        try self.store.startChangeLog();
        self.buffers = try testing.allocator.alloc(u8, 4 * protocol.max_frame_bytes);
        errdefer testing.allocator.free(self.buffers);
        self.replica = .init(self.frameBuffer(0), self.frameBuffer(1), .{ .database_id = (try self.store.databaseId()).?, .token = token }, timeout_ns, self.now);
        // The master's node reads the hello, then hands the connection
        // over to a writer session.
        var opening = MasterSession.init(self.frameBuffer(2), self.frameBuffer(3), .{
            .token = token,
            .heartbeat_ns = heartbeat_ns,
            .timeout_ns = timeout_ns,
            .copy_timeout_ns = timeout_ns,
        }, self.now);
        defer opening.deinit(testing.allocator);
        move(&self.replica.outbox, &opening.inbox, std.math.maxInt(usize));
        const event = (try opening.next(&self.store)).?;
        self.master = .init(testing.allocator, opening.inbox, opening.outbox, .{ .token = token, .heartbeat_ns = heartbeat_ns, .timeout_ns = timeout_ns }, self.now);
        try self.master.introduced(&self.store, event.writer);
    }

    fn deinit(self: *Pair) void {
        self.master.deinit();
        self.replica.deinit(testing.allocator);
        testing.allocator.free(self.buffers);
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn frameBuffer(self: *Pair, index: usize) []u8 {
        return self.buffers[index * protocol.max_frame_bytes ..][0..protocol.max_frame_bytes];
    }

    /// Sends what the replica has to send, at most `limit` bytes.
    fn toMaster(self: *Pair, limit: usize) void {
        self.replica.pump(self.now);
        const count = @min(limit, self.replica.outbox.unsent().len, self.master.inbox.unfilled().len);
        @memcpy(self.master.inbox.unfilled()[0..count], self.replica.outbox.unsent()[0..count]);
        self.master.received(count, self.now);
        self.replica.sent(count, self.now);
    }

    /// Sends all the master has to send.
    fn toReplica(self: *Pair) !void {
        try self.master.pump(&self.store, self.now);
        const count = @min(self.master.outbox.unsent().len, self.replica.inbox.unfilled().len);
        @memcpy(self.replica.inbox.unfilled()[0..count], self.master.outbox.unsent()[0..count]);
        self.replica.received(count, self.now);
        self.master.sent(count, self.now);
    }

    /// Takes the master to `writer_ready`, read by the replica.
    fn introduce(self: *Pair) !void {
        try self.toReplica();
        try testing.expect((try self.replica.next(testing.allocator)).? == .ready);
    }
};

/// Moves at most `limit` bytes of `outbox` into `inbox`.
fn move(outbox: *protocol.Outbox, inbox: *protocol.Inbox, limit: usize) void {
    const count = @min(limit, outbox.unsent().len, inbox.unfilled().len);
    @memcpy(inbox.unfilled()[0..count], outbox.unsent()[0..count]);
    inbox.filled(count);
    outbox.sent(count);
}

fn put(inbox: *protocol.Inbox, message: protocol.Message) void {
    var writer: std.Io.Writer = .fixed(inbox.unfilled());
    protocol.write(&writer, message) catch unreachable;
    inbox.filled(writer.end);
}

test "a request goes to the master in parts and its answer comes back whole, one write at a time" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    try pair.introduce();
    for (0..2) |round| {
        const id: u64 = 40 + round;
        // Larger than a part: sent in three.
        const request = try testing.allocator.alloc(u8, 2 * protocol.part_bytes + 10);
        defer testing.allocator.free(request);
        for (request, 0..) |*byte, i| byte.* = @truncate(i + round);
        pair.replica.request(id, request);
        var received: ?[]u8 = null;
        while (received == null) {
            pair.toMaster(std.math.maxInt(usize));
            received = try pair.master.next();
        }
        defer testing.allocator.free(received.?);
        try testing.expectEqualSlices(u8, request, received.?);
        try testing.expectEqual(ForwardingSession.State.waiting, pair.replica.state);
        try testing.expect(pair.replica.delivered());

        const answer = try testing.allocator.alloc(u8, protocol.part_bytes + 3);
        for (answer, 0..) |*byte, i| byte.* = @truncate(i * 7 + round);
        const expected = try testing.allocator.dupe(u8, answer);
        defer testing.allocator.free(expected);
        pair.master.answered(answer);
        const joined = while (true) {
            try pair.toReplica();
            const event = try pair.replica.next(testing.allocator) orelse continue;
            break event.answer;
        };
        defer testing.allocator.free(joined);
        try testing.expectEqualSlices(u8, expected, joined);
        try testing.expectEqual(ForwardingSession.State.ready, pair.replica.state);
        try testing.expect(!pair.replica.delivered());
    }
}

test "a request is not delivered until the last byte of its final part is sent" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    try pair.introduce();
    const request = try testing.allocator.alloc(u8, protocol.part_bytes + 1);
    defer testing.allocator.free(request);
    @memset(request, 'r');
    pair.replica.request(1, request);
    // A byte at a time: the master has the request whole exactly when the
    // replica takes it as delivered.
    while (true) {
        pair.toMaster(1);
        const received = try pair.master.next();
        try testing.expectEqual(received != null, pair.replica.delivered());
        if (received) |bytes| {
            testing.allocator.free(bytes);
            break;
        }
    }
}

test "heartbeats are acked while ready and while a write runs; the master keeps the replica" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    try pair.introduce();
    for (0..20) |round| {
        if (round == 10) {
            pair.replica.request(9, "CREATE ()");
            pair.toMaster(std.math.maxInt(usize));
            testing.allocator.free((try pair.master.next()).?);
        }
        pair.now += heartbeat_ns;
        try pair.toReplica();
        try testing.expectEqual(null, try pair.replica.next(testing.allocator));
        pair.toMaster(std.math.maxInt(usize));
        try testing.expectEqual(null, try pair.master.next());
        try testing.expect(!pair.master.expired(pair.now));
        try testing.expect(pair.now < pair.replica.deadline());
    }
    try testing.expectEqual(ForwardingSession.State.waiting, pair.replica.state);
}

test "a silent master, or one that reads nothing sent, is given up on" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    try pair.introduce();
    // Idle for longer than the timeout, the master heard from, nothing
    // sent (the acks owed wait for the next `pump`).
    for (0..10) |_| {
        pair.now += heartbeat_ns;
        try pair.toReplica();
        _ = try pair.replica.next(testing.allocator);
    }
    try testing.expectEqual(pair.now + timeout_ns, pair.replica.deadline());

    // A request the master reads nothing of: its clock starts when it is
    // put in the outbox, however long the replica was idle.
    pair.replica.request(1, "CREATE ()");
    pair.replica.pump(pair.now);
    const requested = pair.now;
    for (0..3) |_| {
        pair.now += heartbeat_ns;
        try pair.toReplica();
        _ = try pair.replica.next(testing.allocator);
    }
    try testing.expectEqual(requested + timeout_ns, pair.replica.deadline());

    // Sent; then the master says nothing.
    pair.toMaster(std.math.maxInt(usize));
    testing.allocator.free((try pair.master.next()).?);
    try testing.expectEqual(pair.now + timeout_ns, pair.replica.deadline());
}

test "refused: the conversation is over" {
    var buffers: [2 * protocol.max_frame_bytes]u8 = undefined;
    var session = ForwardingSession.init(buffers[0..protocol.max_frame_bytes], buffers[protocol.max_frame_bytes..], .{ .database_id = @splat(1), .token = token }, timeout_ns, 0);
    defer session.deinit(testing.allocator);
    try testing.expect((try protocol.decode(session.outbox.unsent())).?.message == .writer_hello);
    put(&session.inbox, .{ .refused = .not_master });
    try testing.expectEqual(protocol.Refusal.not_master, (try session.next(testing.allocator)).?.refused);
    put(&session.inbox, .{ .heartbeat = 3 });
    try testing.expectError(error.UnexpectedMessage, session.next(testing.allocator));
}

test "an answer the replica did not ask for ends the conversation" {
    var buffers: [2 * protocol.max_frame_bytes]u8 = undefined;
    const cases = [_]struct { request: bool, message: protocol.Message }{
        // Before `writer_ready`.
        .{ .request = false, .message = .{ .heartbeat = 1 } },
        // With no request sent.
        .{ .request = false, .message = .{ .answer_part = .{ .id = 0, .final = true, .bytes = "x" } } },
        // Under another id.
        .{ .request = true, .message = .{ .answer_part = .{ .id = 6, .final = true, .bytes = "x" } } },
        .{ .request = true, .message = .{ .writer_ready = {} } },
    };
    for (cases, 0..) |case, index| {
        var session = ForwardingSession.init(buffers[0..protocol.max_frame_bytes], buffers[protocol.max_frame_bytes..], .{ .database_id = @splat(1), .token = token }, timeout_ns, 0);
        defer session.deinit(testing.allocator);
        if (index > 0) {
            put(&session.inbox, .writer_ready);
            try testing.expect((try session.next(testing.allocator)).? == .ready);
        }
        if (case.request) {
            session.request(5, "CREATE ()");
            session.pump(0);
            session.sent(session.outbox.unsent().len, 0);
            try testing.expect(session.delivered());
        }
        put(&session.inbox, case.message);
        try testing.expectError(error.UnexpectedMessage, session.next(testing.allocator));
    }
}
