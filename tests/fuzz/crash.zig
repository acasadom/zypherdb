//! The crash fuzzer: a writer process killed with SIGKILL at random points
//! must leave a database that opens, passes the integrity checker, and holds
//! every transaction the writer reported committed.
//!
//! The writer is this executable run as `crash-writer`: it runs a seed's
//! write workload (fault_workload.zig) one statement per transaction and
//! prints the number of statements done after each one returns. The parent
//! runs the same workload on a twin first, keeping a digest of the twin
//! after each statement, and counting the engine's crash points (before
//! each storage operation, and after each commit: engine/faulty.zig). Then,
//! a few times per seed, it starts the writer from where the database is,
//! and the writer dies:
//! - at a crash point the parent chose: the writer kills itself there, so
//!   the crash is reproducible from the seed (most crashes). Half of them
//!   are near the end of a statement (its commit and what follows it),
//!   where atomicity breaks; the writer counts its points after opening
//!   the database, as the twin does, so the numbers match;
//! - or killed by the parent a random delay after a random report, which
//!   may land inside the engine (in a commit's writes or its sync), but
//!   depends on timing.
//! The parent reopens the database, checks it, and finds its digest among
//! the twin's: it must be the one after the last statement reported, or
//! after the next (whose commit may have reached the disk before the
//! kill). The last writer runs to the end, and the database must equal the
//! twin.
//!
//! A process crash keeps what the operating system already holds, so every
//! durability keeps every reported commit; a seed picks one. Power failures
//! are not tested (they need a simulated disk).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");
const workload = @import("fault_workload.zig");
const Database = @import("database.zig");

const Durability = zypherdb.KeyValueStore.Durability;

pub const Options = struct {
    seed: u64,
    /// How many statements the seed's workload has.
    steps: u32 = 60,
    verbose: bool = false,
};

pub const Statistics = struct {
    crashes: u64 = 0,
    /// Of them, killed by the parent (the others at a crash point).
    timed_kills: u64 = 0,
    /// Crashes after which the statement in flight had committed.
    in_flight_committed: u64 = 0,
    statements: u64 = 0,

    pub fn add(self: *Statistics, other: Statistics) void {
        self.crashes += other.crashes;
        self.timed_kills += other.timed_kills;
        self.in_flight_committed += other.in_flight_committed;
        self.statements += other.statements;
    }

    pub fn format(self: Statistics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("  {d} statements, {d} crashes ({d} timed kills), {d} with the statement in flight committed\n", .{ self.statements, self.crashes, self.timed_kills, self.in_flight_committed });
    }
};

/// What a seed does (swarm testing). Parent and writer derive it from the
/// seed alike.
const Swarm = struct {
    durability: Durability,
    /// Crashes before the last writer runs to the end.
    crashes: u8,
    /// Out of 4: a crash is a timed kill (else at a crash point).
    timed_kills: u8,
    /// The most microseconds between a report and a timed kill.
    max_delay: u32,
    mix: workload.Mix,

    fn choose(random: std.Random) Swarm {
        var mix = workload.Mix.choose(random);
        mix.writes = random.intRangeAtMost(u8, 10, 14);
        return .{
            .durability = random.enumValue(Durability),
            .crashes = random.intRangeAtMost(u8, 1, 8),
            .timed_kills = random.uintAtMost(u8, 2),
            .max_delay = if (random.boolean()) 200 else 5000,
            .mix = mix,
        };
    }

    pub fn format(self: Swarm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("durability {t}, {d} crashes, timed kills {d}/4 (up to {d} us), {f}", .{ self.durability, self.crashes, self.timed_kills, self.max_delay, self.mix });
    }
};

/// The seed's swarm and workload.
const Plan = struct {
    swarm: Swarm,
    steps: []const workload.Step,
    /// For the kill points.
    random: std.Random.DefaultPrng,

    fn make(seed: u64, count: u32, arena: Allocator) Allocator.Error!Plan {
        var prng = std.Random.DefaultPrng.init(seed);
        const swarm = Swarm.choose(prng.random());
        const steps = try arena.alloc(workload.Step, count);
        for (steps) |*step| step.* = try workload.generate(prng.random(), swarm.mix, arena);
        return .{ .swarm = swarm, .steps = steps, .random = .init(seed ^ 0x9e3779b97f4a7c15) };
    }
};

