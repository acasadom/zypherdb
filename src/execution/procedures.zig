//! The procedures CALL runs (their signatures are in `src/query/procedures.zig`).
//!
//! A procedure gets its arguments' values and emits rows, one value per
//! column of its signature, in order. `callRow` runs the CALL of one input
//! row: it binds the yielded columns, applies the CALL's WHERE, and hands
//! each row on.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Value = @import("../value.zig").Value;
const eqlSequences = @import("../value.zig").eqlSequences;
const signatures = @import("../query/procedures.zig");
const fulltext = @import("../storage/fulltext.zig");
const fulltext_search = @import("../storage/fulltext_search.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const expressions = @import("expressions.zig");

/// Where a procedure's rows go.
pub const Emit = struct {
    context: *anyopaque,
    row: *const fn (context: *anyopaque, values: []const Value) ExecutionError!void,
};

/// What becomes of the rows of a CALL on one input row.
pub const Consumer = struct {
    context: *anyopaque,
    /// A row that goes on through the query, with the yielded variables bound.
    extended: *const fn (context: *anyopaque, row: *Bindings) ExecutionError!void,
    /// A row of a CALL without YIELD that ends the query: its values are a result row.
    result: *const fn (context: *anyopaque, values: []const Value) ExecutionError!void,
};

/// Runs `clause` (a CALL) for `row`. When it `ends_query`, its rows are the
/// result: every column without YIELD, else the yielded ones.
pub fn callRow(executor: *Executor, clause: Index, row: *Bindings, ends_query: bool, consumer: Consumer) ExecutionError!void {
    const call = executor.ast.data(clause).call;
    const children = executor.ast.nodeChildren(clause);
    const signature = signatures.find(call.procedure, executor.table_procedures).?; // checked by the semantic checks
    const arguments = if (call.implicit_arguments) try implicitArguments(executor, signature) else arguments: {
        const values = try executor.allocator.alloc(Value, call.argument_count);
        for (values, children[0..call.argument_count]) |*argument, expression| argument.* = try expressions.evaluate(executor, expression, row);
        break :arguments values;
    };

    // A procedure without columns yields nothing: each row goes on as it is.
    if (signature.columns.len == 0) {
        try run(executor, call.procedure, arguments, .{ .context = executor, .row = ignoreRow });
        if (!ends_query) try consumer.extended(consumer.context, row);
        return;
    }

    var binder = Binder{
        .executor = executor,
        .signature = signature,
        .yield_items = children[call.argument_count .. children.len - 1],
        .where_expression = children[children.len - 1],
        .yield_all = call.yield_all,
        .ends_query = ends_query,
        .row = row,
        .consumer = consumer,
    };
    try run(executor, call.procedure, arguments, .{ .context = &binder, .row = Binder.emit });
}

const Binder = struct {
    executor: *Executor,
    signature: signatures.Signature,
    yield_items: []const Index,
    where_expression: Index,
    yield_all: bool,
    ends_query: bool,
    row: *Bindings,
    consumer: Consumer,

    fn emit(context: *anyopaque, values: []const Value) ExecutionError!void {
        const self: *Binder = @ptrCast(@alignCast(context));
        if (self.yield_all) return self.consumer.result(self.consumer.context, values);
        const saved = self.row.mark();
        defer self.row.restore(saved);
        const yielded = try self.executor.allocator.alloc(Value, self.yield_items.len);
        for (self.yield_items, yielded) |item, *value| {
            const yield_item = self.executor.ast.data(item).yield_;
            const position = for (self.signature.columns, 0..) |column, i| {
                if (std.mem.eql(u8, column.name, yield_item.column)) break i;
            } else unreachable; // checked by the semantic checks
            value.* = values[position];
            const name = if (yield_item.alias.len > 0) yield_item.alias else yield_item.column;
            try self.row.put(self.executor.allocator, name, value.*);
        }
        if (!try expressions.evaluateBool(self.executor, self.where_expression, self.row)) return;
        if (self.ends_query) return self.consumer.result(self.consumer.context, yielded);
        try self.consumer.extended(self.consumer.context, self.row);
    }
};

fn ignoreRow(_: *anyopaque, _: []const Value) ExecutionError!void {}

/// `CALL proc` without parentheses: each declared argument is the query
/// parameter of its name.
fn implicitArguments(executor: *Executor, signature: signatures.Signature) ExecutionError![]const Value {
    const values = try executor.allocator.alloc(Value, signature.arguments.len);
    for (values, signature.arguments) |*value, argument| {
        value.* = executor.parameters.get(argument.name) orelse {
            executor.fail(.parameter_missing, "{s} takes its argument '{s}' from the parameter ${s}, which is missing", .{ signature.name, argument.name, argument.name });
            return error.ParameterMissing;
        };
    }
    return values;
}

/// Runs procedure `name` with `arguments`, emitting its rows.
fn run(executor: *Executor, name: []const u8, arguments: []const Value, emit: Emit) ExecutionError!void {
    if (signatures.findTable(name, executor.table_procedures)) |procedure| return runTable(procedure, arguments, emit);
    if (std.mem.eql(u8, name, "db.index.fulltext.queryNodes")) return queryIndex(executor, name, .nodes, arguments, emit);
    if (std.mem.eql(u8, name, "db.index.fulltext.queryRelationships")) return queryIndex(executor, name, .relationships, arguments, emit);
    if (std.mem.eql(u8, name, "db.labels")) {
        for (try executor.graph.labelNames(executor.allocator)) |label| try emit.row(emit.context, &.{.{ .string = label }});
    } else if (std.mem.eql(u8, name, "db.relationshipTypes")) {
        for (try executor.graph.relationshipTypeNames(executor.allocator)) |edge_type| try emit.row(emit.context, &.{.{ .string = edge_type }});
    } else if (std.mem.eql(u8, name, "db.index.fulltext.listAvailableAnalyzers")) {
        for (analyzers) |analyzer| try emit.row(emit.context, &.{ .{ .string = analyzer[0] }, .{ .string = analyzer[1] } });
    } else {
        executor.fail(.invalid_expression, "procedure '{s}' is not available yet", .{name});
        return error.InvalidExpression;
    }
}

/// A table procedure: the columns of each row whose arguments equal the
/// call's (null equals null here, as the TCK's tables expect).
fn runTable(procedure: *const signatures.TableProcedure, arguments: []const Value, emit: Emit) ExecutionError!void {
    for (procedure.rows) |row| {
        const argument_count = row.len - procedure.signature.columns.len;
        if (argument_count != arguments.len) continue;
        if (!eqlSequences(row[0..argument_count], arguments)) continue;
        try emit.row(emit.context, row[argument_count..]);
    }
}

/// `db.index.fulltext.queryNodes(index, query[, {skip, limit}])` and its
/// relationship twin: the matches, best first, with their scores.
fn queryIndex(executor: *Executor, name: []const u8, entity: fulltext.Entity, arguments: []const Value, emit: Emit) ExecutionError!void {
    if (arguments[0] != .string or arguments[1] != .string) {
        executor.fail(.type_mismatch, "{s}() takes an index name and a query, both strings", .{name});
        return error.TypeMismatch;
    }
    const index_name = arguments[0].string;
    const definition = try fulltext.find(executor.graph, index_name, executor.allocator) orelse {
        executor.fail(.invalid_expression, "there is no full-text index named '{s}'", .{index_name});
        return error.InvalidExpression;
    };
    if (definition.entity != entity) {
        executor.fail(.invalid_expression, "'{s}' indexes {s}: use db.index.fulltext.{s}", .{ index_name, @tagName(definition.entity), if (definition.entity == .nodes) "queryNodes" else "queryRelationships" });
        return error.InvalidExpression;
    }
    var skip: usize = 0;
    var limit: usize = std.math.maxInt(usize);
    if (arguments.len > 2) {
        if (arguments[2] != .map) {
            executor.fail(.type_mismatch, "{s}() takes its options as a map: {{skip: n, limit: n}}", .{name});
            return error.TypeMismatch;
        }
        for (arguments[2].map) |option| {
            const count = if (option.value == .int and option.value.int >= 0) @as(usize, @intCast(option.value.int)) else {
                executor.fail(.invalid_expression, "the option '{s}' must be a non-negative integer", .{option.key});
                return error.InvalidExpression;
            };
            if (std.mem.eql(u8, option.key, "skip")) skip = count else if (std.mem.eql(u8, option.key, "limit")) limit = count else {
                executor.fail(.invalid_expression, "unknown option '{s}' (expected skip, limit)", .{option.key});
                return error.InvalidExpression;
            }
        }
    }
    var message: []const u8 = "";
    const hits = fulltext_search.search(executor.graph, executor.allocator, definition, arguments[1].string, &message) catch |err| switch (err) {
        error.InvalidQuery => {
            executor.fail(.invalid_expression, "invalid full-text query: {s}", .{message});
            return error.InvalidExpression;
        },
        else => |other| return other,
    };
    const end = @min(hits.len, skip +| limit);
    if (skip >= end) return;
    for (hits[skip..end]) |hit| {
        const value: Value = switch (entity) {
            .nodes => .{ .node = std.mem.readInt(u64, hit.entity[0..8], .big) },
            .relationships => .{ .relationship = .{
                .src = std.mem.readInt(u64, hit.entity[0..8], .big),
                .dst = std.mem.readInt(u64, hit.entity[8..16], .big),
                .edge_type = hit.entity[16..],
            } },
        };
        try emit.row(emit.context, &.{ value, .{ .float = hit.score } });
    }
}

const analyzers = [_]struct { []const u8, []const u8 }{
    .{ "standard", "Unicode words, lower-cased, without accents." },
    .{ "english", "Like standard, without English stop words, and with English stemming." },
    .{ "spanish", "Like standard, without Spanish stop words, and with Spanish stemming." },
};

/// A CALL in a query that writes (rows materialized between clauses): the
/// rows of every input row, or, for a CALL without YIELD that ends the query,
/// its result rows in `executor.rows`.
pub fn runCall(executor: *Executor, clause: Index, input: []Bindings, ends_query: bool) ExecutionError![]Bindings {
    const Collector = struct {
        executor: *Executor,
        output: std.ArrayList(Bindings) = .empty,

        fn extended(context: *anyopaque, row: *Bindings) ExecutionError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try self.output.append(self.executor.allocator, try clauses.copyRow(self.executor, row.*));
        }

        fn result(context: *anyopaque, values: []const Value) ExecutionError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try appendResult(self.executor, values);
        }
    };
    var collector = Collector{ .executor = executor };
    for (input) |*row| try callRow(executor, clause, row, ends_query, .{ .context = &collector, .extended = Collector.extended, .result = Collector.result });
    return collector.output.items;
}

/// Adds `values` to the query's result rows (a CALL without YIELD).
pub fn appendResult(executor: *Executor, values: []const Value) ExecutionError!void {
    var row = Executor.Row.empty;
    try row.appendSlice(executor.allocator, values);
    try executor.rows.append(executor.allocator, .{ .item = row, .sort_key = &.{} });
}

const clauses = @import("clauses.zig");
