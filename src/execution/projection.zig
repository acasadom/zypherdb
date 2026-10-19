//! Projection: WITH (project, group, filter) and RETURN post-processing
//! (DISTINCT, ORDER BY, SKIP, LIMIT).
//!
//! RETURN rows and WITH rows are different types (value rows vs. variable
//! bindings), but DISTINCT, ORDER BY and SKIP/LIMIT are the same algorithms
//! on both: they are written once, generically, in `sequence_algorithms` and
//! `sortByKey` below.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const AggregateKind = @import("../query/ast.zig").AggregateKind;
const Value = @import("../value.zig").Value;
const eqlSequences = @import("../value.zig").eqlSequences;

const sequence_algorithms = @import("../sequence_algorithms.zig");
const ElementContext = sequence_algorithms.ElementContext;
const SequenceContext = sequence_algorithms.SequenceContext;

const Executor = @import("Executor.zig");
const expressions = @import("expressions.zig");
const aggregation = @import("aggregation.zig");
const ExecutionError = Executor.ExecutionError;
const Row = Executor.Row;

const aggregateResult = @import("aggregation.zig").aggregateResult;
const Binding = @import("bindings.zig").Binding;
const Bindings = @import("bindings.zig").Bindings;

/// An item paired with its ORDER BY key. The key is evaluated alongside the
/// item because ORDER BY may use variables that are not projected.
pub fn Sortable(comptime T: type) type {
    return struct { item: T, sort_key: []const Value };
}

/// Stable sort of `items` by their `sort_key`, column by column, each column
/// ascending or descending. Ties keep their input order. O(n log n).
pub fn sortByKey(comptime T: type, items: []Sortable(T), ascending: []const bool) void {
    std.sort.block(Sortable(T), items, ascending, struct {
        fn lessThan(directions: []const bool, a: Sortable(T), b: Sortable(T)) bool {
            return keyLessThan(directions, a.sort_key, b.sort_key);
        }
    }.lessThan);
}

fn keyLessThan(directions: []const bool, a: []const Value, b: []const Value) bool {
    for (a, b, directions) |x, y, ascending| {
        switch (Value.order(x, y)) {
            .lt => return ascending,
            .gt => return !ascending,
            .eq => {},
        }
    }
    return false;
}

/// RETURN rows are distinct by their projected values (not their sort key).
const ReturnRowContext = struct {
    pub fn hash(_: ReturnRowContext, row: Sortable(Row)) u64 {
        return SequenceContext(Value).hash(.{}, row.item.items);
    }

    pub fn eql(_: ReturnRowContext, a: Sortable(Row), b: Sortable(Row)) bool {
        return eqlSequences(a.item.items, b.item.items);
    }
};

/// WITH groups: keyed by the bindings of the non-aggregate projection items.
const BindingGrouping = aggregation.Grouping([]const Binding, SequenceContext(Binding));

/// Appends a copy of `bindings` to `with_rows` (the input of WITH).
pub fn collect(self: *Executor, bindings: *Bindings) ExecutionError!void {
    var copy = Bindings{ .entries = .empty };
    try copy.entries.appendSlice(self.allocator, bindings.entries.items);
    try self.with_rows.append(self.allocator, copy);
}

pub fn withClauseParts(self: *Executor, with_clause: Index) WithClauseParts {
    const children = self.ast.nodeChildren(with_clause);
    var info = WithClauseParts{
        .projection = children[0],
        .order_by = null,
        .skip = null,
        .limit = null,
        .where_expression = children[children.len - 1],
        .distinct = self.ast.data(with_clause).with_.distinct,
    };
    for (children[1 .. children.len - 1]) |child| {
        switch (self.ast.kind(child)) {
            .order_by => info.order_by = child,
            .skip => info.skip = child,
            .limit => info.limit = child,
            else => {},
        }
    }
    return info;
}