/// How the writer starting at statement `done` ends: within the first half
/// of what is left, so the crashes spread out.
fn chooseEndingFor(plan: *Plan, twin: Twin, done: u32) Ending {
    const random = plan.random.random();
    const left: u32 = @intCast(plan.steps.len - done);
    if (random.uintLessThan(u8, 4) < plan.swarm.timed_kills) {
        return .{ .timed = .{ .reports = random.uintLessThan(u32, @max(1, left / 2)), .delay = random.uintAtMost(u32, plan.swarm.max_delay) } };
    }
    const start = twin.crash_points[done];
    if (random.boolean()) {
        // Near the end of a statement: its last points, or the next one's first.
        const statement = done + random.uintLessThan(u32, @max(1, left / 2)) + 1;
        const end = twin.crash_points[statement] - start;
        return .{ .crash_point = (end + random.uintAtMost(u64, 2)) -| 3 };
    }
    return .{ .crash_point = random.uintLessThan(u64, @max(1, (twin.crash_points[plan.steps.len] - start) / 2)) };
}

fn storeOptions(durability: Durability) zypherdb.KeyValueStore.Options {
    return .{ .durability = durability };
}

/// Runs one seed: the database at `path` is crashed, the twin is at
/// `twin_path` (both directories must exist and be empty). `executable` is
/// this program, to start as the writer.
pub fn run(allocator: Allocator, io: std.Io, executable: []const u8, path: []const u8, twin_path: []const u8, options: Options, out: *std.Io.Writer) !Statistics {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plan = try Plan.make(options.seed, options.steps, arena);
    if (options.verbose) try out.print("seed {d}, swarm: {f}\n", .{ options.seed, plan.swarm });

    const twin = try runTwin(allocator, arena, twin_path, plan);
    var statistics = Statistics{ .statements = options.steps };
    var done: u32 = 0;
    var crash: u32 = 0;
    while (true) : (crash += 1) {
        const last = crash == plan.swarm.crashes or done == options.steps;
        const ending: Ending = if (last) .run_to_end else chooseEndingFor(&plan, twin, done);
        const writer = try runWriter(io, arena, executable, path, options, done, ending);
        if (options.verbose) try out.print("writer from {d}: {d} reported, {f}\n", .{ done, writer.reported, ending });

        var database: Database = undefined;
        database.open(allocator, path, storeOptions(plan.swarm.durability)) catch |err| {
            return fail(out, options, plan.swarm, "the database does not open after a crash: {t}\n", .{err});
        };
        defer database.close(allocator);
        if (!try database.checkIntegrity(allocator, out)) return fail(out, options, plan.swarm, "integrity check after a crash\n", .{});
        const digest = try database.digest();
        const committed = done + writer.reported;
        if (!writer.killed) {
            // It ran to the end (a crash point it never reached, or the last writer).
            if (committed != options.steps or digest != twin.digests[options.steps]) return fail(out, options, plan.swarm, "the writer ended without reaching the twin's database ({d} of {d} reported)\n", .{ committed, options.steps });
            if (last or done == options.steps) return statistics;
            done = committed;
            continue;
        }
        statistics.crashes += 1;
        if (ending == .timed) statistics.timed_kills += 1;
        if (digest == twin.digests[committed]) {
            done = committed;
        } else if (committed < options.steps and digest == twin.digests[committed + 1]) {
            done = committed + 1;
            statistics.in_flight_committed += 1;
        } else {
            for (twin.digests, 0..) |known, i| {
                if (known == digest) return fail(out, options, plan.swarm, "after a crash ({f}) the database is the twin's after statement {d}, but {d} were reported\n", .{ ending, i, committed });
            }
            return fail(out, options, plan.swarm, "after a crash ({f}) the database is none of the twin's ({d} statements reported)\n", .{ ending, committed });
        }
    }
}

/// The twin's digests and crash points: when opened, then after each
/// statement.
const Twin = struct { digests: []u64, crash_points: []u64 };

fn runTwin(allocator: Allocator, arena: Allocator, twin_path: []const u8, plan: Plan) !Twin {
    const counts = &zypherdb.faults.faults;
    counts.* = .{};
    var twin: Database = undefined;
    try twin.open(allocator, twin_path, storeOptions(plan.swarm.durability));
    defer twin.close(allocator);
    const result = Twin{ .digests = try arena.alloc(u64, plan.steps.len + 1), .crash_points = try arena.alloc(u64, plan.steps.len + 1) };
    result.crash_points[0] = counts.crash_points;
    result.digests[0] = try twin.digest();
    counts.crash_points = result.crash_points[0]; // the digest's reads are not the writer's
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (plan.steps, 1..) |step, i| {
        _ = try twin.run(allocator, scratch.allocator(), step, false, .empty);
        _ = scratch.reset(.retain_capacity);
        result.crash_points[i] = counts.crash_points;
        result.digests[i] = try twin.digest();
        counts.crash_points = result.crash_points[i];
    }
    return result;
}

