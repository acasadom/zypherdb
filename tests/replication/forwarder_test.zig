//! A replica's forwarded writes (replication/forwarder.zig), its node and
//! a master's node (master_node.zig) stepped on one thread over the
//! network in memory, on a clock of the test's own; the master runs the
//! writes when the test says. A request runs on the master and its answer
//! comes back over a connection kept for the next; one lost before it
//! reached the master whole is sent once more, one lost after ends
//! unknown; a master not reached, or out of time, ends it too.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Value = zypherdb.Value;
const protocol = zypherdb.replication_protocol;
const forwarding = zypherdb.replication_forwarding;
const Instant = zypherdb.replication_clock.Instant;
const network = zypherdb.replication_network;
const Watched = network.Watched;
const Wakeup = network.Wakeup;
const MemoryNetwork = zypherdb.replication_memory_network.MemoryNetwork;
const master_node = zypherdb.replication_master_node;
const MasterNode = master_node.MasterNode;
const forwarder = zypherdb.replication_forwarder;
const ForwardingNode = forwarder.ForwardingNode;
const Outcome = forwarder.Outcome;

const support = @import("../support.zig");

const token = "the master's token";
const master_address = "master:7000";
const ms = std.time.ns_per_ms;
const heartbeat_ns = 100 * ms;
const timeout_ns = 500 * ms;

/// A master's node and a forwarding node, for the database of the
/// master's store (as a standby forwards).
const Bench = struct {
    tmp: testing.TmpDir,
    base: [256]u8 = undefined,
    copies: [256]u8 = undefined,
    net: MemoryNetwork,
    store: KeyValueStore = undefined,
    master_wakeup: Wakeup = undefined,
    copier: master_node.InlineCopier = undefined,
    runner: master_node.InlineRunner = undefined,
    master: ?MasterNode = null,
    wakeup: Wakeup = undefined,
    node: ForwardingNode = undefined,
    now: Instant = 0,

    fn init(self: *Bench, options: forwarder.Options) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .net = .{ .allocator = testing.allocator } };
        errdefer self.tmp.cleanup();
        self.store = try support.openStore(&self.tmp, &self.base);
        errdefer self.store.deinit();
        try self.store.startChangeLog();
        const copies_directory = try std.fmt.bufPrint(&self.copies, "{s}/copies", .{support.testPath(&self.tmp, &self.base)});
        const net = self.net.network();
        self.master_wakeup = try net.wakeup();
        errdefer self.master_wakeup.close();
        self.copier = .{ .allocator = testing.allocator, .io = testing.io, .store = try self.store.share(), .wakeup = self.master_wakeup, .copies_directory = copies_directory };
        errdefer self.copier.deinit();
        self.runner = .{ .allocator = testing.allocator, .store = try self.store.share(), .wakeup = self.master_wakeup };
        errdefer self.runner.deinit();
        self.master = try MasterNode.init(testing.allocator, testing.io, net, &self.store, self.master_wakeup, self.copier.copier(), self.runner.runner(), .{
            .address = master_address,
            .token = token,
            .copies_directory = copies_directory,
            .heartbeat_ns = heartbeat_ns,
            .timeout_ns = timeout_ns,
        });
        errdefer self.master.?.deinit();
        self.wakeup = try net.wakeup();
        errdefer self.wakeup.close();
        self.node = try .init(testing.allocator, net, &self.store, self.wakeup, options);
    }

    fn deinit(self: *Bench) void {
        self.node.deinit();
        self.wakeup.close();
        if (self.master) |*master| master.deinit();
        self.runner.deinit();
        self.copier.deinit();
        self.master_wakeup.close();
        self.store.deinit();
        self.net.deinit();
        self.tmp.cleanup();
    }

    /// Hands `bytes` over under `id`, as a forwarder does.
    fn request(self: *Bench, id: u64, bytes: []const u8) void {
        self.node.request(id, bytes, self.now);
        self.wakeup.raise();
    }

    /// Steps each node with something ready or past its deadline, as its
    /// thread would, until none has.
    fn settle(self: *Bench) !void {
        const net = self.net.network();
        for (0..10_000) |_| {
            var stepped = false;
            if (self.master) |*master| {
                var buffer: [network.max_watched]Watched = undefined;
                const watched = master.watch(&buffer);
                try net.wait(watched, null);
                master.ready(watched);
                if (anyReady(watched) or due(master.deadline(), self.now)) {
                    master.step(self.now);
                    stepped = true;
                }
            }
            var buffer: [2]Watched = undefined;
            const watched = self.node.watch(&buffer);
            try net.wait(watched, null);
            self.node.ready(watched);
            if (anyReady(watched) or due(self.node.deadline(), self.now)) {
                self.node.step(self.now);
                stepped = true;
            }
            if (!stepped) return;
        }
        return error.NeverSettled;
    }

    /// `duration` passes, a tenth of a heartbeat at a time.
    fn pass(self: *Bench, duration: u64) !void {
        const until = self.now + duration;
        while (self.now < until) {
            self.now = @min(until, self.now + heartbeat_ns / 10);
            try self.settle();
        }
    }

    /// Runs the writes the master was asked for.
    fn runWrites(self: *Bench) !void {
        while (self.runner.waiting() > 0) try self.runner.runNext();
        try self.settle();
    }

    /// How the request `id` ended; fails if it did not.
    fn finished(self: *Bench, id: u64) !Outcome {
        const done = self.node.take() orelse return error.NotFinished;
        try testing.expectEqual(id, done.id);
        return done.outcome;
    }

    fn lastLsn(self: *Bench) !u64 {
        return (try self.store.changeLogState()).?.next_lsn - 1;
    }

    fn anyReady(watched: []const Watched) bool {
        for (watched) |one| if (one.ready.readable or one.ready.writable) return true;
        return false;
    }

    fn due(deadline: ?Instant, now: Instant) bool {
        return if (deadline) |at| now >= at else false;
    }
};

