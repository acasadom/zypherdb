//! The copies a master's node (master_node.zig) sends replicas
//! (replica_node.zig) stepped on one thread over the network in memory, on
//! a clock of the test's own; copies are made, and replicas apply, when the
//! test says. Replicas asking while a copy is made, or sent, share it; one
//! the log has left behind is not given; a copy is deleted once no replica
//! reads it; a copy cut short changes nothing, and the replica starts over.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const clock_module = zypherdb.replication_clock;
const Clock = clock_module.Clock;
const Instant = clock_module.Instant;
const Signal = clock_module.Signal;
const network = zypherdb.replication_network;
const Watched = network.Watched;
const Wakeup = network.Wakeup;
const MemoryNetwork = zypherdb.replication_memory_network.MemoryNetwork;
const master_node = zypherdb.replication_master_node;
const MasterNode = master_node.MasterNode;
const replica_node = zypherdb.replication_replica_node;
const ReplicaNode = replica_node.ReplicaNode;

const support = @import("../support.zig");

const token = "the master's token";
const master_address = "master:7000";
const ms = std.time.ns_per_ms;
const heartbeat_ns = 100 * ms;
const timeout_ns = 500 * ms;
const max_replicas = 3;

/// Time passes only when the test says.
const TestClock = struct {
    time: Instant = 0,

    fn clock(self: *TestClock) Clock {
        return .{ .context = self, .vtable = &.{ .now = now, .wait = wait, .raise = raise, .stop = stop } };
    }

    fn now(context: *anyopaque) Instant {
        const self: *TestClock = @ptrCast(@alignCast(context));
        return self.time;
    }

    fn wait(_: *anyopaque, _: *Signal, _: u64, _: Instant) ?u64 {
        unreachable;
    }

    fn raise(_: *anyopaque, signal: *Signal, value: u64) void {
        if (value > signal.value) signal.value = value;
    }

    fn stop(_: *anyopaque, signal: *Signal) void {
        signal.stopped = true;
    }
};

const Replica = struct {
    path: [256]u8 = undefined,
    store: KeyValueStore = undefined,
    applied: Signal = .{},
    wakeup: Wakeup = undefined,
    applier: replica_node.InlineApplier = undefined,
    node: ReplicaNode = undefined,
    /// Whether it applies what it is given as the bench settles.
    applying: bool = true,
};

