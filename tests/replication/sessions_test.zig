//! The master's and the replica's conversations as state machines
//! (replication/master_session.zig, replica_session.zig), run against each
//! other with no network: bytes go from one to the other in pieces of
//! random size, on a clock of the test's own. A replica made this way
//! equals its master; a silent or stuck peer is let go in time.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Graph = zypherdb.Graph;
const Ast = zypherdb.Ast;
const protocol = zypherdb.replication_protocol;
const replica = zypherdb.replication_replica;
const MasterSession = zypherdb.replication_master_session.MasterSession;
const ReplicaSession = zypherdb.replication_replica_session.ReplicaSession;
const Instant = zypherdb.replication_clock.Instant;

const support = @import("../support.zig");
const testPath = support.testPath;
const expectQuery = support.expectQuery;
const contents = support.contents;

const token = "the master's token";
const ms = std.time.ns_per_ms;

const settings: zypherdb.replication_master_session.Settings = .{
    .token = token,
    .heartbeat_ns = 100 * ms,
    .timeout_ns = 500 * ms,
    .copy_timeout_ns = 10_000 * ms,
};

/// The path of directory `name` in `tmp`, created.
fn directoryAt(tmp: *testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var base_buffer: [128]u8 = undefined;
    try tmp.dir.createDirPath(testing.io, name);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(tmp, &base_buffer), name });
}

/// A master and a replica store and the conversation between them, which
/// `step` moves on: each side handles what it received, then bytes go
/// across in pieces of random size, then time passes.
const Conversation = struct {
    tmp: *testing.TmpDir,
    source: *KeyValueStore,
    target: *KeyValueStore,
    buffers: [4][]u8,
    master: MasterSession,
    replica: ReplicaSession,
    random: std.Random.DefaultPrng,
    now: Instant = 0,
    /// Whether each side reads what the other sends.
    master_reads: bool = true,
    replica_reads: bool = true,
    /// The copy the master sends, open while it does.
    master_copy: ?std.Io.File = null,
    master_copy_buffer: [4096]u8 = undefined,
    master_copy_reader: std.Io.File.Reader = undefined,
    /// The copy the replica receives, open while it does.
    replica_copy: ?std.Io.File = null,
    replica_copy_buffer: [4096]u8 = undefined,
    replica_copy_writer: std.Io.File.Writer = undefined,
    refusal: ?protocol.Refusal = null,
    master_lsn: ?u64 = null,
    heartbeats: usize = 0,
    copies_made: usize = 0,

    /// Opens a conversation for the replica `target` (null hello store
    /// if empty) with the master `source`. Free with `deinit`.
    fn init(self: *Conversation, tmp: *testing.TmpDir, source: *KeyValueStore, target: *KeyValueStore, seed: u64) !void {
        self.* = .{ .tmp = tmp, .source = source, .target = target, .buffers = undefined, .master = undefined, .replica = undefined, .random = .init(seed) };
        for (&self.buffers, 0..) |*buffer, i| {
            buffer.* = testing.allocator.alloc(u8, protocol.max_frame_bytes) catch |err| {
                for (self.buffers[0..i]) |allocated| testing.allocator.free(allocated);
                return err;
            };
        }
        const has_database = try target.appliedLsn() != null;
        const hello = try replica.hello(if (has_database) target else null, token);
        self.master = .init(self.buffers[0], self.buffers[1], settings, self.now);
        self.replica = .init(self.buffers[2], self.buffers[3], hello, settings.timeout_ns, self.now);
    }

    fn deinit(self: *Conversation) void {
        if (self.master_copy) |file| file.close(testing.io);
        if (self.replica_copy) |file| file.close(testing.io);
        self.master.deinit(testing.allocator);
        self.replica.deinit(testing.allocator);
        for (self.buffers) |buffer| testing.allocator.free(buffer);
    }

    fn step(self: *Conversation) !void {
        while (try self.master.next(self.source)) |event| switch (event) {
            .make_copy => try self.makeCopy(),
        };
        try self.master.pump(self.source, self.now);
        if (self.master.state != .sending_copy) if (self.master_copy) |file| {
            file.close(testing.io);
            self.master_copy = null;
        };
        if (self.replica_reads) {
            const count = self.cross(self.master.outbox.unsent(), self.replica.inbox.unfilled());
            self.master.sent(count, self.now);
            self.replica.received(count, self.now);
        }
        while (try self.replica.next(testing.allocator)) |event| switch (event) {
            .refused => |reason| self.refusal = reason,
            .copy_part => |bytes| try self.writeCopyPart(bytes),
            .copy_received => try self.loadCopy(),
            .change_set => |change_set| {
                defer testing.allocator.free(change_set.bytes);
                _ = try self.target.applyChangeSet(change_set.lsn, change_set.bytes);
                self.replica.applied(change_set.lsn);
            },
            .heartbeat => |last| {
                self.master_lsn = last;
                self.heartbeats += 1;
            },
        };
        self.replica.pump();
        if (self.master_reads) {
            const count = self.cross(self.replica.outbox.unsent(), self.master.inbox.unfilled());
            self.replica.outbox.sent(count);
            self.master.received(count, self.now);
        }
        self.now += 1 + self.random.random().uintLessThan(u64, 20 * ms);
    }

    /// Copies a piece of random size of `from` to `to`; returns its size.
    fn cross(self: *Conversation, from: []const u8, to: []u8) usize {
        const most = @min(from.len, to.len);
        if (most == 0) return 0;
        const count = 1 + self.random.random().uintLessThan(usize, @min(most, 256 << 10));
        @memcpy(to[0..count], from[0..count]);
        return count;
    }

    /// Steps until `done` holds; fails if it takes too many.
    fn stepUntil(self: *Conversation, comptime done: fn (*Conversation) anyerror!bool) !void {
        for (0..10_000) |_| {
            if (try done(self)) return;
            try self.step();
        }
        return error.TestTimedOut;
    }

    fn makeCopy(self: *Conversation) !void {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "master-copy-{d}", .{self.copies_made});
        self.copies_made += 1;
        var path: [256]u8 = undefined;
        try self.source.copyDatabase(try directoryAt(self.tmp, name, &path));
        var file_path: [64]u8 = undefined;
        const file = try self.tmp.dir.openFile(testing.io, try std.fmt.bufPrint(&file_path, "{s}/{s}", .{ name, KeyValueStore.data_file_name }), .{});
        self.master_copy = file;
        self.master_copy_reader = file.reader(testing.io, &self.master_copy_buffer);
        self.master.copyMade(&self.master_copy_reader.interface);
    }

    fn writeCopyPart(self: *Conversation, bytes: []const u8) !void {
        if (self.replica_copy == null) {
            var path: [256]u8 = undefined;
            _ = try directoryAt(self.tmp, "replica-copy", &path);
            const file = try self.tmp.dir.createFile(testing.io, "replica-copy/" ++ KeyValueStore.data_file_name, .{});
            self.replica_copy = file;
            self.replica_copy_writer = file.writer(testing.io, &self.replica_copy_buffer);
        }
        try self.replica_copy_writer.interface.writeAll(bytes);
    }

    fn loadCopy(self: *Conversation) !void {
        try self.replica_copy_writer.interface.flush();
        self.replica_copy.?.close(testing.io);
        self.replica_copy = null;
        var path: [256]u8 = undefined;
        const lsn = try self.target.loadCopy(try directoryAt(self.tmp, "replica-copy", &path));
        self.replica.copyLoaded(lsn, self.now);
    }

    fn caughtUp(self: *Conversation) !bool {
        const last = (try self.source.changeLogState()).?.next_lsn - 1;
        return self.replica.state == .streaming and try self.target.appliedLsn() == last and self.master.acked_lsn == last;
    }
};

