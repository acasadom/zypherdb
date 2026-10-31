//! The replication simulator: a master and one to three replicas, each a
//! node with no thread of its own (replication/master_node.zig,
//! replica_node.zig), run on one thread over the network in memory
//! (memory_network.zig) and a clock of the simulation's own. The
//! simulation decides everything a thread or the operating system would:
//! when the master commits, when time passes, when a copy is made and when
//! a replica applies what it received. It breaks things too: connections
//! cut, a partition, a replica frozen, a replica or the master restarted.
//! A node steps only when something it watches is ready or its deadline
//! comes, as on its thread.
//!
//! Checked: a replica's applied LSN is never past the master's last, and
//! at each LSN it applies its database equals the master's at that LSN
//! (and, sampled, its derived structures agree); a replica never halts.
//! Once the faults stop, every replica streams, acked and applied up to
//! the master's last LSN, equal to the master, and stays so for a while
//! with no new connection.
//!
//! Swarm testing: each seed chooses the replicas, the faults and their
//! rates, the network's capacity and how much change log the master keeps.
//! A run is determined by its seed: a failure prints the command that
//! repeats it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zypherdb = @import("zypherdb");
const Graph = zypherdb.Graph;
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

pub const Options = struct {
    seed: u64,
    /// The simulation's moves before the faults stop.
    steps: u32 = 1000,
    verbose: bool = false,
};

pub const Statistics = struct {
    commits: u64 = 0,
    large_commits: u64 = 0,
    change_sets_applied: u64 = 0,
    copies_made: u64 = 0,
    copies_loaded: u64 = 0,
    connects: u64 = 0,
    cuts: u64 = 0,
    partitions: u64 = 0,
    freezes: u64 = 0,
    replica_restarts: u64 = 0,
    master_restarts: u64 = 0,

    pub fn add(self: *Statistics, other: Statistics) void {
        inline for (@typeInfo(Statistics).@"struct".field_names) |name| @field(self, name) += @field(other, name);
    }

    pub fn format(self: Statistics, writer: *Io.Writer) Io.Writer.Error!void {
        inline for (@typeInfo(Statistics).@"struct".field_names) |name| try writer.print("  {s}: {d}\n", .{ name, @field(self, name) });
    }
};

const token = "the simulation's token";
const master_address = "master:7000";
const ms = std.time.ns_per_ms;
const heartbeat_ns = 100 * ms;
const timeout_ns = 500 * ms;
const max_replicas = 3;
/// What each replica calls itself: its index in `Simulation.replicas`.
const replica_names = [max_replicas][]const u8{ "replica-0", "replica-1", "replica-2" };
/// Simulated time the faults off may take to bring every replica up to
/// date.
const settle_ns = 120 * std.time.ns_per_s;
/// Simulated time every replica must then stay up to date, with no new
/// connection.
const steady_ns = 20 * heartbeat_ns;
const store_options = KeyValueStore.Options{ .durability = .deferred };

/// What each seed runs: how many replicas, how often each move happens.
const Swarm = struct {
    replicas: usize,
    capacity: usize,
    change_log_limit: u64,
    max_unapplied_bytes: usize,
    /// The weight of each move (0: never).
    commit: u32,
    large_commit: u32,
    pass_time: u32,
    make_copy: u32,
    apply: u32,
    cut: u32,
    partition: u32,
    freeze: u32,
    restart_replica: u32,
    restart_master: u32,

    fn choose(random: std.Random) Swarm {
        // libmdbx's copies are 16 MiB at least (its file's growth step),
        // however little they hold: through a small buffer each would take
        // minutes. LMDB's runs cover the messages cut in small pieces.
        const capacities: []const usize = if (std.mem.eql(u8, zypherdb.storage_engine, "mdbx")) &.{64 << 10} else &.{ 61, 1 << 10, 64 << 10 };
        return .{
            .replicas = random.intRangeAtMost(usize, 1, max_replicas),
            .capacity = capacities[random.uintLessThan(usize, capacities.len)],
            .change_log_limit = if (random.boolean()) 4 << 10 else 512 << 20,
            .max_unapplied_bytes = if (random.boolean()) 2 << 10 else 64 << 20,
            .commit = random.intRangeAtMost(u32, 1, 10),
            .large_commit = if (random.uintLessThan(u32, 4) == 0) 1 else 0,
            .pass_time = random.intRangeAtMost(u32, 1, 10),
            .make_copy = random.intRangeAtMost(u32, 1, 10),
            .apply = random.intRangeAtMost(u32, 1, 20),
            .cut = rarely(random),
            .partition = rarely(random),
            .freeze = rarely(random),
            .restart_replica = rarely(random),
            .restart_master = rarely(random),
        };
    }

    /// A fault's weight: off for some seeds.
    fn rarely(random: std.Random) u32 {
        return if (random.boolean()) 0 else random.intRangeAtMost(u32, 1, 3);
    }

    pub fn format(self: Swarm, writer: *Io.Writer) Io.Writer.Error!void {
        inline for (@typeInfo(Swarm).@"struct".field_names, 0..) |name, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s} {d}", .{ name, @field(self, name) });
        }
    }
};

