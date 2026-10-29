//! The master's replication threads: a loop that runs the master's node
//! (master_node.zig: accepts replicas, holds each one's conversation),
//! waiting on the network until the node's earliest deadline, and a
//! worker that makes the copies replicas ask for (it may take minutes;
//! the loop goes on meanwhile). A commit wakes the loop
//! (`commitListener`) to send its change set. Each replica acks how far
//! it applied; `replicaStates` tells it, and so its lag.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const copies = @import("copies.zig");
const Clock = @import("clock.zig").Clock;
const network = @import("network.zig");
const Network = network.Network;
const Wakeup = network.Wakeup;
const Watched = network.Watched;
const master_node = @import("master_node.zig");
const MasterNode = master_node.MasterNode;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;

const log = std.log.scoped(.replication);

pub const Options = master_node.Options;
pub const ReplicaState = master_node.ReplicaState;

pub const Server = struct {
    allocator: Allocator,
    clock: Clock,
    network: Network,
    /// Raised by each commit, each copy made, and `stop`.
    wakeup: Wakeup,
    stopping: std.atomic.Value(bool) = .init(false),
    loop_thread: ?std.Thread = null,
    copier: Copier,
    /// The loop's alone, but for `replicaStates`.
    node: MasterNode,

    /// Listens for replicas of the master `store` and starts accepting
    /// them. Set `commitListener` on the store that writes to the master.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, net: Network, store: *KeyValueStore, options: Options) !*Server {
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const wakeup = try net.wakeup();
        errdefer wakeup.close();
        var copier_store = try store.share();
        errdefer copier_store.deinit();
        self.* = .{
            .allocator = allocator,
            .clock = clock,
            .network = net,
            .wakeup = wakeup,
            .copier = .{ .allocator = allocator, .io = io, .store = copier_store, .wakeup = wakeup, .copies_directory = options.copies_directory },
            .node = undefined,
        };
        self.node = try MasterNode.init(allocator, io, net, store, wakeup, self.copier.copier(), options);
        errdefer self.node.deinit();
        try self.copier.start();
        errdefer self.copier.stop();
        self.loop_thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops every thread, closes every connection and frees the server.
    /// Unset the `commitListener` first: it points to the server.
    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        self.wakeup.raise();
        if (self.loop_thread) |thread| thread.join();
        self.copier.stop();
        self.copier.deinit();
        self.node.deinit();
        self.wakeup.close();
        self.allocator.destroy(self);
    }

    /// Where the server listens (the port chosen, if asked to choose).
    pub fn address(self: *Server, buffer: *[network.max_address_bytes]u8) []const u8 {
        return self.node.address(buffer);
    }

    /// The replicas served now, at most `buffer.len` of them, as the loop
    /// last saw them (it looks at least each heartbeat).
    pub fn replicaStates(self: *Server, buffer: []ReplicaState) []ReplicaState {
        return self.node.replicaStates(buffer);
    }

    /// For the master's writing store (`KeyValueStore.commit_listener`).
    pub fn commitListener(self: *Server) KeyValueStore.CommitListener {
        return .{ .context = self, .committed = committed };
    }

    fn committed(context: *anyopaque, lsn: u64) void {
        _ = lsn;
        const self: *Server = @ptrCast(@alignCast(context));
        self.wakeup.raise();
    }

    fn run(self: *Server) void {
        var watched_buffer: [network.max_watched]Watched = undefined;
        while (!self.stopping.load(.acquire)) {
            const now = self.clock.now();
            self.node.step(now);
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

/// The worker that makes copies of the master's database, one at a time
/// (`master_node.makeCopy`); the loop asks for them and takes them when
/// the wakeup tells it some are made.
const Copier = struct {
    allocator: Allocator,
    io: Io,
    store: KeyValueStore,
    wakeup: Wakeup,
    copies_directory: []const u8,
    thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Under `mutex`.
    asked: std.ArrayList(u64) = .empty,
    made: std.ArrayList(Made) = .empty,
    stopping: bool = false,

    const Made = master_node.Copier.Made;

    fn copier(self: *Copier) master_node.Copier {
        return .{ .context = self, .vtable = &.{ .ask = ask, .take = take } };
    }

    fn start(self: *Copier) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Waits for the copy being made, if one is.
    fn stop(self: *Copier) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Once stopped: deletes the copies made and not taken.
    fn deinit(self: *Copier) void {
        for (self.made.items) |made| copies.delete(self.io, self.copies_directory, made.number);
        self.made.deinit(self.allocator);
        self.asked.deinit(self.allocator);
        self.store.deinit();
    }

    fn ask(context: *anyopaque, number: u64) Allocator.Error!void {
        const self: *Copier = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.asked.append(self.allocator, number);
        self.condition.signal(self.io);
    }

    fn take(context: *anyopaque) std.ArrayList(Made) {
        const self: *Copier = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const made = self.made;
        self.made = .empty;
        return made;
    }

    fn run(self: *Copier) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (!self.stopping and self.asked.items.len == 0) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) return;
            const number = self.asked.orderedRemove(0);
            self.mutex.unlock(self.io);
            const failed = if (master_node.makeCopy(self.io, &self.store, self.copies_directory, number)) false else |err| blk: {
                log.warn("making copy {d} failed: {t}", .{ number, err });
                break :blk true;
            };
            self.mutex.lockUncancelable(self.io);
            // The loop is gone once stopping: `Server.stop` deletes it.
            self.made.append(self.allocator, .{ .number = number, .failed = failed }) catch {
                self.mutex.unlock(self.io);
                copies.delete(self.io, self.copies_directory, number);
                self.mutex.lockUncancelable(self.io);
                continue;
            };
            self.wakeup.raise();
        }
    }
};
