//! The fault fuzzer: runs a random workload (fault_workload.zig) on a
//! database whose storage engine fails on purpose
//! (src/storage/engine/faulty.zig), and on a twin that never fails.
//!
//! Each statement runs on the twin once, then on the failing database again
//! and again, with the engine failing at its first operation, then at a
//! later one, until a run reaches no fault point. After each failure:
//! - no transaction is left open;
//! - the statement failed with a storage error (or the error it fails with
//!   on the twin), or it absorbed the failure with the twin's outcome;
//! - a failed statement left the database exactly as before it;
//! - the integrity checker finds nothing.
//! The run that reaches no fault point must match the twin (outcome and
//! the whole database): failures leave nothing behind, not even in
//! prepared statements. At the end, no memory leaked.
//!
//! A seed picks (swarm testing): transient failures (one operation fails)
//! or persistent ones (every operation from that one on, a dead disk);
//! whether a failure breaks the write transaction, as in a real engine, or
//! leaves it usable (then a write error ignored above shows as a database
//! unlike the twin's); how many fault points are skipped between runs, how
//! many statements are prepared, and the workload's mix.
//!
//! A statement may absorb a failure: the planner reads its counts as
//! "unknown" when storage cannot give them (planning/statistics.zig), and
//! plans without them. The twin's outcome shows the rows are the same.

const std = @import("std");
const Allocator = std.mem.Allocator;
const acmedb = @import("acmedb");
const workload = @import("fault_workload.zig");
const generator = @import("query_generator.zig");
const Outcome = @import("query_results.zig").Outcome;

const Graph = acmedb.Graph;
const KeyValueStore = acmedb.KeyValueStore;
const Statement = acmedb.Statement;
const Operation = acmedb.faults.Operation;
const plan = &acmedb.faults.faults;

comptime {
    if (!acmedb.fault_injection) @compileError("the fault fuzzer needs the acmedb module built with fault_injection (see build.zig)");
}

pub const Options = struct {
    seed: u64,
    /// How many statements the seed's workload has.
    steps: u32 = 40,
    /// Prints every statement as it runs.
    verbose: bool = false,
};

pub const Statistics = struct {
    steps: u64 = 0,
    /// Runs that reached a fault point, by the operation that failed.
    faults: [operation_count]u64 = @splat(0),
    /// Of those, the runs whose statement failed, and those that absorbed
    /// the failure (same outcome as the twin).
    failed: u64 = 0,
    absorbed: u64 = 0,

    const operation_count = @typeInfo(Operation).@"enum".field_names.len;

    pub fn add(self: *Statistics, other: Statistics) void {
        self.steps += other.steps;
        for (&self.faults, other.faults) |*mine, theirs| mine.* += theirs;
        self.failed += other.failed;
        self.absorbed += other.absorbed;
    }

    pub fn format(self: Statistics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("  {d} statements, {d} runs failed by a fault, {d} absorbed it\n", .{ self.steps, self.failed, self.absorbed });
        try writer.writeAll("  faults by operation:");
        inline for (@typeInfo(Operation).@"enum".field_names, 0..) |name, i| {
            if (self.faults[i] > 0) try writer.print(" {s} {d}", .{ name, self.faults[i] });
        }
        try writer.writeAll("\n");
    }
};

/// What a seed does (swarm testing).
const Swarm = struct {
    persistent: bool,
    breaks_writer: bool,
    /// Fault points advance by 1 up to this many between runs.
    stride: u8,
    /// Out of 8: a statement runs prepared (kept and run again later).
    prepared: u8,
    mix: workload.Mix,

    fn choose(random: std.Random) Swarm {
        return .{
            .persistent = random.uintLessThan(u8, 3) == 0,
            .breaks_writer = random.uintLessThan(u8, 4) != 0,
            .stride = if (random.boolean()) 1 else random.intRangeAtMost(u8, 2, 4),
            .prepared = random.uintAtMost(u8, 8),
            .mix = workload.Mix.choose(random),
        };
    }

    pub fn format(self: Swarm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s} faults{s}, stride {d}, prepared {d}/8, {f}", .{ if (self.persistent) "persistent" else "transient", if (self.breaks_writer) "" else " (writer kept)", self.stride, self.prepared, self.mix });
    }
};

