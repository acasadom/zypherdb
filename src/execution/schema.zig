//! Schema commands: CREATE [FULLTEXT|RANGE|VECTOR] INDEX, CREATE CONSTRAINT, DROP
//! INDEX / CONSTRAINT, SHOW INDEXES / CONSTRAINTS. Each runs as a statement
//! of its own, in its own transaction. `CALL db.awaitIndexes()` runs here
//! too, on its own, in a read transaction per look.

const std = @import("std");
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const fulltext = @import("../storage/fulltext.zig");
const fulltext_postings = @import("../storage/fulltext_postings.zig");
const constraints = @import("../storage/constraints.zig");
const property_indexes = @import("../storage/property_indexes.zig");
const vector_index = @import("../storage/vector_index.zig");
const vector_population = @import("../storage/vector_population.zig");
const similarity = @import("../vector/similarity.zig");
const layout = @import("../storage/layout.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Row = Executor.Row;
const Bindings = @import("bindings.zig").Bindings;
const ExpressionProgram = @import("../planning/expression_program.zig").Program;
const expressions = @import("expressions.zig");
const requireStorableName = @import("writes.zig").requireStorableName;

comptime {
    // The parser joins a document path's names as the indexes split them.
    std.debug.assert(@import("../query/ast.zig").path_separator == property_indexes.path_separator);
    // A generated name is shortened to what a name may hold.
    std.debug.assert(@import("../query/schema_parser.zig").max_name_length == layout.max_name_length);
}

/// The analyzers a full-text index can use.
pub const analyzers = [_][]const u8{ "standard", "english", "spanish" };

pub fn isSchemaCommand(executor: *Executor, root: Index) bool {
    return switch (executor.ast.kind(root)) {
        .create_fulltext_index, .create_index, .create_vector_index, .create_constraint, .drop_index, .drop_constraint, .show_indexes, .show_constraints => true,
        .query => awaitsIndexes(executor.ast, root),
        else => false,
    };
}

/// True if query `root` is `CALL db.awaitIndexes(...)` and nothing else.
pub fn awaitsIndexes(ast: *const Ast, root: Index) bool {
    const clauses = ast.nodeChildren(root);
    if (clauses.len != 1 or ast.kind(clauses[0]) != .call_clause) return false;
    return std.mem.eql(u8, ast.data(clauses[0]).call.procedure, "db.awaitIndexes");
}

/// Runs a schema command; SHOW returns rows, the others none.
pub fn run(executor: *Executor, root: Index) ExecutionError![]const Row {
    const graph = executor.graph;
    switch (executor.ast.kind(root)) {
        .query => return awaitIndexes(executor, root),
        .show_indexes, .show_constraints => {
            try graph.beginRead();
            defer graph.commitRead();
            return if (executor.ast.kind(root) == .show_indexes) showIndexes(executor, executor.ast.data(root).show_indexes) else showConstraints(executor);
        },
        else => {},
    }
    try graph.beginWrite();
    errdefer graph.abortWrite();
    switch (executor.ast.kind(root)) {
        .create_fulltext_index => try create(executor, root, .fulltext),
        .create_index => try create(executor, root, .range),
        .create_vector_index => try create(executor, root, .vector),
        .create_constraint => try create(executor, root, .unique),
        .drop_index => try drop(executor, root, "index"),
        .drop_constraint => try drop(executor, root, "constraint"),
        else => unreachable,
    }
    try graph.commitWrite();
    return &.{};
}

/// `DROP INDEX` drops an index, `DROP CONSTRAINT` a constraint (one
/// namespace for both names).
fn drop(executor: *Executor, root: Index, comptime what: []const u8) ExecutionError!void {
    const graph = executor.graph;
    const command = executor.ast.data(root).drop_index;
    const found = try fulltext.find(graph, command.name, executor.allocator) orelse {
        if (command.if_exists) return;
        executor.fail(.invalid_expression, "there is no " ++ what ++ " named '{s}'", .{command.name});
        return error.InvalidExpression;
    };
    const is_constraint = found.kind == .unique;
    if (is_constraint != std.mem.eql(u8, what, "constraint")) {
        executor.fail(.invalid_expression, "'{s}' is {s}: use DROP {s}", .{ command.name, if (is_constraint) "a constraint" else "an index", if (is_constraint) "CONSTRAINT" else "INDEX" });
        return error.InvalidExpression;
    }
    if (found.kind == .fulltext) try fulltext_postings.clear(graph, command.name);
    if (found.hasPropertyIndex()) try property_indexes.clear(graph, found.index_id);
    if (found.kind == .vector) try vector_index.clear(graph, found.index_id);
    _ = try fulltext.drop(graph, command.name);
}

fn create(executor: *Executor, root: Index, kind: fulltext.Kind) ExecutionError!void {
    const command = executor.ast.data(root).schema_definition;
    // Names go into keys, where 0x00 ends them ("f" would find "f\x00g").
    // (A generated name holds the labels and properties: check them first.)
    for (command.labels_or_types) |name| try requireStorableName(executor, if (command.relationships) "relationship type" else "label", name);
    for (command.properties) |property| {
        // A range index's property may be a document path (its names joined
        // by path_separator: the parser refuses it inside a name).
        if (kind != .range) try requireStorableName(executor, "property name", property);
        var names = std.mem.splitScalar(u8, property, property_indexes.path_separator);
        if (kind == .range) while (names.next()) |name| try requireStorableName(executor, "property name", name);
        // A path is stored as one name.
        if (property.len > layout.max_name_length) {
            executor.fail(.invalid_expression, "a document path cannot be longer than {d} bytes", .{layout.max_name_length});
            return error.InvalidExpression;
        }
    }
    try requireStorableName(executor, "name for an index or constraint", command.name);
    const max_properties: usize = if (kind == .fulltext) fulltext.max_fulltext_properties else fulltext.max_names;
    if (command.labels_or_types.len > fulltext.max_names or command.properties.len > max_properties) {
        executor.fail(.invalid_expression, "an index or constraint can name at most {d} labels or types and {d} properties", .{ fulltext.max_names, max_properties });
        return error.InvalidExpression;
    }
    if (try fulltext.find(executor.graph, command.name, executor.allocator)) |existing| {
        if (command.if_not_exists) return;
        executor.fail(.invalid_expression, "{s} named '{s}' already exists", .{ if (existing.kind == .unique) "a constraint" else "an index", command.name });
        return error.InvalidExpression;
    }
    if (kind == .range and command.properties.len > 1) {
        executor.fail(.invalid_expression, "an index on several properties is not supported: create one index per property", .{});
        return error.InvalidExpression;
    }
    const children = executor.ast.nodeChildren(root);
    const options: ?Value = if (children.len > 0) try evaluateOptions(executor, children[0]) else null;
    const analyzer = if (kind != .fulltext) "" else if (options) |map| try analyzerOption(executor, map) else "standard";
    var definition = fulltext.Definition{
        .name = command.name,
        .kind = kind,
        .entity = if (command.relationships) .relationships else .nodes,
        .analyzer = analyzer,
        .labels_or_types = command.labels_or_types,
        .properties = command.properties,
    };
    if (kind == .vector) {
        const config = try vectorOptions(executor, options);
        definition.dimensions = config.dimensions;
        definition.similarity = config.similarity;
    }
    const stored = try fulltext.create(executor.graph, definition);
    // A constraint the graph already breaks is refused (the transaction is
    // aborted); a vector index fails later instead, as it is populated.
    populate(executor.graph, stored) catch |err| {
        if (err == error.ConstraintViolation) executor.fail(.constraint_violation, "{s}", .{executor.graph.violationMessage()});
        return err;
    };
}

/// Indexes what the graph holds already for a new definition (a constraint
/// is checked on its index, once built), or starts a vector index's
/// population in the background.
fn populate(graph: *@import("../storage/graph.zig").Graph, stored: fulltext.Definition) @import("../storage/key_value_store.zig").StorageError!void {
    switch (stored.kind) {
        .fulltext => try fulltext_postings.populate(graph, stored),
        .range => try property_indexes.populate(graph, stored),
        .unique => {
            try property_indexes.populate(graph, stored);
            try constraints.checkExisting(graph, stored);
        },
        .vector => try vector_population.start(graph, stored),
    }
}

/// How long `db.awaitIndexes()` waits without an argument, as in Neo4j.
const default_await_seconds = 300;
/// How often it looks at the indexes again.
const await_poll_interval = std.Io.Duration.fromMilliseconds(10);

/// `CALL db.awaitIndexes([seconds])`: waits until no vector index is being
/// populated (the other kinds are populated as they are created), for at
/// most `seconds`, 300 unless given. It looks at what is committed every
/// few milliseconds, each time in a read transaction of its own, so it
/// holds no old snapshot as it waits. A failed index, or one still
/// populating when the time is up, is an error. It refuses to wait in a
/// write transaction: populating needs the writer.
fn awaitIndexes(executor: *Executor, root: Index) ExecutionError![]const Row {
    try executor.check(root);
    if (executor.graph.inWriteTransaction()) {
        executor.fail(.invalid_expression, "db.awaitIndexes() cannot wait in a write transaction: populating an index needs the writer it holds", .{});
        return error.InvalidExpression;
    }
    const seconds = try awaitSeconds(executor, root);
    const io = std.Io.Threaded.global_single_threaded.io();
    const deadline = std.Io.Clock.awake.now(io).nanoseconds +| @as(i96, seconds) * std.time.ns_per_s;
    // Each look in memory of its own: a long wait makes many.
    var look_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer look_arena.deinit();
    while (true) {
        _ = look_arena.reset(.retain_capacity);
        const populating = try lookForPopulating(executor, look_arena.allocator()) orelse return &.{};
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) {
            executor.fail(.index_populating, "vector index '{s}' is still being populated ({d:.1}% done) after waiting {d} s", .{ populating.name, populating.percent, seconds });
            return error.IndexPopulating;
        }
        io.sleep(await_poll_interval, .awake) catch {};
    }
}

