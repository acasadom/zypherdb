//! The query fuzzer: a small random graph and random read queries
//! (query_generator.zig), each checked against oracles that need no second
//! engine. The same query must give the same rows
//!
//! - with the planner's optimizations off, in random combinations
//!   (`zypherdb.PlanOptions`);
//! - prepared, run twice (the second run reuses the plan), and after the
//!   graph changed under a statement prepared before;
//! - as the union of its rows WHERE p, WHERE NOT p and WHERE p IS NULL
//!   (ternary logic partitioning) for a random predicate p.
//!
//! Rows compare as multisets, or in order when the query sorts on every
//! column. Each seed prints a digest of its results: two builds (LMDB and
//! libmdbx) must print the same digests for the same seeds.
//!
//! Swarm testing: each seed chooses the graph's size and shape, the values,
//! the query features and how often the graph changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");
const Graph = zypherdb.Graph;
const KeyValueStore = zypherdb.KeyValueStore;
const Value = zypherdb.Value;
const Statement = zypherdb.Statement;
const PlanOptions = zypherdb.PlanOptions;
const NodeId = u64;
const RelationshipId = u64;

const generator = @import("query_generator.zig");
const Query = generator.Query;
const Outcome = @import("query_results.zig").Outcome;
const values = @import("values.zig");

pub const Options = struct {
    seed: u64,
    /// How many queries the seed generates.
    queries: u32 = 200,
    /// Prints every query as it runs.
    verbose: bool = false,
};

pub const Oracle = enum { plan_options, prepared, prepared_after_writes, partitioning };
const oracle_count = @typeInfo(Oracle).@"enum".field_names.len;

/// What a seed exercises.
pub const Swarm = struct {
    nodes: u32,
    relationships: u32,
    /// Property values from every type (values.randomValue), else a few.
    all_values: bool,
    /// How many of the few values (fewer: more nodes share a value).
    value_pool: u8,
    /// Out of 8: a node or relationship has a given property.
    property_chance: u8,
    /// Plan option variants tried per query.
    variants: u8,
    /// Queries between changes to the graph.
    writes_every: u32,
    /// Which property indexes exist: a bit per label and property, then per
    /// relationship type and property.
    indexes: u16,
    /// The indexes are made before the graph (kept current by its writes),
    /// else after (built from it).
    indexes_first: bool,
    mix: generator.Mix,

    pub fn choose(random: std.Random) Swarm {
        const nodes = random.uintAtMost(u32, 30);
        return .{
            .nodes = nodes,
            .relationships = if (nodes == 0) 0 else random.uintAtMost(u32, nodes * 5),
            .all_values = random.uintLessThan(u8, 3) == 0,
            .value_pool = random.intRangeAtMost(u8, 2, few_values.len),
            .property_chance = random.intRangeAtMost(u8, 2, 8),
            .variants = random.intRangeAtMost(u8, 1, 3),
            .writes_every = random.intRangeAtMost(u32, 5, 50),
            .indexes = random.int(u16),
            .indexes_first = random.boolean(),
            .mix = .choose(random),
        };
    }

    pub fn format(self: Swarm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d} nodes, {d} relationships, {s} values, {d} of the few, properties {d}/8, {d} variant(s), writes every {d}, indexes {x} ({s}); mix: {any}", .{
            self.nodes,                                   self.relationships, if (self.all_values) "all" else "narrow", self.value_pool,
            self.property_chance,                         self.variants,      self.writes_every,                        self.indexes,
            if (self.indexes_first) "first" else "after", self.mix,
        });
    }
};

/// What the queries did, and how often each oracle compared two results.
pub const Statistics = struct {
    queries: u64 = 0,
    /// Queries that failed (the same way everywhere), by error.
    failures: std.StringArrayHashMapUnmanaged(u64) = .empty,
    empty_results: u64 = 0,
    rows: u64 = 0,
    comparisons: [oracle_count]u64 = @splat(0),

    pub fn add(self: *Statistics, allocator: Allocator, other: Statistics) Allocator.Error!void {
        self.queries += other.queries;
        self.empty_results += other.empty_results;
        self.rows += other.rows;
        for (&self.comparisons, other.comparisons) |*total, count| total.* += count;
        for (other.failures.keys(), other.failures.values()) |name, count| {
            const entry = try self.failures.getOrPutValue(allocator, name, 0);
            entry.value_ptr.* += count;
        }
    }

    pub fn deinit(self: *Statistics, allocator: Allocator) void {
        self.failures.deinit(allocator);
    }

    pub fn format(self: Statistics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("  queries: {d}, {d} with no rows, {d} rows in all\n", .{ self.queries, self.empty_results, self.rows });
        for (self.failures.keys(), self.failures.values()) |name, count| try writer.print("  failed with {s}: {d}\n", .{ name, count });
        for (self.comparisons, 0..) |count, i| try writer.print("  {s}: {d} comparisons\n", .{ @tagName(@as(Oracle, @fromBackingInt(@intCast(i)))), count });
    }
};

