//! Projection: WITH (project, group, filter) and RETURN post-processing
//! (DISTINCT, ORDER BY, SKIP, LIMIT).
//!
//! RETURN rows and WITH rows are different types (value rows vs. variable
//! bindings), but DISTINCT, ORDER BY and SKIP/LIMIT are the same algorithms
//! on both: they are written once, generically, in `sequence_algorithms` and
//! `sortByKey` below.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Value = @import("../value.zig").Value;
const eqlSequences = @import("../value.zig").eqlSequences;

const sequence_algorithms = @import("../sequence_algorithms.zig");
const ElementContext = sequence_algorithms.ElementContext;
const SequenceContext = sequence_algorithms.SequenceContext;

const Executor = @import("Executor.zig");
const expressions = @import("expressions.zig");
const clauses = @import("clauses.zig");
const aggregation = @import("aggregation.zig");
const ExecutionError = Executor.ExecutionError;
const Row = Executor.Row;

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

/// Distinctness of sortable rows: by their item only, not their sort key.
/// `Inner` is a hash-map context for `T`.
fn SortableContext(comptime T: type, comptime Inner: type) type {
    return struct {
        pub fn hash(_: @This(), row: Sortable(T)) u64 {
            return Inner.hash(.{}, row.item);
        }

        pub fn eql(_: @This(), a: Sortable(T), b: Sortable(T)) bool {
            return Inner.eql(.{}, a.item, b.item);
        }
    };
}

/// RETURN rows are distinct by their projected values.
pub const RowContext = struct {
    pub fn hash(_: RowContext, row: Row) u64 {
        return SequenceContext(Value).hash(.{}, row.items);
    }

    pub fn eql(_: RowContext, a: Row, b: Row) bool {
        return eqlSequences(a.items, b.items);
    }
};

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
pub fn applyWith(self: *Executor, with_clause: Index, input: []Bindings) ExecutionError![]Bindings {
    const info = withClauseParts(self, with_clause);
    const items = try withItems(self, info.projection);
    const projected = try self.projectedExpressions(info.projection);

    var keys = std.ArrayList(Index).empty;
    var aggregating = std.ArrayList(Index).empty;
    for (items) |item| try (if (item.aggregating) &aggregating else &keys).append(self.allocator, item.expr);
    const ordering = try aggregation.orderByAggregating(self, info.order_by, projected, aggregating.items.len > 0);

    var rows = std.ArrayList(Sortable(Bindings)).empty;
    if (aggregating.items.len == 0) {
        // No aggregates: project each row (no grouping, so no deduplication).
        for (input) |*input_row| {
            var row = Bindings{ .entries = .empty };
            for (items) |item| try row.put(self.allocator, item.name, try expressions.evaluate(self, item.expr, input_row));
            // The WHERE also sees the variables from before the WITH (the
            // projected names win): `WITH x[i] AS v WHERE i > 0`.
            var scope = try clauses.copyRow(self, input_row.*);
            for (row.entries.items) |entry| try scope.put(self.allocator, entry.name, entry.value);
            if (!try expressions.evaluateBool(self, info.where_expression, &scope)) continue;
            const sort_key = if (info.order_by) |order_by| try orderByKey(self, order_by, &row) else &.{};
            try rows.append(self.allocator, .{ .item = row, .sort_key = sort_key });
        }
    } else {
        const names = try self.allocator.alloc([]const u8, items.len);
        for (names, items) |*name, item| name.* = item.name;
        try aggregating.appendSlice(self.allocator, ordering);
        const aggregation_plan = try aggregation.plan(self, keys.items, aggregating.items, names);

        var groups: aggregation.ValueGrouping = .{};
        for (input) |*input_row| try aggregation.accumulateRow(self, &groups, aggregation_plan, input_row);
        try aggregation.ensureGroupWithoutKeys(self, &groups, aggregation_plan);
        for (groups.keys.items, groups.states.items) |key_values, states| {
            var row = Bindings{ .entries = .empty };
            var values = std.ArrayList(Value).empty;
            var key_index: usize = 0;
            for (items) |item| {
                const value = if (item.aggregating)
                    try aggregation.evaluateAggregating(self, item.expr, aggregation_plan, key_values, states, &row)
                else value: {
                    key_index += 1;
                    break :value key_values[key_index - 1];
                };
                try row.put(self.allocator, item.name, value);
                try values.append(self.allocator, value);
            }
            if (!try expressions.evaluateBool(self, info.where_expression, &row)) continue;
            const sort_key = try groupSortKey(self, info.order_by, projected, values.items, &row, aggregation_plan, key_values, states);
            try rows.append(self.allocator, .{ .item = row, .sort_key = sort_key });
        }
    }

    if (info.distinct) {
        try sequence_algorithms.removeDuplicates(Sortable(Bindings), self.allocator, &rows, SortableContext(Bindings, ElementContext(Bindings)){});
    }
    if (info.order_by) |order_by| sortByKey(Bindings, rows.items, try orderByDirections(self, order_by));
    try paginate(self, Sortable(Bindings), &rows, info.skip, info.limit);

    const output = try self.allocator.alloc(Bindings, rows.items.len);
    for (output, rows.items) |*row, sortable| row.* = sortable.item;
    return output;
}