const Move = enum { commit, large_commit, pass_time, make_copy, apply, cut, partition, freeze, restart_replica, restart_master };

/// The moves that break things, off once the simulation settles.
fn isFault(move: Move) bool {
    return switch (move) {
        .cut, .partition, .freeze, .restart_replica, .restart_master => true,
        else => false,
    };
}

/// One thread runs everything: `wait` is never called, and a signal is
/// raised or stopped with nobody to wake.
const SimulatedClock = struct {
    time: Instant = 0,

    fn clock(self: *SimulatedClock) Clock {
        return .{ .context = self, .vtable = &.{ .now = now, .wait = wait, .raise = raise, .stop = stop } };
    }

    fn now(context: *anyopaque) Instant {
        const self: *SimulatedClock = @ptrCast(@alignCast(context));
        return self.time;
    }

    fn wait(context: *anyopaque, signal: *Signal, seen: u64, deadline: Instant) ?u64 {
        _ = context;
        _ = signal;
        _ = seen;
        _ = deadline;
        unreachable;
    }

    fn raise(context: *anyopaque, signal: *Signal, value: u64) void {
        _ = context;
        if (value > signal.value) signal.value = value;
    }

    fn stop(context: *anyopaque, signal: *Signal) void {
        _ = context;
        signal.stopped = true;
    }
};

/// What a database holds, as a digest of its keys and values (the
/// replication bookkeeping, keys starting with '#', left out).
fn digest(store: *KeyValueStore) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    try store.beginRead();
    defer store.abortRead();
    inline for (.{ "main", "nodes", "relationships" }) |table| {
        var scan = if (comptime std.mem.eql(u8, table, "main")) try store.scanAll() else if (comptime std.mem.eql(u8, table, "nodes")) try store.scanNodes() else try store.scanRelationships();
        defer scan.deinit();
        while (try scan.next()) |entry| {
            if (comptime std.mem.eql(u8, table, "main")) if (entry.key.len > 0 and entry.key[0] == '#') continue;
            hasher.update(table);
            hasher.update(std.mem.asBytes(&entry.key.len));
            hasher.update(entry.key);
            hasher.update(std.mem.asBytes(&entry.value.len));
            hasher.update(entry.value);
        }
    }
    return hasher.final();
}

pub fn run(allocator: Allocator, io: Io, path: []const u8, options: Options, out: *Io.Writer) !Statistics {
    const simulation = try allocator.create(Simulation);
    defer allocator.destroy(simulation);
    try simulation.init(allocator, io, path, options, out);
    defer simulation.deinit();
    if (options.verbose) try out.print("seed {d}, swarm: {f}\n", .{ options.seed, simulation.swarm });
    for (0..options.steps) |_| try simulation.move(true);
    try simulation.settle();
    simulation.statistics.connects = simulation.network.connects;
    return simulation.statistics;
}

const Master = struct {
    store: KeyValueStore,
    graph: Graph,
    /// Raised by each commit and each copy made; outlives the node.
    wakeup: Wakeup,
    copier: master_node.InlineCopier,
    /// No replica forwards writes yet: it stays idle.
    runner: master_node.InlineRunner,
    node: MasterNode,
    copies_path: []const u8,
    /// The nodes alive, for the writes.
    nodes: std.ArrayList(u64) = .empty,
};

const Replica = struct {
    path: []const u8,
    copies_path: []const u8,
    /// The simulation's own handle, for the checks.
    store: KeyValueStore,
    applied: Signal = .{},
    wakeup: Wakeup,
    applier: replica_node.InlineApplier,
    node: ReplicaNode,
    /// A frozen replica does nothing until then.
    frozen_until: Instant = 0,
    /// The LSN its database was last checked at.
    checked_lsn: ?u64 = null,
    /// False after a restart that failed to open it again.
    open: bool = false,
};

