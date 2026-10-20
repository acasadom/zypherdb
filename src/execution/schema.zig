//! Schema commands: CREATE FULLTEXT INDEX, DROP INDEX, SHOW INDEXES. Each runs
//! as a statement of its own, in its own transaction.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const fulltext = @import("../storage/fulltext.zig");
const fulltext_postings = @import("../storage/fulltext_postings.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Row = Executor.Row;
const Bindings = @import("bindings.zig").Bindings;
const expressions = @import("expressions.zig");

/// The analyzers a full-text index can use.
pub const analyzers = [_][]const u8{ "standard", "english", "spanish" };

pub fn isSchemaCommand(executor: *Executor, root: Index) bool {
    return switch (executor.ast.kind(root)) {
        .create_fulltext_index, .drop_index, .show_indexes => true,
        else => false,
    };
}

/// Runs a schema command; SHOW INDEXES returns rows, the others none.
pub fn run(executor: *Executor, root: Index) ExecutionError![]const Row {
    const graph = executor.graph;
    switch (executor.ast.kind(root)) {
        .show_indexes => {
            try graph.beginRead();
            defer graph.commitRead();
            return showIndexes(executor);
        },
        else => {},
    }
    try graph.beginWrite();
    errdefer graph.abortWrite();
    switch (executor.ast.kind(root)) {
        .create_fulltext_index => try createIndex(executor, root),
        .drop_index => {
            const drop = executor.ast.data(root).drop_index;
            if (try fulltext.find(graph, drop.name, executor.allocator) != null) try fulltext_postings.clear(graph, drop.name);
            if (!try fulltext.drop(graph, drop.name) and !drop.if_exists) {
                executor.fail(.invalid_expression, "there is no index named '{s}'", .{drop.name});
                return error.InvalidExpression;
            }
        },
        else => unreachable,
    }
    try graph.commitWrite();
    return &.{};
}

fn createIndex(executor: *Executor, root: Index) ExecutionError!void {
    const command = executor.ast.data(root).fulltext_index;
    if (try fulltext.find(executor.graph, command.name, executor.allocator) != null) {
        if (command.if_not_exists) return;
        executor.fail(.invalid_expression, "an index named '{s}' already exists", .{command.name});
        return error.InvalidExpression;
    }
    const children = executor.ast.nodeChildren(root);
    const analyzer = if (children.len > 0) try analyzerOption(executor, children[0]) else "standard";
    const definition = fulltext.Definition{
        .name = command.name,
        .entity = if (command.relationships) .relationships else .nodes,
        .analyzer = analyzer,
        .labels_or_types = command.labels_or_types,
        .properties = command.properties,
    };
    try fulltext.create(executor.graph, definition);
    // Index what the graph holds already.
    try fulltext_postings.populate(executor.graph, definition);
}

/// The analyzer named in `OPTIONS {indexConfig: {`fulltext.analyzer`: 'spanish'}}`.
fn analyzerOption(executor: *Executor, options_expression: Index) ExecutionError![]const u8 {
    var empty = Bindings{ .entries = .empty };
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

/// One row per full-text index: name, type, entityType, labelsOrTypes,
/// properties, options.
fn showIndexes(executor: *Executor) ExecutionError![]const Row {
    const allocator = executor.allocator;
    var rows = std.ArrayList(Row).empty;
    for (try fulltext.all(executor.graph, allocator)) |definition| {
        var row = Row.empty;
        try row.append(allocator, .{ .string = definition.name });
        try row.append(allocator, .{ .string = "FULLTEXT" });
        try row.append(allocator, .{ .string = if (definition.entity == .nodes) "NODE" else "RELATIONSHIP" });
        try row.append(allocator, try stringList(allocator, definition.labels_or_types));
        try row.append(allocator, try stringList(allocator, definition.properties));
        const config = try allocator.dupe(MapEntry, &.{.{ .key = "fulltext.analyzer", .value = .{ .string = definition.analyzer } }});
        try row.append(allocator, .{ .map = try allocator.dupe(MapEntry, &.{.{ .key = "indexConfig", .value = .{ .map = config } }}) });
        try rows.append(allocator, row);
    }
    return rows.items;
}

fn stringList(allocator: std.mem.Allocator, strings: []const []const u8) std.mem.Allocator.Error!Value {
    const items = try allocator.alloc(Value, strings.len);
    for (items, strings) |*item, string| item.* = .{ .string = string };
    return .{ .list = items };
}