/// The seconds `db.awaitIndexes()` was given: a whole number, 0 or more.
fn awaitSeconds(executor: *Executor, root: Index) ExecutionError!u32 {
    const call = executor.ast.nodeChildren(root)[0];
    const data = executor.ast.data(call).call;
    if (data.argument_count == 0) return default_await_seconds;
    const seconds = try evaluateOptions(executor, executor.ast.nodeChildren(call)[0]);
    if (seconds != .int) {
        executor.fail(.type_mismatch, "db.awaitIndexes() takes a number of seconds, as an integer", .{});
        return error.TypeMismatch;
    }
    if (seconds.int < 0) {
        executor.fail(.invalid_expression, "db.awaitIndexes() needs a number of seconds of at least 0, not {d}", .{seconds.int});
        return error.InvalidExpression;
    }
    return std.math.cast(u32, seconds.int) orelse std.math.maxInt(u32);
}

/// A vector index being populated now, and how far it got; null if none
/// is. A failed one is an error.
fn lookForPopulating(executor: *Executor, allocator: std.mem.Allocator) ExecutionError!?struct { name: []const u8, percent: f64 } {
    const graph = executor.graph;
    try graph.beginRead();
    defer graph.commitRead();
    for (try fulltext.allOfKind(graph, allocator, .vector)) |definition| {
        switch (try vector_index.state(graph, allocator, definition.index_id)) {
            .online => {},
            .populating => |progress| return .{ .name = definition.name, .percent = try populationPercent(graph, definition, progress) },
            .failed => |failure| {
                const message = try vectorFailureMessage(allocator, definition, failure);
                executor.fail(.invalid_expression, "vector index '{s}' failed ({s}): correct the data, then drop it and create it again", .{ definition.name, message });
                return error.InvalidExpression;
            },
        }
    }
    return null;
}

