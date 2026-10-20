//! Benchmark: an access-control graph at realistic scale, and the queries
//! such a system runs.
//!
//!     zig build bench -Doptimize=ReleaseFast -- [--people N] [--runs N] [--dir PATH]
//!                                               [--only TEXT] [--reuse]
//!                                               [--durability full|relaxed|deferred]
//!
//! The graph (deterministic, from a fixed seed), for `--people` P (default
//! 100,000):
//!
//! - P `:Person {id, name, age, department}`, each holding one
//!   `:Card {number}` (`(card)-[:HELD_BY]->(person)`);
//! - P / 100 `:Group {id, name}` in a hierarchy (`(group)-[:MEMBER_OF]->(parent)`,
//!   ten children per parent), each person in 1 to 3 groups;
//! - P / 500 `:Zone {id}`, and P / 10 `:Door {id}` in them (`(door)-[:IN]->(zone)`);
//! - every group may enter two zones on weekdays from 9:00 to 18:00
//!   (`(group)-[:MAY_ENTER {days, from, until}]->(zone)`).
//!
//! It loads the graph through the storage API in one transaction, then runs
//! each query `--runs` times with random parameters and reports the median,
//! 95th percentile and mean time per query.

const std = @import("std");
const acmedb = @import("acmedb");

const Graph = acmedb.Graph;
const Value = acmedb.Value;
const KeyValueStore = acmedb.KeyValueStore;

const Config = struct {
    people: u64 = 100_000,
    runs: usize = 200,
    dir: []const u8 = ".bench-data",
    /// Run only the queries whose name contains this text.
    only: []const u8 = "",
    /// Reuse the graph already in `dir` instead of loading it again (to
    /// profile one query: the write queries of earlier runs stay in it).
    reuse: bool = false,
    durability: KeyValueStore.Durability = .full,
};

const Counts = struct {
    people: u64,
    groups: u64,
    zones: u64,
    doors: u64,

    fn of(config: Config) Counts {
        return .{
            .people = config.people,
            .groups = @max(config.people / 100, 10),
            .zones = @max(config.people / 500, 2),
            .doors = @max(config.people / 10, 2),
        };
    }

    // Node ids by kind: persons, then cards, groups, zones, doors.
    fn person(self: Counts, i: u64) u64 {
        _ = self;
        return i;
    }
    fn card(self: Counts, i: u64) u64 {
        return self.people + i;
    }
    fn group(self: Counts, i: u64) u64 {
        return 2 * self.people + i;
    }
    fn zone(self: Counts, i: u64) u64 {
        return 2 * self.people + self.groups + i;
    }
    fn door(self: Counts, i: u64) u64 {
        return 2 * self.people + self.groups + self.zones + i;
    }
};

const departments = [_][]const u8{ "engineering", "sales", "support", "finance", "legal", "operations", "research", "security" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const config = try parseArguments(try init.minimal.args.toSlice(arena));
    const counts = Counts.of(config);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    if (!config.reuse) std.Io.Dir.cwd().deleteTree(io, config.dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, config.dir);
    const allocator = std.heap.smp_allocator;
    var store = try KeyValueStore.openWithOptions(allocator, config.dir, .{ .durability = config.durability });
    defer store.deinit();
    var graph = Graph.init(&store, allocator);

    try out.print("acmedb access-control benchmark ({s} build, {s} durability)\n", .{ @tagName(@import("builtin").mode), @tagName(config.durability) });
    try out.print("graph: {d} people and cards, {d} groups, {d} zones, {d} doors\n\n", .{ counts.people, counts.groups, counts.zones, counts.doors });
    try out.flush();

    if (!config.reuse) {
        const load_start = now(io);
        const loaded = try load(&graph, counts);
        const load_seconds = seconds(now(io) - load_start);
        try out.print("load: {d} nodes, {d} relationships, {d} properties in {d:.2} s ({d:.0} items/s)\n\n", .{
            loaded.nodes,                                                                                    loaded.relationships, loaded.properties, load_seconds,
            @as(f64, @floatFromInt(loaded.nodes + loaded.relationships + loaded.properties)) / load_seconds,
        });
        try out.flush();
    }

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    try out.print("{s:<34} {s:>7} {s:>12} {s:>12} {s:>12} {s:>8}\n", .{ "query", "runs", "median", "p95", "mean", "rows" });
    for (queries) |query| {
        if (std.mem.indexOf(u8, query.name, config.only) == null) continue;
        const runs = if (query.heavy) @max(config.runs / 20, 3) else config.runs;
        const result = try measure(io, &graph, query, counts, random, runs);
        try out.print("{s:<34} {d:>7} {f} {f} {f} {d:>8}\n", .{ query.name, runs, Micros{ .ns = result.median }, Micros{ .ns = result.p95 }, Micros{ .ns = result.mean }, result.rows });
        try out.flush();
    }
}