const Simulation = struct {
    allocator: Allocator,
    io: Io,
    out: *Io.Writer,
    options: Options,
    prng: std.Random.DefaultPrng,
    swarm: Swarm,
    clock: SimulatedClock = .{},
    network: MemoryNetwork,
    master: Master,
    replicas: [max_replicas]Replica,
    /// The master's database at each LSN it committed.
    digests: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// The partition lasts until then.
    partition_until: Instant = 0,
    statistics: Statistics = .{},

    fn init(self: *Simulation, allocator: Allocator, io: Io, path: []const u8, options: Options, out: *Io.Writer) !void {
        var prng = std.Random.DefaultPrng.init(options.seed);
        const swarm = Swarm.choose(prng.random());
        self.* = .{
            .allocator = allocator,
            .io = io,
            .out = out,
            .options = options,
            .prng = prng,
            .swarm = swarm,
            .network = .{ .allocator = allocator, .capacity = swarm.capacity },
            .master = undefined,
            .replicas = undefined,
        };
        try self.openMaster(path);
        for (self.replicas[0..swarm.replicas], 0..) |*replica, i| {
            replica.path = try std.fmt.allocPrint(allocator, "{s}/replica-{d}", .{ path, i });
            replica.copies_path = try std.fmt.allocPrint(allocator, "{s}/replica-{d}-copies", .{ path, i });
            try Io.Dir.cwd().createDirPath(io, replica.path);
            replica.open = false;
            try self.openReplica(replica);
        }
    }

    fn deinit(self: *Simulation) void {
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            self.closeReplica(replica);
            self.allocator.free(replica.path);
            self.allocator.free(replica.copies_path);
        }
        const master = &self.master;
        master.node.deinit();
        master.copier.deinit();
        master.runner.deinit();
        master.store.commit_listener = null;
        master.store.deinit();
        master.wakeup.close();
        master.nodes.deinit(self.allocator);
        self.allocator.free(master.copies_path);
        self.digests.deinit(self.allocator);
        self.network.deinit();
    }

    fn random(self: *Simulation) std.Random {
        return self.prng.random();
    }

    fn openMaster(self: *Simulation, path: []const u8) !void {
        const master = &self.master;
        const master_path = try std.fmt.allocPrint(self.allocator, "{s}/master", .{path});
        defer self.allocator.free(master_path);
        try Io.Dir.cwd().createDirPath(self.io, master_path);
        master.copies_path = try std.fmt.allocPrint(self.allocator, "{s}/master-copies", .{path});
        master.nodes = .empty;
        master.store = try KeyValueStore.openWithOptions(self.allocator, master_path, store_options);
        master.store.change_log_limit = self.swarm.change_log_limit;
        try master.store.startChangeLog();
        master.store.commit_listener = .{ .context = self, .committed = committed };
        master.graph = Graph.init(&master.store, self.allocator);
        master.wakeup = try self.network.network().wakeup();
        try self.digests.put(self.allocator, try self.lastLsn(), try digest(&master.store));
        try self.startMasterNode();
    }

    fn startMasterNode(self: *Simulation) !void {
        const master = &self.master;
        master.copier = .{ .allocator = self.allocator, .io = self.io, .store = try master.store.share(), .wakeup = master.wakeup, .copies_directory = master.copies_path };
        errdefer master.copier.deinit();
        master.runner = .{ .allocator = self.allocator, .store = try master.store.share(), .wakeup = master.wakeup };
        errdefer master.runner.deinit();
        master.node = try MasterNode.init(self.allocator, self.io, self.network.network(), &master.store, master.wakeup, master.copier.copier(), master.runner.runner(), .{
            .address = master_address,
            .token = token,
            .copies_directory = master.copies_path,
            .heartbeat_ns = heartbeat_ns,
            .timeout_ns = timeout_ns,
            .copy_timeout_ns = 10 * std.time.ns_per_s,
            .max_replicas = max_replicas + 1,
        });
    }

    fn committed(context: *anyopaque, lsn: u64) void {
        _ = lsn;
        const self: *Simulation = @ptrCast(@alignCast(context));
        self.master.wakeup.raise();
    }

    fn lastLsn(self: *Simulation) !u64 {
        const state = (try self.master.store.changeLogState()).?;
        return state.next_lsn - 1;
    }

    fn openReplica(self: *Simulation, replica: *Replica) !void {
        replica.store = try KeyValueStore.openWithOptions(self.allocator, replica.path, store_options);
        errdefer replica.store.deinit();
        replica.applied = .{};
        replica.frozen_until = 0;
        replica.checked_lsn = null;
        replica.wakeup = try self.network.network().wakeup();
        errdefer replica.wakeup.close();
        replica.applier = .{
            .allocator = self.allocator,
            .io = self.io,
            .clock = self.clock.clock(),
            .applied = &replica.applied,
            .store = try replica.store.share(),
            .wakeup = replica.wakeup,
            .copies_directory = replica.copies_path,
        };
        errdefer replica.applier.deinit();
        replica.node = try ReplicaNode.init(self.allocator, self.io, self.clock.clock(), self.network.network(), &replica.store, &replica.applied, replica.wakeup, replica.applier.applier(), .{
            .master_address = master_address,
            .token = token,
            .copies_directory = replica.copies_path,
            .first_retry_ns = 10 * ms,
            .longest_retry_ns = 200 * ms,
            .timeout_ns = timeout_ns,
            .max_unapplied_bytes = self.swarm.max_unapplied_bytes,
            .name = replica_names[self.indexOf(replica)],
        });
        replica.open = true;
    }

    fn indexOf(self: *const Simulation, replica: *const Replica) usize {
        return (@intFromPtr(replica) - @intFromPtr(&self.replicas[0])) / @sizeOf(Replica);
    }

    fn closeReplica(self: *Simulation, replica: *Replica) void {
        _ = self;
        if (!replica.open) return;
        replica.open = false;
        replica.node.deinit();
        replica.applier.deinit();
        replica.wakeup.close();
        replica.store.deinit();
    }

    fn note(self: *Simulation, comptime format: []const u8, arguments: anytype) void {
        if (!self.options.verbose) return;
        self.out.print("{d} ms: " ++ format ++ "\n", .{self.clock.time / ms} ++ arguments) catch {};
        // A seed that hangs shows how far it went.
        self.out.flush() catch {};
    }

    fn fail(self: *Simulation, comptime format: []const u8, arguments: anytype) error{FuzzFailed} {
        self.out.print("seed {d} failed at {d} ms: " ++ format ++ "\n", .{ self.options.seed, self.clock.time / ms } ++ arguments) catch {};
        self.out.print("swarm: {f}\nrepeat: zig build fuzz -- replication --seed {d} --steps {d} --verbose\n", .{ self.swarm, self.options.seed, self.options.steps }) catch {};
        self.out.flush() catch {};
        return error.FuzzFailed;
    }

    /// One move of the simulation, then every node that has something to
    /// do steps. Faults only while `faults`.
    fn move(self: *Simulation, faults: bool) !void {
        const chosen = self.chooseMove(faults);
        switch (chosen) {
            .commit => try self.commit(self.random().intRangeAtMost(usize, 1, 8)),
            .large_commit => {
                self.statistics.large_commits += 1;
                try self.commit(self.random().intRangeAtMost(usize, 200, 1000));
            },
            .pass_time => self.passTime(),
            .make_copy => if (self.master.copier.waiting() > 0) {
                self.note("the master makes a copy", .{});
                try self.master.copier.makeNext();
                self.statistics.copies_made += 1;
            },
            .apply => try self.apply(&self.replicas[self.random().uintLessThan(usize, self.swarm.replicas)]),
            .cut => if (self.network.linkCount() > 0) {
                self.note("a connection is cut", .{});
                self.network.cut(self.random().uintLessThan(usize, self.network.linkCount()));
                self.statistics.cuts += 1;
            },
            .partition => if (self.clock.time >= self.partition_until) {
                self.partition_until = self.clock.time + self.random().intRangeAtMost(u64, 1, 2 * timeout_ns);
                self.note("a partition until {d} ms", .{self.partition_until / ms});
                self.statistics.partitions += 1;
            },
            .freeze => {
                const replica = &self.replicas[self.random().uintLessThan(usize, self.swarm.replicas)];
                replica.frozen_until = self.clock.time + self.random().intRangeAtMost(u64, 1, 3 * timeout_ns);
                self.note("a replica is frozen until {d} ms", .{replica.frozen_until / ms});
                self.statistics.freezes += 1;
            },
            .restart_replica => {
                const replica = &self.replicas[self.random().uintLessThan(usize, self.swarm.replicas)];
                self.note("a replica restarts", .{});
                self.closeReplica(replica);
                try self.openReplica(replica);
                self.statistics.replica_restarts += 1;
            },
            .restart_master => {
                self.note("the master's node restarts", .{});
                self.master.node.deinit();
                self.master.copier.deinit();
                self.master.runner.deinit();
                try self.startMasterNode();
                self.statistics.master_restarts += 1;
            },
        }
        _ = try self.stepNodes();
    }

    fn chooseMove(self: *Simulation, faults: bool) Move {
        const names = @typeInfo(Move).@"enum".field_names;
        var weights: [names.len]u32 = undefined;
        var total: u32 = 0;
        inline for (names, 0..) |name, i| {
            weights[i] = if (!faults and isFault(@field(Move, name))) 0 else @field(self.swarm, name);
            total += weights[i];
        }
        var pick = self.random().uintLessThan(u32, total);
        for (weights, 0..) |weight, i| {
            if (pick < weight) return @fromBackingInt(@intCast(i));
            pick -= weight;
        }
        unreachable;
    }

    /// A write transaction of `operations` writes on the master, kept or
    /// (now and then) aborted.
    fn commit(self: *Simulation, operations: usize) !void {
        const master = &self.master;
        const graph = &master.graph;
        try graph.beginWrite();
        var created: std.ArrayList(u64) = .empty;
        defer created.deinit(self.allocator);
        var deleted: std.ArrayList(u64) = .empty;
        defer deleted.deinit(self.allocator);
        for (0..operations) |_| {
            const alive = master.nodes.items.len + created.items.len;
            const choice = if (alive == 0) 0 else self.random().uintLessThan(u32, 4);
            switch (choice) {
                0 => {
                    const id = try graph.allocateNodeId();
                    try graph.addNode(id, if (self.random().boolean()) "" else "Person");
                    try created.append(self.allocator, id);
                },
                1, 2 => {
                    const id = self.pickNode(created.items, deleted.items) orelse continue;
                    const value: zypherdb.Value = if (self.random().boolean()) .{ .int = self.random().int(i64) } else .{ .string = "a value a little longer than a few bytes" };
                    try graph.setProperty(id, if (self.random().boolean()) "age" else "name", value);
                },
                3 => {
                    const id = self.pickNode(created.items, deleted.items) orelse continue;
                    try graph.deleteNode(id);
                    try deleted.append(self.allocator, id);
                },
                else => unreachable,
            }
        }
        if (self.random().uintLessThan(u32, 10) == 0) {
            graph.abortWrite();
            self.note("the master aborts {d} writes", .{operations});
            return;
        }
        try graph.commitWrite();
        try master.nodes.appendSlice(self.allocator, created.items);
        for (deleted.items) |id| {
            const index = std.mem.indexOfScalar(u64, master.nodes.items, id).?;
            _ = master.nodes.swapRemove(index);
        }
        const lsn = try self.lastLsn();
        try self.digests.put(self.allocator, lsn, try digest(&master.store));
        self.statistics.commits += 1;
        self.note("the master commits {d} writes: LSN {d}", .{ operations, lsn });
    }

    /// A node alive in the transaction: committed or `created`, not
    /// `deleted`.
    fn pickNode(self: *Simulation, created: []const u64, deleted: []const u64) ?u64 {
        const committed_count = self.master.nodes.items.len;
        const count = committed_count + created.len;
        if (count == 0) return null;
        const index = self.random().uintLessThan(usize, count);
        const id = if (index < committed_count) self.master.nodes.items[index] else created[index - committed_count];
        if (std.mem.indexOfScalar(u64, deleted, id) != null) return null;
        return id;
    }

    /// Time passes: up to the earliest deadline of what waits, or by a
    /// little.
    fn passTime(self: *Simulation) void {
        const now = self.clock.time;
        if (self.random().boolean()) {
            if (self.earliestDeadline()) |at| if (at > now) {
                self.clock.time = at;
                return;
            };
        }
        self.clock.time += self.random().intRangeAtMost(u64, 1, heartbeat_ns / 2);
    }

    fn earliestDeadline(self: *Simulation) ?Instant {
        var earliest: ?Instant = self.master.node.deadline();
        const now = self.clock.time;
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            const at = if (replica.frozen_until > now) replica.frozen_until else replica.node.deadline() orelse continue;
            earliest = if (earliest) |known| @min(known, at) else at;
        }
        if (self.partition_until > now) earliest = if (earliest) |known| @min(known, self.partition_until) else self.partition_until;
        return earliest;
    }

    /// `replica` applies the oldest work it was given, then is checked
    /// against the master at the LSN it reached.
    fn apply(self: *Simulation, replica: *Replica) !void {
        if (replica.frozen_until > self.clock.time) return;
        if (replica.applier.waiting() == 0) return;
        const loads_copy = replica.applier.work.items[0] == .load_copy;
        replica.applier.applyNext();
        if (loads_copy) self.statistics.copies_loaded += 1 else self.statistics.change_sets_applied += 1;
        try self.check(replica);
    }

    fn check(self: *Simulation, replica: *Replica) !void {
        const lsn = try replica.store.appliedLsn() orelse return;
        if (replica.checked_lsn == lsn) return;
        replica.checked_lsn = lsn;
        const last = try self.lastLsn();
        if (lsn > last) return self.fail("a replica applied LSN {d}, past the master's last, {d}", .{ lsn, last });
        const expected = self.digests.get(lsn) orelse return self.fail("a replica is at LSN {d}, which the master never committed", .{lsn});
        if (try digest(&replica.store) != expected) return self.fail("a replica at LSN {d} differs from the master at that LSN", .{lsn});
        if (self.random().uintLessThan(u32, 8) == 0) try self.checkIntegrity(replica);
        self.note("a replica is at LSN {d}, equal to the master then", .{lsn});
    }

    fn checkIntegrity(self: *Simulation, replica: *Replica) !void {
        var graph = Graph.init(&replica.store, self.allocator);
        var report = try zypherdb.integrity.check(&graph, self.allocator);
        defer report.deinit();
        if (!report.ok()) return self.fail("a replica: {f}", .{report});
    }

    /// Every node with something ready or past its deadline steps, as its
    /// thread would after `Network.wait`; returns whether any did. Frozen
    /// replicas do nothing.
    fn stepNodes(self: *Simulation) !bool {
        const now = self.clock.time;
        self.network.refusing = now < self.partition_until;
        const net = self.network.network();
        var stepped = false;
        {
            var buffer: [network.max_watched]Watched = undefined;
            const node = &self.master.node;
            const watched = node.watch(&buffer);
            try net.wait(watched, null);
            node.ready(watched);
            if (anyReady(watched) or due(node.deadline(), now)) {
                node.step(now);
                stepped = true;
            }
        }
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            if (replica.frozen_until > now) continue;
            var buffer: [2]Watched = undefined;
            const node = &replica.node;
            const watched = node.watch(&buffer);
            try net.wait(watched, null);
            node.ready(watched);
            if (anyReady(watched) or due(node.deadline(), now)) {
                node.step(now);
                stepped = true;
            }
            if (node.halted()) |reason| return self.fail("a replica halted: {t}", .{reason});
        }
        return stepped;
    }

    fn anyReady(watched: []const Watched) bool {
        for (watched) |one| if (one.ready.readable or one.ready.writable) return true;
        return false;
    }

    fn due(deadline: ?Instant, now: Instant) bool {
        return if (deadline) |at| now >= at else false;
    }

    /// Faults stop; every replica must come up to date, then stay so with
    /// no new connection.
    fn settle(self: *Simulation) !void {
        self.partition_until = 0;
        for (self.replicas[0..self.swarm.replicas]) |*replica| replica.frozen_until = 0;
        self.note("the faults stop", .{});
        const settle_by = self.clock.time + settle_ns;
        while (!try self.upToDate()) {
            if (self.clock.time > settle_by) {
                try self.describe();
                return self.fail("the replicas did not come up to date in {d} s with no faults", .{settle_ns / std.time.ns_per_s});
            }
            try self.drain();
        }
        self.note("every replica is up to date", .{});
        const connects = self.network.connects;
        const steady_until = self.clock.time + steady_ns;
        while (self.clock.time < steady_until) {
            try self.drain();
            if (!try self.upToDate()) return self.fail("a replica fell behind with no faults and no writes", .{});
            if (self.network.connects != connects) return self.fail("a replica connected again with no faults", .{});
        }
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            if (try digest(&replica.store) != try digest(&self.master.store)) return self.fail("a replica up to date differs from the master", .{});
            try self.checkIntegrity(replica);
        }
        try self.checkIdentities();
    }

    /// The master serves each replica once, by its name, from its
    /// connection; each replica streams, last heard within a timeout.
    fn checkIdentities(self: *Simulation) !void {
        var buffer: [max_replicas + 1]master_node.ReplicaState = undefined;
        const states = self.master.node.replicaStates(&buffer);
        for (self.replicas[0..self.swarm.replicas], 0..) |*replica, i| {
            const node = &replica.node;
            if (node.phase() != .streaming) return self.fail("replica {d} is up to date but tells {t}", .{ i, node.phase() });
            const heard = node.lastHeard() orelse return self.fail("replica {d} never heard from its master", .{i});
            if (self.clock.time - heard > timeout_ns) return self.fail("replica {d} last heard from its master too long ago", .{i});
            var served: usize = 0;
            for (states) |*state| {
                if (!std.mem.eql(u8, state.name(), replica_names[i])) continue;
                served += 1;
                if (!std.mem.startsWith(u8, state.address(), "memory:")) return self.fail("replica {d} served from {s}", .{ i, state.address() });
                if (state.connected_at > self.clock.time) return self.fail("replica {d} connected in the future", .{i});
            }
            if (served != 1) return self.fail("replica {d} served {d} times", .{ i, served });
        }
    }

    /// With no faults and no writes: copies made, work applied and nodes
    /// stepped until none has anything to do, then time passes to the
    /// next deadline (a heartbeat at most).
    fn drain(self: *Simulation) !void {
        var idle_rounds: usize = 0;
        while (true) {
            const copies_made = self.statistics.copies_made;
            while (self.master.copier.waiting() > 0) {
                try self.master.copier.makeNext();
                self.statistics.copies_made += 1;
            }
            var applied = false;
            for (self.replicas[0..self.swarm.replicas]) |*replica| {
                while (replica.applier.waiting() > 0) {
                    try self.apply(replica);
                    applied = true;
                }
            }
            const bytes_moved = self.network.bytes_moved;
            if (!try self.stepNodes() and !applied) break;
            // On its thread, a node that steps again and again with
            // nothing moving spins.
            const moved = applied or self.statistics.copies_made != copies_made or self.network.bytes_moved != bytes_moved;
            idle_rounds = if (moved) 0 else idle_rounds + 1;
            if (idle_rounds == 1000) return self.fail("a node steps again and again with nothing moving", .{});
        }
        const now = self.clock.time;
        const next = self.earliestDeadline() orelse now + heartbeat_ns;
        self.clock.time = if (next > now) @min(next, now + heartbeat_ns) else now + 1;
    }

    /// Where each node is, for a failure.
    fn describe(self: *Simulation) !void {
        try self.out.print("master: last LSN {d}, copies waiting {d}\n", .{ try self.lastLsn(), self.master.copier.waiting() });
        var buffer: [max_replicas + 1]master_node.ReplicaState = undefined;
        for (self.master.node.replicaStates(&buffer)) |state| try self.out.print("  served: {t}, acked {d}\n", .{ state.phase, state.acked_lsn });
        for (self.replicas[0..self.swarm.replicas], 0..) |*replica, i| {
            const node = &replica.node;
            try self.out.print("replica {d}: applied {?d}, work waiting {d}, retry at {d} ms, refusal {?t}, ", .{ i, try replica.store.appliedLsn(), replica.applier.waiting(), node.retry_at / ms, node.lastRefusal() });
            if (node.conversation) |conversation| {
                try self.out.print("conversation {t}, deadline {?d}\n", .{ conversation.session.state, conversation.session.deadline() });
            } else try self.out.writeAll("no conversation\n");
        }
    }

    /// Every replica streams, has applied and acked the master's last LSN.
    fn upToDate(self: *Simulation) !bool {
        const last = try self.lastLsn();
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            if (try replica.store.appliedLsn() != last) return false;
        }
        var buffer: [max_replicas + 1]master_node.ReplicaState = undefined;
        const states = self.master.node.replicaStates(&buffer);
        if (states.len != self.swarm.replicas) return false;
        for (states) |state| {
            if (state.phase != .streaming or state.acked_lsn != last) return false;
        }
        return true;
    }
};
