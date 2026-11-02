//! The master's conversation with a replica's connection for forwarded
//! writes (replication/writer_session.zig), with no network: frames go
//! into its inbox and come out of its outbox, on a clock of the test's
//! own. Only a replica of the master is served; a request is handed over
//! once whole and answered in parts under its id, one at a time; heartbeats
//! go on while a write runs and a silent replica is let go.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const protocol = zypherdb.replication_protocol;
const MasterSession = zypherdb.replication_master_session.MasterSession;
const WriterSession = zypherdb.replication_writer_session.WriterSession;
const Instant = zypherdb.replication_clock.Instant;

const support = @import("../support.zig");

const token = "the master's token";
const ms = std.time.ns_per_ms;
const heartbeat_ns = 100 * ms;
const timeout_ns = 500 * ms;

const Setup = struct {
    tmp: testing.TmpDir,
    store: KeyValueStore,
    buffers: []u8,
    session: WriterSession = undefined,
    now: Instant = 0,

    fn init(self: *Setup) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var buffer: [256]u8 = undefined;
        self.store = try support.openStore(&self.tmp, &buffer);
        errdefer self.store.deinit();
        try self.store.startChangeLog();
        self.buffers = try testing.allocator.alloc(u8, 2 * protocol.max_frame_bytes);
    }

    fn deinit(self: *Setup) void {
        testing.allocator.free(self.buffers);
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn databaseId(self: *Setup) !protocol.DatabaseId {
        return (try self.store.databaseId()).?;
    }

    /// Opens a connection that says `hello`, as the master's node does.
    fn open(self: *Setup, hello: protocol.WriterHello) !void {
        var master = MasterSession.init(self.buffers[0..protocol.max_frame_bytes], self.buffers[protocol.max_frame_bytes..], .{
            .token = token,
            .heartbeat_ns = heartbeat_ns,
            .timeout_ns = timeout_ns,
            .copy_timeout_ns = timeout_ns,
        }, self.now);
        put(&master.inbox, .{ .writer_hello = hello });
        const event = (try master.next(&self.store)).?;
        self.session = .init(testing.allocator, master.inbox, master.outbox, .{ .token = token, .heartbeat_ns = heartbeat_ns, .timeout_ns = timeout_ns }, self.now);
        try self.session.introduced(&self.store, event.writer);
        master.deinit(self.store.allocator);
    }

    /// The replica sends `message`.
    fn send(self: *Setup, message: protocol.Message) void {
        var writer: std.Io.Writer = .fixed(self.session.inbox.unfilled());
        protocol.write(&writer, message) catch unreachable;
        self.session.received(writer.end, self.now);
    }

    /// The first message sent, if any, taken off the outbox.
    fn receive(self: *Setup) !?protocol.Message {
        const decoded = try protocol.decode(self.session.outbox.unsent()) orelse return null;
        self.session.sent(decoded.length, self.now);
        return decoded.message;
    }

    fn pass(self: *Setup, ns: u64) !void {
        self.now += ns;
        try self.session.pump(&self.store, self.now);
    }
};

fn put(inbox: *protocol.Inbox, message: protocol.Message) void {
    var writer: std.Io.Writer = .fixed(inbox.unfilled());
    protocol.write(&writer, message) catch unreachable;
    inbox.filled(writer.end);
}

test "a replica of this master is ready to forward writes; any other is refused" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    const id = try setup.databaseId();
    try setup.open(.{ .database_id = id, .token = token, .name = "edge-1" });
    defer setup.session.deinit();
    try testing.expect((try setup.receive()).? == .writer_ready);
    try testing.expect(!setup.session.finished());

    var other = id;
    other[0] +%= 1;
    const refused = [_]struct { protocol.WriterHello, protocol.Refusal }{
        .{ .{ .database_id = id, .token = "another token" }, .token },
        .{ .{ .database_id = other, .token = token }, .database_id },
        .{ .{ .protocol_version = protocol.version + 1, .database_id = id, .token = token }, .protocol_version },
    };
    for (refused) |case| {
        var refusing: Setup = setup;
        try refusing.open(case[0]);
        defer refusing.session.deinit();
        try testing.expectEqual(case[1], (try refusing.receive()).?.refused);
        try testing.expect(refusing.session.finished());
        // Whatever it says next ends the conversation.
        refusing.send(.{ .ack = 0 });
        try testing.expectError(error.UnexpectedMessage, refusing.session.next());
    }
}