/// How a writer ends.
const Ending = union(enum) {
    /// It kills itself at this crash point (counted after it opens the
    /// database).
    crash_point: u64,
    /// The parent kills it this many microseconds after this many reports.
    timed: struct { reports: u32, delay: u32 },
    run_to_end,

    pub fn format(self: Ending, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .crash_point => |point| try writer.print("crash point {d}", .{point}),
            .timed => |kill| try writer.print("killed {d} us after report {d}", .{ kill.delay, kill.reports }),
            .run_to_end => try writer.writeAll("run to the end"),
        }
    }
};

const Writer = struct { reported: u32, killed: bool };

/// Starts the writer from statement `from`, ends it as `ending` says, and
/// returns how many statements it reported done.
fn runWriter(io: std.Io, arena: Allocator, executable: []const u8, path: []const u8, options: Options, from: u32, ending: Ending) !Writer {
    const crash_at = switch (ending) {
        .crash_point => |point| try std.fmt.allocPrint(arena, "{d}", .{point}),
        else => "-",
    };
    const argv = [_][]const u8{
        executable,                                            "crash-writer",                                         path,
        try std.fmt.allocPrint(arena, "{d}", .{options.seed}), try std.fmt.allocPrint(arena, "{d}", .{options.steps}), try std.fmt.allocPrint(arena, "{d}", .{from}),
        crash_at,
    };
    var child = try std.process.spawn(io, .{ .argv = &argv, .stdout = .pipe });
    var buffer: [64]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    var reported: u32 = 0;
    var signalled = false;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (!std.mem.eql(u8, line, "open")) reported = try std.fmt.parseInt(u32, line, 10) - from;
        if (ending == .timed and !signalled and reported == ending.timed.reports) {
            if (ending.timed.delay > 0) try io.sleep(.fromMicroseconds(ending.timed.delay), .awake);
            std.posix.kill(child.id.?, .KILL) catch {};
            signalled = true;
        }
    }
    return switch (try child.wait(io)) {
        .exited => |code| if (code == 0) .{ .reported = reported, .killed = false } else error.WriterFailed,
        .signal => |signal| if (signal == .KILL and ending != .run_to_end) .{ .reported = reported, .killed = true } else error.WriterFailed,
        else => error.WriterFailed,
    };
}

/// The writer: `crash-writer PATH SEED STEPS FROM CRASH_AT`. Runs the
/// seed's statements from FROM on, printing the number done after each, and
/// kills itself at crash point CRASH_AT ("-": none).
pub fn writerMain(allocator: Allocator, arguments: []const [:0]const u8, out: *std.Io.Writer) !void {
    if (arguments.len != 5) return error.Usage;
    const path = arguments[0];
    const seed = try std.fmt.parseInt(u64, arguments[1], 10);
    const count = try std.fmt.parseInt(u32, arguments[2], 10);
    const from = try std.fmt.parseInt(u32, arguments[3], 10);
    const crash_at = if (std.mem.eql(u8, arguments[4], "-")) null else try std.fmt.parseInt(u64, arguments[4], 10);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const plan = try Plan.make(seed, count, arena_state.allocator());

    var database: Database = undefined;
    try database.open(allocator, path, storeOptions(plan.swarm.durability));
    defer database.close(allocator);
    // Counted from here, as the twin counts them.
    zypherdb.faults.faults.crash_points = 0;
    zypherdb.faults.faults.crash_at = crash_at;
    try out.writeAll("open\n");
    try out.flush();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (plan.steps[from..], from + 1..) |step, done| {
        _ = try database.run(allocator, scratch.allocator(), step, false, .empty);
        _ = scratch.reset(.retain_capacity);
        try out.print("{d}\n", .{done});
        try out.flush();
    }
}

fn fail(out: *std.Io.Writer, options: Options, swarm: Swarm, comptime fmt: []const u8, args: anytype) error{ FuzzFailed, WriteFailed } {
    try out.print("\ncrash fuzzer FAILED in seed {d} ({s}): ", .{ options.seed, zypherdb.storage_engine });
    try out.print(fmt, args);
    try out.print("swarm: {f}\n", .{swarm});
    try out.print("reproduce: zig build fuzz -Dstorage-engine={s} -- crash --seed {d} --steps {d} --verbose\n", .{ zypherdb.storage_engine, options.seed, options.steps });
    try out.flush();
    return error.FuzzFailed;
}
