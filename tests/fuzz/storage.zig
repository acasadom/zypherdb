//! The storage fuzzer: random operations through the `Graph` API (and the
//! schema commands, as statements), applied also to a model in memory
//! (model.zig) that predicts which ones must fail. After every commit and
//! every abort it checks that the database equals the model
//! (storage_compare.zig) and that every derived structure agrees with the
//! primary records (`zypherdb.integrity`).
//!
//! Swarm testing: each seed chooses which operations run and how often, and
//! the pools of labels, properties and types (a small pool makes collisions).
//! A run is determined by its seed: a failure prints the command that
//! repeats it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");
const Graph = zypherdb.Graph;
const KeyValueStore = zypherdb.KeyValueStore;
const Value = zypherdb.Value;
const value_encoding = zypherdb.value_encoding;

const model_module = @import("model.zig");
const Model = model_module.Model;
const NodeId = model_module.NodeId;
const RelationshipId = model_module.RelationshipId;
const values = @import("values.zig");
const storage_compare = @import("storage_compare.zig");

pub const Options = struct {
    seed: u64,
    steps: u32 = 1000,
    /// Prints every operation as it runs.
    verbose: bool = false,
};

pub const Operation = enum {
    create_node,
    create_node_with_id,
    add_existing_node,
    delete_node,
    delete_node_detach,
    add_label,
    remove_label,
    set_property,
    copy_property,
    remove_property,
    create_relationship,
    delete_relationship,
    set_relationship_property,
    remove_relationship_property,
    commit,
    abort,
    check_inside_transaction,
    create_fulltext_index,
    create_index,
    create_constraint,
    drop_definition,
    reopen,
};

const operation_count = @typeInfo(Operation).@"enum".field_names.len;

const label_pool = [_][]const u8{ "A", "B", "Person", "Door", "C" };
const property_pool = [_][]const u8{ "p", "name", "q", "text", "x" };
const type_pool = [_][]const u8{ "T", "KNOWS", "U" };
const definition_names = [_][]const u8{ "one", "two", "three", "four", "five" };
const analyzers = [_][]const u8{ "standard", "english", "spanish" };

/// What a seed exercises.
pub const Swarm = struct {
    weights: [operation_count]u32,
    /// Writes run in write transactions (committed or aborted by the
    /// operations); otherwise each is committed on its own.
    transactions: bool,
    /// Without transactions: steps between checks.
    check_every: u32,
    /// Values from a handful (values.narrowValue), else from every type.
    narrow_values: bool,
    labels: []const []const u8,
    properties: []const []const u8,
    types: []const []const u8,

    pub fn choose(random: std.Random) Swarm {
        var swarm: Swarm = undefined;
        for (&swarm.weights) |*weight| weight.* = if (random.uintLessThan(u8, 4) == 0) 0 else random.intRangeAtMost(u32, 1, 10);
        // Always something to work on, and transactions that end.
        swarm.weights[@backingInt(Operation.create_node)] += 1;
        swarm.weights[@backingInt(Operation.commit)] += 1;
        swarm.transactions = random.uintLessThan(u8, 5) != 0;
        swarm.check_every = random.intRangeAtMost(u32, 1, 20);
        // Narrow values come with few labels and properties: then equal
        // values meet on nodes of one label, and constraints are broken.
        swarm.narrow_values = random.uintLessThan(u8, 3) == 0;
        const most: usize = if (swarm.narrow_values) 2 else label_pool.len;
        swarm.labels = label_pool[0..random.intRangeAtMost(usize, 1, most)];
        swarm.properties = property_pool[0..random.intRangeAtMost(usize, 1, most)];
        swarm.types = type_pool[0..random.intRangeAtMost(usize, 1, type_pool.len)];
        return swarm;
    }

    pub fn format(self: Swarm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{s}, {s} values, {d} label(s), {d} propert(ies), {d} type(s); weights:", .{
            if (self.transactions) "transactions" else "autocommit",
            if (self.narrow_values) "narrow" else "all",
            self.labels.len,
            self.properties.len,
            self.types.len,
        });
        for (self.weights, 0..) |weight, i| if (weight > 0) try writer.print(" {s}={d}", .{ @tagName(@as(Operation, @fromBackingInt(@intCast(i)))), weight });
    }
};