/// Writes `count` keys of `bytes` bytes each to `store`, from `first`.
fn putKeys(store: *KeyValueStore, first: u8, count: u8, bytes: usize) !void {
    const value = try testing.allocator.alloc(u8, bytes);
    defer testing.allocator.free(value);
    @memset(value, 'v');
    for (first..first + count) |i| try store.put(&.{ 'k', @intCast(i) }, value);
}

test "a replica made from a copy, then streamed to, equals its master and acks how far it is" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var source = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &master_path));
    defer source.deinit();
    try source.startChangeLog();
    var g = Graph.init(&source, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try expectQuery(&ast, &g, "UNWIND range(1, 40) AS i CREATE (:Person {id: i})", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX FOR (p:Person) ON (p.id)", &.{});
    var replica_path: [256]u8 = undefined;
    var target = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "replica", &replica_path));
    defer target.deinit();

    for (0..4) |seed| {
        var conversation: Conversation = undefined;
        try conversation.init(&tmp, &source, &target, seed);
        defer conversation.deinit();
        // The first conversation makes the replica from a copy; the next
        // ones resume it.
        try conversation.stepUntil(Conversation.caughtUp);
        try testing.expectEqual(@as(usize, if (seed == 0) 1 else 0), conversation.copies_made);
        // A change set larger than a part, and deletes, as they commit.
        try putKeys(&source, @intCast(seed * 4), 3, protocol.part_bytes + 1);
        try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.id % 4 = 0 DETACH DELETE p", &.{});
        try putKeys(&source, 100, 1, 10);
        try conversation.stepUntil(Conversation.caughtUp);
        try testing.expectEqual(try contents(&source), try contents(&target));
        // With nothing committed, a heartbeat each `heartbeat_ns` (steps
        // are up to 20 ms) tells the replica the master's last LSN.
        const last = (try source.changeLogState()).?.next_lsn - 1;
        conversation.heartbeats = 0;
        const quiet_from = conversation.now;
        while (conversation.now < quiet_from + 2000 * ms) try conversation.step();
        try testing.expectEqual(@as(?u64, last), conversation.master_lsn);
        try testing.expect(conversation.heartbeats >= 15 and conversation.heartbeats <= 21);
        try testing.expect(!conversation.master.expired(conversation.now));
    }
}