/// Runs one seed on databases at `path` (failing) and `twin_path` (both
/// directories must exist and be empty).
pub fn run(backing_allocator: Allocator, path: []const u8, twin_path: []const u8, options: Options, out: *std.Io.Writer) !Statistics {
    var debug_allocator = std.heap.DebugAllocator(.{}){ .backing_allocator = backing_allocator };
    const allocator = debug_allocator.allocator();
    var statistics = Statistics{};
    {
        var fuzzer: Fuzzer = undefined;
        try fuzzer.init(allocator, path, twin_path, options, out);
        defer fuzzer.deinit();
        try fuzzer.runSteps();
        statistics = fuzzer.statistics;
    }
    plan.* = .{};
    if (debug_allocator.deinit() == .leak) {
        try out.print("\nfault fuzzer FAILED: memory leaked in seed {d} ({s})\n", .{ options.seed, acmedb.storage_engine });
        return error.FuzzFailed;
    }
    return statistics;
}

/// An entry the engine keeps in the main table for one of its other tables
/// (LMDB names them with a trailing 0x00, libmdbx without): its value
/// describes the table's pages, which may differ between equal databases.
fn isTableCatalogEntry(key: []const u8) bool {
    const name = if (std.mem.endsWith(u8, key, "\x00")) key[0 .. key.len - 1] else key;
    return std.mem.eql(u8, name, "#nodes") or std.mem.eql(u8, name, "#relationships");
}

/// A stored key and value, copied.
const Pair = struct { key: []const u8, value: []const u8 };

/// A database and the statements prepared on it.
const Database = struct {
    store: KeyValueStore,
    graph: Graph,
    /// Prepared statements by text (the texts live in `Fuzzer.texts`).
    statements: std.StringHashMapUnmanaged(*Statement) = .empty,

    const store_options = KeyValueStore.Options{ .durability = .deferred };

    fn open(self: *Database, allocator: Allocator, path: []const u8) !void {
        self.* = .{ .store = try KeyValueStore.openWithOptions(allocator, path, store_options), .graph = undefined };
        self.graph = Graph.init(&self.store, allocator);
    }

    fn close(self: *Database, allocator: Allocator) void {
        var statements = self.statements.valueIterator();
        while (statements.next()) |statement| statement.*.destroy();
        self.statements.deinit(allocator);
        self.store.deinit();
    }

    /// Runs `step`'s statement (prepared, or kept from an earlier run, if
    /// `prepared`); rows and the run's memory go to `arena`.
    fn run(self: *Database, allocator: Allocator, arena: Allocator, step: workload.Step, prepared: bool, parameters: acmedb.Executor.Parameters) Allocator.Error!Outcome {
        const rows = if (prepared) rows: {
            const statement = self.statements.get(step.text) orelse made: {
                const statement = Statement.prepare(allocator, step.text, .{ .graph = &self.graph }) catch |err| return failure(err);
                errdefer statement.destroy();
                try self.statements.put(allocator, step.text, statement);
                break :made statement;
            };
            var executor = statement.executorFor(&self.graph, arena);
            executor.parameters = parameters;
            break :rows statement.run(&executor) catch |err| return failure(err);
        } else rows: {
            const ast = try arena.create(acmedb.Ast);
            ast.* = acmedb.Ast.init(arena);
            const root = acmedb.parser.parse(ast, step.text, null) catch |err| return failure(err);
            var executor = acmedb.Executor.init(ast, &self.graph, arena);
            executor.parameters = parameters;
            break :rows executor.run(root) catch |err| return failure(err);
        };
        return Outcome.fromRows(arena, rows, step.ordered);
    }

    fn failure(err: anyerror) Allocator.Error!Outcome {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = err };
    }

    /// A hash of every record and key of the database, read in its own
    /// transaction, without the engine's catalog of its tables.
    fn digest(self: *Database) !u64 {
        var hasher = std.hash.Wyhash.init(0);
        inline for (.{ KeyValueStore.scanAll, KeyValueStore.scanNodes, KeyValueStore.scanRelationships }) |scan| {
            var iterator = try scan(&self.store);
            defer iterator.deinit();
            while (try iterator.next()) |entry| {
                if (isTableCatalogEntry(entry.key)) continue;
                hasher.update(std.mem.asBytes(&entry.key.len));
                hasher.update(entry.key);
                hasher.update(std.mem.asBytes(&entry.value.len));
                hasher.update(entry.value);
            }
            hasher.update("|");
        }
        return hasher.final();
    }

    /// Every entry of the three tables, in order, copied into `arena`
    /// (the table's number first in each key).
    fn entries(self: *Database, arena: Allocator) !std.ArrayList(Pair) {
        var list = std.ArrayList(Pair).empty;
        inline for (.{ KeyValueStore.scanAll, KeyValueStore.scanNodes, KeyValueStore.scanRelationships }, 0..) |scan, table| {
            var iterator = try scan(&self.store);
            defer iterator.deinit();
            while (try iterator.next()) |entry| {
                if (isTableCatalogEntry(entry.key)) continue;
                const key = try std.mem.concat(arena, u8, &.{ &.{@as(u8, table)}, entry.key });
                try list.append(arena, .{ .key = key, .value = try arena.dupe(u8, entry.value) });
            }
        }
        return list;
    }

    fn checkIntegrity(self: *Database, allocator: Allocator, out: *std.Io.Writer) !bool {
        var report = try acmedb.integrity.check(&self.graph, allocator);
        defer report.deinit();
        if (report.ok()) return true;
        try out.print("{f}", .{report});
        return false;
    }
};