fn parseArguments(args: []const []const u8) !Config {
    var config = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const name = args[i];
        if (std.mem.eql(u8, name, "--reuse")) {
            config.reuse = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgumentValue;
        i += 1;
        if (std.mem.eql(u8, name, "--people")) {
            config.people = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, name, "--runs")) {
            config.runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, name, "--dir")) {
            config.dir = args[i];
        } else if (std.mem.eql(u8, name, "--only")) {
            config.only = args[i];
        } else if (std.mem.eql(u8, name, "--durability")) {
            config.durability = std.meta.stringToEnum(KeyValueStore.Durability, args[i]) orelse return error.UnknownDurability;
        } else return error.UnknownArgument;
    }
    return config;
}

// --- Loading -------------------------------------------------------------------

const Loaded = struct { nodes: u64 = 0, relationships: u64 = 0, properties: u64 = 0 };

fn load(graph: *Graph, counts: Counts) !Loaded {
    var loaded = Loaded{};
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    var name_buffer: [32]u8 = undefined;

    try graph.beginWrite();
    errdefer graph.abortWrite();
    for (0..counts.people) |i| {
        const person = counts.person(i);
        try graph.addNode(person, "Person");
        try graph.setProperty(person, "id", .{ .int = @intCast(i) });
        try graph.setProperty(person, "name", .{ .string = try std.fmt.bufPrint(&name_buffer, "person-{d}", .{i}) });
        try graph.setProperty(person, "age", .{ .int = 18 + @as(i64, @intCast(i % 50)) });
        try graph.setProperty(person, "department", .{ .string = departments[i % departments.len] });
        const card = counts.card(i);
        try graph.addNode(card, "Card");
        try graph.setProperty(card, "number", .{ .int = 1_000_000 + @as(i64, @intCast(i)) });
        try graph.addEdge(card, person, "HELD_BY");
        // One to three groups, distinct.
        const memberships = 1 + random.uintLessThan(u64, 3);
        for (0..memberships) |m| {
            const group = (random.uintLessThan(u64, counts.groups) + m * 7) % counts.groups;
            try graph.addEdge(person, counts.group(group), "MEMBER_OF");
        }
        loaded.nodes += 2;
        loaded.properties += 5;
        loaded.relationships += 1 + memberships;
    }
    const weekdays = Value{ .list = &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 }, .{ .int = 4 }, .{ .int = 5 } } };
    const nine = Value{ .local_time = .{ .nanoseconds = 9 * 3600 * std.time.ns_per_s } };
    const six = Value{ .local_time = .{ .nanoseconds = 18 * 3600 * std.time.ns_per_s } };
    for (0..counts.groups) |i| {
        const group = counts.group(i);
        try graph.addNode(group, "Group");
        try graph.setProperty(group, "id", .{ .int = @intCast(i) });
        try graph.setProperty(group, "name", .{ .string = try std.fmt.bufPrint(&name_buffer, "group-{d}", .{i}) });
        if (i >= 10) {
            try graph.addEdge(group, counts.group(i / 10), "MEMBER_OF");
            loaded.relationships += 1;
        }
        for (0..2) |z| {
            const zone = counts.zone((i * 3 + z * 11) % counts.zones);
            try graph.addEdge(group, zone, "MAY_ENTER");
            try graph.setEdgeProperty(group, zone, "MAY_ENTER", "days", weekdays);
            try graph.setEdgeProperty(group, zone, "MAY_ENTER", "from", nine);
            try graph.setEdgeProperty(group, zone, "MAY_ENTER", "until", six);
            loaded.relationships += 1;
            loaded.properties += 3;
        }
        loaded.nodes += 1;
        loaded.properties += 2;
    }
    for (0..counts.zones) |i| {
        try graph.addNode(counts.zone(i), "Zone");
        try graph.setProperty(counts.zone(i), "id", .{ .int = @intCast(i) });
        loaded.nodes += 1;
        loaded.properties += 1;
    }
    for (0..counts.doors) |i| {
        try graph.addNode(counts.door(i), "Door");
        try graph.setProperty(counts.door(i), "id", .{ .int = @intCast(i) });
        try graph.addEdge(counts.door(i), counts.zone(i % counts.zones), "IN");
        loaded.nodes += 1;
        loaded.properties += 1;
        loaded.relationships += 1;
    }
    try graph.commitWrite();
    return loaded;
}

// --- Queries ---------------------------------------------------------------------

const Parameter = enum { person, card, door };

const Query = struct {
    name: []const u8,
    text: []const u8,
    parameters: []const Parameter = &.{},
    /// Scans the whole graph: run fewer times.
    heavy: bool = false,
};