/// Projects the collected bindings through the WITH clause (grouping +
/// aggregation), then applies WHERE / DISTINCT / ORDER BY / SKIP / LIMIT,
/// rebinding the result into fresh variable bindings for the next clauses.
pub fn applyWith(self: *Executor, with_clause: Index) ExecutionError!void {
    const info = withClauseParts(self, with_clause);
    const items = try withItems(self, info.projection);

    var kinds = std.ArrayList(AggregateKind).empty;
    for (items) |item| {
        if (item == .aggregate) try kinds.append(self.allocator, item.aggregate.kind);
    }

    var groups: BindingGrouping = .{};
    for (self.with_rows.items) |*bindings| {
        var keys = std.ArrayList(Binding).empty;
        var args = std.ArrayList(Value).empty;
        for (items) |item| {
            switch (item) {
                .pass => |p| {
                    const b = bindings.get(p.source_name) orelse {
                        self.fail(.unknown_variable, "unknown variable '{s}'", .{p.source_name});
                        return error.UnknownVariable;
                    };
                    try keys.append(self.allocator, b);
                },
                .key => |k| try keys.append(self.allocator, .{ .value = try expressions.evaluate(self, k.expr, bindings) }),
                .aggregate => |a| try args.append(self.allocator, try aggregation.evaluateAggregateArgument(self, a.kind, a.arg, bindings)),
            }
        }
        const states = try groups.statesFor(self.allocator, keys.items, kinds.items);
        for (states, args.items) |*state, arg| try aggregation.updateAggregate(self, state, arg);
    }

    // No grouping keys: zero input rows still aggregate into one row.
    if (groups.keys.items.len == 0 and !hasWithKey(items)) {
        _ = try groups.statesFor(self.allocator, &.{}, kinds.items);
    }

    var out = std.ArrayList(Bindings).empty;
    for (groups.keys.items, groups.states.items) |keys, states| {
        var b = Bindings{ .entries = .empty };
        var key_index: usize = 0;
        var aggregate_index: usize = 0;
        for (items) |item| {
            switch (item) {
                .pass => |p| {
                    try b.put(self.allocator, p.name, keys[key_index]);
                    key_index += 1;
                },
                .key => |k| {
                    try b.put(self.allocator, k.name, keys[key_index]);
                    key_index += 1;
                },
                .aggregate => |a| {
                    try b.put(self.allocator, a.name, .{ .value = aggregateResult(a.kind, states[aggregate_index]) });
                    aggregate_index += 1;
                },
            }
        }
        // WHERE filter (always present; `true` when absent).
        if (try expressions.evaluateBool(self, info.where_expression, &b)) {
            try out.append(self.allocator, b);
        }
    }

    if (info.distinct) {
        try sequence_algorithms.removeDuplicates(Bindings, self.allocator, &out, ElementContext(Bindings){});
    }
    if (info.order_by) |order_by| try sortBindings(self, &out, order_by);
    try paginate(self, Bindings, &out, info.skip, info.limit);

    self.with_rows = out;
}

/// Classifies the WITH projection items: passthrough variables, aliased
/// expressions (grouping keys) and aliased aggregates.
fn withItems(self: *Executor, projection: Index) ExecutionError![]const WithItem {
    var items = std.ArrayList(WithItem).empty;
    for (self.ast.nodeChildren(projection)) |item| {
        const expr = self.ast.nodeChildren(item)[0];
        const alias = self.ast.data(item).text;
        switch (self.ast.kind(expr)) {
            .aggregate => {
                if (alias.len == 0) {
                    self.fail(.invalid_expression, "WITH aggregation requires an alias", .{});
                    return error.InvalidExpression;
                }
                const kind = self.ast.data(expr).aggregate;
                const children = self.ast.nodeChildren(expr);
                const arg: ?Index = if (children.len > 0) children[0] else null;
                try items.append(self.allocator, .{ .aggregate = .{ .name = alias, .kind = kind, .arg = arg } });
            },
            .variable => {
                const source_name = self.ast.data(expr).text;
                const name = if (alias.len > 0) alias else source_name;
                try items.append(self.allocator, .{ .pass = .{ .name = name, .source_name = source_name } });
            },
            else => {
                if (alias.len == 0) {
                    self.fail(.invalid_expression, "WITH expression requires an alias", .{});
                    return error.InvalidExpression;
                }
                try items.append(self.allocator, .{ .key = .{ .name = alias, .expr = expr } });
            },
        }
    }
    return items.items;
}

/// Sorts WITH rows by the ORDER BY keys, evaluated against each row.
fn sortBindings(self: *Executor, rows: *std.ArrayList(Bindings), order_by: Index) ExecutionError!void {
    const sortable = try self.allocator.alloc(Sortable(Bindings), rows.items.len);
    for (sortable, rows.items) |*entry, *bindings| {
        entry.* = .{ .item = bindings.*, .sort_key = try orderByKey(self, order_by, bindings) };
    }
    sortByKey(Bindings, sortable, try orderByDirections(self, order_by));
    for (rows.items, sortable) |*row, entry| row.* = entry.item;
}

/// Evaluates the ORDER BY expressions against `bindings` (WITH rows, whose
/// bindings already hold the projected names).
fn orderByKey(self: *Executor, order_by: Index, bindings: *Bindings) ExecutionError![]const Value {
    const order_items = self.ast.nodeChildren(order_by);
    const key = try self.allocator.alloc(Value, order_items.len);
    for (key, order_items) |*value, item| {
        value.* = try expressions.evaluate(self, self.ast.nodeChildren(item)[0], bindings);
    }
    return key;
}