/// The value of an OPTIONS map.
fn evaluateOptions(executor: *Executor, options_expression: Index) ExecutionError!Value {
    // A schema command has no plan: its options are compiled here.
    const no_chains: std.AutoHashMapUnmanaged(Index, u32) = .empty;
    try executor.useExpressions(try ExpressionProgram.compile(executor.allocator, executor.ast, &.{}, &no_chains));
    var empty = try Bindings.init(executor.allocator, 0);
    return expressions.evaluate(executor, options_expression, &empty);
}

/// `OPTIONS {indexConfig: {`vector.dimensions`: N, `vector.similarity_function`: 'cosine'}}`:
/// the dimensions are required, the similarity is cosine unless named.
fn vectorOptions(executor: *Executor, options: ?Value) ExecutionError!struct { dimensions: u16, similarity: similarity.Similarity } {
    var dimensions: ?i64 = null;
    var chosen: similarity.Similarity = .cosine;
    if (options) |map| for (map.map) |option| {
        if (!std.mem.eql(u8, option.key, "indexConfig") or option.value != .map) return unknownVectorOption(executor, option.key);
        for (option.value.map) |setting| {
            if (std.mem.eql(u8, setting.key, "vector.dimensions")) {
                if (setting.value != .int) return unknownVectorOption(executor, setting.key);
                dimensions = setting.value.int;
            } else if (std.mem.eql(u8, setting.key, "vector.similarity_function")) {
                chosen = if (setting.value == .string) similarity.Similarity.parse(setting.value.string) orelse {
                    executor.fail(.invalid_expression, "unknown vector similarity function '{s}' (available: cosine, euclidean)", .{setting.value.string});
                    return error.InvalidExpression;
                } else return unknownVectorOption(executor, setting.key);
            } else {
                return unknownVectorOption(executor, setting.key);
            }
        }
    };
    const count = dimensions orelse {
        executor.fail(.invalid_expression, "a vector index needs its dimensions: OPTIONS {{indexConfig: {{`vector.dimensions`: N}}}}", .{});
        return error.InvalidExpression;
    };
    if (count < 1 or count > similarity.max_dimensions) {
        executor.fail(.invalid_expression, "`vector.dimensions` must be between 1 and {d}, not {d}", .{ similarity.max_dimensions, count });
        return error.InvalidExpression;
    }
    return .{ .dimensions = @intCast(count), .similarity = chosen };
}

