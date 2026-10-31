//! The master's replication threads: a loop that runs the master's node
//! (master_node.zig: accepts replicas, holds each one's conversation),
//! waiting on the network until the node's earliest deadline, and a
//! worker that makes the copies replicas ask for (it may take minutes;
//! the loop goes on meanwhile), and one that runs the writes replicas
//! forward, one at a time. A commit wakes the loop
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
    /// Raised by each commit, each copy made, each write run, and `stop`.
    wakeup: Wakeup,
    stopping: std.atomic.Value(bool) = .init(false),
    loop_thread: ?std.Thread = null,
    copier: Worker(CopyWork),
    runner: Worker(RunWork),
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
        var runner_store = try store.share();
        errdefer runner_store.deinit();
        self.* = .{
            .allocator = allocator,
            .clock = clock,
            .network = net,
            .wakeup = wakeup,
            .copier = .{ .allocator = allocator, .io = io, .wakeup = wakeup, .work = .{ .io = io, .store = copier_store, .copies_directory = options.copies_directory } },
            .runner = .{ .allocator = allocator, .io = io, .wakeup = wakeup, .work = .{ .allocator = allocator, .store = runner_store } },
            .node = undefined,
        };
        self.node = try MasterNode.init(allocator, io, net, store, wakeup, self.copier.copier(), self.runner.runner(), options);
        errdefer self.node.deinit();
        try self.copier.start();
        errdefer self.copier.stop();
        try self.runner.start();
        errdefer self.runner.stop();
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
        self.runner.stop();
        self.runner.deinit();
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

/// A worker thread that does the jobs the loop asks for, one at a time
/// and in order, and raises the wakeup when some are done. `Work` does
/// each (`work(*Work, Job) Done`) and frees what is left once stopped
/// (`dropJob`, `dropDone`, `deinit`).
fn Worker(comptime Work: type) type {
    return struct {
        allocator: Allocator,
        io: Io,
        wakeup: Wakeup,
        work: Work,
        thread: ?std.Thread = null,
        mutex: Io.Mutex = .init,
        condition: Io.Condition = .init,
        /// Under `mutex`.
        asked: std.ArrayList(Work.Job) = .empty,
        done: std.ArrayList(Work.Done) = .empty,
        stopping: bool = false,

        const Self = @This();

        fn start(self: *Self) !void {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        /// Waits for the job in hand, if any.
        fn stop(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopping = true;
            self.condition.broadcast(self.io);
            self.mutex.unlock(self.io);
            if (self.thread) |thread| thread.join();
            self.thread = null;
        }

        /// Once stopped: frees the jobs not done and those done and not
        /// taken.
        fn deinit(self: *Self) void {
            for (self.asked.items) |job| self.work.dropJob(job);
            self.asked.deinit(self.allocator);
            for (self.done.items) |done| self.work.dropDone(done);
            self.done.deinit(self.allocator);
            self.work.deinit();
        }

        fn ask(self: *Self, job: Work.Job) Allocator.Error!void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.asked.append(self.allocator, job) catch |err| {
                self.work.dropJob(job);
                return err;
            };
            self.condition.signal(self.io);
        }

        fn take(self: *Self) std.ArrayList(Work.Done) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const done = self.done;
            self.done = .empty;
            return done;
        }

        fn run(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (true) {
                while (!self.stopping and self.asked.items.len == 0) self.condition.waitUncancelable(self.io, &self.mutex);
                if (self.stopping) return;
                const job = self.asked.orderedRemove(0);
                self.mutex.unlock(self.io);
                const done = self.work.work(job);
                self.mutex.lockUncancelable(self.io);
                // The loop is gone once stopping: `Server.stop` frees it.
                self.done.append(self.allocator, done) catch {
                    self.work.dropDone(done);
                    continue;
                };
                self.wakeup.raise();
            }
        }

        fn copier(self: *Self) master_node.Copier {
            return .{ .context = self, .vtable = &.{ .ask = askCopy, .take = takeCopies } };
        }

        fn askCopy(context: *anyopaque, number: u64) Allocator.Error!void {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.ask(number);
        }

        fn takeCopies(context: *anyopaque) std.ArrayList(master_node.Copier.Made) {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.take();
        }

        fn runner(self: *Self) master_node.Runner {
            return .{ .context = self, .vtable = &.{ .run = askRun, .take = takeRuns } };
        }

        fn askRun(context: *anyopaque, asked: master_node.Runner.Asked) Allocator.Error!void {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.ask(asked);
        }

        fn takeRuns(context: *anyopaque) std.ArrayList(master_node.Runner.Ran) {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.take();
        }
    };
}

/// Makes copies of the master's database (`master_node.makeCopy`).
const CopyWork = struct {
    io: Io,
    store: KeyValueStore,
    copies_directory: []const u8,

    const Job = u64;
    const Done = master_node.Copier.Made;

    fn work(self: *CopyWork, number: u64) Done {
        const failed = if (master_node.makeCopy(self.io, &self.store, self.copies_directory, number)) false else |err| blk: {
            log.warn("making copy {d} failed: {t}", .{ number, err });
            break :blk true;
        };
        return .{ .number = number, .failed = failed };
    }

    fn dropJob(_: *CopyWork, _: u64) void {}

    fn dropDone(self: *CopyWork, made: Done) void {
        copies.delete(self.io, self.copies_directory, made.number);
    }

    fn deinit(self: *CopyWork) void {
        self.store.deinit();
    }
};

/// Runs the writes replicas forward (`master_node.runWrite`).
const RunWork = struct {
    allocator: Allocator,
    store: KeyValueStore,

    const Job = master_node.Runner.Asked;
    const Done = master_node.Runner.Ran;

    fn work(self: *RunWork, asked: Job) Done {
        return master_node.runWrite(self.allocator, &self.store, asked);
    }

    fn dropJob(self: *RunWork, asked: Job) void {
        self.allocator.free(asked.request);
    }

    fn dropDone(self: *RunWork, ran: Done) void {
        if (ran.answer) |answer| self.allocator.free(answer);
    }

    fn deinit(self: *RunWork) void {
        self.store.deinit();
    }
};
