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
//! Each replica forwards writes (forwarder.zig), and so does a standby on
//! the master's machine, which goes on when the master's node restarts as
//! when another process takes over: the master runs them (a write in its
//! hands is lost when its node restarts) when the simulation says.
//!
//! Checked: a replica's applied LSN is never past the master's last, and
//! at each LSN it applies its database equals the master's at that LSN
//! (and, sampled, its derived structures agree); a replica never halts.
//! A forwarded write runs once at most; one answered ran, at the LSN the
//! answer tells, and its rows are its own; one told unreachable never
//! runs; one unknown may run, once. Once the faults stop, every replica
//! streams, acked and applied up to the master's last LSN, equal to the
//! master, and stays so for a while with no new connection; a write each
//! process forwards then is answered.
//!
//! Some seeds work on a vector index too: the master creates and drops
//! it, and writes vectors; each process populates and rebuilds its own
//! index a batch at a time, as its builder thread does, when the simulation
//! says and only while that thread would be awake. A replica loading a copy
//! mid-population or mid-rebuild must wake its builder. The index's keys are each process's own (they
//! are not logged), so the databases compare without them; at the end every
//! index must be online and every database sound.
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
const EncryptedNetwork = zypherdb.replication_encrypted_network.EncryptedNetwork;
const master_node = zypherdb.replication_master_node;
const MasterNode = master_node.MasterNode;
const replica_node = zypherdb.replication_replica_node;
const ReplicaNode = replica_node.ReplicaNode;
const forwarder = zypherdb.replication_forwarder;
const ForwardingNode = forwarder.ForwardingNode;
const forwarding = zypherdb.replication_forwarding;
const MapEntry = zypherdb.value.MapEntry;
const population = zypherdb.vector.population;
const vector_index_marker = zypherdb.vector.index.marker;

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
    forwards: u64 = 0,
    forwarded_writes_run: u64 = 0,
    forwards_answered: u64 = 0,
    forwards_unknown: u64 = 0,
    forwards_unreachable: u64 = 0,
    forwards_without_copy: u64 = 0,
    vector_index_changes: u64 = 0,
    background_batches: u64 = 0,
    copies_loaded_mid_population: u64 = 0,
    copies_loaded_mid_rebuild: u64 = 0,

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
/// What each forwarded write does: a node of its own, by its number.
const forwarded_write = "CREATE (n:Forwarded {number: $number}) RETURN n.number AS number";
/// What the second statement of a forwarded batch does: on the node the
/// first made, in the same transaction.
const batched_write = "MATCH (n:Forwarded {number: $number}) SET n.batched = true RETURN n.number AS number";
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
const create_vector_index = "CREATE VECTOR INDEX people IF NOT EXISTS FOR (n:Person) ON n.v OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}";
const drop_vector_index = "DROP INDEX people IF EXISTS";

/// What each seed runs: how many replicas, how often each move happens.
const Swarm = struct {
    replicas: usize,
    capacity: usize,
    change_log_limit: u64,
    max_unapplied_bytes: usize,
    /// The longest a forwarded write may take.
    request_timeout_ns: u64,
    /// Whether the conversations go over an `EncryptedNetwork`.
    encrypted: bool,
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
    forward: u32,
    run_write: u32,

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
            .request_timeout_ns = if (random.boolean()) timeout_ns else 10 * timeout_ns,
            .encrypted = random.boolean(),
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
            .forward = random.intRangeAtMost(u32, 0, 5),
            // A master slow to run them: writes it holds run out of time.
            .run_write = if (random.uintLessThan(u32, 4) == 0) 0 else random.intRangeAtMost(u32, 1, 10),
        };
    }

    /// A fault's weight: off for some seeds.
    fn rarely(random: std.Random) u32 {
        return if (random.boolean()) 0 else random.intRangeAtMost(u32, 1, 3);
    }

    pub fn format(self: Swarm, writer: *Io.Writer) Io.Writer.Error!void {
        inline for (@typeInfo(Swarm).@"struct".field_names, 0..) |name, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("{s} {any}", .{ name, @field(self, name) });
        }
    }
};