/// Runs one seed on a new database in directory `path` (which must exist and
/// be empty). Writes the seed's digest to `out`; on a failure, what happened,
/// and returns `error.FuzzFailed`.
pub fn run(allocator: Allocator, path: []const u8, options: Options, out: *std.Io.Writer) !Statistics {
    var fuzzer: Fuzzer = undefined;
    try fuzzer.init(allocator, path, options, out);
    defer fuzzer.deinit();
    try fuzzer.build();
    try fuzzer.runQueries();
    try out.print("seed {d}: digest {x:0>16}\n", .{ options.seed, fuzzer.digest.final() });
    const statistics = fuzzer.statistics;
    fuzzer.statistics = .{};
    return statistics;
}

/// A statement prepared earlier, run again after the graph changed.
const Kept = struct { statement: *Statement, text: []const u8, ordered: bool };
const most_kept = 8;

/// Values that the queries' literals also use (1 and 1.0 among them).
const few_values = [_]Value{ .{ .int = 1 }, .{ .string = "a" }, .{ .float = 1.0 }, .{ .int = 0 }, .{ .int = 2 }, .{ .float = 2.5 }, .{ .string = "b" }, .{ .string = "ab" }, .{ .string = "" }, .{ .boolean = true }, .{ .boolean = false } };