/// A master's node and up to `max_replicas` replicas' nodes.
const Bench = struct {
    tmp: testing.TmpDir,
    base: [256]u8 = undefined,
    copies: [256]u8 = undefined,
    copies_directory: []const u8 = "",
    net: MemoryNetwork,
    clock: TestClock = .{},
    store: KeyValueStore = undefined,
    master_wakeup: Wakeup = undefined,
    copier: master_node.InlineCopier = undefined,
    runner: master_node.InlineRunner = undefined,
    master: MasterNode = undefined,
    replicas: [max_replicas]Replica = @splat(.{}),
    replica_count: usize = 0,

    /// A master whose log keeps `change_log_limit` bytes.
    fn init(self: *Bench, change_log_limit: u64) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .net = .{ .allocator = testing.allocator, .capacity = 16 << 10 } };
        errdefer self.tmp.cleanup();
        const base = support.testPath(&self.tmp, &self.base);
        try self.tmp.dir.createDirPath(testing.io, "master");
        var master_path: [256]u8 = undefined;
        self.store = try KeyValueStore.open(testing.allocator, try std.fmt.bufPrint(&master_path, "{s}/master", .{base}));
        errdefer self.store.deinit();
        self.store.change_log_limit = change_log_limit;
        try self.store.startChangeLog();
        self.copies_directory = try std.fmt.bufPrint(&self.copies, "{s}/copies", .{base});
        const net = self.net.network();
        self.master_wakeup = try net.wakeup();
        errdefer self.master_wakeup.close();
        self.copier = .{ .allocator = testing.allocator, .io = testing.io, .store = try self.store.share(), .wakeup = self.master_wakeup, .copies_directory = self.copies_directory };
        errdefer self.copier.deinit();
        self.runner = .{ .allocator = testing.allocator, .store = try self.store.share(), .wakeup = self.master_wakeup };
        errdefer self.runner.deinit();
        self.master = try MasterNode.init(testing.allocator, testing.io, net, &self.store, self.master_wakeup, self.copier.copier(), self.runner.runner(), .{
            .address = master_address,
            .token = token,
            .copies_directory = self.copies_directory,
            .heartbeat_ns = heartbeat_ns,
            .timeout_ns = timeout_ns,
            .max_replicas = max_replicas,
        });
    }

    fn deinit(self: *Bench) void {
        for (self.replicas[0..self.replica_count]) |*replica| {
            replica.node.deinit();
            replica.applier.deinit();
            replica.wakeup.close();
            replica.store.deinit();
        }
        self.master.deinit();
        self.runner.deinit();
        self.copier.deinit();
        self.master_wakeup.close();
        self.store.deinit();
        self.net.deinit();
        self.tmp.cleanup();
    }

    /// An empty replica, which reads past `max_unapplied_bytes` of what
    /// it did not apply yet.
    fn addReplica(self: *Bench, max_unapplied_bytes: usize) !*Replica {
        const replica = &self.replicas[self.replica_count];
        var name: [32]u8 = undefined;
        const directory = try std.fmt.bufPrint(&name, "replica-{d}", .{self.replica_count});
        try self.tmp.dir.createDirPath(testing.io, directory);
        var base: [256]u8 = undefined;
        replica.store = try KeyValueStore.open(testing.allocator, try std.fmt.bufPrint(&replica.path, "{s}/{s}", .{ support.testPath(&self.tmp, &base), directory }));
        errdefer replica.store.deinit();
        const net = self.net.network();
        replica.wakeup = try net.wakeup();
        errdefer replica.wakeup.close();
        replica.applier = .{ .allocator = testing.allocator, .clock = self.clock.clock(), .applied = &replica.applied, .store = try replica.store.share(), .wakeup = replica.wakeup };
        errdefer replica.applier.deinit();
        replica.node = try ReplicaNode.init(testing.allocator, self.clock.clock(), net, &replica.store, &replica.applied, replica.wakeup, replica.applier.applier(), .{
            .master_address = master_address,
            .token = token,
            .first_retry_ns = 10 * ms,
            .longest_retry_ns = 10 * ms,
            .max_unapplied_bytes = max_unapplied_bytes,
        });
        self.replica_count += 1;
        return replica;
    }

    /// Steps each node with something ready or past its deadline, as its
    /// thread would, until none has; replicas applying apply all they got.
    fn settle(self: *Bench) !void {
        const net = self.net.network();
        const now = self.clock.time;
        for (0..100_000) |_| {
            var stepped = false;
            var buffer: [network.max_watched]Watched = undefined;
            const watched = self.master.watch(&buffer);
            try net.wait(watched, null);
            self.master.ready(watched);
            if (anyReady(watched) or due(self.master.deadline(), now)) {
                self.master.step(now);
                stepped = true;
            }
            for (self.replicas[0..self.replica_count]) |*replica| {
                if (replica.applying) while (replica.applier.waiting() > 0) replica.applier.applyNext();
                var replica_buffer: [2]Watched = undefined;
                const replica_watched = replica.node.watch(&replica_buffer);
                try net.wait(replica_watched, null);
                replica.node.ready(replica_watched);
                if (anyReady(replica_watched) or due(replica.node.deadline(), now)) {
                    replica.node.step(now);
                    stepped = true;
                }
            }
            if (!stepped) return;
        }
        return error.NeverSettled;
    }

    /// `duration` passes, a tenth of a heartbeat at a time.
    fn pass(self: *Bench, duration: u64) !void {
        const until = self.clock.time + duration;
        while (self.clock.time < until) {
            self.clock.time = @min(until, self.clock.time + heartbeat_ns / 10);
            try self.settle();
        }
    }

    /// Makes the copies asked for, and lets them be sent.
    fn makeCopies(self: *Bench) !void {
        while (self.copier.waiting() > 0) try self.copier.makeNext();
        try self.settle();
    }

    /// Whether copy `number`'s file is on the master's disk.
    fn copyKept(self: *Bench, number: u64) bool {
        var buffer: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buffer, "{s}/copy-{d}", .{ self.copies_directory, number }) catch unreachable;
        std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
        return true;
    }

    /// Every replica streams and holds what the master holds.
    fn expectCaughtUp(self: *Bench) !void {
        const last = (try self.store.changeLogState()).?.next_lsn - 1;
        const expected = try support.contents(&self.store);
        for (self.replicas[0..self.replica_count]) |*replica| {
            try testing.expectEqual(replica_node.Phase.streaming, replica.node.phase());
            try testing.expectEqual(@as(?u64, last), try replica.store.appliedLsn());
            try testing.expectEqual(expected, try support.contents(&replica.store));
        }
    }

    fn anyReady(watched: []const Watched) bool {
        for (watched) |one| if (one.ready.readable or one.ready.writable) return true;
        return false;
    }

    fn due(deadline: ?Instant, now: Instant) bool {
        return if (deadline) |at| now >= at else false;
    }
};