const queries = [_]Query{
    .{ .name = "card lookup", .text = "MATCH (c:Card {number: $card}) RETURN c.number", .parameters = &.{.card} },
    .{ .name = "person's groups (1 hop)", .text = "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g) RETURN g.name", .parameters = &.{.person} },
    .{ .name = "colleagues (2 hops, distinct)", .text = "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g)<-[:MEMBER_OF]-(q) RETURN count(DISTINCT q)", .parameters = &.{.person} },
    .{
        .name = "may this card open this door?",
        .text =
        \\MATCH (:Card {number: $card})-[:HELD_BY]->(p)-[:MEMBER_OF*1..3]->(g)-[w:MAY_ENTER]->(z)<-[:IN]-(:Door {id: $door})
        \\WHERE 3 IN w.days AND w.from <= localtime('10:30') AND localtime('10:30') < w.until
        \\RETURN count(*) > 0
        ,
        .parameters = &.{ .card, .door },
    },
    .{
        .name = "same, with EXISTS",
        .text =
        \\MATCH (c:Card {number: $card}), (d:Door {id: $door})
        \\RETURN EXISTS { (c)-[:HELD_BY]->()-[:MEMBER_OF*1..3]->()-[w:MAY_ENTER]->()<-[:IN]-(d) WHERE 3 IN w.days }
        ,
        .parameters = &.{ .card, .door },
    },
    .{ .name = "doors of a person's zones", .text = "MATCH (p:Person {id: $person})-[:MEMBER_OF*1..3]->()-[:MAY_ENTER]->(z)<-[:IN]-(d) RETURN count(DISTINCT d)", .parameters = &.{.person} },
    .{ .name = "people over 60 (scan + filter)", .text = "MATCH (p:Person) WHERE p.age > 60 RETURN count(*)", .heavy = true },
    .{ .name = "oldest 10 (ORDER BY + LIMIT)", .text = "MATCH (p:Person) RETURN p.name ORDER BY p.age DESC, p.id LIMIT 10", .heavy = true },
    .{ .name = "group sizes (aggregate)", .text = "MATCH (p:Person)-[:MEMBER_OF]->(g:Group) RETURN g.name, count(*) AS n ORDER BY n DESC LIMIT 10", .heavy = true },
    .{ .name = "department counts", .text = "MATCH (p:Person) RETURN p.department, count(*)", .heavy = true },
    .{ .name = "return 100k rows (3 columns)", .text = "MATCH (p:Person) RETURN p.id, p.name, p.age", .heavy = true },
    .{ .name = "return 10k whole nodes", .text = "MATCH (p:Person) RETURN p LIMIT 10000", .heavy = true },
    .{ .name = "create one node (commit)", .text = "CREATE (:Event {at: datetime(), card: $card})", .parameters = &.{.card} },
    .{ .name = "create 1000 nodes (UNWIND)", .text = "UNWIND range(1, 1000) AS i CREATE (:Event {n: i})", .heavy = true },
};

const Measurement = struct { median: u64, p95: u64, mean: u64, rows: usize };

fn measure(io: std.Io, graph: *Graph, query: Query, counts: Counts, random: std.Random, runs: usize) !Measurement {
    var durations = try std.heap.smp_allocator.alloc(u64, runs);
    defer std.heap.smp_allocator.free(durations);
    var rows: usize = 0;
    for (0..runs + 2) |run| { // two warm-up runs
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        var ast = acmedb.Ast.init(arena.allocator());
        var executor = acmedb.Executor.init(&ast, graph, arena.allocator());
        for (query.parameters) |parameter| {
            const value: Value = switch (parameter) {
                .person => .{ .int = @intCast(random.uintLessThan(u64, counts.people)) },
                .card => .{ .int = 1_000_000 + @as(i64, @intCast(random.uintLessThan(u64, counts.people))) },
                .door => .{ .int = @intCast(random.uintLessThan(u64, counts.doors)) },
            };
            try executor.parameters.put(arena.allocator(), @tagName(parameter), value);
        }
        // Parsing is part of what a query costs: it is timed too.
        const start = now(io);
        const parsed = try acmedb.parser.parse(&ast, query.text, null);
        const result = try executor.run(parsed);
        const elapsed: u64 = @intCast(now(io) - start);
        rows = result.len;
        if (run >= 2) durations[run - 2] = elapsed;
    }
    std.sort.pdq(u64, durations, {}, std.sort.asc(u64));
    var total: u128 = 0;
    for (durations) |d| total += d;
    return .{
        .median = durations[durations.len / 2],
        .p95 = durations[@min(durations.len - 1, durations.len * 95 / 100)],
        .mean = @intCast(total / durations.len),
        .rows = rows,
    };
}

fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn seconds(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

/// A duration printed in microseconds, or milliseconds above ten of them.
const Micros = struct {
    ns: u64,

    pub fn format(self: Micros, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        var buffer: [32]u8 = undefined;
        const text = if (self.ns >= 10_000_000)
            std.fmt.bufPrint(&buffer, "{d:.1} ms", .{@as(f64, @floatFromInt(self.ns)) / 1e6}) catch unreachable
        else
            std.fmt.bufPrint(&buffer, "{d:.1} µs", .{@as(f64, @floatFromInt(self.ns)) / 1e3}) catch unreachable;
        try writer.alignBufferOptions(text, .{ .width = 12, .alignment = .right });
    }
};
