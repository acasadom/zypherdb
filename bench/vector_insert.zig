//! Benchmark: what a vector index costs a write, engine only (no Python).
//! Each mode writes `--nodes` single-node CREATEs of a random vector of
//! `--dimensions` numbers, each in a transaction of its own, `deferred`
//! durability, with the change log started, and prints, for each fifth of
//! the writes, the median and p95 of one write and the change log bytes
//! it added:
//!
//!     plain      no vector index
//!     indexed    a cosine vector index on the property
//!     populate   the writes with no index, then CREATE VECTOR INDEX over
//!                them (one transaction), its time and the process's peak
//!                memory
//!
//!     zig build bench-vector-insert -Doptimize=ReleaseFast -- [--nodes N] [--dimensions N] [--only MODE]

const std = @import("std");
const zypherdb = @import("zypherdb");
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;
const KeyValueStore = zypherdb.KeyValueStore;

const Mode = enum { plain, indexed, populate };

const Config = struct {
    nodes: usize = 20_000,
    dimensions: usize = 128,
    only: ?Mode = null,
    dir: []const u8 = "/tmp/zypherdb-vector-insert-bench",
};

const write_text = "CREATE (:Doc {id: $id, embedding: $embedding})";
const parts = 5;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const config = try parseArguments(try init.minimal.args.toSlice(init.arena.allocator()));

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    try out.print("ZypherDB vector insert benchmark ({s} build, deferred durability, {d} writes of {d} dimensions)\n", .{ @tagName(@import("builtin").mode), config.nodes, config.dimensions });
    try out.print("{s:<8} {s:>14} {s:>10} {s:>10} {s:>12}\n", .{ "mode", "writes", "median", "p95", "log/write" });
    try out.flush();

    for (std.enums.values(Mode)) |mode| {
        if (config.only) |only| if (only != mode) continue;
        try measure(io, out, config, mode);
    }
}

fn measure(io: std.Io, out: *std.Io.Writer, config: Config, mode: Mode) !void {
    std.Io.Dir.cwd().deleteTree(io, config.dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, config.dir);
    const allocator = std.heap.smp_allocator;
    var store = try KeyValueStore.openWithOptions(allocator, config.dir, .{ .durability = .deferred });
    defer store.deinit();
    try store.startChangeLog();
    store.change_log_limit = std.math.maxInt(u64);
    var graph = Graph.init(&store, allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (mode == .indexed) try createIndex(&graph, arena.allocator(), config);

    // The same vectors in every mode.
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    const embedding = try allocator.alloc(Value, config.dimensions);
    defer allocator.free(embedding);
    const part_length = config.nodes / parts;
    const durations = try allocator.alloc(u64, part_length);
    defer allocator.free(durations);
    for (0..parts) |part| {
        const log_before = (try store.changeLogState()).?.bytes;
        for (0..part_length) |i| {
            defer _ = arena.reset(.{ .retain_with_limit = 1 << 20 });
            for (embedding) |*element| element.* = .{ .float = random.float(f64) * 2 - 1 };
            var ast = zypherdb.Ast.init(arena.allocator());
            var executor = zypherdb.Executor.init(&ast, &graph, arena.allocator());
            try executor.parameters.put(arena.allocator(), "id", Value{ .int = @intCast(part * part_length + i) });
            try executor.parameters.put(arena.allocator(), "embedding", Value{ .list = embedding });
            const start = now(io);
            _ = try executor.run(try zypherdb.parser.parse(&ast, write_text, null));
            durations[i] = @intCast(now(io) - start);
        }
        const log_bytes = (try store.changeLogState()).?.bytes - log_before;
        std.sort.pdq(u64, durations, {}, std.sort.asc(u64));
        var range_buffer: [32]u8 = undefined;
        const range = try std.fmt.bufPrint(&range_buffer, "{d}-{d}", .{ part * part_length + 1, (part + 1) * part_length });
        try out.print("{s:<8} {s:>14} {d:>8.1}us {d:>8.1}us {d:>10.0} B\n", .{
            @tagName(mode),
            range,
            micros(durations[durations.len / 2]),
            micros(durations[durations.len * 95 / 100]),
            @as(f64, @floatFromInt(log_bytes)) / @as(f64, @floatFromInt(part_length)),
        });
        try out.flush();
    }
    if (mode == .populate) {
        const start = now(io);
        try createIndex(&graph, arena.allocator(), config);
        const elapsed: u64 = @intCast(now(io) - start);
        const usage = std.posix.getrusage(std.posix.rusage.SELF);
        // ru_maxrss is in bytes on macOS, in KiB on Linux.
        const peak_bytes: u64 = @as(u64, @intCast(usage.maxrss)) * (if (@import("builtin").os.tag == .macos) 1 else 1024);
        try out.print("{s:<8} CREATE VECTOR INDEX over {d}: {d:.2} s, {d:.0} us per entity, peak memory {d} MiB\n", .{
            @tagName(mode),
            config.nodes,
            @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s,
            micros(elapsed) / @as(f64, @floatFromInt(config.nodes)),
            peak_bytes >> 20,
        });
        try out.flush();
    }
}

fn createIndex(graph: *Graph, arena: std.mem.Allocator, config: Config) !void {
    const text = try std.fmt.allocPrint(arena, "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.embedding OPTIONS {{indexConfig: {{`vector.dimensions`: {d}, `vector.similarity_function`: 'cosine'}}}}", .{config.dimensions});
    var ast = zypherdb.Ast.init(arena);
    var executor = zypherdb.Executor.init(&ast, graph, arena);
    _ = try executor.run(try zypherdb.parser.parse(&ast, text, null));
}

fn parseArguments(args: []const [:0]const u8) !Config {
    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const name = args[i];
        i += 1;
        if (i == args.len) return error.MissingValue;
        if (std.mem.eql(u8, name, "--nodes")) {
            config.nodes = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, name, "--dimensions")) {
            config.dimensions = try std.fmt.parseInt(usize, args[i], 10);
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
