//! A replica's replication threads: a loop that runs the replica's node
//! (replica_node.zig: connects to the master, holds the conversation),
//! waiting on the network until the node's deadline, and an applier that
//! applies the change sets and loads the copy the loop receives (it may
//! take long; the loop goes on meanwhile, acking heartbeats). A refusal
//! that asking again cannot help ends the loop: `halted` tells why.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const Clock = @import("clock.zig").Clock;
const Signal = @import("clock.zig").Signal;
const network = @import("network.zig");
const Network = network.Network;
const Wakeup = network.Wakeup;
const Watched = network.Watched;
const replica_node = @import("replica_node.zig");
const ReplicaNode = replica_node.ReplicaNode;
const Work = replica_node.Work;
const Done = replica_node.Done;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;

const log = std.log.scoped(.replication);

pub const Options = replica_node.Options;
pub const Phase = replica_node.Phase;

pub const Follower = struct {
    allocator: Allocator,
    clock: Clock,
    network: Network,
    /// The replica's last applied LSN, raised by each change set applied.
    applied: Signal = .{},
    /// Raised by the applier when it is done with something, and by `stop`.
    wakeup: Wakeup,
    stopping: std.atomic.Value(bool) = .init(false),
    loop_thread: ?std.Thread = null,
    applier: Applier,
    /// The loop's alone, but for its atomics.
    node: ReplicaNode,

    /// Starts following the master for the database of `store`, which must
    /// not be a master. It becomes a replica of it with its first copy.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, net: Network, store: *KeyValueStore, options: Options) !*Follower {
        if (try store.changeLogState() != null) return error.MasterDatabase;
        const self = try allocator.create(Follower);
        errdefer allocator.destroy(self);
        const wakeup = try net.wakeup();
        errdefer wakeup.close();
        var applier_store = try store.share();
        errdefer applier_store.deinit();
        self.* = .{
            .allocator = allocator,
            .clock = clock,
            .network = net,
            .wakeup = wakeup,
            .applier = .{ .allocator = allocator, .io = io, .clock = clock, .applied = &self.applied, .store = applier_store, .wakeup = wakeup, .copies_directory = options.copies_directory },
            .node = undefined,
        };
        self.node = try ReplicaNode.init(allocator, io, clock, net, store, &self.applied, wakeup, self.applier.applier(), options);
        errdefer self.node.deinit();
        try self.applier.start();
        errdefer self.applier.stop();
        self.loop_thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops the threads, closes the connection and frees the follower.
    pub fn stop(self: *Follower) void {
        self.stopping.store(true, .release);
        self.clock.stop(&self.applied);
        self.wakeup.raise();
        if (self.loop_thread) |thread| thread.join();
        self.node.deinit();
        self.applier.stop();
        self.applier.deinit();
        self.wakeup.close();
        self.allocator.destroy(self);
    }

    /// Waits until change set `lsn` is applied or `deadline` comes; returns
    /// the last applied then, or null once stopped or halted.
    pub fn waitApplied(self: *Follower, lsn: u64, deadline: u64) ?u64 {
        if (lsn == 0) return self.applied.value;
        return self.clock.wait(&self.applied, lsn - 1, deadline);
    }

    /// Why the master last turned this replica away, if it did since it
    /// last followed it.
    pub fn lastRefusal(self: *Follower) ?protocol.Refusal {
        return self.node.lastRefusal();
    }

    /// The master's last LSN, as its last heartbeat told (0 before one).
    pub fn masterLsn(self: *Follower) u64 {
        return self.node.master_lsn.load(.acquire);
    }

    /// Where the replica is in following its master.
    pub fn phase(self: *Follower) Phase {
        return self.node.phase();
    }

    /// When the master was last heard from, on the follower's clock; null
    /// if never.
    pub fn lastHeard(self: *Follower) ?u64 {
        return self.node.lastHeard();
    }

    /// The refusal that made the replica stop following its master for
    /// good (`Refusal.permanent`), or null while it follows. The threads
    /// stay until `stop`.
    pub fn halted(self: *Follower) ?protocol.Refusal {
        return self.node.halted();
    }

    fn run(self: *Follower) void {
        var watched_buffer: [2]Watched = undefined;
        while (true) {
            // Before looking: a `stop` raises it after.
            self.node.clearWakeup();
            if (self.stopping.load(.acquire)) return;
            const now = self.clock.now();
            self.node.step(now);
            if (self.node.halted() != null) return;
            const watched = self.node.watch(&watched_buffer);
            const timeout: ?u64 = if (self.node.deadline()) |deadline| deadline -| now else null;
            self.network.wait(watched, timeout) catch |err| {
                log.warn("waiting on the network failed: {t}", .{err});
                continue;
            };
            self.node.ready(watched);
        }
    }
};