/// The ORDER BY key of one RETURN row (empty without ORDER BY). Each ORDER BY
/// expression that repeats a projected expression reuses that column;
/// otherwise it is evaluated with the RETURN aliases in scope, on top of the
/// row's variables (`bindings`, null for an aggregated row, which has none).
pub fn returnSortKey(self: *Executor, info: ReturnClauseParts, row: []const Value, bindings: ?*const Bindings) ExecutionError![]const Value {
    const order_by = info.order_by orelse return &.{};
    const projected = self.ast.nodeChildren(info.projection);

    var scope = Bindings{ .entries = .empty };
    if (bindings) |b| try scope.entries.appendSlice(self.allocator, b.entries.items);
    for (projected, row) |item, value| {
        const alias = self.ast.data(item).text;
        if (alias.len > 0) try scope.put(self.allocator, alias, .{ .value = value });
    }

    const order_items = self.ast.nodeChildren(order_by);
    const key = try self.allocator.alloc(Value, order_items.len);
    for (key, order_items) |*value, order_item| {
        const expr = self.ast.nodeChildren(order_item)[0];
        value.* = if (projectedColumn(self, projected, expr)) |column|
            row[column]
        else
            try expressions.evaluate(self, expr, &scope);
    }
    return key;
}

/// The index of the projection item whose expression is `expr`, if any.
fn projectedColumn(self: *Executor, projected: []const Index, expr: Index) ?usize {
    for (projected, 0..) |item, column| {
        if (self.ast.sameExpression(self.ast.nodeChildren(item)[0], expr)) return column;
    }
    return null;
}

/// The direction of each ORDER BY column (`true` = ascending).
fn orderByDirections(self: *Executor, order_by: Index) ExecutionError![]const bool {
    const order_items = self.ast.nodeChildren(order_by);
    const ascending = try self.allocator.alloc(bool, order_items.len);
    for (ascending, order_items) |*direction, item| direction.* = self.ast.data(item).order_item.ascending;
    return ascending;
}

/// Applies SKIP then LIMIT to any row list.
fn paginate(self: *Executor, comptime T: type, rows: *std.ArrayList(T), skip: ?Index, limit: ?Index) ExecutionError!void {
    if (skip) |s| sequence_algorithms.dropFirst(T, rows, try expressions.evaluateCount(self, self.ast.nodeChildren(s)[0]));
    if (limit) |l| sequence_algorithms.truncate(T, rows, try expressions.evaluateCount(self, self.ast.nodeChildren(l)[0]));
}

pub const ReturnClauseParts = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    distinct: bool,
};

pub fn returnClauseParts(self: *Executor, return_clause: Index) ReturnClauseParts {
    var info = ReturnClauseParts{
        .projection = 0,
        .order_by = null,
        .skip = null,
        .limit = null,
        .distinct = self.ast.data(return_clause).return_.distinct,
    };
    for (self.ast.nodeChildren(return_clause)) |child| {
        switch (self.ast.kind(child)) {
            .projection => info.projection = child,
            .order_by => info.order_by = child,
            .skip => info.skip = child,
            .limit => info.limit = child,
            else => {},
        }
    }
    return info;
}

/// RETURN post-processing: aggregation, then DISTINCT, ORDER BY, SKIP, LIMIT.
pub fn postProcess(self: *Executor, return_clause: Index) ExecutionError!void {
    const info = returnClauseParts(self, return_clause);

    if (self.has_aggregates) try aggregation.aggregate(self, info);
    if (info.distinct) {
        try sequence_algorithms.removeDuplicates(Sortable(Row), self.allocator, &self.rows, ReturnRowContext{});
    }
    if (info.order_by) |order_by| sortByKey(Row, self.rows.items, try orderByDirections(self, order_by));
    try paginate(self, Sortable(Row), &self.rows, info.skip, info.limit);
}

/// One `WITH` projection item: a variable passthrough (keeps its node/edge/value
/// binding), a scalar key expression, or an aggregation. `name` is the variable
/// it binds in the new scope (alias, or the variable name for a passthrough).
pub const WithItem = union(enum) {
    pass: struct { name: []const u8, source_name: []const u8 },
    key: struct { name: []const u8, expr: Index },
    aggregate: struct { name: []const u8, kind: AggregateKind, arg: ?Index },
};

pub const WithClauseParts = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    where_expression: Index,
    distinct: bool,
};

fn hasWithKey(items: []const WithItem) bool {
    for (items) |item| if (item != .aggregate) return true;
    return false;
}