/// Puts `count` keys of 4 KiB, from `first`, each in a change set.
fn putKeys(store: *KeyValueStore, first: usize, count: usize) !void {
    var value: [4 << 10]u8 = undefined;
    @memset(&value, 'v');
    for (first..first + count) |i| {
        var key: [16]u8 = undefined;
        try store.put(try std.fmt.bufPrint(&key, "key-{d}", .{i}), &value);
    }
}

test "replicas asking for a copy at once share one, deleted once all have it" {
    var bench: Bench = undefined;
    try bench.init(512 << 20);
    defer bench.deinit();
    try putKeys(&bench.store, 0, 100);
    for (0..max_replicas) |_| _ = try bench.addReplica(64 << 20);
    try bench.pass(heartbeat_ns);
    try testing.expectEqual(@as(usize, 1), bench.copier.waiting());
    try bench.makeCopies();
    try bench.pass(heartbeat_ns);
    try testing.expectEqual(@as(u64, 1), bench.master.copies_asked);
    try testing.expect(!bench.copyKept(0));
    try testing.expectEqual(@as(usize, 0), bench.master.copies.items.len);
    try bench.expectCaughtUp();
    try putKeys(&bench.store, 100, 5);
    try bench.pass(heartbeat_ns);
    try bench.expectCaughtUp();
}

test "a replica asking while a copy is sent joins it" {
    var bench: Bench = undefined;
    try bench.init(512 << 20);
    defer bench.deinit();
    try putKeys(&bench.store, 0, 800);
    // It stops reading halfway, holding what it did not apply: more than
    // the master's outbox and its inbox hold.
    const first = try bench.addReplica(64 << 10);
    first.applying = false;
    try bench.pass(heartbeat_ns);
    try bench.makeCopies();
    try testing.expectEqual(replica_node.Phase.copying, first.node.phase());
    try testing.expect(bench.copyKept(0));
    // Committed meanwhile: the log still holds it after the copy.
    try putKeys(&bench.store, 800, 2);
    _ = try bench.addReplica(64 << 20);
    try bench.pass(heartbeat_ns);
    try testing.expectEqual(@as(u64, 1), bench.master.copies_asked);
    try testing.expectEqual(@as(usize, 0), bench.copier.waiting());
    // Read by the first still.
    try testing.expect(bench.copyKept(0));
    first.applying = true;
    try bench.pass(heartbeat_ns);
    try testing.expect(!bench.copyKept(0));
    try bench.expectCaughtUp();
}

test "a copy cut short changes nothing, is deleted, and the replica starts over" {
    var bench: Bench = undefined;
    try bench.init(512 << 20);
    defer bench.deinit();
    try putKeys(&bench.store, 0, 800);
    const replica = try bench.addReplica(64 << 10);
    replica.applying = false;
    try bench.pass(heartbeat_ns);
    try bench.makeCopies();
    // Some of it applied, in the write transaction left open.
    replica.applier.applyNext();
    replica.applier.applyNext();
    try testing.expectEqual(replica_node.Phase.copying, replica.node.phase());
    bench.net.cut(0);
    try bench.settle();
    // No one reads it: gone.
    try testing.expect(!bench.copyKept(0));
    try testing.expect(try replica.store.appliedLsn() == null);
    try testing.expectEqual(@as(usize, 0), (try support.contents(&replica.store)).entries);
    replica.applying = true;
    try bench.pass(heartbeat_ns);
    try bench.makeCopies();
    try bench.pass(heartbeat_ns);
    try testing.expectEqual(@as(u64, 2), bench.master.copies_asked);
    try testing.expect(!bench.copyKept(1));
    try bench.expectCaughtUp();
}

test "a copy the log has left behind is given to no replica" {
    var bench: Bench = undefined;
    // A log of a few change sets.
    try bench.init(32 << 10);
    defer bench.deinit();
    try putKeys(&bench.store, 0, 800);
    const first = try bench.addReplica(64 << 10);
    first.applying = false;
    try bench.pass(heartbeat_ns);
    try bench.makeCopies();
    try testing.expectEqual(replica_node.Phase.copying, first.node.phase());
    // The log drops the change sets after the copy.
    try putKeys(&bench.store, 800, 50);
    try testing.expect(bench.copyKept(0));
    _ = try bench.addReplica(64 << 20);
    try bench.settle();
    try testing.expectEqual(@as(u64, 2), bench.master.copies_asked);
    try testing.expectEqual(@as(usize, 1), bench.copier.waiting());
    try testing.expect(bench.copyKept(0));
    try bench.makeCopies();
    // The first loads its copy, which turns out outdated, and gets the
    // newest.
    first.applying = true;
    for (0..10) |_| {
        try bench.pass(heartbeat_ns);
        try bench.makeCopies();
    }
    try testing.expect(!bench.copyKept(0));
    try testing.expect(!bench.copyKept(1));
    try bench.expectCaughtUp();
}
