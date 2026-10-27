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
const zypherdb = @import("zypherdb");
const workload = @import("fault_workload.zig");
const generator = @import("query_generator.zig");
const Outcome = @import("query_results.zig").Outcome;
const Database = @import("database.zig");

const Operation = zypherdb.faults.Operation;
const plan = &zypherdb.faults.faults;

comptime {
    if (!zypherdb.fault_injection) @compileError("the fault fuzzer needs the zypherdb module built with fault_injection (see build.zig)");
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
        try out.print("\nfault fuzzer FAILED: memory leaked in seed {d} ({s})\n", .{ options.seed, zypherdb.storage_engine });
        return error.FuzzFailed;
    }
    return statistics;
}

const Fuzzer = struct {
    allocator: Allocator,
    options: Options,
    out: *std.Io.Writer,
    prng: std.Random.DefaultPrng,
    swarm: Swarm,
    failing: Database,
    twin: Database,
    parameters: zypherdb.Executor.Parameters = .empty,
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
        try self.twin.open(allocator, twin_path, Database.fuzz_options);
        errdefer self.twin.close(allocator);
        // The query generator's parameters.
        const values = [_]zypherdb.Value{ .{ .int = 1 }, .{ .string = "red" }, .{ .float = 2.0 } };
        for (generator.parameter_names, values) |name, value| try self.parameters.put(allocator, name, value);
    }

    /// Opens the failing database, first failing at each point of opening.
    fn openFailing(self: *Fuzzer, path: []const u8) !void {
        var point: u64 = 0;
        while (true) : (point += 1) {
            plan.arm(point, self.swarm.persistent, self.swarm.breaks_writer);
            const opened = self.failing.open(self.allocator, path, Database.fuzz_options);
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
        for (try workload.initialIndexes(self.texts.allocator())) |step| {
            try self.runStep(step, false);
            _ = self.scratch.reset(.retain_capacity);
        }
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
            self.statistics.faults[@backingInt(operation.?)] += 1;
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

    fn printDifference(self: *Fuzzer) !void {
        try Database.printDifference(&self.failing, &self.twin, self.scratch.allocator(), self.out);
    }

    fn isStorageError(err: anyerror) bool {
        return switch (err) {
            error.ReadFailed, error.WriteFailed, error.DeleteFailed, error.IteratorFailed => true,
            else => false,
        };
    }

    fn fail(self: *Fuzzer, comptime fmt: []const u8, args: anytype) error{ FuzzFailed, WriteFailed } {
        const out = self.out;
        try out.print("\nfault fuzzer FAILED at statement {d} of seed {d} ({s}): ", .{ self.step_number, self.options.seed, zypherdb.storage_engine });
        try out.print(fmt, args);
        try out.print("swarm: {f}\n", .{self.swarm});
        try out.print("reproduce: zig build fuzz -Dstorage-engine={s} -- faults --seed {d} --steps {d} --verbose\n", .{ zypherdb.storage_engine, self.options.seed, self.step_number + 1 });
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