fn unknownVectorOption(executor: *Executor, key: []const u8) ExecutionError {
    executor.fail(.invalid_expression, "unknown index option '{s}' (expected indexConfig: {{`vector.dimensions`: N, `vector.similarity_function`: 'cosine' or 'euclidean'}})", .{key});
    return error.InvalidExpression;
}

/// The analyzer named in `OPTIONS {indexConfig: {`fulltext.analyzer`: 'spanish'}}`.
fn analyzerOption(executor: *Executor, options: Value) ExecutionError![]const u8 {
    var analyzer: []const u8 = "standard";
    for (options.map) |option| {
        if (!std.mem.eql(u8, option.key, "indexConfig")) return unknownOption(executor, option.key);
        if (option.value != .map) return unknownOption(executor, option.key);
        for (option.value.map) |setting| {
            if (std.mem.eql(u8, setting.key, "fulltext.analyzer")) {
                if (setting.value != .string) return unknownOption(executor, setting.key);
                analyzer = setting.value.string;
            } else if (!std.mem.eql(u8, setting.key, "fulltext.eventually_consistent")) {
                return unknownOption(executor, setting.key);
            }
        }
    }
    for (analyzers) |known| if (std.mem.eql(u8, known, analyzer)) return known;
    executor.fail(.invalid_expression, "unknown full-text analyzer '{s}' (available: standard, english, spanish)", .{analyzer});
    return error.InvalidExpression;
}

fn unknownOption(executor: *Executor, key: []const u8) ExecutionError {
    executor.fail(.invalid_expression, "unknown index option '{s}' (expected indexConfig: {{`fulltext.analyzer`: ...}})", .{key});
    return error.InvalidExpression;
}

/// The columns of SHOW INDEXES (`showIndexes`) and SHOW CONSTRAINTS
/// (`showConstraints`), named as Neo4j 5 names them.
pub const index_columns = [_][]const u8{ "name", "type", "entityType", "labelsOrTypes", "properties", "owningConstraint", "options" };
/// SHOW VECTOR INDEXES adds where each index is: `state` (POPULATING,
/// ONLINE or FAILED), `populationPercent`, and `failureMessage` (null but
/// for a failed one).
pub const vector_index_columns = index_columns ++ [_][]const u8{ "state", "populationPercent", "failureMessage" };
pub const constraint_columns = [_][]const u8{ "name", "type", "entityType", "labelsOrTypes", "properties", "ownedIndex" };

/// One row per index (full-text or range, a uniqueness constraint's
/// included, as in Neo4j 5): name, type, entityType, labelsOrTypes,
/// properties (a document path as `a.b`), owningConstraint (the
/// constraint's name, else null), options.
fn showIndexes(executor: *Executor, which: @FieldType(@import("../query/ast.zig").Data, "show_indexes")) ExecutionError![]const Row {
    const allocator = executor.allocator;
    var rows = std.ArrayList(Row).empty;
    for (try fulltext.all(executor.graph, allocator)) |definition| {
        switch (definition.kind) {
            .fulltext => if (which != .all and which != .fulltext) continue,
            .range, .unique => if (which != .all and which != .range) continue,
            .vector => if (which != .all and which != .vector) continue,
        }
        // A constraint's index keys its first property (constraints.zig).
        const properties = if (definition.kind == .unique) definition.properties[0..1] else definition.properties;
        var row = Row.empty;
        try row.append(allocator, .{ .string = definition.name });
        try row.append(allocator, .{ .string = switch (definition.kind) {
            .fulltext => "FULLTEXT",
            .range, .unique => "RANGE",
            .vector => "VECTOR",
        } });
        try row.append(allocator, .{ .string = if (definition.entity == .nodes) "NODE" else "RELATIONSHIP" });
        try row.append(allocator, try stringList(allocator, definition.labels_or_types));
        try row.append(allocator, try propertyList(allocator, properties));
        try row.append(allocator, if (definition.kind == .unique) .{ .string = definition.name } else .null);
        const config: []const MapEntry = switch (definition.kind) {
            .fulltext => try allocator.dupe(MapEntry, &.{.{ .key = "fulltext.analyzer", .value = .{ .string = definition.analyzer } }}),
            .vector => try allocator.dupe(MapEntry, &.{
                .{ .key = "vector.dimensions", .value = .{ .int = definition.dimensions } },
                .{ .key = "vector.similarity_function", .value = .{ .string = definition.similarity.name() } },
            }),
            .range, .unique => &.{},
        };
        try row.append(allocator, .{ .map = try allocator.dupe(MapEntry, &.{.{ .key = "indexConfig", .value = .{ .map = config } }}) });
        if (which == .vector) try appendVectorState(executor, &row, definition);
        try rows.append(allocator, row);
    }
    return rows.items;
}

