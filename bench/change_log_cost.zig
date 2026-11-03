//! Benchmark: what the change log costs a write, engine only (no replication
//! server, no Python). Each mode writes `--writes` single-node CREATEs, each
//! in a transaction of its own, `deferred` durability, and prints the median
//! and p95 of one write:
//!
//!     plain      no change log
//!     log        change log started, never full
//!     log-full   change log started, full: each commit drops the oldest set
//!
//!     zig build bench-change-log -Doptimize=ReleaseFast -- [--writes N] [--rounds N] [--only MODE]

const std = @import("std");
const zypherdb = @import("zypherdb");
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;
const KeyValueStore = zypherdb.KeyValueStore;

const Mode = enum { plain, log, @"log-full" };

const Config = struct {
    writes: usize = 50_000,
    rounds: usize = 3,
    only: ?Mode = null,
    dir: []const u8 = "/tmp/zypherdb-change-log-bench",
};

const write_text = "CREATE (:Event {id: $id})";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const config = try parseArguments(try init.minimal.args.toSlice(init.arena.allocator()));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("ZypherDB change log benchmark ({s} build, deferred durability, {d} writes)\n", .{ @tagName(@import("builtin").mode), config.writes });
    try out.print("{s:<10} {s:>6} {s:>10} {s:>10}\n", .{ "mode", "round", "median", "p95" });
    try out.flush();

    // Rounds interleave the modes, so a slower machine slows all of them.
    for (0..config.rounds) |round| {
        for (std.enums.values(Mode)) |mode| {
            if (config.only) |only| if (only != mode) continue;
            const result = try measure(io, config, mode);
            try out.print("{s:<10} {d:>6} {d:>8.2}us {d:>8.2}us\n", .{ @tagName(mode), round, micros(result.median), micros(result.p95) });
            try out.flush();
        }
    }
}

const Result = struct { median: u64, p95: u64 };

fn measure(io: std.Io, config: Config, mode: Mode) !Result {
    std.Io.Dir.cwd().deleteTree(io, config.dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, config.dir);
    const allocator = std.heap.smp_allocator;
    var store = try KeyValueStore.openWithOptions(allocator, config.dir, .{ .durability = .deferred });
    defer store.deinit();
    switch (mode) {
        .plain => {},
        .log => try store.startChangeLog(),
        .@"log-full" => {
            try store.startChangeLog();
            store.change_log_limit = 64 << 10;
        },
    }
    var graph = Graph.init(&store, allocator);

    const durations = try allocator.alloc(u64, config.writes);
    defer allocator.free(durations);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const warm_up = 1000;
    for (0..config.writes + warm_up) |i| {
        defer _ = arena.reset(.{ .retain_with_limit = 1 << 20 });
        var ast = zypherdb.Ast.init(arena.allocator());
        var executor = zypherdb.Executor.init(&ast, &graph, arena.allocator());
        try executor.parameters.put(arena.allocator(), "id", Value{ .int = @intCast(i) });
        const start = now(io);
        _ = try executor.run(try zypherdb.parser.parse(&ast, write_text, null));
        const elapsed: u64 = @intCast(now(io) - start);
        if (i >= warm_up) durations[i - warm_up] = elapsed;
    }
    std.sort.pdq(u64, durations, {}, std.sort.asc(u64));
    return .{ .median = durations[durations.len / 2], .p95 = durations[durations.len * 95 / 100] };
}

fn parseArguments(args: []const [:0]const u8) !Config {
    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const name = args[i];
        i += 1;
        if (i == args.len) return error.MissingValue;
        if (std.mem.eql(u8, name, "--writes")) {
            config.writes = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, name, "--rounds")) {
            config.rounds = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, name, "--only")) {
            config.only = std.meta.stringToEnum(Mode, args[i]) orelse return error.UnknownMode;
        } else if (std.mem.eql(u8, name, "--dir")) {
            config.dir = args[i];
        } else return error.UnknownArgument;
    }
    return config;
}

fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn micros(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_us;
}