/// The thread that applies what the loop receives, in order
/// (`replica_node.doWork`). It tells the loop (`take`) through the wakeup.
const Applier = struct {
    allocator: Allocator,
    io: Io,
    clock: Clock,
    applied: *Signal,
    store: KeyValueStore,
    wakeup: Wakeup,
    copies_directory: []const u8,
    thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Under `mutex`.
    work: std.ArrayList(Work) = .empty,
    /// The bytes of the change sets in `work` and in hand.
    unapplied_bytes: usize = 0,
    busy: bool = false,
    done: Done = .{},
    stopping: bool = false,

    fn applier(self: *Applier) replica_node.Applier {
        return .{ .context = self, .vtable = &.{ .give = give, .take = take, .drop = drop, .unappliedBytes = unappliedBytes } };
    }

    fn start(self: *Applier) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Waits for what is in hand, if anything is.
    fn stop(self: *Applier) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Once stopped.
    fn deinit(self: *Applier) void {
        self.dropWork();
        self.work.deinit(self.allocator);
        self.store.deinit();
    }

    fn give(context: *anyopaque, work: Work) Allocator.Error!void {
        const self: *Applier = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.work.append(self.allocator, work);
        if (work == .change_set) self.unapplied_bytes += work.change_set.bytes.len;
        self.condition.broadcast(self.io);
    }

    fn unappliedBytes(context: *anyopaque) usize {
        const self: *Applier = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.unapplied_bytes;
    }

    fn take(context: *anyopaque) Done {
        const self: *Applier = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const done = self.done;
        self.done = .{};
        return done;
    }

    fn drop(context: *anyopaque) void {
        const self: *Applier = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropWork();
        while (self.busy) self.condition.waitUncancelable(self.io, &self.mutex);
        self.done = .{};
    }

    fn dropWork(self: *Applier) void {
        for (self.work.items) |work| {
            if (work == .change_set) self.unapplied_bytes -= work.change_set.bytes.len;
            replica_node.dropWork(self.allocator, self.io, self.copies_directory, work);
        }
        self.work.clearRetainingCapacity();
    }

    fn run(self: *Applier) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (!self.stopping and self.work.items.len == 0) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) return;
            const work = self.work.orderedRemove(0);
            self.busy = true;
            self.mutex.unlock(self.io);
            const result = replica_node.doWork(self.clock, self.applied, &self.store, self.copies_directory, work);
            replica_node.dropWork(self.allocator, self.io, self.copies_directory, work);
            self.mutex.lockUncancelable(self.io);
            self.busy = false;
            if (work == .change_set) self.unapplied_bytes -= work.change_set.bytes.len;
            if (result) |lsn| switch (work) {
                .change_set => self.done.applied = lsn,
                .load_copy => self.done.copy_loaded = lsn,
            } else |err| {
                log.info("applying what the master sent failed: {t}", .{err});
                self.done.failure = err;
                // What follows depends on what failed.
                self.dropWork();
            }
            self.condition.broadcast(self.io);
            self.wakeup.raise();
        }
    }
};