/// A vector index's state, how much of it is populated, and why it failed.
fn appendVectorState(executor: *Executor, row: *Row, definition: fulltext.Definition) ExecutionError!void {
    const allocator = executor.allocator;
    const graph = executor.graph;
    switch (try vector_index.state(graph, allocator, definition.index_id)) {
        .populating => |progress| {
            try row.append(allocator, .{ .string = "POPULATING" });
            try row.append(allocator, .{ .float = try populationPercent(graph, definition, progress) });
            try row.append(allocator, .null);
        },
        .online => {
            try row.append(allocator, .{ .string = "ONLINE" });
            try row.append(allocator, .{ .float = 100 });
            try row.append(allocator, .null);
        },
        .failed => |failure| {
            try row.append(allocator, .{ .string = "FAILED" });
            try row.append(allocator, .{ .float = 0 });
            try row.append(allocator, .{ .string = try vectorFailureMessage(allocator, definition, failure) });
        },
    }
}

/// How much of a populating index is done, from the entities it looked at
/// and those of its label or type now: below 100 until it is online.
pub fn populationPercent(graph: *@import("../storage/graph.zig").Graph, definition: fulltext.Definition, progress: vector_index.Progress) ExecutionError!f64 {
    const total = switch (definition.entity) {
        .nodes => try graph.labelCount(definition.labels_or_types[0]),
        .relationships => try graph.edgeTypeCount(definition.labels_or_types[0]),
    };
    if (total == 0) return 0;
    const percent = 100 * @as(f64, @floatFromInt(progress.examined)) / @as(f64, @floatFromInt(total));
    return @min(percent, 99.9);
}

/// "node 5: its v has 2 elements, and the index takes a list of 3 numbers".
pub fn vectorFailureMessage(allocator: std.mem.Allocator, definition: fulltext.Definition, failure: vector_index.Failure) std.mem.Allocator.Error![]const u8 {
    const what = if (definition.entity == .nodes) "node" else "relationship";
    return std.fmt.allocPrint(allocator, "{s} {d}: its {s} {s}, and the index takes a list of {d} numbers", .{ what, failure.entity, definition.properties[0], failure.reason, definition.dimensions });
}

/// One row per constraint: name, type, entityType, labelsOrTypes,
/// properties, ownedIndex (its index, listed by SHOW INDEXES: same name).
fn showConstraints(executor: *Executor) ExecutionError![]const Row {
    const allocator = executor.allocator;
    var rows = std.ArrayList(Row).empty;
    for (try fulltext.allOfKind(executor.graph, allocator, .unique)) |definition| {
        var row = Row.empty;
        try row.append(allocator, .{ .string = definition.name });
        try row.append(allocator, .{ .string = "UNIQUENESS" });
        try row.append(allocator, .{ .string = "NODE" });
        try row.append(allocator, try stringList(allocator, definition.labels_or_types));
        try row.append(allocator, try propertyList(allocator, definition.properties));
        try row.append(allocator, .{ .string = definition.name });
        try rows.append(allocator, row);
    }
    return rows.items;
}

fn stringList(allocator: std.mem.Allocator, strings: []const []const u8) std.mem.Allocator.Error!Value {
    const items = try allocator.alloc(Value, strings.len);
    for (items, strings) |*item, string| item.* = .{ .string = string };
    return .{ .list = items };
}

/// The properties of a definition, a document path written `a.b`.
fn propertyList(allocator: std.mem.Allocator, properties: []const []const u8) std.mem.Allocator.Error!Value {
    const items = try allocator.alloc(Value, properties.len);
    for (items, properties) |*item, property| {
        const text = try allocator.dupe(u8, property);
        std.mem.replaceScalar(u8, text, property_indexes.path_separator, '.');
        item.* = .{ .string = text };
    }
    return .{ .list = items };
}