/// How often each operation ran, and how often it failed as the model said
/// it must (a constraint broken, a node still connected...).
pub const Statistics = struct {
    performed: [operation_count]u64 = @splat(0),
    refused: [operation_count][refusals.len]u64 = @splat(@splat(0)),

    /// The failures the model predicts.
    pub const refusals = [_]anyerror{ error.NodeStillConnected, error.UnsupportedPropertyType, error.ConstraintViolation, error.InvalidExpression };

    fn refuse(self: *Statistics, operation: Operation, err: anyerror) void {
        for (refusals, 0..) |refusal, i| if (refusal == err) {
            self.refused[@backingInt(operation)][i] += 1;
        };
    }

    pub fn add(self: *Statistics, other: Statistics) void {
        for (&self.performed, other.performed) |*total, count| total.* += count;
        for (&self.refused, other.refused) |*totals, counts| {
            for (totals, counts) |*total, count| total.* += count;
        }
    }

    pub fn format(self: Statistics, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.performed, self.refused, 0..) |performed, refused, i| {
            if (performed == 0) continue;
            try writer.print("  {s}: {d}", .{ @tagName(@as(Operation, @fromBackingInt(@intCast(i)))), performed });
            for (refused, refusals) |count, refusal| if (count > 0) try writer.print(", {d} {t}", .{ count, refusal });
            try writer.writeAll("\n");
        }
    }
};

/// Runs one seed on a new database in directory `path` (which must exist and
/// be empty). On a failure it writes what happened to `out` and returns
/// `error.FuzzFailed`.
pub fn run(allocator: Allocator, path: []const u8, options: Options, out: *std.Io.Writer) !Statistics {
    var fuzzer: Fuzzer = undefined;
    try fuzzer.init(allocator, path, options, out);
    defer fuzzer.deinit();
    try fuzzer.runSteps();
    return fuzzer.statistics;
}

