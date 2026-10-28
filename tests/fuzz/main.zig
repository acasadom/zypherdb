//! The fuzzers' command line:
//!
//!     zig build fuzz -- storage|query|faults|crash [--seed N] [--steps N] [--seeds N] [--dir PATH] [--verbose] [--quiet]
//!
//! For the query fuzzer, `--steps` is the number of queries per seed; for
//! the fault and crash fuzzers, the number of statements. The crash fuzzer
//! starts this program as its writer (`crash-writer`, see crash.zig).
//! Without `--seed` the first seed is random. `--seeds N` runs N seeds in a
//! row from it (a long run). Each seed's database lives in `PATH/seed-N`
//! (by default under .zig-cache/fuzz), removed when the seed passes. Build
//! with `-Dstorage-engine=mdbx` to fuzz libmdbx, and with
//! `-Doptimize=ReleaseSafe` for long runs.

const std = @import("std");
const storage = @import("storage.zig");
const query = @import("query.zig");
const faults = @import("faults.zig");
const crash = @import("crash.zig");

const usage = "usage: zig build fuzz -- storage|query|faults|crash [--seed N] [--steps N] [--seeds N] [--dir PATH] [--verbose] [--quiet]\n";

const Fuzzer = enum { storage, query, faults, crash };

const Arguments = struct {
    fuzzer: Fuzzer = .storage,
    seed: ?u64 = null,
    steps: u32 = 1000,
    seeds: u64 = 1,
    dir: []const u8 = ".zig-cache/fuzz",
    verbose: bool = false,
    /// Prints only failures (for `zig build test`).
    quiet: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "crash-writer")) {
        return crash.writerMain(std.heap.smp_allocator, args[2..], out);
    }
    const arguments = parseArguments(args) catch {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    };
    const first_seed = arguments.seed orelse seed: {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        break :seed std.mem.readInt(u64, &bytes, .little);
    };

    const allocator = std.heap.smp_allocator;
    var totals = Totals{ .executable = try std.process.executablePathAlloc(io, arena) };
    for (0..arguments.seeds) |i| {
        const seed = first_seed +% i;
        const path = try std.fmt.allocPrint(arena, "{s}/seed-{d}", .{ arguments.dir, seed });
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, path);
        runSeed(io, allocator, path, seed, arguments, out, &totals) catch |err| {
            try out.print("database kept in {s}\n", .{path});
            try out.flush();
            if (err == error.FuzzFailed) std.process.exit(1);
            return err;
        };
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
        if (!arguments.quiet) try out.print("seed {d}: {d} steps ok\n", .{ seed, arguments.steps });
        try out.flush();
    }
    if (arguments.quiet) return;
    switch (arguments.fuzzer) {
        .storage => try out.print("operations over {d} seed(s):\n{f}", .{ arguments.seeds, totals.storage }),
        .query => try out.print("over {d} seed(s):\n{f}", .{ arguments.seeds, totals.query }),
        .faults => try out.print("over {d} seed(s):\n{f}", .{ arguments.seeds, totals.faults }),
        .crash => try out.print("over {d} seed(s):\n{f}", .{ arguments.seeds, totals.crash }),
    }
    try out.flush();
}

/// Each fuzzer's statistics over the seeds run.
const Totals = struct {
    /// This program (the crash fuzzer starts it as its writer).
    executable: []const u8,
    storage: storage.Statistics = .{},
    query: query.Statistics = .{},
    faults: faults.Statistics = .{},
    crash: crash.Statistics = .{},
};

fn runSeed(io: std.Io, allocator: std.mem.Allocator, path: []const u8, seed: u64, arguments: Arguments, out: *std.Io.Writer, totals: *Totals) !void {
    switch (arguments.fuzzer) {
        .storage => {
            const replica = try std.fmt.allocPrint(allocator, "{s}/replica", .{path});
            defer allocator.free(replica);
            try std.Io.Dir.cwd().createDirPath(io, replica);
            totals.storage.add(try storage.run(allocator, path, .{ .seed = seed, .steps = arguments.steps, .verbose = arguments.verbose, .replica = replica }, out));
        },
        .query => {
            var statistics = try query.run(allocator, path, .{ .seed = seed, .queries = arguments.steps, .verbose = arguments.verbose }, out);
            defer statistics.deinit(allocator);
            try totals.query.add(allocator, statistics);
        },
        .faults => {
            const paths = try databaseAndTwin(io, allocator, path, "failing");
            defer allocator.free(paths.database);
            defer allocator.free(paths.twin);
            totals.faults.add(try faults.run(allocator, paths.database, paths.twin, .{ .seed = seed, .steps = arguments.steps, .verbose = arguments.verbose }, out));
        },
        .crash => {
            const paths = try databaseAndTwin(io, allocator, path, "crashed");
            defer allocator.free(paths.database);
            defer allocator.free(paths.twin);
            totals.crash.add(try crash.run(allocator, io, totals.executable, paths.database, paths.twin, .{ .seed = seed, .steps = arguments.steps, .verbose = arguments.verbose }, out));
        },
    }
}

/// Makes the directories of a fuzzed database (`name`) and its twin, side
/// by side under `path`.
fn databaseAndTwin(io: std.Io, allocator: std.mem.Allocator, path: []const u8, name: []const u8) !struct { database: []u8, twin: []u8 } {
    const database = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
    errdefer allocator.free(database);
    const twin = try std.fmt.allocPrint(allocator, "{s}/twin", .{path});
    errdefer allocator.free(twin);
    try std.Io.Dir.cwd().createDirPath(io, database);
    try std.Io.Dir.cwd().createDirPath(io, twin);
    return .{ .database = database, .twin = twin };
}

fn parseArguments(args: []const [:0]const u8) !Arguments {
    var arguments = Arguments{};
    if (args.len < 2) return error.Usage;
    arguments.fuzzer = std.meta.stringToEnum(Fuzzer, args[1]) orelse return error.Usage;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose")) {
            arguments.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            arguments.quiet = true;
            continue;
        }
        if (i + 1 >= args.len) return error.Usage;
        i += 1;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--seed")) {
            arguments.seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--steps")) {
            arguments.steps = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--seeds")) {
            arguments.seeds = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--dir")) {
            arguments.dir = value;
        } else return error.Usage;
    }
    return arguments;
}
