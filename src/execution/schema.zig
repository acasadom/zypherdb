//! Schema commands: CREATE [FULLTEXT|RANGE] INDEX, CREATE CONSTRAINT, DROP
//! INDEX / CONSTRAINT, SHOW INDEXES / CONSTRAINTS. Each runs as a statement
//! of its own, in its own transaction.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const fulltext = @import("../storage/fulltext.zig");
const fulltext_postings = @import("../storage/fulltext_postings.zig");
const constraints = @import("../storage/constraints.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Row = Executor.Row;
const Bindings = @import("bindings.zig").Bindings;
const ExpressionProgram = @import("../planning/expression_program.zig").Program;
const expressions = @import("expressions.zig");
const requireStorableName = @import("writes.zig").requireStorableName;

/// The analyzers a full-text index can use.
pub const analyzers = [_][]const u8{ "standard", "english", "spanish" };

pub fn isSchemaCommand(executor: *Executor, root: Index) bool {
    return switch (executor.ast.kind(root)) {
        .create_fulltext_index, .create_index, .create_constraint, .drop_index, .drop_constraint, .show_indexes, .show_constraints => true,
        else => false,
    };
}

/// Runs a schema command; SHOW returns rows, the others none.
pub fn run(executor: *Executor, root: Index) ExecutionError![]const Row {
    const graph = executor.graph;
    switch (executor.ast.kind(root)) {
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
    _ = try fulltext.drop(graph, command.name);
}

fn create(executor: *Executor, root: Index, kind: fulltext.Kind) ExecutionError!void {
    const command = executor.ast.data(root).schema_definition;
    // Names go into keys, where 0x00 ends them ("f" would find "f\x00g").
    // (A generated name holds the labels and properties: check them first.)
    for (command.labels_or_types) |name| try requireStorableName(executor, if (command.relationships) "relationship type" else "label", name);
    for (command.properties) |name| try requireStorableName(executor, "property name", name);
    try requireStorableName(executor, "name for an index or constraint", command.name);
    if (try fulltext.find(executor.graph, command.name, executor.allocator)) |existing| {
        if (command.if_not_exists) return;
        executor.fail(.invalid_expression, "{s} named '{s}' already exists", .{ if (existing.kind == .unique) "a constraint" else "an index", command.name });
        return error.InvalidExpression;
    }
    const children = executor.ast.nodeChildren(root);
    const analyzer = if (kind != .fulltext) "" else if (children.len > 0) try analyzerOption(executor, children[0]) else "standard";
    const definition = fulltext.Definition{
        .name = command.name,
        .kind = kind,
        .entity = if (command.relationships) .relationships else .nodes,
        .analyzer = analyzer,
        .labels_or_types = command.labels_or_types,
        .properties = command.properties,
    };
    switch (kind) {
        // A constraint the graph already breaks is refused.
        .unique => constraints.checkExisting(executor.graph, definition) catch |err| {
            if (err == error.ConstraintViolation) executor.fail(.constraint_violation, "{s}", .{executor.graph.violationMessage()});
            return err;
        },
        .fulltext, .range => {},
    }
    try fulltext.create(executor.graph, definition);
    // Index what the graph holds already.
    if (kind == .fulltext) try fulltext_postings.populate(executor.graph, definition);
}

/// The analyzer named in `OPTIONS {indexConfig: {`fulltext.analyzer`: 'spanish'}}`.
fn analyzerOption(executor: *Executor, options_expression: Index) ExecutionError![]const u8 {
    // A schema command has no plan: its options are compiled here.
    const no_chains: std.AutoHashMapUnmanaged(Index, u32) = .empty;
    try executor.useExpressions(try ExpressionProgram.compile(executor.allocator, executor.ast, &.{}, &no_chains));
    var empty = try Bindings.init(executor.allocator, 0);
    const options = try expressions.evaluate(executor, options_expression, &empty);
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

/// One row per index (full-text, or range: declared, and doing nothing):
/// name, type, entityType, labelsOrTypes, properties, options.
fn showIndexes(executor: *Executor, which: @FieldType(@import("../query/ast.zig").Data, "show_indexes")) ExecutionError![]const Row {
    const allocator = executor.allocator;
    var rows = std.ArrayList(Row).empty;
    for (try fulltext.all(executor.graph, allocator)) |definition| {
        switch (definition.kind) {
            .unique => continue,
            .fulltext => if (which == .range) continue,
            .range => if (which == .fulltext) continue,
        }
        var row = Row.empty;
        try row.append(allocator, .{ .string = definition.name });
        try row.append(allocator, .{ .string = if (definition.kind == .fulltext) "FULLTEXT" else "RANGE" });
        try row.append(allocator, .{ .string = if (definition.entity == .nodes) "NODE" else "RELATIONSHIP" });
        try row.append(allocator, try stringList(allocator, definition.labels_or_types));
        try row.append(allocator, try stringList(allocator, definition.properties));
        const config: []const MapEntry = if (definition.kind == .fulltext)
            try allocator.dupe(MapEntry, &.{.{ .key = "fulltext.analyzer", .value = .{ .string = definition.analyzer } }})
        else
            &.{};
        try row.append(allocator, .{ .map = try allocator.dupe(MapEntry, &.{.{ .key = "indexConfig", .value = .{ .map = config } }}) });
        try rows.append(allocator, row);
    }
    return rows.items;
}

/// One row per constraint: name, type, entityType, labelsOrTypes, properties.
fn showConstraints(executor: *Executor) ExecutionError![]const Row {
    const allocator = executor.allocator;
    var rows = std.ArrayList(Row).empty;
    for (try fulltext.allOfKind(executor.graph, allocator, .unique)) |definition| {
        var row = Row.empty;
        try row.append(allocator, .{ .string = definition.name });
        try row.append(allocator, .{ .string = "UNIQUENESS" });
        try row.append(allocator, .{ .string = "NODE" });
        try row.append(allocator, try stringList(allocator, definition.labels_or_types));
        try row.append(allocator, try stringList(allocator, definition.properties));
        try rows.append(allocator, row);
    }
    return rows.items;
}

fn stringList(allocator: std.mem.Allocator, strings: []const []const u8) std.mem.Allocator.Error!Value {
    const items = try allocator.alloc(Value, strings.len);
    for (items, strings) |*item, string| item.* = .{ .string = string };
    return .{ .list = items };
}
