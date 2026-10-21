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
/// aggregation), then applies WHERE / DISTINCT / ORDER BY / SKIP / LIMIT,
/// rebinding the result into fresh variable bindings for the next clauses.
/// (Also a subquery's RETURN, whose rows are made the same way.)
pub fn applyWith(self: *Executor, with_clause: Index, input: []Bindings) ExecutionError![]Bindings {
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
        for (input) |*input_row| {
            const row = try withRow(self, info, items, input_row) orelse continue;
            // Without grouping, the ORDER BY also sees the variables from
            // before the WITH (the projected names win).
            const sort_key = if (info.order_by) |order_by| key: {
                var scope = try clauses.copyRow(self, input_row.*);
                for (row.entries.items) |entry| try scope.put(self.allocator, entry.name, entry.value);
                break :key try orderByKey(self, order_by, &scope);
            } else &.{};
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
            if (info.where_expression != Executor.no_where and !try expressions.evaluateBool(self, info.where_expression, &row)) continue;
            const sort_key = try groupSortKey(self, info.order_by, projected, values.items, &row, aggregation_plan, key_values, states);
            try rows.append(self.allocator, .{ .item = row, .sort_key = sort_key });
        }
    }

    if (info.distinct) {
        try sequence_algorithms.removeDuplicates(Sortable(Bindings), self.allocator, &rows, SortableContext(Bindings, ElementContext(Bindings)){});
    }
    try orderAndPaginate(self, Bindings, &rows, info.order_by, info.skip, info.limit);

    const output = try self.allocator.alloc(Bindings, rows.items.len);
    for (output, rows.items) |*row, sortable| row.* = sortable.item;
    return output;
}

/// One input row of a WITH without aggregates, projected into the new scope,
/// or null if the WITH's WHERE drops it.
pub fn withRow(self: *Executor, info: WithClauseParts, items: []const WithItem, input_row: *Bindings) ExecutionError!?Bindings {
    var row = Bindings{ .entries = .empty };
    for (items) |item| try row.put(self.allocator, item.name, try expressions.evaluate(self, item.expr, input_row));
    // The WHERE also sees the variables from before the WITH (the projected
    // names win): `WITH x[i] AS v WHERE i > 0`.
    if (info.where_expression != Executor.no_where) {
        var scope = try clauses.copyRow(self, input_row.*);
        for (row.entries.items) |entry| try scope.put(self.allocator, entry.name, entry.value);
        if (!try expressions.evaluateBool(self, info.where_expression, &scope)) return null;
    }
    return row;
}

/// Whether a WITH can pass its rows on one at a time: it neither groups,
/// removes duplicates, sorts nor pages.
pub fn withStreams(self: *Executor, with_clause: Index) ExecutionError!bool {
    const info = withClauseParts(self, with_clause);
    if (info.distinct or info.order_by != null or info.skip != null or info.limit != null) return false;
    for (try withItems(self, info)) |item| if (item.aggregating) return false;
    return true;
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
        try items.append(self.allocator, .{ .name = name, .expr = expr, .aggregating = aggregation.containsAggregate(self, expr) });
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
/// ORDER BY, then SKIP and LIMIT. With a LIMIT only the rows that can be
/// kept are put in order (a partial sort: O(n log k), not O(n log n)).
fn orderAndPaginate(self: *Executor, comptime T: type, rows: *std.ArrayList(Sortable(T)), order_by: ?Index, skip: ?Index, limit: ?Index) ExecutionError!void {
    if (order_by) |order| {
        const directions = try orderByDirections(self, order);
        if (limit) |l| {
            const skipped = if (skip) |s| try expressions.evaluateCount(self, self.ast.nodeChildren(s)[0]) else 0;
            const kept = try expressions.evaluateCount(self, self.ast.nodeChildren(l)[0]);
            try sequence_algorithms.partialSortStable(Sortable(T), self.allocator, rows.items, skipped +| kept, directions, struct {
                fn lessThan(ascending: []const bool, a: Sortable(T), b: Sortable(T)) bool {
                    return keyLessThan(ascending, a.sort_key, b.sort_key);
                }
            }.lessThan);
        } else sortByKey(T, rows.items, directions);
    }
    try paginate(self, Sortable(T), rows, skip, limit);
}

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

/// Starts a RETURN: plans its projection and aggregation. Then each row goes
/// to `returnRow`, and `endReturn` produces the result in `self.rows`.
pub fn beginReturn(self: *Executor, return_clause: Index) ExecutionError!ReturnClauseParts {
    const info = returnClauseParts(self, return_clause);
    try planReturn(self, info);
    return info;
}

/// Adds one row to a RETURN: accumulated into its group, or projected. The
/// row is not kept, so the caller may reuse it.
pub fn returnRow(self: *Executor, info: ReturnClauseParts, row: *Bindings) ExecutionError!void {
    if (self.has_aggregates) return aggregation.accumulate(self, row);
    var values = std.ArrayList(Value).empty;
    for (self.ast.nodeChildren(info.projection)) |item| {
        try values.append(self.allocator, try expressions.evaluate(self, self.ast.nodeChildren(item)[0], row));
    }
    // The ORDER BY key is evaluated now, while the row's variables are
    // still bound: it may use variables that are not projected.
    const sort_key = try returnSortKey(self, info, values.items, row);
    try self.rows.append(self.allocator, .{ .item = values, .sort_key = sort_key });
}

/// Ends a RETURN: aggregates, removes duplicates, sorts and pages `self.rows`.
pub fn endReturn(self: *Executor, info: ReturnClauseParts) ExecutionError!void {
    if (self.has_aggregates) try aggregation.aggregate(self, info);
    if (info.distinct) {
        try sequence_algorithms.removeDuplicates(Sortable(Row), self.allocator, &self.rows, SortableContext(Row, RowContext){});
    }
    try orderAndPaginate(self, Row, &self.rows, info.order_by, info.skip, info.limit);
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
    /// Every non-variable expression must have an alias (a WITH; not a
    /// subquery's RETURN).
    requires_aliases: bool,
};