fn encode(arena: std.mem.Allocator, text: []const u8, name: []const u8) ![]const u8 {
    var request: std.ArrayList(u8) = .empty;
    try forwarding.encodeRequest(&request, arena, .{ .text = text, .parameters = &.{.{ .key = "name", .value = .{ .string = name } }} });
    return request.items;
}

fn expectAnswered(bench: *Bench, arena: std.mem.Allocator, outcome: Outcome, name: []const u8) !void {
    const bytes = switch (outcome) {
        .answer => |bytes| bytes,
        else => |other| {
            std.debug.print("ended {t}, not answered\n", .{other});
            return error.TestUnexpectedResult;
        },
    };
    defer testing.allocator.free(bytes);
    const done = (try forwarding.decodeAnswer(try arena.dupe(u8, bytes), arena)).done;
    try testing.expectEqual(try bench.lastLsn(), done.lsn);
    try testing.expect(Value.eql(.{ .string = name }, done.rows[0][0]));
}

const create_door = "CREATE (d:Door {name: $name}) RETURN d.name AS name";

test "a forwarded write runs on the master and is answered; the connection stays for the next" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = master_address, .token = token, .timeout_ns = timeout_ns });
    defer bench.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "B7", "C1", "D4" }, 1..) |name, id| {
        bench.request(id, try encode(arena.allocator(), create_door, name));
        try bench.settle();
        try testing.expectEqual(null, bench.node.take());
        try bench.runWrites();
        try expectAnswered(&bench, arena.allocator(), try bench.finished(id), name);
        // Idle for many heartbeats, each acked: the master keeps it.
        try bench.pass(10 * heartbeat_ns);
    }
    try testing.expectEqual(1, bench.net.connects);
    try testing.expectEqual(1, bench.net.linkCount());
}

test "a request lost before it reached the master whole is sent once more" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = master_address, .token = token, .timeout_ns = timeout_ns });
    defer bench.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    bench.request(1, try encode(arena.allocator(), create_door, "B7"));
    // Connected, the hello sent; nothing answered yet.
    bench.node.step(bench.now);
    bench.net.cut(0);
    try bench.settle();
    try bench.runWrites();
    try expectAnswered(&bench, arena.allocator(), try bench.finished(1), "B7");
    try testing.expectEqual(2, bench.net.connects);
}

test "a request lost halfway to the master is sent whole once more" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = master_address, .token = token, .timeout_ns = timeout_ns });
    defer bench.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try bench.settle();
    // Larger than the network holds: the master reads none of it until
    // it steps.
    const name = try arena.allocator().alloc(u8, 2 * bench.net.capacity);
    @memset(name, 'n');
    bench.request(1, try encode(arena.allocator(), create_door, "B7"));
    try bench.settle();
    try bench.runWrites();
    testing.allocator.free((try bench.finished(1)).answer);
    bench.request(2, try encode(arena.allocator(), create_door, name));
    for (0..3) |_| bench.node.step(bench.now);
    try testing.expectEqual(.requesting, bench.node.conversation.?.session.state);
    bench.net.cut(0);
    try bench.settle();
    try bench.runWrites();
    try expectAnswered(&bench, arena.allocator(), try bench.finished(2), name);
    try testing.expectEqual(2, bench.net.connects);
}