test "a replica with the wrong token is refused and the master ends the conversation" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var source = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &master_path));
    defer source.deinit();
    try source.startChangeLog();
    var replica_path: [256]u8 = undefined;
    var target = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "replica", &replica_path));
    defer target.deinit();
    var conversation: Conversation = undefined;
    try conversation.init(&tmp, &source, &target, 7);
    defer conversation.deinit();
    conversation.master.settings.token = "another";
    try conversation.stepUntil(struct {
        fn done(c: *Conversation) !bool {
            return c.refusal != null and c.master.finished();
        }
    }.done);
    try testing.expectEqual(protocol.Refusal.token, conversation.refusal.?);
}

test "a silent or stuck replica is let go, and a silent master left" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var source = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &master_path));
    defer source.deinit();
    try source.startChangeLog();
    try putKeys(&source, 0, 2, 10);
    var replica_path: [256]u8 = undefined;
    var target = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "replica", &replica_path));
    defer target.deinit();

    // A replica that never says hello.
    {
        var conversation: Conversation = undefined;
        try conversation.init(&tmp, &source, &target, 1);
        defer conversation.deinit();
        conversation.master_reads = false;
        try conversation.stepUntil(struct {
            fn done(c: *Conversation) !bool {
                return c.master.expired(c.now);
            }
        }.done);
        try testing.expect(conversation.now >= settings.timeout_ns);
        try testing.expect(conversation.master.deadline() <= conversation.now);
    }
    // A replica that stops reading while streamed to: the master's writes
    // stop moving, and the replica's acks (of heartbeats it no longer
    // reads) stop coming; it is let go.
    {
        var conversation: Conversation = undefined;
        try conversation.init(&tmp, &source, &target, 2);
        defer conversation.deinit();
        try conversation.stepUntil(Conversation.caughtUp);
        conversation.replica_reads = false;
        try putKeys(&source, 10, 3, protocol.part_bytes);
        const stopped = conversation.now;
        try conversation.stepUntil(struct {
            fn done(c: *Conversation) !bool {
                return c.master.expired(c.now);
            }
        }.done);
        try testing.expect(!conversation.master.outbox.isEmpty());
        // Its last ack came at most a heartbeat (and a step) before.
        try testing.expect(conversation.now + settings.heartbeat_ns + 20 * ms >= stopped + settings.timeout_ns);
        // The replica, which reads nothing, gives up on the master too, a
        // timeout after it last read.
        try conversation.stepUntil(struct {
            fn done(c: *Conversation) !bool {
                return c.replica.deadline().? <= c.now;
            }
        }.done);
        try testing.expect(conversation.now <= stopped + settings.timeout_ns + 20 * ms);
    }
}

test "a message out of turn ends a conversation" {
    var buffers: [4][]u8 = undefined;
    for (&buffers) |*buffer| buffer.* = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer for (buffers) |buffer| testing.allocator.free(buffer);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var source = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &master_path));
    defer source.deinit();
    try source.startChangeLog();

    // An ack before the hello.
    var master: MasterSession = .init(buffers[0], buffers[1], settings, 0);
    defer master.deinit(testing.allocator);
    var frame: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&frame);
    try protocol.write(&writer, .{ .ack = 1 });
    @memcpy(master.inbox.unfilled()[0..writer.end], writer.buffered());
    master.received(writer.end, 0);
    try testing.expectError(error.UnexpectedMessage, master.next(&source));

    // A stream from elsewhere than after the replica's last change set.
    var session: ReplicaSession = .init(buffers[2], buffers[3], try replica.hello(null, token), settings.timeout_ns, 0);
    defer session.deinit(testing.allocator);
    writer = .fixed(&frame);
    try protocol.write(&writer, .{ .stream = 2 });
    @memcpy(session.inbox.unfilled()[0..writer.end], writer.buffered());
    session.received(writer.end, 0);
    try testing.expectError(error.UnexpectedMessage, session.next(testing.allocator));
}
