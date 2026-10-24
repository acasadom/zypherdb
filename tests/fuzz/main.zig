//! The fuzzers' command line:
//!
//!     zig build fuzz -- storage [--seed N] [--steps N] [--seeds N] [--dir PATH] [--verbose]
//!
//! Without `--seed` the first seed is random. `--seeds N` runs N seeds in a
//! row from it (a long run). Each seed's database lives in `PATH/seed-N`
//! (by default under .zig-cache/fuzz), removed when the seed passes. Build
//! with `-Dstorage-engine=mdbx` to fuzz libmdbx, and with
//! `-Doptimize=ReleaseSafe` for long runs.

const std = @import("std");
const storage = @import("storage.zig");

const usage = "usage: zig build fuzz -- storage [--seed N] [--steps N] [--seeds N] [--dir PATH] [--verbose]\n";

const Arguments = struct {
    seed: ?u64 = null,
    steps: u32 = 1000,
    seeds: u64 = 1,
    dir: []const u8 = ".zig-cache/fuzz",
    verbose: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const arguments = parseArguments(try init.minimal.args.toSlice(arena)) catch {
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
    var totals = storage.Statistics{};
    for (0..arguments.seeds) |i| {
        const seed = first_seed +% i;
        const path = try std.fmt.allocPrint(arena, "{s}/seed-{d}", .{ arguments.dir, seed });
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, path);
        const statistics = storage.run(allocator, path, .{ .seed = seed, .steps = arguments.steps, .verbose = arguments.verbose }, out) catch |err| {
            try out.print("database kept in {s}\n", .{path});
            try out.flush();
            if (err == error.FuzzFailed) std.process.exit(1);
            return err;
        };
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
        totals.add(statistics);
        try out.print("seed {d}: {d} steps ok\n", .{ seed, arguments.steps });
        try out.flush();
    }
    try out.print("operations over {d} seed(s):\n{f}", .{ arguments.seeds, totals });
    try out.flush();
}

fn parseArguments(args: []const [:0]const u8) !Arguments {
    var arguments = Arguments{};
    if (args.len < 2 or !std.mem.eql(u8, args[1], "storage")) return error.Usage;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose")) {
            arguments.verbose = true;
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