/// The WITH projection items: each binds `name` (its alias, or the variable it
/// projects) to `expr`; an expression containing aggregates is computed per
/// group.
fn withItems(self: *Executor, projection: Index) ExecutionError![]const WithItem {
    var items = std.ArrayList(WithItem).empty;
    for (self.ast.nodeChildren(projection)) |item| {
        const expr = self.ast.nodeChildren(item)[0];
        const alias = self.ast.data(item).text;
        const name = if (alias.len > 0) alias else if (self.ast.kind(expr) == .variable) self.ast.data(expr).text else {
            self.fail(.invalid_expression, "WITH expression requires an alias", .{});
            return error.InvalidExpression;
        };
        try items.append(self.allocator, .{ .name = name, .expr = expr, .aggregating = aggregation.containsAggregate(self, expr) });
    }
    return items.items;
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
pub fn returnSortKey(self: *Executor, info: ReturnClauseParts, row: []const Value, bindings: *const Bindings) ExecutionError![]const Value {
    const order_by = info.order_by orelse return &.{};
    const items = self.ast.nodeChildren(info.projection);

    var scope = Bindings{ .entries = .empty };
    try scope.entries.appendSlice(self.allocator, bindings.entries.items);
    for (items, row) |item, value| {
        const alias = self.ast.data(item).text;
        if (alias.len > 0) try scope.put(self.allocator, alias, value);
    }

    const projected = try self.projectedExpressions(info.projection);
    const order_items = self.ast.nodeChildren(order_by);
    const key = try self.allocator.alloc(Value, order_items.len);
    for (key, order_items) |*value, order_item| {
        const expr = self.ast.nodeChildren(order_item)[0];
        value.* = if (projectedColumn(self, projected, expr)) |column| row[column] else try expressions.evaluate(self, expr, &scope);
    }
    return key;
}

/// The ORDER BY key of one aggregated group (RETURN or WITH): a projected
/// column is reused, an expression with aggregates is computed for the group
/// (see `aggregation.evaluateAggregating`), anything else is evaluated with
/// the projection's names in `scope`.
pub fn groupSortKey(self: *Executor, order_by: ?Index, projected: []const Index, row: []const Value, scope: *Bindings, aggregation_plan: aggregation.AggregationPlan, key_values: []const Value, states: []const aggregation.AggregateState) ExecutionError![]const Value {
    const order = order_by orelse return &.{};
    const order_items = self.ast.nodeChildren(order);
    const key = try self.allocator.alloc(Value, order_items.len);
    for (key, order_items) |*value, order_item| {
        const expr = self.ast.nodeChildren(order_item)[0];
        value.* = if (projectedColumn(self, projected, expr)) |column|
            row[column]
        else if (aggregation.containsAggregate(self, expr))
            try aggregation.evaluateAggregating(self, expr, aggregation_plan, key_values, states, scope)
        else
            try expressions.evaluate(self, expr, scope);
    }
    return key;
}

/// The column whose projected expression is `expr`, if any.
fn projectedColumn(self: *Executor, projected: []const Index, expr: Index) ?usize {
    for (projected, 0..) |item, column| {
        if (self.ast.sameExpression(item, expr)) return column;
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

/// RETURN: projects every row (or folds it into its group when the
/// projection aggregates), then aggregates, applies DISTINCT, ORDER BY, SKIP
/// and LIMIT. The rows go to `self.rows`.
pub fn applyReturn(self: *Executor, return_clause: Index, input: []Bindings) ExecutionError!void {
    const info = returnClauseParts(self, return_clause);
    try planReturn(self, info);
    for (input) |*row| {
        if (self.has_aggregates) {
            try aggregation.accumulate(self, row);
            continue;
        }
        var values = std.ArrayList(Value).empty;
        for (self.ast.nodeChildren(info.projection)) |item| {
            try values.append(self.allocator, try expressions.evaluate(self, self.ast.nodeChildren(item)[0], row));
        }
        // The ORDER BY key is evaluated now, while the row's variables are
        // still bound: it may use variables that are not projected.
        const sort_key = try returnSortKey(self, info, values.items, row);
        try self.rows.append(self.allocator, .{ .item = values, .sort_key = sort_key });
    }

    if (self.has_aggregates) try aggregation.aggregate(self, info);
    if (info.distinct) {
        try sequence_algorithms.removeDuplicates(Sortable(Row), self.allocator, &self.rows, SortableContext(Row, RowContext){});
    }
    if (info.order_by) |order_by| sortByKey(Row, self.rows.items, try orderByDirections(self, order_by));
    try paginate(self, Sortable(Row), &self.rows, info.skip, info.limit);
}

/// Splits the RETURN projection into grouping keys and aggregating
/// expressions, and plans the aggregation (with any ORDER BY aggregates).
fn planReturn(self: *Executor, parts: ReturnClauseParts) ExecutionError!void {
    var keys = std.ArrayList(Index).empty;
    var aggregating = std.ArrayList(Index).empty;
    for (self.ast.nodeChildren(parts.projection)) |item| {
        const expression = self.ast.nodeChildren(item)[0];
        if (aggregation.containsAggregate(self, expression)) {
            try self.projection_items.append(self.allocator, .{ .aggregating = expression });
            try aggregating.append(self.allocator, expression);
        } else {
            try self.projection_items.append(self.allocator, .{ .key = expression });
            try keys.append(self.allocator, expression);
        }
    }
    self.has_aggregates = aggregating.items.len > 0;
    const projected = try self.projectedExpressions(parts.projection);
    const ordering = try aggregation.orderByAggregating(self, parts.order_by, projected, self.has_aggregates);
    if (self.has_aggregates) {
        try aggregating.appendSlice(self.allocator, ordering);
        self.return_aggregation = try aggregation.plan(self, keys.items, aggregating.items, try projectionNames(self, parts.projection));
    }
}

/// The alias of each aliased projection item.
fn projectionNames(self: *Executor, projection_node: Index) ExecutionError![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    for (self.ast.nodeChildren(projection_node)) |item| {
        const alias = self.ast.data(item).text;
        if (alias.len > 0) try names.append(self.allocator, alias);
    }
    return names.items;
}

/// One WITH projection item: `name` is the variable it binds in the new scope
/// (its alias, or the variable it projects); an `aggregating` item contains
/// aggregates and is computed per group.
pub const WithItem = struct { name: []const u8, expr: Index, aggregating: bool };

pub const WithClauseParts = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    where_expression: Index,
    distinct: bool,
};
