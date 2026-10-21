//! Aggregation: count/sum/min/max/collect with implicit grouping, for RETURN
//! and WITH. Aggregates may sit anywhere in a projected expression
//! (`count(*) + 1`, `sum(x) * 100 / count(*)`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Index = @import("../query/ast.zig").Index;
const AggregateKind = @import("../query/ast.zig").AggregateKind;
const AggregateCall = @import("../query/ast.zig").AggregateCall;
const isSubquery = @import("../query/ast.zig").isSubquery;
const Value = @import("../value.zig").Value;

const SequenceContext = @import("../sequence_algorithms.zig").SequenceContext;
const ElementContext = @import("../sequence_algorithms.zig").ElementContext;

const Executor = @import("Executor.zig");
const expressions = @import("expressions.zig");
const projection = @import("projection.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;
const asFloat = @import("expressions.zig").asFloat;

/// How a projection (RETURN or WITH) aggregates: its grouping keys, and every
/// aggregate call inside its aggregating expressions, in order.
pub const AggregationPlan = struct {
    keys: []const Index,
    aggregates: []const Index,
    kinds: []const AggregateCall,
};

/// True if `expr` contains an aggregate call anywhere.
pub fn containsAggregate(self: *const Executor, expr: Index) bool {
    if (self.ast.kind(expr) == .aggregate) return true;
    if (isSubquery(self.ast.kind(expr))) return false; // its aggregates are its own
    for (self.ast.nodeChildren(expr)) |child| {
        if (containsAggregate(self, child)) return true;
    }
    return false;
}

/// Builds the plan of a projection: `keys` are the grouping-key expressions,
/// `aggregating` the expressions that contain aggregates. Checks openCypher's
/// rules: no aggregate inside an aggregate, and an aggregating expression
/// uses, outside its aggregates, only constants and grouping keys
/// (AmbiguousAggregationExpression).
/// `aliases` are the projection's names, also usable next to an aggregate
/// (in ORDER BY: `RETURN n.x AS x, count(*) ORDER BY x + count(*)`).
pub fn plan(self: *Executor, keys: []const Index, aggregating: []const Index, aliases: []const []const u8) ExecutionError!AggregationPlan {
    var aggregates = std.ArrayList(Index).empty;
    var kinds = std.ArrayList(AggregateCall).empty;
    for (aggregating) |expr| {
        try checkAggregating(self, expr, keys, aliases);
        try collectAggregates(self, expr, &aggregates, &kinds);
    }
    return .{ .keys = keys, .aggregates = aggregates.items, .kinds = kinds.items };
}

fn collectAggregates(self: *Executor, expr: Index, aggregates: *std.ArrayList(Index), kinds: *std.ArrayList(AggregateCall)) ExecutionError!void {
    if (self.ast.kind(expr) == .aggregate) {
        for (self.ast.nodeChildren(expr)) |argument| {
            if (containsAggregate(self, argument)) {
                self.fail(.invalid_expression, "an aggregate cannot contain another aggregate", .{});
                return error.InvalidExpression;
            }
        }
        try aggregates.append(self.allocator, expr);
        try kinds.append(self.allocator, self.ast.data(expr).aggregate);
        return;
    }
    if (isSubquery(self.ast.kind(expr))) return;
    for (self.ast.nodeChildren(expr)) |child| try collectAggregates(self, child, aggregates, kinds);
}

fn checkAggregating(self: *Executor, expr: Index, keys: []const Index, aliases: []const []const u8) ExecutionError!void {
    if (self.ast.kind(expr) == .aggregate) return; // its argument is read per row
    // Only a simple grouping key (a variable or a property) may be reused
    // next to an aggregate, even if a more complex one is projected.
    switch (self.ast.kind(expr)) {
        .variable, .property_access => for (keys) |key| {
            if (self.ast.sameExpression(expr, key)) return;
        },
        else => {},
    }
    // A comprehension's or quantifier's variable is local to it.
    const local: ?[]const u8 = switch (self.ast.kind(expr)) {
        .list_comprehension => self.ast.data(expr).text,
        .quantifier => self.ast.data(expr).quantifier.variable_name,
        else => null,
    };
    if (local) |name| {
        const children = self.ast.nodeChildren(expr);
        try checkAggregating(self, children[0], keys, aliases);
        const with_local = try std.mem.concat(self.allocator, []const u8, &.{ aliases, &.{name} });
        for (children[1..]) |child| try checkAggregating(self, child, keys, with_local);
        return;
    }
    if (self.ast.kind(expr) == .variable) {
        const name = self.ast.data(expr).text;
        for (aliases) |alias| {
            if (std.mem.eql(u8, alias, name)) return;
        }
        self.fail(.invalid_expression, "'{s}' is used next to an aggregate but is not a grouping key", .{name});
        return error.InvalidExpression;
    }
    for (self.ast.nodeChildren(expr)) |child| try checkAggregating(self, child, keys, aliases);
}

/// The ORDER BY expressions that aggregate and are not simply a projected
/// column: they are computed per group, like the projection's aggregating
/// expressions. Each aggregate in them must be one the projection computes
/// (`ORDER BY age + count(x)` with `count(x)` projected), and a projection
/// that does not aggregate cannot order by an aggregate. Checked before any
/// row is read.
pub fn orderByAggregating(self: *Executor, order_by: ?Index, projected: []const Index, projection_aggregates: bool) ExecutionError![]const Index {
    const order = order_by orelse return &.{};
    var aggregating = std.ArrayList(Index).empty;
    for (self.ast.nodeChildren(order)) |order_item| {
        const expr = self.ast.nodeChildren(order_item)[0];
        if (!containsAggregate(self, expr)) continue;
        if (!projection_aggregates) {
            self.fail(.invalid_expression, "ORDER BY cannot aggregate when the projection does not", .{});
            return error.InvalidExpression;
        }
        for (projected) |item| {
            if (self.ast.sameExpression(expr, item)) break;
        } else {
            try requireProjectedAggregates(self, expr, projected);
            try aggregating.append(self.allocator, expr);
        }
    }
    return aggregating.items;
}

/// Every aggregate call under `expr` repeats one under the projection.
fn requireProjectedAggregates(self: *Executor, expr: Index, projected: []const Index) ExecutionError!void {
    if (self.ast.kind(expr) == .aggregate) {
        for (projected) |item| {
            if (containsExpression(self, item, expr)) return;
        }
        self.fail(.invalid_expression, "ORDER BY uses an aggregate the projection does not compute", .{});
        return error.InvalidExpression;
    }
    for (self.ast.nodeChildren(expr)) |child| try requireProjectedAggregates(self, child, projected);
}

/// True if `needle`'s expression appears anywhere under `haystack`.
fn containsExpression(self: *Executor, haystack: Index, needle: Index) bool {
    if (self.ast.sameExpression(haystack, needle)) return true;
    for (self.ast.nodeChildren(haystack)) |child| {
        if (containsExpression(self, child, needle)) return true;
    }
    return false;
}

/// Folds one input row into its group.
pub fn accumulateRow(self: *Executor, grouping: *ValueGrouping, aggregation: AggregationPlan, bindings: *Bindings) ExecutionError!void {
    // The key is evaluated into a scratch buffer: most rows join a group that
    // exists, and only a new group keeps a copy (see `statesFor`).
    var buffer: [8]Value = undefined;
    const keys = if (aggregation.keys.len <= buffer.len) buffer[0..aggregation.keys.len] else try self.allocator.alloc(Value, aggregation.keys.len);
    for (keys, aggregation.keys) |*key, expr| key.* = try expressions.evaluate(self, expr, bindings);
    const states = try grouping.statesFor(self.allocator, keys, aggregation.kinds);
    for (states, aggregation.aggregates) |*state, call| {
        const arguments = self.ast.nodeChildren(call);
        if (state.kind == .percentileDisc or state.kind == .percentileCont) {
            state.percentile = try percentileArgument(self, try expressions.evaluate(self, arguments[1], bindings));
        }
        try updateAggregate(self, state, try evaluateAggregateArgument(self, if (arguments.len > 0) arguments[0] else null, bindings));
    }
}

/// With no grouping keys, aggregating zero rows still yields one group
/// (`count` 0, `sum` 0, `min`/`max` null, `collect` []), as in openCypher.
pub fn ensureGroupWithoutKeys(self: *Executor, grouping: *ValueGrouping, aggregation: AggregationPlan) ExecutionError!void {
    if (grouping.keys.items.len == 0 and aggregation.keys.len == 0) {
        _ = try grouping.statesFor(self.allocator, &.{}, aggregation.kinds);
    }
}

/// The value of an aggregating expression for one group: each aggregate
/// call is replaced by its result and each grouping-key expression by the
/// group's key value; any other variable (an alias) is read from `scope`.
pub fn evaluateAggregating(self: *Executor, expr: Index, aggregation: AggregationPlan, key_values: []const Value, states: []const AggregateState, scope: *Bindings) ExecutionError!Value {
    var overrides = std.AutoHashMapUnmanaged(Index, Value).empty;
    for (aggregation.aggregates, states) |call, state| {
        try overrides.put(self.allocator, call, aggregateResult(self.ast.data(call).aggregate.kind, state));
    }
    try overrideKeys(self, expr, aggregation, key_values, &overrides);

    const saved = self.expression_overrides;
    self.expression_overrides = &overrides;
    defer self.expression_overrides = saved;
    return expressions.evaluate(self, expr, scope);
}

fn overrideKeys(self: *Executor, expr: Index, aggregation: AggregationPlan, key_values: []const Value, overrides: *std.AutoHashMapUnmanaged(Index, Value)) ExecutionError!void {
    if (self.ast.kind(expr) == .aggregate) return;
    for (aggregation.keys, key_values) |key, value| {
        if (self.ast.sameExpression(expr, key)) return overrides.put(self.allocator, expr, value);
    }
    for (self.ast.nodeChildren(expr)) |child| try overrideKeys(self, child, aggregation, key_values, overrides);
}

/// RETURN with aggregates: folds one input row into its group.
pub fn accumulate(self: *Executor, bindings: *Bindings) ExecutionError!void {
    try accumulateRow(self, &self.groups, self.return_aggregation, bindings);
}

/// Evaluates an aggregation argument. `count(*)` (no argument) returns a
/// non-null sentinel so it always counts; otherwise the argument's value (a
/// null is skipped by the aggregate).
pub fn evaluateAggregateArgument(self: *Executor, arg: ?Index, bindings: *Bindings) ExecutionError!Value {
    if (arg == null) return .{ .int = 0 }; // count(*) always counts
    return expressions.evaluate(self, arg.?, bindings);
}

pub fn updateAggregate(self: *Executor, state: *AggregateState, arg: Value) ExecutionError!void {
    if (state.distinct and arg != .null) {
        if ((try state.seen.getOrPutContext(self.allocator, arg, .{})).found_existing) return;
    }
    switch (state.kind) {
        .count => {
            if (!Value.isNull(arg)) state.count += 1;
        },
        .sum => switch (arg) {
            .null => {},
            .int => |n| state.sum = std.math.add(i64, state.sum, n) catch {
                self.fail(.arithmetic, "integer overflow: the sum does not fit in 64 bits", .{});
                return error.IntegerOverflow;
            },
            .float => |x| {
                state.float_sum += x;
                state.has_float = true;
            },
            else => return notANumber(self, "sum"),
        },
        .avg, .stDev, .stDevP => switch (arg) {
            .null => {},
            // Welford's update: a running mean and sum of squared deviations,
            // stable where a sum of squares would cancel.
            .int, .float => {
                const x = asFloat(arg);
                state.count += 1;
                const delta = x - state.mean;
                state.mean += delta / @as(f64, @floatFromInt(state.count));
                state.squared_deviations += delta * (x - state.mean);
            },
            else => return notANumber(self, @tagName(state.kind)),
        },
        .min => {
            if (Value.isNull(arg)) return;
            if (state.min) |m| {
                if (Value.order(arg, m) == .lt) state.min = arg;
            } else state.min = arg;
        },
        .max => {
            if (Value.isNull(arg)) return;
            if (state.max) |m| {
                if (Value.order(arg, m) == .gt) state.max = arg;
            } else state.max = arg;
        },
        // Like every aggregate, collect skips nulls.
        .collect => if (arg != .null) try state.list.append(self.allocator, arg),
        .percentileDisc, .percentileCont => switch (arg) {
            .null => {},
            .int, .float => try state.list.append(self.allocator, arg),
            else => return notANumber(self, @tagName(state.kind)),
        },
    }
}

/// A percentile: a number from 0 to 1.
fn percentileArgument(self: *Executor, value: Value) ExecutionError!f64 {
    const p: f64 = switch (value) {
        .int => |n| @floatFromInt(n),
        .float => |x| x,
        else => return notANumber(self, "the percentile"),
    };
    if (!(p >= 0 and p <= 1)) {
        self.fail(.invalid_expression, "a percentile is a number from 0.0 to 1.0, not {d}", .{p});
        return error.InvalidExpression;
    }
    return p;
}

/// The percentile of `numbers` (sorted here), as Neo4j computes it:
/// `percentileDisc` the value at index floor(p * n) (one less when p * n is
/// a whole number other than 0), `percentileCont` interpolated at p * (n - 1).
fn percentile(kind: AggregateKind, numbers: []Value, p: f64) Value {
    if (numbers.len == 0) return .{ .null = {} };
    std.mem.sort(Value, numbers, {}, struct {
        fn lessThan(_: void, a: Value, b: Value) bool {
            return Value.order(a, b) == .lt;
        }
    }.lessThan);
    const count: f64 = @floatFromInt(numbers.len);
    if (kind == .percentileDisc) {
        const position = p * count;
        const whole: usize = @intFromFloat(@floor(position));
        const index = if (position != @floor(position) or whole == 0) whole else whole - 1;
        return numbers[@min(index, numbers.len - 1)];
    }
    const position = p * (count - 1);
    const below: usize = @intFromFloat(@floor(position));
    const above: usize = @intFromFloat(@ceil(position));
    const low = asFloat(numbers[below]);
    if (below == above) return .{ .float = low };
    return .{ .float = low + (asFloat(numbers[above]) - low) * (position - @floor(position)) };
}

fn notANumber(self: *Executor, function: []const u8) ExecutionError {
    self.fail(.type_mismatch, "{s}() needs numbers", .{function});
    return error.TypeMismatch;
}

/// Turns the groups into RETURN rows: grouping keys and aggregate results in
/// projection order.
/// RETURN with aggregates: turns the groups into rows, in projection order.
pub fn aggregate(self: *Executor, info: projection.ReturnClauseParts) ExecutionError!void {
    self.rows = .empty;
    try ensureGroupWithoutKeys(self, &self.groups, self.return_aggregation);
    const projected = try self.projectedExpressions(info.projection);
    for (self.groups.keys.items, self.groups.states.items) |keys, states| {
        var row = std.ArrayList(Value).empty;
        var key_index: usize = 0;
        var scope = Bindings{ .entries = .empty };
        for (self.projection_items.items, self.ast.nodeChildren(info.projection)) |item, item_node| {
            const value = switch (item) {
                .key => value: {
                    key_index += 1;
                    break :value keys[key_index - 1];
                },
                .aggregating => |expr| try evaluateAggregating(self, expr, self.return_aggregation, keys, states, &scope),
            };
            try row.append(self.allocator, value);
            const alias = self.ast.data(item_node).text;
            if (alias.len > 0) try scope.put(self.allocator, alias, value);
        }
        const sort_key = try projection.groupSortKey(self, info.order_by, projected, row.items, &scope, self.return_aggregation, keys, states);
        try self.rows.append(self.allocator, .{ .item = row, .sort_key = sort_key });
    }
}

/// One projection item: either a grouping key or an aggregation.
/// One RETURN projection item: a grouping key, or an expression containing
/// aggregates.
pub const ProjectionItem = union(enum) {
    key: Index,
    aggregating: Index,
};

pub const AggregateState = struct {
    kind: AggregateKind,
    /// percentileDisc / percentileCont: the percentile asked for.
    percentile: f64 = 0,
    /// `count(DISTINCT x)`: each value counts once; `seen` holds those met.
    distinct: bool = false,
    seen: std.HashMapUnmanaged(Value, void, ElementContext(Value), std.hash_map.default_max_load_percentage) = .empty,
    count: usize = 0,
    /// sum: the integers' total, and the floats' (when there are any).
    sum: i64 = 0,
    float_sum: f64 = 0,
    has_float: bool = false,
    /// avg, stDev, stDevP: the running mean and the sum of squared
    /// deviations from it, over `count` numbers.
    mean: f64 = 0,
    squared_deviations: f64 = 0,
    min: ?Value = null,
    max: ?Value = null,
    list: std.ArrayList(Value) = .empty,
};

/// Rows grouped by key, each group holding one `AggregateState` per aggregate.
/// Groups keep first-seen order; lookup is a hash probe (expected O(1)), so
/// grouping n rows is O(n). `KeyContext` is a std.HashMap context for `Key`
/// (see `sequence_algorithms`). Keys and states live in the executor's arena.
pub fn Grouping(comptime Key: type, comptime KeyContext: type) type {
    return struct {
        const Self = @This();

        keys: std.ArrayList(Key) = .empty,
        states: std.ArrayList([]AggregateState) = .empty,
        index: std.HashMapUnmanaged(Key, usize, KeyContext, std.hash_map.default_max_load_percentage) = .empty,

        /// The aggregation states of `key`'s group, created (one per entry of
        /// `kinds`) the first time the key is seen. A slice key (a row of
        /// values) is copied then, so the caller may reuse its buffer.
        pub fn statesFor(self: *Self, allocator: Allocator, key: Key, kinds: []const AggregateCall) Allocator.Error![]AggregateState {
            const entry = try self.index.getOrPutContext(allocator, key, .{});
            if (!entry.found_existing) {
                if (@typeInfo(Key) == .pointer and @typeInfo(Key).pointer.size == .slice) {
                    entry.key_ptr.* = try allocator.dupe(@typeInfo(Key).pointer.child, key);
                }
                const states = try allocator.alloc(AggregateState, kinds.len);
                for (states, kinds) |*state, call| state.* = .{ .kind = call.kind, .distinct = call.distinct };
                entry.value_ptr.* = self.keys.items.len;
                try self.keys.append(allocator, entry.key_ptr.*);
                try self.states.append(allocator, states);
            }
            return self.states.items[entry.value_ptr.*];
        }
    };
}

/// RETURN groups: keyed by the values of the non-aggregate projection items.
pub const ValueGrouping = Grouping([]const Value, SequenceContext(Value));

pub fn aggregateResult(kind: AggregateKind, state: AggregateState) Value {
    return switch (kind) {
        .count => .{ .int = @intCast(state.count) },
        .sum => if (state.has_float) .{ .float = @as(f64, @floatFromInt(state.sum)) + state.float_sum } else .{ .int = state.sum },
        .avg => if (state.count == 0) .{ .null = {} } else .{ .float = state.mean },
        // Sample (n - 1) and population (n) standard deviation; 0 when undefined.
        .stDev => .{ .float = if (state.count < 2) 0 else @sqrt(state.squared_deviations / @as(f64, @floatFromInt(state.count - 1))) },
        .stDevP => .{ .float = if (state.count == 0) 0 else @sqrt(state.squared_deviations / @as(f64, @floatFromInt(state.count))) },
        .min => state.min orelse .{ .null = {} },
        .max => state.max orelse .{ .null = {} },
        .collect => .{ .list = state.list.items },
        .percentileDisc, .percentileCont => percentile(kind, state.list.items, state.percentile),
    };
}