const Fuzzer = struct {
    allocator: Allocator,
    options: Options,
    out: *std.Io.Writer,
    prng: std.Random.DefaultPrng,
    swarm: Swarm,
    failing: Database,
    twin: Database,
    parameters: acmedb.Executor.Parameters = .empty,
    /// The workload's texts, for the whole run.
    texts: std.heap.ArenaAllocator,
    /// Memory for one statement's runs.
    scratch: std.heap.ArenaAllocator,
    statistics: Statistics = .{},
    step_number: u32 = 0,

    fn init(self: *Fuzzer, allocator: Allocator, path: []const u8, twin_path: []const u8, options: Options, out: *std.Io.Writer) !void {
        self.* = .{
            .allocator = allocator,
            .options = options,
            .out = out,
            .prng = .init(options.seed),
            .swarm = undefined,
            .failing = undefined,
            .twin = undefined,
            .texts = .init(allocator),
            .scratch = .init(allocator),
        };
        errdefer self.texts.deinit();
        errdefer self.scratch.deinit();
        self.swarm = Swarm.choose(self.prng.random());
        if (options.verbose) try out.print("seed {d}, swarm: {f}\n", .{ options.seed, self.swarm });
        try self.openFailing(path);
        errdefer self.failing.close(allocator);
        try self.twin.open(allocator, twin_path);
        errdefer self.twin.close(allocator);
        // The query generator's parameters.
        const values = [_]acmedb.Value{ .{ .int = 1 }, .{ .string = "red" }, .{ .float = 2.0 } };
        for (generator.parameter_names, values) |name, value| try self.parameters.put(allocator, name, value);
    }

    /// Opens the failing database, first failing at each point of opening.
    fn openFailing(self: *Fuzzer, path: []const u8) !void {
        var point: u64 = 0;
        while (true) : (point += 1) {
            plan.arm(point, self.swarm.persistent, self.swarm.breaks_writer);
            const opened = self.failing.open(self.allocator, path);
            const fired = plan.injected > 0;
            plan.disarm();
            if (opened) |_| {
                if (!fired) return;
                self.failing.close(self.allocator);
            } else |err| if (!fired) return err;
        }
    }

    fn deinit(self: *Fuzzer) void {
        plan.disarm();
        self.parameters.deinit(self.allocator);
        self.failing.close(self.allocator);
        self.twin.close(self.allocator);
        self.texts.deinit();
        self.scratch.deinit();
    }

    fn runSteps(self: *Fuzzer) !void {
        while (self.step_number < self.options.steps) : (self.step_number += 1) {
            const random = self.prng.random();
            const step = try workload.generate(random, self.swarm.mix, self.texts.allocator());
            const prepared = random.uintLessThan(u8, 8) < self.swarm.prepared;
            try self.runStep(step, prepared);
            _ = self.scratch.reset(.retain_capacity);
        }
        if (!try self.failing.checkIntegrity(self.allocator, self.out)) return self.fail("integrity check at the end", .{});
    }

    fn runStep(self: *Fuzzer, step: workload.Step, prepared: bool) !void {
        const arena = self.scratch.allocator();
        if (self.options.verbose) try self.out.print("{d}{s}: {s}\n", .{ self.step_number, if (prepared) " (prepared)" else "", step.text });
        const expected = try self.twin.run(self.allocator, arena, step, prepared, self.parameters);
        const expected_state = try self.twin.digest();
        const before = try self.failing.digest();
        self.statistics.steps += 1;

        var point: u64 = 0;
        while (true) {
            plan.arm(point, self.swarm.persistent, self.swarm.breaks_writer);
            const actual = try self.failing.run(self.allocator, arena, step, prepared, self.parameters);
            const fired = plan.injected > 0;
            const operation = plan.first_failed;
            plan.disarm();
            const context = Context{ .step = step, .prepared = prepared, .point = point, .operation = operation, .expected = expected, .actual = actual };

            if (self.failing.store.inTransaction()) return self.fail("a transaction was left open\n{f}", .{context});
            if (!fired) {
                if (!expected.eql(actual)) return self.fail("not the twin's outcome after the faults\n{f}", .{context});
                if (try self.failing.digest() != expected_state) {
                    try self.printDifference();
                    return self.fail("not the twin's database after the faults\n{f}", .{context});
                }
                return;
            }
            self.statistics.faults[@intFromEnum(operation.?)] += 1;
            switch (actual) {
                .failure => |err| {
                    if (!isStorageError(err) and !expected.eql(actual)) return self.fail("a fault reported as another error\n{f}", .{context});
                    if (try self.failing.digest() != before) return self.fail("a failed statement changed the database\n{f}", .{context});
                    self.statistics.failed += 1;
                },
                .rows => {
                    if (!expected.eql(actual)) return self.fail("a fault absorbed with another outcome\n{f}", .{context});
                    if (try self.failing.digest() != expected_state) {
                        try self.printDifference();
                        return self.fail("a fault absorbed with another database\n{f}", .{context});
                    }
                    self.statistics.absorbed += 1;
                    return;
                },
            }
            if (!try self.failing.checkIntegrity(self.allocator, self.out)) return self.fail("integrity check after a fault\n{f}", .{context});
            point += 1 + self.prng.random().uintLessThan(u8, self.swarm.stride);
        }
    }

    /// Prints the first entries that differ between the failing database
    /// and the twin (table number, then key and value bytes).
    fn printDifference(self: *Fuzzer) !void {
        const arena = self.scratch.allocator();
        const mine = (try self.failing.entries(arena)).items;
        const theirs = (try self.twin.entries(arena)).items;
        var i: usize = 0;
        var j: usize = 0;
        var printed: usize = 0;
        while ((i < mine.len or j < theirs.len) and printed < 10) {
            const order = if (i == mine.len) std.math.Order.gt else if (j == theirs.len) std.math.Order.lt else std.mem.order(u8, mine[i].key, theirs[j].key);
            switch (order) {
                .lt => {
                    try self.out.print("only here: {x} = {x}\n", .{ mine[i].key, mine[i].value });
                    i += 1;
                    printed += 1;
                },
                .gt => {
                    try self.out.print("only in the twin: {x} = {x}\n", .{ theirs[j].key, theirs[j].value });
                    j += 1;
                    printed += 1;
                },
                .eq => {
                    if (!std.mem.eql(u8, mine[i].value, theirs[j].value)) {
                        try self.out.print("differs: {x} = {x}, twin {x}\n", .{ mine[i].key, mine[i].value, theirs[j].value });
                        printed += 1;
                    }
                    i += 1;
                    j += 1;
                },
            }
        }
    }

    fn isStorageError(err: anyerror) bool {
        return switch (err) {
            error.ReadFailed, error.WriteFailed, error.DeleteFailed, error.IteratorFailed => true,
            else => false,
        };
    }

    fn fail(self: *Fuzzer, comptime fmt: []const u8, args: anytype) error{ FuzzFailed, WriteFailed } {
        const out = self.out;
        try out.print("\nfault fuzzer FAILED at statement {d} of seed {d} ({s}): ", .{ self.step_number, self.options.seed, acmedb.storage_engine });
        try out.print(fmt, args);
        try out.print("swarm: {f}\n", .{self.swarm});
        try out.print("reproduce: zig build fuzz -Dstorage-engine={s} -- faults --seed {d} --steps {d} --verbose\n", .{ acmedb.storage_engine, self.options.seed, self.step_number + 1 });
        try out.flush();
        return error.FuzzFailed;
    }
};

/// The run that failed, for the report.
const Context = struct {
    step: workload.Step,
    prepared: bool,
    point: u64,
    operation: ?Operation,
    expected: Outcome,
    actual: Outcome,

    pub fn format(self: Context, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("statement{s}: {s}\n", .{ if (self.prepared) " (prepared)" else "", self.step.text });
        if (self.operation) |operation| {
            try writer.print("failed at engine operation {d} of the run ({t})\n", .{ self.point, operation });
        } else try writer.writeAll("no fault reached\n");
        try writer.print("twin: {f}this run: {f}", .{ self.expected, self.actual });
    }
};