test "a request lost once it reached the master whole ends unknown; the next connects again" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = master_address, .token = token, .timeout_ns = timeout_ns });
    defer bench.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    bench.request(1, try encode(arena.allocator(), create_door, "B7"));
    try bench.settle();
    try testing.expectEqual(1, bench.runner.waiting());
    bench.net.cut(0);
    try bench.settle();
    try testing.expectEqual(Outcome.unknown, try bench.finished(1));
    // The master ran it anyway.
    try bench.runWrites();

    bench.request(2, try encode(arena.allocator(), create_door, "C1"));
    try bench.settle();
    try bench.runWrites();
    try expectAnswered(&bench, arena.allocator(), try bench.finished(2), "C1");
    try testing.expectEqual(2, bench.net.connects);
}

test "a master nobody listens for is not reached, twice" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = "elsewhere:7000", .token = token, .timeout_ns = timeout_ns });
    defer bench.deinit();
    bench.request(1, "not even sent");
    try bench.settle();
    try testing.expectEqual(Outcome.master_unreachable, try bench.finished(1));
    try testing.expectEqual(2, bench.net.connects);
}

test "a master that reads nothing is given up on, twice" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = "silent:7000", .token = token, .timeout_ns = timeout_ns });
    defer bench.deinit();
    // It listens and never accepts.
    var silent = try bench.net.network().listen("silent:7000");
    defer silent.close();
    bench.request(1, "not even sent");
    try bench.settle();
    try bench.pass(timeout_ns);
    try testing.expectEqual(null, bench.node.take());
    try testing.expectEqual(2, bench.net.connects);
    try bench.pass(timeout_ns);
    try testing.expectEqual(Outcome.master_unreachable, try bench.finished(1));
}

test "out of time: unknown once the master has the request, unreachable before" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = master_address, .token = token, .timeout_ns = timeout_ns, .request_timeout_ns = 2 * timeout_ns });
    defer bench.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Never run: the master heartbeats meanwhile.
    bench.request(1, try encode(arena.allocator(), create_door, "B7"));
    try bench.pass(2 * timeout_ns - heartbeat_ns);
    try testing.expectEqual(null, bench.node.take());
    try bench.pass(heartbeat_ns);
    try testing.expectEqual(Outcome.unknown, try bench.finished(1));
    try testing.expectEqual(null, bench.node.conversation);

    // A master that does not answer the hello, sooner than it is given up on.
    bench.master.?.deinit();
    bench.master = null;
    var silent = try bench.net.network().listen(master_address);
    defer silent.close();
    bench.node.options.request_timeout_ns = timeout_ns / 2;
    bench.request(2, "not even sent");
    try bench.pass(timeout_ns / 2);
    try testing.expectEqual(Outcome.master_unreachable, try bench.finished(2));
}

test "turned away: once if asking again cannot help, twice if it may" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = master_address, .token = "not the master's", .timeout_ns = timeout_ns });
    defer bench.deinit();
    bench.request(1, "not even sent");
    try bench.settle();
    try testing.expectEqual(Outcome{ .refused = .token }, try bench.finished(1));
    try testing.expectEqual(1, bench.net.connects);

    // In place of the master, one that is no master yet.
    bench.master.?.deinit();
    bench.master = null;
    var listener = try bench.net.network().listen(master_address);
    defer listener.close();
    bench.request(2, "not even sent");
    for (0..2) |_| {
        try bench.settle();
        const connection = (try listener.accept()).?;
        defer connection.close();
        var frame: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&frame);
        try protocol.write(&writer, .{ .refused = .not_master });
        try testing.expectEqual(writer.end, try connection.send(writer.buffered()));
        try bench.settle();
    }
    try testing.expectEqual(Outcome{ .refused = .not_master }, try bench.finished(2));
    try testing.expectEqual(3, bench.net.connects);
}

test "a replica with no copy of a master forwards nothing" {
    var bench: Bench = undefined;
    try bench.init(.{ .master_address = master_address, .token = token, .timeout_ns = timeout_ns });
    defer bench.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [256]u8 = undefined;
    var empty = try support.openStore(&tmp, &buffer);
    defer empty.deinit();
    var node: ForwardingNode = try .init(testing.allocator, bench.net.network(), &empty, bench.wakeup, bench.node.options);
    defer node.deinit();
    node.request(1, "not even sent", 0);
    node.step(0);
    try testing.expectEqual(Outcome{ .failed = error.NoCopy }, node.take().?.outcome);
    try testing.expectEqual(0, bench.net.connects);
}