const Fuzzer = struct {
    allocator: Allocator,
    options: Options,
    out: *std.Io.Writer,
    prng: std.Random.DefaultPrng,
    swarm: Swarm,
    store: KeyValueStore,
    graph: Graph,
    parameters: zypherdb.Executor.Parameters = .empty,
    node_ids: std.ArrayList(NodeId) = .empty,
    relationship_ids: std.ArrayList(RelationshipId) = .empty,
    next_node_id: NodeId = 1,
    kept: std.ArrayList(Kept) = .empty,
    /// The run's values (parameters, kept texts).
    values: std.heap.ArenaAllocator,
    /// Memory for one query and its oracles.
    scratch: std.heap.ArenaAllocator,
    query_number: u32 = 0,
    /// The query being checked, for the failure report.
    text: []const u8 = "",
    digest: std.hash.Wyhash = .init(0),
    statistics: Statistics = .{},

    const store_options = KeyValueStore.Options{ .durability = .deferred };

    fn init(self: *Fuzzer, allocator: Allocator, path: []const u8, options: Options, out: *std.Io.Writer) !void {
        self.* = .{
            .allocator = allocator,
            .options = options,
            .out = out,
            .prng = .init(options.seed),
            .swarm = undefined,
            .store = try KeyValueStore.openWithOptions(allocator, path, store_options),
            .graph = undefined,
            .values = .init(allocator),
            .scratch = .init(allocator),
        };
        self.swarm = Swarm.choose(self.random());
        self.graph = Graph.init(&self.store, allocator);
        if (options.verbose) try out.print("seed {d}, swarm: {f}\n", .{ options.seed, self.swarm });
    }

    fn deinit(self: *Fuzzer) void {
        for (self.kept.items) |kept| kept.statement.destroy();
        self.kept.deinit(self.allocator);
        self.node_ids.deinit(self.allocator);
        self.relationship_ids.deinit(self.allocator);
        self.parameters.deinit(self.allocator);
        self.statistics.deinit(self.allocator);
        self.store.deinit();
        self.values.deinit();
        self.scratch.deinit();
    }

    fn random(self: *Fuzzer) std.Random {
        return self.prng.random();
    }

    // --- The graph -----------------------------------------------------------------

    fn build(self: *Fuzzer) !void {
        for (generator.parameter_names) |name| {
            try self.parameters.put(self.allocator, name, try self.propertyValue(self.values.allocator()));
        }
        try self.graph.beginWrite();
        errdefer self.graph.abortWrite();
        if (self.swarm.indexes_first) try self.createIndexes();
        for (0..self.swarm.nodes) |_| try self.addNode();
        for (0..self.swarm.relationships) |_| try self.addRelationship();
        if (!self.swarm.indexes_first) try self.createIndexes();
        try self.graph.commitWrite();
    }

    /// The property indexes the swarm picked (`Swarm.indexes`), as CREATE
    /// INDEX makes them.
    fn createIndexes(self: *Fuzzer) !void {
        const schema = zypherdb.schema_definitions;
        var bit: u4 = 0;
        for ([_]schema.Entity{ .nodes, .relationships }) |entity| {
            const targets: []const []const u8 = if (entity == .nodes) &generator.labels else &generator.types;
            for (targets) |target| for (generator.properties) |property| {
                defer bit += 1;
                if (self.swarm.indexes & (@as(u16, 1) << bit) == 0) continue;
                const name = try std.fmt.allocPrint(self.scratch.allocator(), "{s}_{s}", .{ target, property });
                const stored = try schema.create(&self.graph, .{ .name = name, .kind = .range, .entity = entity, .analyzer = "", .labels_or_types = &.{target}, .properties = &.{property} });
                try zypherdb.property_indexes.populate(&self.graph, stored);
            };
        }
    }

    fn addNode(self: *Fuzzer) !void {
        const id = self.next_node_id;
        self.next_node_id += 1;
        try self.graph.addNode(id, "");
        for (generator.labels) |label| if (self.random().boolean()) try self.graph.addLabel(id, label);
        for (generator.properties) |property| if (self.hasProperty()) try self.setNodeProperty(id, property);
        try self.node_ids.append(self.allocator, id);
    }

    fn addRelationship(self: *Fuzzer) !void {
        if (self.node_ids.items.len == 0) return;
        const source = self.pickNode();
        // Loops sometimes: a node related to itself.
        const target = if (self.random().uintLessThan(u8, 8) == 0) source else self.pickNode();
        const id = try self.graph.addEdge(source, target, generator.types[self.random().uintLessThan(usize, generator.types.len)]);
        for (generator.properties) |property| if (self.hasProperty()) {
            self.graph.setEdgeProperty(id, property, try self.propertyValue(self.scratch.allocator())) catch |err| if (err != error.UnsupportedPropertyType) return err;
        };
        try self.relationship_ids.append(self.allocator, id);
    }

    fn setNodeProperty(self: *Fuzzer, id: NodeId, property: []const u8) !void {
        self.graph.setProperty(id, property, try self.propertyValue(self.scratch.allocator())) catch |err| if (err != error.UnsupportedPropertyType) return err;
    }

    fn hasProperty(self: *Fuzzer) bool {
        return self.random().uintLessThan(u8, 8) < self.swarm.property_chance;
    }

    /// A value from the literals the queries use (equal values meet), or
    /// from every type.
    fn propertyValue(self: *Fuzzer, allocator: Allocator) Allocator.Error!Value {
        if (self.swarm.all_values and self.random().boolean()) return values.randomValue(self.random(), allocator);
        if (self.random().uintLessThan(u8, 12) == 0) return .{ .list = try allocator.dupe(Value, &.{ .{ .int = 1 }, .{ .int = 2 } }) };
        return few_values[self.random().uintLessThan(usize, self.swarm.value_pool)];
    }

    fn pickNode(self: *Fuzzer) NodeId {
        return self.node_ids.items[self.random().uintLessThan(usize, self.node_ids.items.len)];
    }

    /// A few random changes in one transaction: the counts move, so kept
    /// statements may plan again or run a plan made for another graph.
    fn changeGraph(self: *Fuzzer) !void {
        try self.graph.beginWrite();
        errdefer self.graph.abortWrite();
        for (0..self.random().intRangeAtMost(u32, 1, 10)) |_| {
            switch (self.random().uintLessThan(u8, 6)) {
                0 => try self.addNode(),
                1 => try self.addRelationship(),
                2 => if (self.node_ids.items.len > 0) try self.setNodeProperty(self.pickNode(), generator.properties[self.random().uintLessThan(usize, generator.properties.len)]),
                3 => if (self.node_ids.items.len > 0) {
                    const label = generator.labels[self.random().uintLessThan(usize, generator.labels.len)];
                    if (self.random().boolean()) try self.graph.addLabel(self.pickNode(), label) else try self.graph.removeLabel(self.pickNode(), label);
                },
                4 => if (self.relationship_ids.items.len > 0) {
                    const position = self.random().uintLessThan(usize, self.relationship_ids.items.len);
                    try self.graph.deleteEdge(self.relationship_ids.swapRemove(position));
                },
                else => if (self.node_ids.items.len > 0) {
                    const position = self.random().uintLessThan(usize, self.node_ids.items.len);
                    const id = self.node_ids.swapRemove(position);
                    try self.graph.deleteNodeDetach(id);
                    try self.forgetDeletedRelationships();
                },
            }
        }
        try self.graph.commitWrite();
    }

    /// Drops the ids of the relationships a detached node took along.
    fn forgetDeletedRelationships(self: *Fuzzer) !void {
        var position: usize = 0;
        while (position < self.relationship_ids.items.len) {
            if (!try self.graph.hasRelationship(self.relationship_ids.items[position])) {
                _ = self.relationship_ids.swapRemove(position);
            } else position += 1;
        }
    }

    // --- Queries -------------------------------------------------------------------

    fn runQueries(self: *Fuzzer) !void {
        while (self.query_number < self.options.queries) : (self.query_number += 1) {
            _ = self.scratch.reset(.retain_capacity);
            if (self.query_number > 0 and self.query_number % self.swarm.writes_every == 0) {
                try self.changeGraph();
                try self.checkKept();
            }
            const query = try generator.generate(self.random(), self.swarm.mix, self.scratch.allocator());
            try self.checkQuery(query);
        }
    }

    fn checkQuery(self: *Fuzzer, query: Query) !void {
        const arena = self.scratch.allocator();
        self.text = try query.text(arena, null);
        if (self.options.verbose) try self.out.print("query {d}: {s}\n", .{ self.query_number, self.text });
        const expected = try self.runOnce(self.text, .{}, query.ordered);
        self.note(expected);
        expected.digest(&self.digest);

        for (0..self.swarm.variants) |_| {
            const options = self.planOptions();
            try self.compare(.plan_options, expected, try self.runOnce(self.text, options, query.ordered), options);
        }
        try self.checkPrepared(query, expected);
        if (query.partitionable and expected == .rows) try self.checkPartitions(query, expected);
    }

    fn note(self: *Fuzzer, outcome: Outcome) void {
        self.statistics.queries += 1;
        switch (outcome) {
            .failure => |err| {
                const entry = self.statistics.failures.getOrPutValue(self.allocator, @errorName(err), 0) catch return;
                entry.value_ptr.* += 1;
            },
            .rows => |rows| {
                self.statistics.rows += rows.len;
                if (rows.len == 0) self.statistics.empty_results += 1;
            },
        }
    }

    fn planOptions(self: *Fuzzer) PlanOptions {
        const choice = self.random();
        return .{
            .where_seeks = choice.boolean(),
            .index_lookups = choice.boolean(),
            .index_counts = choice.boolean(),
            .anchor = if (choice.boolean()) .cheapest else .{ .position = choice.uintAtMost(u32, 3) },
            .top = choice.boolean(),
        };
    }

    /// Prepared, the statement runs twice (the second time on its cached
    /// plan); sometimes it is kept for after the next change to the graph.
    fn checkPrepared(self: *Fuzzer, query: Query, expected: Outcome) !void {
        const statement = Statement.prepare(self.allocator, self.text, .{ .graph = &self.graph }) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.compare(.prepared, expected, .{ .failure = err }, null);
        };
        var keep = false;
        defer if (!keep) statement.destroy();
        for (0..2) |_| try self.compare(.prepared, expected, try self.runPrepared(statement, query.ordered), null);
        if (self.random().uintLessThan(u8, 4) != 0) return;
        if (self.kept.items.len == most_kept) {
            const old = self.kept.swapRemove(self.random().uintLessThan(usize, most_kept));
            old.statement.destroy();
        }
        try self.kept.append(self.allocator, .{ .statement = statement, .text = try self.values.allocator().dupe(u8, self.text), .ordered = query.ordered });
        keep = true;
    }

    /// The kept statements, on the changed graph, against one-shot runs.
    fn checkKept(self: *Fuzzer) !void {
        for (self.kept.items) |kept| {
            self.text = kept.text;
            const expected = try self.runOnce(kept.text, .{}, kept.ordered);
            try self.compare(.prepared_after_writes, expected, try self.runPrepared(kept.statement, kept.ordered), null);
        }
    }

    /// Q = Q WHERE p ⊎ Q WHERE NOT p ⊎ Q WHERE p IS NULL, as multisets.
    fn checkPartitions(self: *Fuzzer, query: Query, expected: Outcome) !void {
        const arena = self.scratch.allocator();
        const predicates = [_][]const u8{
            query.partition,
            try std.fmt.allocPrint(arena, "NOT ({s})", .{query.partition}),
            try std.fmt.allocPrint(arena, "({s}) IS NULL", .{query.partition}),
        };
        var parts: [predicates.len]Outcome = undefined;
        for (&parts, predicates) |*part, predicate| part.* = try self.runOnce(try query.text(arena, predicate), .{}, false);
        const sorted = try Outcome.concatenated(arena, &.{expected});
        const actual = try Outcome.concatenated(arena, &parts);
        if (!sorted.eql(actual)) {
            return self.fail(sorted, actual, "partitioning by {s}: {s}\n  {s}\n  {s}", .{ query.partition, try query.text(arena, predicates[0]), try query.text(arena, predicates[1]), try query.text(arena, predicates[2]) });
        }
        self.statistics.comparisons[@backingInt(Oracle.partitioning)] += 1;
    }

    fn runOnce(self: *Fuzzer, text: []const u8, options: PlanOptions, ordered: bool) !Outcome {
        const arena = self.scratch.allocator();
        // The AST lives in the scratch memory: rows may point into it.
        const ast = try arena.create(zypherdb.Ast);
        ast.* = zypherdb.Ast.init(arena);
        const root = zypherdb.parser.parse(ast, text, null) catch |err| return .{ .failure = err };
        var executor = zypherdb.Executor.init(ast, &self.graph, arena);
        executor.parameters = self.parameters;
        executor.plan_options = options;
        const rows = executor.run(root) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .failure = err };
        };
        return Outcome.fromRows(arena, rows, ordered);
    }

    fn runPrepared(self: *Fuzzer, statement: *Statement, ordered: bool) !Outcome {
        const arena = self.scratch.allocator();
        var executor = statement.executorFor(&self.graph, arena);
        executor.parameters = self.parameters;
        const rows = statement.run(&executor) catch |err| {
            if (err == error.OutOfMemory) return err;
            return .{ .failure = err };
        };
        return Outcome.fromRows(arena, rows, ordered);
    }

    fn compare(self: *Fuzzer, oracle: Oracle, expected: Outcome, actual: Outcome, options: ?PlanOptions) !void {
        if (!expected.eql(actual)) {
            if (options) |plan_options| return self.fail(expected, actual, "{t} {any}", .{ oracle, plan_options });
            return self.fail(expected, actual, "{t}", .{oracle});
        }
        self.statistics.comparisons[@backingInt(oracle)] += 1;
    }

    fn fail(self: *Fuzzer, expected: Outcome, actual: Outcome, comptime fmt: []const u8, args: anytype) error{ FuzzFailed, WriteFailed } {
        const out = self.out;
        try out.print("\nquery fuzzer FAILED at query {d} of seed {d} ({s})\n", .{ self.query_number, self.options.seed, zypherdb.storage_engine });
        try out.print("reproduce: zig build fuzz -Dstorage-engine={s} -- query --seed {d} --steps {d} --verbose\n", .{ zypherdb.storage_engine, self.options.seed, self.query_number + 1 });
        try out.print("swarm: {f}\nparameters:", .{self.swarm});
        for (generator.parameter_names) |name| try out.print(" ${s} = {any}", .{ name, self.parameters.get(name).? });
        try out.print("\nquery: {s}\noracle: ", .{self.text});
        try out.print(fmt, args);
        try out.print("\nexpected: {f}actual: {f}", .{ expected, actual });
        try out.flush();
        return error.FuzzFailed;
    }
};
