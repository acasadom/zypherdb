//! Projection: WITH and RETURN (project, group, filter), and the stages
//! that follow them in a plan (DISTINCT, ORDER BY, SKIP, LIMIT).
//!
//! RETURN rows and WITH rows are different types (value rows vs. variable
//! bindings), but the stages are the same algorithms on both: they are
//! written once, generically, in `sequence_algorithms` and `applyStage`.

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

const ProjectionStage = @import("../planning/Plan.zig").ProjectionStage;
const Bindings = @import("bindings.zig").Bindings;
const Slot = @import("bindings.zig").Slot;
const SlotsContext = @import("bindings.zig").SlotsContext;

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
        inner: Inner,

        pub fn hash(self: @This(), row: Sortable(T)) u64 {
            return self.inner.hash(row.item);
        }

        pub fn eql(self: @This(), a: Sortable(T), b: Sortable(T)) bool {
            return self.inner.eql(a.item, b.item);
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
    // A subquery's RETURN makes rows as a WITH does, without a WHERE.
    const is_return = self.ast.kind(with_clause) == .return_clause;
    var info = WithClauseParts{
        .projection = children[0],
        .order_by = null,
        .skip = null,
        .limit = null,
        .where_expression = if (is_return) Executor.no_where else children[children.len - 1],
        .distinct = if (is_return) self.ast.data(with_clause).return_.distinct else self.ast.data(with_clause).with_.distinct,
        .requires_aliases = !is_return,
    };
    for (children[1 .. if (is_return) children.len else children.len - 1]) |child| {
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
/// aggregation) and its WHERE, each row with its ORDER BY key; the WITH's
/// stages (`applyStage`) come next. (Also a subquery's RETURN, whose rows
/// are made the same way.)
pub fn applyWith(self: *Executor, with_clause: Index, input: []Bindings) ExecutionError!std.ArrayList(Sortable(Bindings)) {
    const info = withClauseParts(self, with_clause);
    const items = try withItems(self, info);
    const projected = try self.projectedExpressions(info.projection);

    var keys = std.ArrayList(Index).empty;
    var aggregating = std.ArrayList(Index).empty;
    for (items) |item| try (if (item.aggregating) &aggregating else &keys).append(self.allocator, item.expr);
    const ordering = try aggregation.orderByAggregating(self, info.order_by, projected, aggregating.items.len > 0);

    var rows = std.ArrayList(Sortable(Bindings)).empty;
    if (aggregating.items.len == 0) {
        // No aggregates: project each row (no grouping, so no deduplication).
        // The projected slots are new, so the copy holds what the ORDER BY
        // sees: the projected names and the variables from before the WITH.
        for (input) |*input_row| {
            var row = try clauses.copyRow(self, input_row.*);
            if (!try project(self, info, items, &row)) continue;
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
            var row = try self.newRow();
            var values = std.ArrayList(Value).empty;
            var key_index: usize = 0;
            for (items) |item| {
                const value = if (item.aggregating)
                    try aggregation.evaluateAggregating(self, item.expr, aggregation_plan, key_values, states, &row)
                else value: {
                    key_index += 1;
                    break :value key_values[key_index - 1];
                };
                try row.put(self.allocator, item.slot, value);
                try values.append(self.allocator, value);
            }
            if (info.where_expression != Executor.no_where and !try expressions.evaluateBool(self, info.where_expression, &row)) continue;
            const sort_key = try groupSortKey(self, info.order_by, projected, values.items, &row, aggregation_plan, key_values, states);
            try rows.append(self.allocator, .{ .item = row, .sort_key = sort_key });
        }
    }

    return rows;
}

/// Applies a WITH's stage to its projected rows.
pub fn withStage(self: *Executor, stage: ProjectionStage, rows: *std.ArrayList(Sortable(Bindings))) ExecutionError!void {
    // Rows are distinct by their projected slots.
    const items = try withItems(self, withClauseParts(self, stage.clause));
    const slots = try self.allocator.alloc(Slot, items.len);
    for (slots, items) |*slot, item| slot.* = item.slot;
    try applyStage(self, Bindings, stage, rows, SortableContext(Bindings, SlotsContext){ .inner = .{ .slots = slots } });
}

/// Applies a RETURN's stage to `self.rows`.
pub fn returnStage(self: *Executor, stage: ProjectionStage) ExecutionError!void {
    try applyStage(self, Row, stage, &self.rows, SortableContext(Row, RowContext){ .inner = .{} });
}

/// One stage over rows of type `T` paired with their ORDER BY keys;
/// `distinctness` is the hash-map context of DISTINCT. A sort is stable,
/// O(n log n); `top` sorts only the SKIP + LIMIT rows it keeps, O(n log k).
fn applyStage(self: *Executor, comptime T: type, stage: ProjectionStage, rows: *std.ArrayList(Sortable(T)), distinctness: anytype) ExecutionError!void {
    const parts = withClauseParts(self, stage.clause);
    switch (stage.kind) {
        .distinct => try sequence_algorithms.removeDuplicates(Sortable(T), self.allocator, rows, distinctness),
        .sort => sortByKey(T, rows.items, try orderByDirections(self, parts.order_by.?)),
        .top => {
            const skipped = if (parts.skip) |skip| try evaluateClauseCount(self, skip) else 0;
            const kept = skipped +| try evaluateClauseCount(self, parts.limit.?);
            try sequence_algorithms.partialSortStable(Sortable(T), self.allocator, rows.items, kept, try orderByDirections(self, parts.order_by.?), struct {
                fn lessThan(ascending: []const bool, a: Sortable(T), b: Sortable(T)) bool {
                    return keyLessThan(ascending, a.sort_key, b.sort_key);
                }
            }.lessThan);
            sequence_algorithms.truncate(Sortable(T), rows, kept);
        },
        .skip => sequence_algorithms.dropFirst(Sortable(T), rows, try evaluateClauseCount(self, parts.skip.?)),
        .limit => sequence_algorithms.truncate(Sortable(T), rows, try evaluateClauseCount(self, parts.limit.?)),
    }
}

/// The count of a SKIP or LIMIT.
fn evaluateClauseCount(self: *Executor, clause_part: Index) ExecutionError!usize {
    return expressions.evaluateCount(self, self.ast.nodeChildren(clause_part)[0]);
}

/// Projects one row of a WITH without aggregates: binds each item's slot in
/// `row` (the caller marks it, to restore), then applies the WHERE. False if
/// the WHERE drops the row. Each item reads the variables from before the
/// WITH, and its slot is new, so the WHERE sees both, the projected names
/// winning: `WITH x[i] AS v WHERE i > 0`.
pub fn project(self: *Executor, info: WithClauseParts, items: []const WithItem, row: *Bindings) ExecutionError!bool {
    for (items) |item| try row.put(self.allocator, item.slot, try expressions.evaluate(self, item.expr, row));
    if (info.where_expression == Executor.no_where) return true;
    return expressions.evaluateBool(self, info.where_expression, row);
}

/// The WITH projection items: each binds `name` (its alias, or the variable it
/// projects) to `expr`; an expression containing aggregates is computed per
/// group. (A subquery's RETURN may leave an expression unnamed: no clause
/// reads its rows' names.)
pub fn withItems(self: *Executor, info: WithClauseParts) ExecutionError![]const WithItem {
    var items = std.ArrayList(WithItem).empty;
    for (self.ast.nodeChildren(info.projection)) |item| {
        const expr = self.ast.nodeChildren(item)[0];
        const alias = self.ast.data(item).text;
        const name = if (alias.len > 0) alias else if (self.ast.kind(expr) == .variable) self.ast.data(expr).text else if (!info.requires_aliases) "" else {
            self.fail(.invalid_expression, "WITH expression requires an alias", .{});
            return error.InvalidExpression;
        };
        try items.append(self.allocator, .{ .name = name, .slot = self.slotOf(item), .expr = expr, .aggregating = aggregation.containsAggregate(self, expr) });
    }
    return items.items;
}

/// Evaluates the ORDER BY expressions against `bindings` (the projected
/// names over the variables from before the WITH).
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
pub fn returnSortKey(self: *Executor, info: ReturnClauseParts, row: []const Value, bindings: *Bindings) ExecutionError![]const Value {
    const order_by = info.order_by orelse return &.{};
    const items = self.ast.nodeChildren(info.projection);

    // The aliases' slots (an item without one has none) on top of the row's.
    const saved = bindings.mark();
    defer bindings.restore(saved);
    for (items, row) |item, value| try bindings.put(self.allocator, self.slotOf(item), value);

    const order_items = self.ast.nodeChildren(order_by);
    const key = try self.allocator.alloc(Value, order_items.len);
    for (key, order_items) |*value, order_item| {
        const expr = self.ast.nodeChildren(order_item)[0];
        value.* = if (projectedColumn(self, info.projected, expr)) |column| row[column] else try expressions.evaluate(self, expr, bindings);
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

pub const ReturnClauseParts = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    distinct: bool,
    /// The expression of each projection item, found once per run (the
    /// ORDER BY key of every row looks its items up in it).
    projected: []const Index = &.{},
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

/// Starts a RETURN: plans its projection and aggregation. Then each row goes
/// to `returnRow`, and `endReturn` produces the result in `self.rows`.
pub fn beginReturn(self: *Executor, return_clause: Index) ExecutionError!ReturnClauseParts {
    var info = returnClauseParts(self, return_clause);
    info.projected = try self.projectedExpressions(info.projection);
    try planReturn(self, info);
    return info;
}

/// Adds one row to a RETURN: accumulated into its group, or projected. The
/// row is not kept, so the caller may reuse it.
pub fn returnRow(self: *Executor, info: ReturnClauseParts, row: *Bindings) ExecutionError!void {
    if (self.has_aggregates) return aggregation.accumulate(self, row);
    // The row's width is known: allocated exactly, not grown.
    const values = Row.fromOwnedSlice(try self.allocator.alloc(Value, info.projected.len));
    for (values.items, info.projected) |*value, expression| value.* = try expressions.evaluate(self, expression, row);
    // The ORDER BY key is evaluated now, while the row's variables are
    // still bound: it may use variables that are not projected.
    const sort_key = try returnSortKey(self, info, values.items, row);
    try self.rows.append(self.allocator, .{ .item = values, .sort_key = sort_key });
}

/// Ends a RETURN's projection: with aggregates, turns its groups into rows.
/// Its stages (`returnStage`) come next.
pub fn endReturn(self: *Executor, info: ReturnClauseParts) ExecutionError!void {
    if (self.has_aggregates) try aggregation.aggregate(self, info);
}

/// How many rows a RETURN keeps if it can stop reading early: it has a
/// LIMIT and nothing that needs every row first (no aggregate, DISTINCT or
/// ORDER BY). SKIP + LIMIT then, else null.
pub fn returnRowsNeeded(self: *Executor, info: ReturnClauseParts) ExecutionError!?usize {
    if (self.has_aggregates or info.distinct or info.order_by != null) return null;
    const limit = info.limit orelse return null;
    const skipped = if (info.skip) |s| try expressions.evaluateCount(self, self.ast.nodeChildren(s)[0]) else 0;
    return skipped +| try expressions.evaluateCount(self, self.ast.nodeChildren(limit)[0]);
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
    const ordering = try aggregation.orderByAggregating(self, parts.order_by, parts.projected, self.has_aggregates);
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

/// One WITH projection item: `name` is the variable it binds in the new
/// scope (its alias, or the variable it projects), in slot `slot`; an
/// `aggregating` item contains aggregates and is computed per group.
pub const WithItem = struct { name: []const u8, slot: Slot, expr: Index, aggregating: bool };

pub const WithClauseParts = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    where_expression: Index,
    distinct: bool,
    /// Every non-variable expression must have an alias (a WITH; not a
    /// subquery's RETURN).
    requires_aliases: bool,
};