const Fuzzer = struct {
    allocator: Allocator,
    path: []const u8,
    options: Options,
    out: *std.Io.Writer,
    prng: std.Random.DefaultPrng,
    swarm: Swarm,
    store: KeyValueStore,
    graph: Graph,
    model: Model,
    /// The model when the write transaction began (an abort goes back to it).
    snapshot: ?Model = null,
    /// The run's values (shared by the model's copies).
    values: std.heap.ArenaAllocator,
    /// Memory for one step.
    scratch: std.heap.ArenaAllocator,
    step: u32 = 0,
    /// The operation being performed.
    operation: Operation = .create_node,
    history: History = .{},
    statistics: Statistics = .{},

    /// Fuzzing needs no durability: commits only reach the page cache.
    const store_options = KeyValueStore.Options{ .durability = .deferred };

    fn init(self: *Fuzzer, allocator: Allocator, path: []const u8, options: Options, out: *std.Io.Writer) !void {
        self.* = .{
            .allocator = allocator,
            .path = path,
            .options = options,
            .out = out,
            .prng = .init(options.seed),
            .swarm = undefined,
            .store = try KeyValueStore.openWithOptions(allocator, path, store_options),
            .graph = undefined,
            .model = .init(allocator),
            .values = .init(allocator),
            .scratch = .init(allocator),
        };
        self.swarm = Swarm.choose(self.random());
        self.graph = Graph.init(&self.store, allocator);
        if (options.verbose) try out.print("seed {d}, swarm: {f}\n", .{ options.seed, self.swarm });
    }

    fn deinit(self: *Fuzzer) void {
        if (self.graph.inWriteTransaction()) self.graph.abortWrite();
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.model.deinit();
        self.store.deinit();
        self.values.deinit();
        self.scratch.deinit();
    }

    fn random(self: *Fuzzer) std.Random {
        return self.prng.random();
    }

    fn runSteps(self: *Fuzzer) !void {
        while (self.step < self.options.steps) : (self.step += 1) {
            _ = self.scratch.reset(.retain_capacity);
            if (self.swarm.transactions and !self.graph.inWriteTransaction()) try self.begin();
            self.operation = @fromBackingInt(@intCast(self.random().weightedIndex(u32, &self.swarm.weights)));
            self.statistics.performed[@backingInt(self.operation)] += 1;
            try self.perform(self.operation);
            if (!self.swarm.transactions and (self.step + 1) % self.swarm.check_every == 0) try self.verify();
        }
        _ = self.scratch.reset(.retain_capacity);
        try self.leaveTransaction();
        try self.verify();
    }

    fn perform(self: *Fuzzer, operation: Operation) !void {
        switch (operation) {
            .create_node => try self.createNode(),
            .create_node_with_id => try self.createNodeWithId(),
            .add_existing_node => try self.addExistingNode(),
            .delete_node => try self.deleteNode(false),
            .delete_node_detach => try self.deleteNode(true),
            .add_label => try self.addLabel(),
            .remove_label => try self.removeLabel(),
            .set_property => try self.setProperty(),
            .copy_property => try self.copyProperty(),
            .remove_property => try self.removeProperty(),
            .create_relationship => try self.createRelationship(),
            .delete_relationship => try self.deleteRelationship(),
            .set_relationship_property => try self.setRelationshipProperty(),
            .remove_relationship_property => try self.removeRelationshipProperty(),
            .commit => if (self.graph.inWriteTransaction()) try self.commit(),
            .abort => if (self.graph.inWriteTransaction()) try self.abort(),
            .check_inside_transaction => try self.verify(),
            .create_fulltext_index => try self.createFulltextIndex(),
            .create_index => try self.createIndex(),
            .create_constraint => try self.createConstraint(),
            .drop_definition => try self.dropDefinition(),
            .reopen => try self.reopen(),
        }
    }

    // --- Transactions ----------------------------------------------------------

    fn begin(self: *Fuzzer) !void {
        self.note("begin", .{});
        try self.expectSuccess(self.graph.beginWrite());
        self.snapshot = try self.model.clone();
    }

    fn commit(self: *Fuzzer) !void {
        self.note("commit", .{});
        try self.expectSuccess(self.graph.commitWrite());
        self.snapshot.?.deinit();
        self.snapshot = null;
        try self.verify();
    }

    fn abort(self: *Fuzzer) !void {
        self.note("abort", .{});
        self.graph.abortWrite();
        self.model.deinit();
        self.model = self.snapshot.?;
        self.snapshot = null;
        try self.verify();
    }

    /// Commits the write transaction, if one is open (before a statement
    /// that runs in a transaction of its own).
    fn leaveTransaction(self: *Fuzzer) !void {
        if (self.graph.inWriteTransaction()) try self.commit();
    }

    fn reopen(self: *Fuzzer) !void {
        try self.leaveTransaction();
        self.note("close and reopen the database", .{});
        self.store.deinit();
        self.store = try KeyValueStore.openWithOptions(self.allocator, self.path, store_options);
        self.graph = Graph.init(&self.store, self.allocator);
        try self.verify();
    }

    // --- Nodes -----------------------------------------------------------------

    fn createNode(self: *Fuzzer) !void {
        const id = try self.graph.allocateNodeId();
        self.note("create node {d}", .{id});
        if (id < self.model.node_ids_above) return self.fail("allocateNodeId handed out {d}, but ids below {d} were used", .{ id, self.model.node_ids_above });
        try self.expectSuccess(self.graph.addNode(id, ""));
        try self.model.addNode(id);
    }

    /// A node with an id of the caller's choice: past the counter, far past
    /// it, or one that was deleted.
    fn createNodeWithId(self: *Fuzzer) !void {
        const above = self.model.node_ids_above;
        const id = switch (self.random().uintLessThan(u8, 4)) {
            0 => (1 << 40) + self.random().uintLessThan(u64, 4),
            1 => self.random().uintLessThan(u64, above + 1),
            else => above + self.random().uintLessThan(u64, 50),
        };
        if (self.model.nodes.contains(id)) return self.addExistingNodeWith(id);
        const label = if (self.random().boolean()) self.pick(self.swarm.labels) else "";
        self.note("add node {d} with label '{s}'", .{ id, label });
        // A node without properties breaks no constraint.
        try self.expectSuccess(self.graph.addNode(id, label));
        try self.model.addNode(id);
        if (label.len > 0) try self.model.nodes.getPtr(id).?.labels.put(self.allocator, label, {});
    }

    fn addExistingNode(self: *Fuzzer) !void {
        const id = self.pickNode() orelse return self.createNode();
        return self.addExistingNodeWith(id);
    }

    /// `addNode` of a node that exists: only its label, if any, is new.
    fn addExistingNodeWith(self: *Fuzzer, id: NodeId) !void {
        const label = if (self.random().boolean()) self.pick(self.swarm.labels) else "";
        self.note("add existing node {d} with label '{s}'", .{ id, label });
        if (label.len == 0) return self.expectSuccess(self.graph.addNode(id, ""));
        return self.labelNode(id, label, self.graph.addNode(id, label));
    }

    fn deleteNode(self: *Fuzzer, detach: bool) !void {
        // Now and then a node that does not exist: nothing to do.
        const id = if (self.random().uintLessThan(u8, 10) == 0) self.model.node_ids_above + 7 else self.pickNode() orelse return;
        self.note("delete node {d}{s}", .{ id, if (detach) " (detach)" else "" });
        if (detach) {
            try self.expectSuccess(self.graph.deleteNodeDetach(id));
        } else {
            const connected = self.model.hasRelationships(id);
            const deleted = try self.expectOutcome(self.graph.deleteNode(id), if (connected) error.NodeStillConnected else null);
            if (!deleted) return;
        }
        self.model.deleteNode(id);
    }

    fn addLabel(self: *Fuzzer) !void {
        const id = self.pickNode() orelse return;
        const label = self.pick(self.swarm.labels);
        self.note("add label {s} to node {d}", .{ label, id });
        return self.labelNode(id, label, self.graph.addLabel(id, label));
    }

    /// Checks `result`, the outcome of giving node `id` label `label`,
    /// against the model, and applies it.
    fn labelNode(self: *Fuzzer, id: NodeId, label: []const u8, result: anyerror!void) !void {
        const node = self.model.nodes.getPtr(id).?;
        if (node.labels.contains(label)) return self.expectSuccess(result);
        var labels = try node.labels.clone(self.scratch.allocator());
        try labels.put(self.scratch.allocator(), label, {});
        const broken = try self.model.violation(self.scratch.allocator(), id, labels, node.properties);
        if (try self.expectOutcome(result, if (broken != null) error.ConstraintViolation else null)) {
            try node.labels.put(self.allocator, label, {});
        }
    }

    fn removeLabel(self: *Fuzzer) !void {
        const id = self.pickNode() orelse return;
        const node = self.model.nodes.getPtr(id).?;
        const label = if (node.labels.count() > 0 and self.random().uintLessThan(u8, 4) != 0) node.labels.keys()[self.random().uintLessThan(usize, node.labels.count())] else self.pick(self.swarm.labels);
        self.note("remove label {s} from node {d}", .{ label, id });
        try self.expectSuccess(self.graph.removeLabel(id, label));
        _ = node.labels.orderedRemove(label);
    }

    fn setProperty(self: *Fuzzer) !void {
        const id = self.pickNode() orelse return;
        return self.setPropertyTo(id, self.pick(self.swarm.properties), try self.randomValue());
    }

    /// Gives a node the value another node has (or the number equal to it,
    /// 1.0 for 1): equal values, and broken constraints, by construction.
    fn copyProperty(self: *Fuzzer) !void {
        const id = self.pickNode() orelse return;
        const other = self.model.nodes.get(self.pickNode().?).?;
        if (other.properties.count() == 0) return;
        const index = self.random().uintLessThan(usize, other.properties.count());
        const value = other.properties.values()[index];
        const equal: Value = if (self.random().boolean()) switch (value) {
            .int => |n| .{ .float = @floatFromInt(n) },
            .float => |x| if (zypherdb.value.exactInteger(x)) |n| .{ .int = n } else value,
            else => value,
        } else value;
        return self.setPropertyTo(id, other.properties.keys()[index], equal);
    }

    fn setPropertyTo(self: *Fuzzer, id: NodeId, name: []const u8, value: Value) !void {
        self.note("set node {d}.{s} = {f}", .{ id, name, ValueText{ .value = value } });
        const node = self.model.nodes.getPtr(id).?;
        const result = self.graph.setProperty(id, name, value);
        if (value == .null) {
            try self.expectSuccess(result);
            _ = node.properties.orderedRemove(name);
            return;
        }
        if (!value_encoding.isStorable(value)) return self.expectFailure(result, error.UnsupportedPropertyType);
        var properties = try node.properties.clone(self.scratch.allocator());
        try properties.put(self.scratch.allocator(), name, value);
        const broken = try self.model.violation(self.scratch.allocator(), id, node.labels, properties);
        if (try self.expectOutcome(result, if (broken != null) error.ConstraintViolation else null)) {
            try node.properties.put(self.allocator, name, value);
        }
    }

    fn removeProperty(self: *Fuzzer) !void {
        const id = self.pickNode() orelse return;
        const node = self.model.nodes.getPtr(id).?;
        const name = if (node.properties.count() > 0 and self.random().uintLessThan(u8, 4) != 0) node.properties.keys()[self.random().uintLessThan(usize, node.properties.count())] else self.pick(self.swarm.properties);
        self.note("remove node {d}.{s}", .{ id, name });
        try self.expectSuccess(self.graph.removeProperty(id, name));
        _ = node.properties.orderedRemove(name);
    }

    // --- Relationships -----------------------------------------------------------

    fn createRelationship(self: *Fuzzer) !void {
        const src = self.pickNode() orelse return self.createNode();
        // Loops and parallel relationships too.
        const dst = if (self.random().uintLessThan(u8, 8) == 0) src else self.pickNode().?;
        const edge_type = self.pick(self.swarm.types);
        const id = self.graph.addEdge(src, dst, edge_type) catch |err| return self.fail("addEdge failed: {t}", .{err});
        self.note("create relationship {d}: ({d})-[:{s}]->({d})", .{ id, src, edge_type, dst });
        if (id < self.model.relationship_ids_above) return self.fail("addEdge handed out id {d}, but ids below {d} were used", .{ id, self.model.relationship_ids_above });
        try self.model.addRelationship(id, .{ .src = src, .dst = dst, .edge_type = edge_type });
    }

    /// An existing relationship, or now and then one that does not exist.
    fn pickRelationship(self: *Fuzzer) ?RelationshipId {
        const count = self.model.relationships.count();
        if (count == 0 or self.random().uintLessThan(u8, 10) == 0) return self.model.relationship_ids_above + 3;
        return self.model.relationships.keys()[self.random().uintLessThan(usize, count)];
    }

    fn deleteRelationship(self: *Fuzzer) !void {
        const id = self.pickRelationship().?;
        self.note("delete relationship {d}", .{id});
        try self.expectSuccess(self.graph.deleteEdge(id));
        self.model.deleteRelationship(id);
    }

    fn setRelationshipProperty(self: *Fuzzer) !void {
        const id = self.pickRelationship().?;
        const name = self.pick(self.swarm.properties);
        const value = try self.randomValue();
        self.note("set relationship {d}.{s} = {f}", .{ id, name, ValueText{ .value = value } });
        const result = self.graph.setEdgeProperty(id, name, value);
        if (value != .null and !value_encoding.isStorable(value)) return self.expectFailure(result, error.UnsupportedPropertyType);
        try self.expectSuccess(result);
        // A relationship that does not exist is left alone.
        const relationship = self.model.relationships.getPtr(id) orelse return;
        if (value == .null) {
            _ = relationship.properties.orderedRemove(name);
        } else try relationship.properties.put(self.allocator, name, value);
    }

    fn removeRelationshipProperty(self: *Fuzzer) !void {
        const id = self.pickRelationship().?;
        const name = self.pick(self.swarm.properties);
        self.note("remove relationship {d}.{s}", .{ id, name });
        try self.expectSuccess(self.graph.removeEdgeProperty(id, name));
        const relationship = self.model.relationships.getPtr(id) orelse return;
        _ = relationship.properties.orderedRemove(name);
    }

    // --- Schema commands (statements of their own) -------------------------------

    fn createFulltextIndex(self: *Fuzzer) !void {
        try self.leaveTransaction();
        const scratch = self.scratch.allocator();
        const name = self.pickNewName();
        const on_relationships = self.random().boolean();
        const targets = try self.subset(if (on_relationships) self.swarm.types else self.swarm.labels, 2);
        const properties = try self.subset(self.swarm.properties, 3);
        const if_not_exists = self.random().uintLessThan(u8, 4) == 0;
        var property_list = std.ArrayList(u8).empty;
        for (properties, 0..) |property, i| try property_list.print(scratch, "{s}e.{s}", .{ if (i > 0) ", " else "", property });
        const pattern = try std.mem.join(scratch, "|", targets);
        const statement = try std.fmt.allocPrint(scratch, "CREATE FULLTEXT INDEX {s}{s} FOR {s}{s}{s} ON EACH [{s}] OPTIONS {{indexConfig: {{`fulltext.analyzer`: '{s}'}}}}", .{
            name,
            if (if_not_exists) " IF NOT EXISTS" else "",
            if (on_relationships) "()-[e:" else "(e:",
            pattern,
            if (on_relationships) "]-()" else ")",
            property_list.items,
            self.pick(&analyzers),
        });
        const exists = self.model.findDefinition(name) != null;
        const expected: ?anyerror = if (exists and !if_not_exists) error.InvalidExpression else null;
        if (try self.runStatement(statement, expected) and !exists) {
            try self.model.definitions.append(self.allocator, .{ .name = name, .kind = .fulltext, .labels_or_types = targets, .properties = properties });
        }
    }

    /// A property index on one label or relationship type and one property
    /// (the integrity checker checks its entries).
    fn createIndex(self: *Fuzzer) !void {
        try self.leaveTransaction();
        const scratch = self.scratch.allocator();
        const name = self.pickNewName();
        const on_relationships = self.random().boolean();
        const target = try scratch.dupe([]const u8, &.{self.pick(if (on_relationships) self.swarm.types else self.swarm.labels)});
        const property = try scratch.dupe([]const u8, &.{self.pick(self.swarm.properties)});
        const if_not_exists = self.random().uintLessThan(u8, 4) == 0;
        const statement = try std.fmt.allocPrint(scratch, "CREATE INDEX {s}{s} FOR {s}{s}{s} ON (e.{s})", .{
            name,
            if (if_not_exists) " IF NOT EXISTS" else "",
            if (on_relationships) "()-[e:" else "(e:",
            target[0],
            if (on_relationships) "]-()" else ")",
            property[0],
        });
        const exists = self.model.findDefinition(name) != null;
        const expected: ?anyerror = if (exists and !if_not_exists) error.InvalidExpression else null;
        if (try self.runStatement(statement, expected) and !exists) {
            const kept = self.values.allocator();
            try self.model.definitions.append(self.allocator, .{ .name = name, .kind = .range, .labels_or_types = try kept.dupe([]const u8, target), .properties = try kept.dupe([]const u8, property) });
        }
    }

    fn createConstraint(self: *Fuzzer) !void {
        try self.leaveTransaction();
        const scratch = self.scratch.allocator();
        const name = self.pickNewName();
        const label = try scratch.dupe([]const u8, &.{self.pick(self.swarm.labels)});
        const properties = try self.subset(self.swarm.properties, 2);
        const if_not_exists = self.random().uintLessThan(u8, 4) == 0;
        var property_list = std.ArrayList(u8).empty;
        for (properties, 0..) |property, i| try property_list.print(scratch, "{s}n.{s}", .{ if (i > 0) ", " else "", property });
        const statement = try std.fmt.allocPrint(scratch, "CREATE CONSTRAINT {s}{s} FOR (n:{s}) REQUIRE ({s}) IS UNIQUE", .{ name, if (if_not_exists) " IF NOT EXISTS" else "", label[0], property_list.items });
        const definition = model_module.Definition{ .name = name, .kind = .unique, .labels_or_types = label, .properties = properties };
        const exists = self.model.findDefinition(name) != null;
        const expected: ?anyerror = if (exists)
            (if (if_not_exists) null else error.InvalidExpression)
        else if (try self.model.broken(scratch, definition))
            error.ConstraintViolation
        else
            null;
        if (try self.runStatement(statement, expected) and !exists) {
            var kept = definition;
            kept.labels_or_types = try self.values.allocator().dupe([]const u8, label);
            try self.model.definitions.append(self.allocator, kept);
        }
    }

    fn dropDefinition(self: *Fuzzer) !void {
        try self.leaveTransaction();
        const name = self.pick(&definition_names);
        const found = self.model.findDefinition(name);
        // Mostly the right command for what the name is.
        const as_constraint = if (found != null and self.random().uintLessThan(u8, 4) != 0) self.model.definitions.items[found.?].kind == .unique else self.random().boolean();
        const if_exists = self.random().uintLessThan(u8, 4) == 0;
        const statement = try std.fmt.allocPrint(self.scratch.allocator(), "DROP {s} {s}{s}", .{ if (as_constraint) "CONSTRAINT" else "INDEX", name, if (if_exists) " IF EXISTS" else "" });
        const expected: ?anyerror = if (found) |i|
            (if ((self.model.definitions.items[i].kind == .unique) != as_constraint) error.InvalidExpression else null)
        else if (if_exists) null else error.InvalidExpression;
        if (try self.runStatement(statement, expected)) {
            if (found) |i| _ = self.model.definitions.orderedRemove(i);
        }
    }

    /// Runs a statement as the executor does; true if it succeeded (as
    /// `expected` said it must, or fails the run).
    fn runStatement(self: *Fuzzer, statement: []const u8, expected: ?anyerror) !bool {
        self.note("run: {s}", .{statement});
        var ast = zypherdb.Ast.init(self.allocator);
        defer ast.deinit();
        const root = zypherdb.parser.parse(&ast, statement, null) catch |err| return self.fail("cannot parse the statement: {t}", .{err});
        var executor = zypherdb.Executor.init(&ast, &self.graph, self.scratch.allocator());
        const result: anyerror!void = if (executor.run(root)) |_| {} else |err| err;
        const succeeded = try self.expectOutcome(result, expected);
        try self.verify();
        return succeeded;
    }

    // --- Checks ------------------------------------------------------------------

    /// The database equals the model, and its derived structures agree.
    fn verify(self: *Fuzzer) !void {
        var report = try zypherdb.integrity.check(&self.graph, self.allocator);
        defer report.deinit();
        if (!report.ok()) return self.fail("{f}", .{report});
        const pools = storage_compare.Pools{ .labels = self.swarm.labels, .types = self.swarm.types };
        if (try storage_compare.difference(self.scratch.allocator(), &self.graph, &self.model, pools)) |difference| {
            return self.fail("the database differs from the model: {s}", .{difference});
        }
    }

    /// Fails the run unless `result` is the failure `expected` (or success,
    /// for null). True if it succeeded.
    fn expectOutcome(self: *Fuzzer, result: anyerror!void, expected: ?anyerror) !bool {
        if (result) |_| {
            if (expected) |err| return self.fail("succeeded, but it must fail with {t}", .{err});
            return true;
        } else |err| {
            if (expected) |wanted| if (err == wanted) {
                self.statistics.refuse(self.operation, err);
                return false;
            };
            return self.fail("failed with {t}, expected {s}", .{ err, if (expected) |wanted| @errorName(wanted) else "success" });
        }
    }

    fn expectSuccess(self: *Fuzzer, result: anyerror!void) !void {
        _ = try self.expectOutcome(result, null);
    }

    fn expectFailure(self: *Fuzzer, result: anyerror!void, expected: anyerror) !void {
        _ = try self.expectOutcome(result, expected);
    }

    fn fail(self: *Fuzzer, comptime fmt: []const u8, args: anytype) error{ FuzzFailed, WriteFailed } {
        const out = self.out;
        try out.print("\nstorage fuzzer FAILED at step {d} of seed {d} ({s})\n", .{ self.step, self.options.seed, zypherdb.storage_engine });
        try out.print("reproduce: zig build fuzz -Dstorage-engine={s} -- storage --seed {d} --steps {d} --verbose\n", .{ zypherdb.storage_engine, self.options.seed, self.step + 1 });
        try out.print("swarm: {f}\nlast operations:\n{f}problem: ", .{ self.swarm, self.history });
        try out.print(fmt, args);
        try out.writeAll("\n");
        try out.flush();
        return error.FuzzFailed;
    }

    fn note(self: *Fuzzer, comptime fmt: []const u8, args: anytype) void {
        self.history.add(self.step, fmt, args);
        if (self.options.verbose) {
            self.out.print("[{d}] ", .{self.step}) catch {};
            self.out.print(fmt ++ "\n", args) catch {};
        }
    }

    // --- Choices ---------------------------------------------------------------

    fn pick(self: *Fuzzer, items: []const []const u8) []const u8 {
        return items[self.random().uintLessThan(usize, items.len)];
    }

    fn randomValue(self: *Fuzzer) Allocator.Error!Value {
        if (self.swarm.narrow_values) return values.narrowValue(self.random());
        return values.randomValue(self.random(), self.values.allocator());
    }

    /// Mostly a name no index or constraint has, else any.
    fn pickNewName(self: *Fuzzer) []const u8 {
        if (self.random().uintLessThan(u8, 4) != 0) {
            for (definition_names) |name| if (self.model.findDefinition(name) == null) return name;
        }
        return self.pick(&definition_names);
    }

    fn pickNode(self: *Fuzzer) ?NodeId {
        const count = self.model.nodes.count();
        if (count == 0) return null;
        return self.model.nodes.keys()[self.random().uintLessThan(usize, count)];
    }

    /// One to `most` distinct items of `pool`, in pool order (kept for the run).
    fn subset(self: *Fuzzer, pool: []const []const u8, most: usize) Allocator.Error![]const []const u8 {
        const wanted = self.random().intRangeAtMost(usize, 1, @min(most, pool.len));
        var chosen = std.ArrayList([]const u8).empty;
        var start = self.random().uintLessThan(usize, pool.len);
        while (chosen.items.len < wanted) : (start = (start + 1) % pool.len) try chosen.append(self.values.allocator(), pool[start]);
        return chosen.items;
    }
};

