//! Aggregation: count/sum/min/max/collect with implicit grouping (RETURN).

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const AggKind = @import("../query/ast.zig").AggKind;
const Value = @import("../value.zig").Value;
const eqlSequences = @import("../value.zig").eqlSequences;

const Executor = @import("Executor.zig");
const ExecError = Executor.ExecError;

const Bindings = @import("bindings.zig").Bindings;
const asInt = @import("expressions.zig").asInt;

pub fn accumulate(self: *Executor, bindings: *Bindings) ExecError!void {
    var keys = std.ArrayList(Value).empty;
    var args = std.ArrayList(Value).empty;
    for (self.proj_items.items) |item| {
        switch (item) {
            .key => |expr| try keys.append(self.allocator, try self.eval(expr, bindings)),
            .agg => |a| try args.append(self.allocator, try self.evalAggArg(a.kind, a.arg, bindings)),
        }
    }

    const group = try self.findOrCreateGroup(keys.items);
    var arg_i: usize = 0;
    for (group.aggs.items) |*state| {
        try self.updateAgg(state, args.items[arg_i]);
        arg_i += 1;
    }
}

/// Evaluates an aggregation argument. `count(*)` (no argument) returns a
/// non-null sentinel so it always counts; `count(x)` returns the real value
/// (a null skips it); other aggregates return the evaluated value.
pub fn evalAggArg(self: *Executor, kind: AggKind, arg: ?Index, bindings: *Bindings) ExecError!Value {
    if (arg == null) return .{ .int = 0 }; // count(*) always counts
    if (kind == .count) return self.evalCountArg(arg.?, bindings);
    return self.eval(arg.?, bindings);
}

/// Evaluates `count(x)`: a bound node/edge variable is non-null; a scalar or
/// property access may be null.
pub fn evalCountArg(self: *Executor, expr: Index, bindings: *Bindings) ExecError!Value {
    if (self.ast.kind(expr) == .variable) {
        const name = self.ast.data(expr).text;
        switch (bindings.get(name) orelse return error.UnknownVar) {
            .node, .edge => return .{ .int = 0 }, // bound -> non-null sentinel
            .value => |v| return v, // may be null
        }
    }
    return self.eval(expr, bindings);
}

pub fn findOrCreateGroup(self: *Executor, keys: []const Value) ExecError!*Group {
    for (self.groups.items) |*g| {
        if (eqlSequences(g.keys.items, keys)) return g;
    }
    var group = Group{ .keys = .empty, .aggs = .empty };
    for (keys) |k| try group.keys.append(self.allocator, k);
    for (self.proj_items.items) |item| {
        switch (item) {
            .key => {},
            .agg => |a| try group.aggs.append(self.allocator, AggState{ .kind = a.kind }),
        }
    }
    try self.groups.append(self.allocator, group);
    return &self.groups.items[self.groups.items.len - 1];
}

pub fn updateAgg(self: *Executor, state: *AggState, arg: Value) ExecError!void {
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

pub fn aggregate(self: *Executor) ExecError!void {
    self.rows = .empty;
    self.row_keys = .empty;
    // With no grouping keys, aggregating zero rows still yields one row
    // (`count` 0, `sum` 0, `min`/`max` null, `collect` []), as in openCypher.
    if (self.groups.items.len == 0 and !hasProjKey(self.proj_items.items)) {
        _ = try self.findOrCreateGroup(&.{});
    }
    for (self.groups.items) |group| {
        var row = std.ArrayList(Value).empty;
        var key_i: usize = 0;
        var agg_i: usize = 0;
        for (self.proj_items.items) |item| {
            switch (item) {
                .key => {
                    try row.append(self.allocator, group.keys.items[key_i]);
                    key_i += 1;
                },
                .agg => |a| {
                    try row.append(self.allocator, aggResult(a.kind, group.aggs.items[agg_i]));
                    agg_i += 1;
                },
            }
        }
        try self.rows.append(self.allocator, row);
        try self.row_keys.append(self.allocator, @as([]const Value, &.{}));
    }
}

/// One projection item: either a grouping key or an aggregation.
pub const ProjItem = union(enum) {
    key: Index, // expression index
    agg: struct { kind: AggKind, arg: ?Index }, // arg = null for count(*)
};

pub const AggState = struct {
    kind: AggKind,
    count: usize = 0,
    sum: i64 = 0,
    min: ?Value = null,
    max: ?Value = null,
    list: std.ArrayList(Value) = .empty,
};

pub const Group = struct {
    keys: std.ArrayList(Value),
    aggs: std.ArrayList(AggState),
};

pub fn hasProjKey(items: []const ProjItem) bool {
    for (items) |item| if (item == .key) return true;
    return false;
}

pub fn aggResult(kind: AggKind, state: AggState) Value {
    return switch (kind) {
        .count => .{ .int = @intCast(state.count) },
        .sum => .{ .int = state.sum },
        .min => state.min orelse .{ .null = {} },
        .max => state.max orelse .{ .null = {} },
        .collect => .{ .list = state.list.items },
    };
}