const Move = enum { commit, large_commit, pass_time, make_copy, apply, cut, partition, freeze, restart_replica, restart_master, forward, run_write };

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
/// replication bookkeeping, keys starting with '#', and each process's own
/// vector indexes, left out).
fn digest(store: *KeyValueStore) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    try store.beginRead();
    defer store.abortRead();
    inline for (.{ "main", "nodes", "relationships" }) |table| {
        var scan = if (comptime std.mem.eql(u8, table, "main")) try store.scanAll() else if (comptime std.mem.eql(u8, table, "nodes")) try store.scanNodes() else try store.scanRelationships();
        defer scan.deinit();
        while (try scan.next()) |entry| {
            if (comptime std.mem.eql(u8, table, "main")) if (entry.key.len > 0 and (entry.key[0] == '#' or entry.key[0] == vector_index_marker)) continue;
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
    runner: master_node.InlineRunner,
    node: MasterNode,
    copies_path: []const u8,
    /// The nodes alive, for the writes.
    nodes: std.ArrayList(u64) = .empty,
    builder: SimulatedBuilder = .{},
};

const Replica = struct {
    path: []const u8,
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
    forwarding: Forwarding,
    /// False after a restart that failed to open it again.
    open: bool = false,
    builder: SimulatedBuilder = .{},
};

/// A process's vector index builder thread, run by the simulation: woken
/// as the thread is (population.Builder), it takes a batch when the
/// simulation says, and sleeps once no background work is left.
const SimulatedBuilder = struct {
    woken: bool = false,

    /// As the thread starts when its process opens `store`: told by it and
    /// the shares made of it from now on, and woken if background work was
    /// cut short.
    fn open(self: *SimulatedBuilder, store: *KeyValueStore, budget: KeyValueStore.PopulationBudget) !void {
        self.* = .{};
        store.population_waker = .{ .context = self, .wake = wake };
        store.population_budget = budget;
        // Rebuilt after a few deletes.
        store.vector_rebuild_tombstones = 2;
        if (try population.anyWork(store)) self.woken = true;
    }

    fn wake(context: *anyopaque) void {
        const self: *SimulatedBuilder = @ptrCast(@alignCast(context));
        self.woken = true;
    }

    /// One batch on `store` if awake; false if it was not, or no index was
    /// left (it sleeps).
    fn step(self: *SimulatedBuilder, store: *KeyValueStore) !bool {
        if (!self.woken) return false;
        if (try population.advanceAny(store)) return true;
        self.woken = false;
        return false;
    }
};

/// A process's forwarded writes: a replica's, or the standby's.
const Forwarding = struct {
    /// The process's database: the forwarding node's hellos tell its id.
    store: *KeyValueStore,
    wakeup: Wakeup,
    node: ForwardingNode,
    /// The numbers of the writes handed over, the first `in_flight_count`,
    /// until they end.
    in_flight: [max_in_flight]u64 = undefined,
    in_flight_count: usize = 0,

    /// Enough to keep several on their way; few, so faults hit each.
    const max_in_flight = 3;

    fn holds(self: *const Forwarding) bool {
        return self.in_flight_count > 0;
    }
};

/// What became of a forwarded write, by its number.
const ForwardedWrite = struct {
    /// The LSN its commit reached, once the master ran it.
    ran_at: ?u64 = null,
    /// 2 for a batch (`forwarded_write`, then `batched_write`).
    statements: usize = 1,
    told: enum { pending, answered, unknown, not_reached, not_sent } = .pending,
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
    /// Over `network`, if the swarm encrypts; its keys come from
    /// `encryption_prng`, so a seed replays.
    encrypted_network: EncryptedNetwork,
    encryption_prng: std.Random.DefaultPrng,
    master: Master,
    replicas: [max_replicas]Replica,
    /// On the master's machine, apart from its node.
    standby: Forwarding,
    /// Each forwarded write's, from 1.
    last_number: u64 = 0,
    forwarded_writes: std.AutoHashMapUnmanaged(u64, ForwardedWrite) = .empty,
    /// The master's database at each LSN it committed.
    digests: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// The partition lasts until then.
    partition_until: Instant = 0,
    statistics: Statistics = .{},
    /// The seed works on a vector index, its choices drawn from
    /// `vector_prng` (and a few from `prng`, in the commits).
    vector: bool,
    vector_prng: std.Random.DefaultPrng,
    population_budget: KeyValueStore.PopulationBudget,

    fn init(self: *Simulation, allocator: Allocator, io: Io, path: []const u8, options: Options, out: *Io.Writer) !void {
        var prng = std.Random.DefaultPrng.init(options.seed);
        const swarm = Swarm.choose(prng.random());
        // Drawn apart, so the other seeds stay as they were (the constant
        // leaves those build.zig runs first, which found the simulator's
        // mutations, with no vector index).
        var vector_prng = std.Random.DefaultPrng.init(options.seed ^ 0x743215ae97b1492e);
        const vector = vector_prng.random().boolean();
        // By count only: a run is determined by its seed.
        const budget = KeyValueStore.PopulationBudget{ .entities = vector_prng.random().intRangeAtMost(u64, 1, 6), .nanoseconds = std.math.maxInt(u64) };
        self.* = .{
            .allocator = allocator,
            .io = io,
            .out = out,
            .options = options,
            .prng = prng,
            .swarm = swarm,
            .network = .{ .allocator = allocator, .capacity = swarm.capacity },
            .encrypted_network = undefined,
            .encryption_prng = .init(options.seed),
            .master = undefined,
            .replicas = undefined,
            .standby = undefined,
            .vector = vector,
            .vector_prng = vector_prng,
            .population_budget = budget,
        };
        self.encrypted_network = .init(self.network.network(), allocator, self.encryption_prng.random(), token);
        try self.openMaster(path);
        try self.openForwarding(&self.standby, &self.master.store, "standby");
        for (self.replicas[0..swarm.replicas], 0..) |*replica, i| {
            replica.path = try std.fmt.allocPrint(allocator, "{s}/replica-{d}", .{ path, i });
            try Io.Dir.cwd().createDirPath(io, replica.path);
            replica.open = false;
            try self.openReplica(replica);
        }
    }

    fn deinit(self: *Simulation) void {
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            self.closeReplica(replica);
            self.allocator.free(replica.path);
        }
        self.closeForwarding(&self.standby);
        self.forwarded_writes.deinit(self.allocator);
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
        master.builder = .{};
        if (self.vector) try master.builder.open(&master.store, self.population_budget);
        master.store.change_log_limit = self.swarm.change_log_limit;
        try master.store.startChangeLog();
        master.store.commit_listener = .{ .context = self, .committed = committed };
        master.graph = Graph.init(&master.store, self.allocator);
        master.wakeup = try self.net().wakeup();
        try self.digests.put(self.allocator, try self.lastLsn(), try digest(&master.store));
        try self.startMasterNode();
    }

    fn startMasterNode(self: *Simulation) !void {
        const master = &self.master;
        master.copier = .{ .allocator = self.allocator, .io = self.io, .store = try master.store.share(), .wakeup = master.wakeup, .copies_directory = master.copies_path };
        errdefer master.copier.deinit();
        master.runner = .{ .allocator = self.allocator, .store = try master.store.share(), .wakeup = master.wakeup };
        errdefer master.runner.deinit();
        master.node = try MasterNode.init(self.allocator, self.io, self.net(), &master.store, master.wakeup, master.copier.copier(), master.runner.runner(), .{
            .address = master_address,
            .token = self.tokenInHello(),
            .copies_directory = master.copies_path,
            .heartbeat_ns = heartbeat_ns,
            .timeout_ns = timeout_ns,
            .copy_timeout_ns = 10 * std.time.ns_per_s,
            .max_replicas = max_replicas + 1,
        });
    }

    /// The network the nodes run on.
    fn net(self: *Simulation) network.Network {
        return if (self.swarm.encrypted) self.encrypted_network.network() else self.network.network();
    }

    fn tokenInHello(self: *const Simulation) []const u8 {
        return if (self.swarm.encrypted) "" else token;
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
        replica.builder = .{};
        if (self.vector) try replica.builder.open(&replica.store, self.population_budget);
        replica.applied = .{};
        replica.frozen_until = 0;
        replica.checked_lsn = null;
        replica.wakeup = try self.net().wakeup();
        errdefer replica.wakeup.close();
        replica.applier = .{
            .allocator = self.allocator,
            .clock = self.clock.clock(),
            .applied = &replica.applied,
            .store = try replica.store.share(),
            .wakeup = replica.wakeup,
        };
        errdefer replica.applier.deinit();
        replica.node = try ReplicaNode.init(self.allocator, self.clock.clock(), self.net(), &replica.store, &replica.applied, replica.wakeup, replica.applier.applier(), .{
            .master_address = master_address,
            .token = self.tokenInHello(),
            .first_retry_ns = 10 * ms,
            .longest_retry_ns = 200 * ms,
            .answer_timeout_ns = timeout_ns,
            .max_unapplied_bytes = self.swarm.max_unapplied_bytes,
            .name = replica_names[self.indexOf(replica)],
        });
        errdefer replica.node.deinit();
        try self.openForwarding(&replica.forwarding, &replica.store, replica_names[self.indexOf(replica)]);
        replica.open = true;
    }

    fn openForwarding(self: *Simulation, process: *Forwarding, store: *KeyValueStore, name: []const u8) !void {
        const wakeup = try self.net().wakeup();
        errdefer wakeup.close();
        process.* = .{
            .store = store,
            .wakeup = wakeup,
            .node = try .init(self.allocator, self.net(), store, wakeup, .{
                .master_address = master_address,
                .token = self.tokenInHello(),
                .answer_timeout_ns = timeout_ns,
                .request_timeout_ns = self.swarm.request_timeout_ns,
                .name = name,
            }),
        };
    }

    /// A write in hand ends untold: the master may run it yet.
    fn closeForwarding(self: *Simulation, process: *Forwarding) void {
        process.node.deinit();
        process.wakeup.close();
        for (process.in_flight[0..process.in_flight_count]) |number| {
            self.forwarded_writes.getPtr(number).?.told = .unknown;
        }
        process.in_flight_count = 0;
    }

    fn indexOf(self: *const Simulation, replica: *const Replica) usize {
        return (@intFromPtr(replica) - @intFromPtr(&self.replicas[0])) / @sizeOf(Replica);
    }

    fn closeReplica(self: *Simulation, replica: *Replica) void {
        if (!replica.open) return;
        replica.open = false;
        self.closeForwarding(&replica.forwarding);
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
        if (self.vector and self.vector_prng.random().uintLessThan(u32, 4) == 0) {
            try self.vectorMove();
            _ = try self.stepNodes();
            return;
        }
        const chosen = self.chooseMove(faults);
        switch (chosen) {
            .commit => try self.commit(self.random().intRangeAtMost(usize, 1, 8), 0),
            .large_commit => {
                self.statistics.large_commits += 1;
                // Its change set several parts long, a write cut by their
                // ends.
                try self.commit(self.random().intRangeAtMost(usize, 200, 1000), self.random().intRangeAtMost(usize, 1 << 20, 3 << 20));
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
            .forward => {
                const which = self.random().uintLessThan(usize, self.swarm.replicas + 1);
                const process = if (which == self.swarm.replicas) &self.standby else &self.replicas[which].forwarding;
                if (process.in_flight_count < Forwarding.max_in_flight and process.node.room()) try self.forward(process);
            },
            .run_write => try self.runWrite(),
        }
        _ = try self.stepNodes();
    }

    /// The master creates or drops the vector index, or a process's
    /// builder, if awake, takes a batch.
    fn vectorMove(self: *Simulation) !void {
        const vector_random = self.vector_prng.random();
        switch (vector_random.uintLessThan(u32, 16)) {
            0, 1 => try self.runOnMaster(create_vector_index),
            2 => try self.runOnMaster(drop_vector_index),
            else => {
                const which = vector_random.uintLessThan(usize, self.swarm.replicas + 1);
                if (which == self.swarm.replicas) {
                    // Seldom: the copies it makes then hold an index
                    // populating more often. Not while a forwarded write
                    // holds the write lock.
                    if (vector_random.uintLessThan(u32, 4) != 0 or self.master.runner.store.active_write_transaction != null) return;
                    if (!try self.master.builder.step(&self.master.store)) return;
                    self.statistics.background_batches += 1;
                    self.note("the master populates a batch", .{});
                    if (vector_random.uintLessThan(u32, 8) == 0) try self.checkGraph(&self.master.store, "the master");
                    return;
                }
                const replica = &self.replicas[which];
                if (!replica.open or replica.frozen_until > self.clock.time) return;
                // Not while it applies a copy or a change set part by part.
                if (replica.applier.store.active_write_transaction != null) return;
                if (!try replica.builder.step(&replica.store)) return;
                self.statistics.background_batches += 1;
                self.note("replica {d} populates a batch", .{which});
                if (vector_random.uintLessThan(u32, 8) == 0) try self.checkIntegrity(replica);
            },
        }
    }

    /// Runs schema command `text` on the master.
    fn runOnMaster(self: *Simulation, text: []const u8) !void {
        var ast = zypherdb.Ast.init(self.allocator);
        defer ast.deinit();
        const root = try zypherdb.parser.parse(&ast, text, null);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var executor = zypherdb.Executor.init(&ast, &self.master.graph, arena.allocator());
        _ = try executor.run(root);
        const lsn = try self.lastLsn();
        try self.digests.put(self.allocator, lsn, try digest(&self.master.store));
        self.statistics.vector_index_changes += 1;
        self.note("the master runs {s}: LSN {d}", .{ text[0..19], lsn });
    }

    /// Populates every index left, on each process whose builder is awake;
    /// then none may be left populating, and every database is sound.
    fn finishPopulations(self: *Simulation) !void {
        while (try self.master.builder.step(&self.master.store)) self.statistics.background_batches += 1;
        if (try population.anyWork(&self.master.store)) return self.fail("the master has background work left, its builder asleep", .{});
        try self.checkGraph(&self.master.store, "the master");
        for (self.replicas[0..self.swarm.replicas], 0..) |*replica, i| {
            while (try replica.builder.step(&replica.store)) self.statistics.background_batches += 1;
            if (try population.anyWork(&replica.store)) return self.fail("replica {d} has background work left, its builder asleep", .{i});
            try self.checkIntegrity(replica);
        }
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

    /// A write transaction of `operations` writes on the master, and a node
    /// with a string of `large_value_bytes` if not 0, kept or (now and then)
    /// aborted.
    fn commit(self: *Simulation, operations: usize, large_value_bytes: usize) !void {
        const master = &self.master;
        const graph = &master.graph;
        try graph.beginWrite();
        var created: std.ArrayList(u64) = .empty;
        defer created.deinit(self.allocator);
        var deleted: std.ArrayList(u64) = .empty;
        defer deleted.deinit(self.allocator);
        for (0..operations) |_| {
            const alive = master.nodes.items.len + created.items.len;
            const choice = if (alive == 0) 0 else self.random().uintLessThan(u32, if (self.vector) 5 else 4);
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
                4 => {
                    const id = self.pickNode(created.items, deleted.items) orelse continue;
                    const vector = [_]zypherdb.Value{ .{ .float = self.random().float(f64) * 10 - 5 }, .{ .float = self.random().float(f64) * 10 - 5 } };
                    try graph.setProperty(id, "v", .{ .list = &vector });
                },
                else => unreachable,
            }
        }
        if (large_value_bytes > 0) {
            const text = try self.allocator.alloc(u8, large_value_bytes);
            defer self.allocator.free(text);
            @memset(text, 'a' + self.random().uintLessThan(u8, 26));
            const id = try graph.allocateNodeId();
            try graph.addNode(id, "Person");
            try graph.setProperty(id, "bio", .{ .string = text });
            try created.append(self.allocator, id);
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

    /// Hands a write over to `process`, which has room for one.
    fn forward(self: *Simulation, process: *Forwarding) !void {
        self.last_number += 1;
        const number = self.last_number;
        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.allocator);
        const parameters: []const MapEntry = &.{.{ .key = "number", .value = .{ .int = @intCast(number) } }};
        const statements: usize = if (self.random().uintLessThan(u8, 4) == 0) 2 else 1;
        const requests = [_]forwarding.Request{
            .{ .text = forwarded_write, .parameters = parameters },
            .{ .text = batched_write, .parameters = parameters },
        };
        try forwarding.encodeRequests(&request, self.allocator, requests[0..statements]);
        try self.forwarded_writes.put(self.allocator, number, .{ .statements = statements });
        process.in_flight[process.in_flight_count] = number;
        process.in_flight_count += 1;
        process.node.request(number, request.items, self.clock.time);
        process.wakeup.raise();
        self.statistics.forwards += 1;
        self.note("write {d} is forwarded", .{number});
    }

    /// The master runs the oldest write forwarded to it, if any.
    fn runWrite(self: *Simulation) !void {
        const runner = &self.master.runner;
        if (runner.waiting() == 0) return;
        try runner.runNext();
        const answer = runner.ran.items[runner.ran.items.len - 1].answer orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const done = switch (try forwarding.decodeAnswer(answer, arena.allocator())) {
            .done => |done| done,
            .failed => |failure| return self.fail("a forwarded write failed on the master: {s}", .{failure.message}),
        };
        const number: u64 = @intCast(done.results[0].rows[0][0].int);
        const write = self.forwarded_writes.getPtr(number) orelse return self.fail("the master ran write {d}, never forwarded", .{number});
        if (done.results.len != write.statements) return self.fail("write {d} of {d} statements answered {d} results", .{ number, write.statements, done.results.len });
        if (write.ran_at != null) return self.fail("the master ran write {d} twice", .{number});
        if (write.told == .not_reached or write.told == .not_sent) return self.fail("the master ran write {d}, told {t}", .{ number, write.told });
        if (done.lsn != try self.lastLsn()) return self.fail("write {d} answered LSN {d}, not the master's last", .{ number, done.lsn });
        write.ran_at = done.lsn;
        try self.digests.put(self.allocator, done.lsn, try digest(&self.master.store));
        self.statistics.forwarded_writes_run += 1;
        self.note("the master runs write {d}: LSN {d}", .{ number, done.lsn });
    }

    /// A write `process` held ended as `finished` tells.
    fn finish(self: *Simulation, process: *Forwarding, finished: forwarder.Finished) !void {
        defer process.node.free(finished.outcome);
        const held = process.in_flight[0..process.in_flight_count];
        const index = std.mem.indexOfScalar(u64, held, finished.id) orelse return self.fail("write {d} ended, not in hand", .{finished.id});
        std.mem.copyForwards(u64, held[index .. held.len - 1], held[index + 1 ..]);
        process.in_flight_count -= 1;
        const number = finished.id;
        const write = self.forwarded_writes.getPtr(number).?;
        switch (finished.outcome) {
            .answer => |answer| {
                var arena: std.heap.ArenaAllocator = .init(self.allocator);
                defer arena.deinit();
                const done = switch (try forwarding.decodeAnswer(answer, arena.allocator())) {
                    .done => |done| done,
                    .failed => |failure| return self.fail("write {d} failed: {s}", .{ number, failure.message }),
                };
                if (done.results.len != write.statements) return self.fail("write {d} answered {d} results", .{ number, done.results.len });
                for (done.results) |result| {
                    if (result.rows.len != 1 or result.rows[0][0].int != number) return self.fail("write {d} answered another's rows", .{number});
                }
                if (write.ran_at != done.lsn) return self.fail("write {d} answered LSN {d}, ran at {?d}", .{ number, done.lsn, write.ran_at });
                write.told = .answered;
                self.statistics.forwards_answered += 1;
            },
            .unknown => {
                write.told = .unknown;
                self.statistics.forwards_unknown += 1;
            },
            .master_unreachable => {
                if (write.ran_at != null) return self.fail("write {d} ran, told unreachable", .{number});
                write.told = .not_reached;
                self.statistics.forwards_unreachable += 1;
            },
            .refused => |reason| return self.fail("write {d} refused: {t}", .{ number, reason }),
            .failed => |err| {
                if (err != error.NoCopy or try process.store.databaseId() != null) return self.fail("write {d} failed: {t}", .{ number, err });
                write.told = .not_sent;
                self.statistics.forwards_without_copy += 1;
            },
        }
        self.note("write {d} ends {t}", .{ number, write.told });
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
        var earliest: ?Instant = earlier(self.master.node.deadline(), self.standby.node.deadline());
        const now = self.clock.time;
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            earliest = earlier(earliest, if (replica.frozen_until > now) replica.frozen_until else earlier(replica.node.deadline(), replica.forwarding.node.deadline()));
        }
        if (self.partition_until > now) earliest = if (earliest) |known| @min(known, self.partition_until) else self.partition_until;
        return earliest;
    }

    fn earlier(one: ?Instant, other: ?Instant) ?Instant {
        const at = one orelse return other;
        return if (other) |known| @min(at, known) else at;
    }

    /// `replica` applies the oldest work it was given, then is checked
    /// against the master at the LSN it reached.
    fn apply(self: *Simulation, replica: *Replica) !void {
        if (replica.frozen_until > self.clock.time) return;
        if (replica.applier.waiting() == 0) return;
        switch (replica.applier.work.items[0]) {
            .change_set_part => self.statistics.change_sets_applied += 1,
            .copy_part => |part| if (part.final) {
                self.statistics.copies_loaded += 1;
                if (self.vector) return self.applyCopyEnd(replica);
            },
        }
        replica.applier.applyNext();
        try self.check(replica);
    }

    /// The last part of a copy: if the copy holds background work (an
    /// index populating or being rebuilt), the load must wake the replica's
    /// builder.
    fn applyCopyEnd(self: *Simulation, replica: *Replica) !void {
        const woken = replica.builder.woken;
        replica.builder.woken = false;
        replica.applier.applyNext();
        const woken_by_load = replica.builder.woken;
        replica.builder.woken = woken or woken_by_load;
        if (replica.applier.store.loading == null and try population.anyWork(&replica.store)) {
            if (try population.anyPopulating(&replica.store)) self.statistics.copies_loaded_mid_population += 1;
            if (try population.anyRebuilding(&replica.store)) self.statistics.copies_loaded_mid_rebuild += 1;
            if (!woken_by_load) return self.fail("a replica loaded a copy with background work left, and its builder was not woken", .{});
            self.note("a replica loads a copy with background work left", .{});
        }
        try self.check(replica);
    }

    fn check(self: *Simulation, replica: *Replica) !void {
        // Told applied is committed: whoever waits for it reads it next.
        const told = replica.applied.value;
        const stored = try replica.store.appliedLsn() orelse 0;
        if (told > stored) return self.fail("a replica told LSN {d} applied with {d} committed", .{ told, stored });
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
        try self.checkGraph(&replica.store, "a replica");
    }

    fn checkGraph(self: *Simulation, store: *KeyValueStore, who: []const u8) !void {
        var graph = Graph.init(store, self.allocator);
        var report = try zypherdb.integrity.check(&graph, self.allocator);
        defer report.deinit();
        if (!report.ok()) return self.fail("{s}: {f}", .{ who, report });
    }

    /// Every node with something ready or past its deadline steps, as its
    /// thread would after `Network.wait`; returns whether any did. Frozen
    /// replicas do nothing.
    fn stepNodes(self: *Simulation) !bool {
        const now = self.clock.time;
        self.network.refusing = now < self.partition_until;
        const net_now = self.net();
        // Bytes of a record not yet whole move during a wait, with no node
        // ready: that is progress too, and time must not pass for it.
        const moved_before = self.network.bytes_moved;
        var stepped = false;
        {
            var buffer: [network.max_watched]Watched = undefined;
            const node = &self.master.node;
            const watched = node.watch(&buffer);
            try net_now.wait(watched, null);
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
            try net_now.wait(watched, null);
            node.ready(watched);
            if (anyReady(watched) or due(node.deadline(), now)) {
                node.step(now);
                stepped = true;
            }
            if (node.halted()) |reason| return self.fail("a replica halted: {t}", .{reason});
            if (try self.stepForwarding(&replica.forwarding, now)) stepped = true;
        }
        if (try self.stepForwarding(&self.standby, now)) stepped = true;
        return stepped or self.network.bytes_moved != moved_before;
    }

    fn stepForwarding(self: *Simulation, process: *Forwarding, now: Instant) !bool {
        var buffer: [2]Watched = undefined;
        const node = &process.node;
        const watched = node.watch(&buffer);
        try self.net().wait(watched, null);
        node.ready(watched);
        if (!anyReady(watched) and !due(node.deadline(), now)) return false;
        node.step(now);
        while (node.take()) |finished| try self.finish(process, finished);
        return true;
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
        try self.forwardFromEach(settle_by);
        while (!try self.upToDate()) {
            if (self.clock.time > settle_by) return self.fail("the replicas did not come up to date with the writes forwarded last", .{});
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
        if (self.vector) try self.finishPopulations();
        for (self.replicas[0..self.swarm.replicas]) |*replica| {
            if (try digest(&replica.store) != try digest(&self.master.store)) return self.fail("a replica up to date differs from the master", .{});
            try self.checkIntegrity(replica);
        }
        try self.checkIdentities();
    }

    /// Each write in hand ends; then every process forwards one more,
    /// answered by `settle_by`.
    fn forwardFromEach(self: *Simulation, settle_by: Instant) !void {
        while (self.anyForwarding()) {
            if (self.clock.time > settle_by) return self.fail("the writes forwarded before the faults stopped did not end", .{});
            try self.drain();
        }
        try self.forward(&self.standby);
        for (self.replicas[0..self.swarm.replicas]) |*replica| try self.forward(&replica.forwarding);
        for (0..self.swarm.replicas + 1) |i| {
            const number = self.last_number - i;
            while (self.forwarded_writes.get(number).?.told == .pending) {
                if (self.clock.time > settle_by) return self.fail("write {d}, forwarded with no faults, did not end", .{number});
                try self.drain();
            }
            const told = self.forwarded_writes.get(number).?.told;
            if (told != .answered) return self.fail("write {d}, forwarded with no faults, ended {t}", .{ number, told });
        }
    }

    /// Whether a process holds a write that did not end.
    fn anyForwarding(self: *Simulation) bool {
        for (self.replicas[0..self.swarm.replicas]) |*replica| if (replica.forwarding.holds()) return true;
        return self.standby.holds();
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
            while (self.master.runner.waiting() > 0) {
                try self.runWrite();
                applied = true;
            }
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