/// The last operations, for a failure's report.
const History = struct {
    const size = 40;
    const line_length = 240;

    lines: [size][line_length]u8 = undefined,
    lengths: [size]usize = @splat(0),
    steps: [size]u32 = @splat(0),
    next: usize = 0,
    count: usize = 0,

    fn add(self: *History, step: u32, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.lines[self.next], fmt, args) catch self.lines[self.next][0..];
        self.lengths[self.next] = written.len;
        self.steps[self.next] = step;
        self.next = (self.next + 1) % size;
        self.count = @min(self.count + 1, size);
    }

    pub fn format(self: History, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (0..self.count) |i| {
            const at = (self.next + size - self.count + i) % size;
            try writer.print("  [{d}] {s}\n", .{ self.steps[at], self.lines[at][0..self.lengths[at]] });
        }
    }
};

/// A value as an operation's log shows it.
const ValueText = struct {
    value: Value,

    pub fn format(self: ValueText, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.value) {
            .string => |s| try writer.print("'{s}'", .{if (s.len > 40) s[0..40] else s}),
            .int => |n| try writer.print("{d}", .{n}),
            .float => |x| try writer.print("{e}", .{x}),
            .boolean => |b| try writer.print("{}", .{b}),
            .null => try writer.writeAll("null"),
            .list => |items| try writer.print("a list of {d}", .{items.len}),
            .map => |entries| try writer.print("a map of {d}", .{entries.len}),
            else => try writer.print("a {t}", .{self.value}),
        }
    }
};
