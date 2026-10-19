//! Aggregation: count/sum/min/max/collect with implicit grouping (RETURN).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Index = @import("../query/ast.zig").Index;
const AggregateKind = @import("../query/ast.zig").AggregateKind;
const Value = @import("../value.zig").Value;

const SequenceContext = @import("../sequence_algorithms.zig").SequenceContext;

const Executor = @import("Executor.zig");
const expressions = @import("expressions.zig");
const projection = @import("projection.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;
const asInt = @import("expressions.zig").asInt;

/// Folds one input row into its group (RETURN with aggregates).
pub fn accumulate(self: *Executor, bindings: *Bindings) ExecutionError!void {
    var keys = std.ArrayList(Value).empty;
    var args = std.ArrayList(Value).empty;
    for (self.projection_items.items) |item| {
        switch (item) {
            .key => |expr| try keys.append(self.allocator, try expressions.evaluate(self, expr, bindings)),
            .aggregate => |a| try args.append(self.allocator, try evaluateAggregateArgument(self, a.kind, a.arg, bindings)),
        }
    }
    const states = try self.groups.statesFor(self.allocator, keys.items, self.aggregate_kinds.items);
    for (states, args.items) |*state, arg| try updateAggregate(self, state, arg);
}

/// Evaluates an aggregation argument. `count(*)` (no argument) returns a
/// non-null sentinel so it always counts; `count(x)` returns the real value
/// (a null skips it); other aggregates return the evaluated value.
pub fn evaluateAggregateArgument(self: *Executor, kind: AggregateKind, arg: ?Index, bindings: *Bindings) ExecutionError!Value {
    if (arg == null) return .{ .int = 0 }; // count(*) always counts
    if (kind == .count) return evaluateCountArgument(self, arg.?, bindings);
    return expressions.evaluate(self, arg.?, bindings);
}

/// Evaluates `count(x)`: a bound node/edge variable is non-null; a scalar or
/// property access may be null.
pub fn evaluateCountArgument(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!Value {
    if (self.ast.kind(expr) == .variable) {
        const name = self.ast.data(expr).text;
        switch (bindings.get(name) orelse return error.UnknownVariable) {
            .node, .edge => return .{ .int = 0 }, // bound -> non-null sentinel
            .value => |v| return v, // may be null
        }
    }
    return expressions.evaluate(self, expr, bindings);
}

pub fn updateAggregate(self: *Executor, state: *AggregateState, arg: Value) ExecutionError!void {
    switch (state.kind) {
        .count => {
            if (!Value.isNull(arg)) state.count += 1;
        },
        .sum => {
            if (!Value.isNull(arg)) state.sum += try asInt(arg);
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
        .collect => {
            try state.list.append(self.allocator, arg);
        },
    }
}

/// Turns the groups into RETURN rows: grouping keys and aggregate results in
/// projection order.
pub fn aggregate(self: *Executor, info: projection.ReturnClauseParts) ExecutionError!void {
    self.rows = .empty;
    // With no grouping keys, aggregating zero rows still yields one row
    // (`count` 0, `sum` 0, `min`/`max` null, `collect` []), as in openCypher.
    if (self.groups.keys.items.len == 0 and !hasProjKey(self.projection_items.items)) {
        _ = try self.groups.statesFor(self.allocator, &.{}, self.aggregate_kinds.items);
    }
    for (self.groups.keys.items, self.groups.states.items) |keys, states| {
        var row = std.ArrayList(Value).empty;
        var key_index: usize = 0;
        var aggregate_index: usize = 0;
        for (self.projection_items.items) |item| {
            switch (item) {
                .key => {
                    try row.append(self.allocator, keys[key_index]);
                    key_index += 1;
                },
                .aggregate => |a| {
                    try row.append(self.allocator, aggregateResult(a.kind, states[aggregate_index]));
                    aggregate_index += 1;
                },
            }
        }
        const sort_key = try projection.returnSortKey(self, info, row.items, null);
        try self.rows.append(self.allocator, .{ .item = row, .sort_key = sort_key });
    }
}

/// One projection item: either a grouping key or an aggregation.
pub const ProjectionItem = union(enum) {
    key: Index, // expression index
    aggregate: struct { kind: AggregateKind, arg: ?Index }, // arg = null for count(*)
};

pub const AggregateState = struct {
    kind: AggregateKind,
    count: usize = 0,
    sum: i64 = 0,
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
        /// `kinds`) the first time the key is seen. `key` must outlive `self`.
        pub fn statesFor(self: *Self, allocator: Allocator, key: Key, kinds: []const AggregateKind) Allocator.Error![]AggregateState {
            const entry = try self.index.getOrPutContext(allocator, key, .{});
            if (!entry.found_existing) {
                const states = try allocator.alloc(AggregateState, kinds.len);
                for (states, kinds) |*state, kind| state.* = .{ .kind = kind };
                entry.value_ptr.* = self.keys.items.len;
                try self.keys.append(allocator, key);
                try self.states.append(allocator, states);
            }
            return self.states.items[entry.value_ptr.*];
        }
    };
}

/// RETURN groups: keyed by the values of the non-aggregate projection items.
pub const ValueGrouping = Grouping([]const Value, SequenceContext(Value));

pub fn hasProjKey(items: []const ProjectionItem) bool {
    for (items) |item| if (item == .key) return true;
    return false;
}

pub fn aggregateResult(kind: AggregateKind, state: AggregateState) Value {
    return switch (kind) {
        .count => .{ .int = @intCast(state.count) },
        .sum => .{ .int = state.sum },
        .min => state.min orelse .{ .null = {} },
        .max => state.max orelse .{ .null = {} },
        .collect => .{ .list = state.list.items },
    };
}