test "a request is handed over once whole, and its answer goes back in parts under its id" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    try setup.open(.{ .database_id = try setup.databaseId(), .token = token });
    defer setup.session.deinit();
    _ = try setup.receive();
    for (0..2) |round| {
        const id: u64 = 7 + round;
        setup.send(.{ .request_part = .{ .id = id, .final = false, .bytes = "MATCH " } });
        setup.send(.{ .request_part = .{ .id = id, .final = false, .bytes = "(n) " } });
        try testing.expectEqual(null, try setup.session.next());
        setup.send(.{ .request_part = .{ .id = id, .final = true, .bytes = "RETURN n" } });
        const request = (try setup.session.next()).?;
        defer testing.allocator.free(request);
        try testing.expectEqualStrings("MATCH (n) RETURN n", request);
        try testing.expectEqual(WriterSession.State.running, setup.session.state);

        // Larger than a part: sent in three.
        const answer = try testing.allocator.alloc(u8, 2 * protocol.part_bytes + 10);
        for (answer, 0..) |*byte, i| byte.* = @truncate(i);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(testing.allocator);
        try expected.appendSlice(testing.allocator, answer);
        setup.session.answered(answer);
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(testing.allocator);
        var parts: usize = 0;
        while (true) {
            try setup.pass(0);
            const part = (try setup.receive()).?.answer_part;
            try testing.expectEqual(id, part.id);
            try joined.appendSlice(testing.allocator, part.bytes);
            parts += 1;
            if (part.final) break;
        }
        try testing.expectEqual(3, parts);
        try testing.expectEqualSlices(u8, expected.items, joined.items);
        try testing.expectEqual(WriterSession.State.ready, setup.session.state);
    }
}

test "one write at a time: a request while one runs ends the conversation" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    try setup.open(.{ .database_id = try setup.databaseId(), .token = token });
    defer setup.session.deinit();
    setup.send(.{ .request_part = .{ .id = 1, .final = true, .bytes = "CREATE ()" } });
    testing.allocator.free((try setup.session.next()).?);
    setup.send(.{ .request_part = .{ .id = 2, .final = true, .bytes = "CREATE ()" } });
    try testing.expectError(error.UnexpectedMessage, setup.session.next());
}

test "a request too large, or of mixed ids, ends the conversation" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    try setup.open(.{ .database_id = try setup.databaseId(), .token = token });
    defer setup.session.deinit();
    setup.send(.{ .request_part = .{ .id = 1, .final = false, .bytes = "MATCH " } });
    setup.send(.{ .request_part = .{ .id = 2, .final = true, .bytes = "(n)" } });
    try testing.expectError(error.MixedParts, setup.session.next());

    var large: Setup = setup;
    try large.open(.{ .database_id = try setup.databaseId(), .token = token });
    defer large.session.deinit();
    const part = try testing.allocator.alloc(u8, protocol.part_bytes);
    defer testing.allocator.free(part);
    @memset(part, 'x');
    for (0..zypherdb.replication_forwarding.max_request_bytes / protocol.part_bytes) |_| {
        large.send(.{ .request_part = .{ .id = 1, .final = false, .bytes = part } });
        try testing.expectEqual(null, try large.session.next());
    }
    large.send(.{ .request_part = .{ .id = 1, .final = true, .bytes = "x" } });
    try testing.expectError(error.TooLarge, large.session.next());
}

test "heartbeats go on while a write runs; a replica that acks stays, a silent one is let go" {
    var setup: Setup = undefined;
    try setup.init();
    defer setup.deinit();
    try setup.open(.{ .database_id = try setup.databaseId(), .token = token });
    defer setup.session.deinit();
    _ = try setup.receive();
    setup.send(.{ .request_part = .{ .id = 1, .final = true, .bytes = "CREATE ()" } });
    testing.allocator.free((try setup.session.next()).?);
    const last_lsn = (try setup.store.changeLogState()).?.next_lsn - 1;
    // The replica acks each heartbeat: kept, however long the write runs.
    for (0..20) |_| {
        try testing.expectEqual(setup.now + heartbeat_ns, setup.session.deadline());
        try setup.pass(heartbeat_ns);
        try testing.expectEqual(last_lsn, (try setup.receive()).?.heartbeat);
        setup.send(.{ .ack = 0 });
        try testing.expectEqual(null, try setup.session.next());
        try testing.expect(!setup.session.expired(setup.now));
    }
    // Then it says nothing.
    const silent_since = setup.now;
    while (setup.now < silent_since + timeout_ns) {
        try testing.expect(!setup.session.expired(setup.now));
        try setup.pass(heartbeat_ns);
        _ = try setup.receive();
    }
    try testing.expect(setup.session.expired(setup.now));
}
