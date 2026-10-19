//! Projection: WITH (project, group, filter) and RETURN post-processing
//! (DISTINCT, ORDER BY, SKIP, LIMIT).

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const AggKind = @import("../query/ast.zig").AggKind;
const Value = @import("../value.zig").Value;
const eqlSequences = @import("../value.zig").eqlSequences;

const Executor = @import("Executor.zig");
const expressions = @import("expressions.zig");
const aggregation = @import("aggregation.zig");
const ExecError = Executor.ExecError;
const Row = Executor.Row;

const AggState = @import("aggregation.zig").AggState;
const aggResult = @import("aggregation.zig").aggResult;
const Binding = @import("bindings.zig").Binding;
const Bindings = @import("bindings.zig").Bindings;
const bindingKeysEq = @import("bindings.zig").bindingKeysEq;
const bindingsEq = @import("bindings.zig").bindingsEq;

/// Appends a deep copy of `bindings` to `with_rows` (used by WITH).
pub fn collect(self: *Executor, bindings: *Bindings) ExecError!void {
    var copy = Bindings{ .entries = .empty };
    try copy.entries.appendSlice(self.allocator, bindings.entries.items);
    try self.with_rows.append(self.allocator, copy);
}

pub fn withInfo(self: *Executor, wc: Index) WithInfo {
    const kids = self.ast.nodeChildren(wc);
    var info = WithInfo{
        .projection = kids[0],
        .order_by = null,
        .skip = null,
        .limit = null,
        .where_expr = kids[kids.len - 1],
        .distinct = self.ast.data(wc).with_.distinct,
    };
    for (kids[1 .. kids.len - 1]) |child| {
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
pub fn applyWith(self: *Executor, wc: Index) ExecError!void {
    const info = withInfo(self, wc);

    var items = std.ArrayList(WithItem).empty;
    defer items.deinit(self.allocator);
    for (self.ast.nodeChildren(info.projection)) |item| {
        const expr = self.ast.nodeChildren(item)[0];
        const alias = self.ast.data(item).text;
        switch (self.ast.kind(expr)) {
            .agg => {
                if (alias.len == 0) {
                    self.fail(.invalid_expr, "WITH aggregation requires an alias", .{});
                    return error.InvalidExpr;
                }
                const kind = self.ast.data(expr).agg;
                const kids = self.ast.nodeChildren(expr);
                const arg: ?Index = if (kids.len > 0) kids[0] else null;
                try items.append(self.allocator, .{ .agg = .{ .name = alias, .kind = kind, .arg = arg } });
            },
            .variable => {
                const src_name = self.ast.data(expr).text;
                const name = if (alias.len > 0) alias else src_name;
                try items.append(self.allocator, .{ .pass = .{ .name = name, .src_name = src_name } });
            },
            else => {
                if (alias.len == 0) {
                    self.fail(.invalid_expr, "WITH expression requires an alias", .{});
                    return error.InvalidExpr;
                }
                try items.append(self.allocator, .{ .key = .{ .name = alias, .expr = expr } });
            },
        }
    }

    var groups = std.ArrayList(WithGroup).empty;
    defer {
        for (groups.items) |*g| {
            g.keys.deinit(self.allocator);
            g.aggs.deinit(self.allocator);
        }
        groups.deinit(self.allocator);
    }
    for (self.with_rows.items) |*bindings| {
        var keys = std.ArrayList(Binding).empty;
        defer keys.deinit(self.allocator);
        var args = std.ArrayList(Value).empty;
        defer args.deinit(self.allocator);
        for (items.items) |item| {
            switch (item) {
                .pass => |p| {
                    const b = bindings.get(p.src_name) orelse {
                        self.fail(.unknown_var, "unknown variable '{s}'", .{p.src_name});
                        return error.UnknownVar;
                    };
                    try keys.append(self.allocator, b);
                },
                .key => |k| try keys.append(self.allocator, .{ .value = try expressions.eval(self, k.expr, bindings) }),
                .agg => |a| {
                    if (a.arg == null) {
                        try args.append(self.allocator, .{ .int = 0 }); // count(*) always counts
                    } else if (a.kind == .count) {
                        try args.append(self.allocator, try aggregation.evalCountArg(self, a.arg.?, bindings));
                    } else {
                        try args.append(self.allocator, try expressions.eval(self, a.arg.?, bindings));
                    }
                },
            }
        }
        const group = try findOrCreateWithGroup(self, &groups, keys.items, items.items);
        var arg_i: usize = 0;
        for (group.aggs.items) |*state| {
            try aggregation.updateAgg(self, state, args.items[arg_i]);
            arg_i += 1;
        }
    }

    // No grouping keys: zero input rows still aggregate into one row.
    if (groups.items.len == 0 and !hasWithKey(items.items)) {
        _ = try findOrCreateWithGroup(self, &groups, &.{}, items.items);
    }

    var out = std.ArrayList(Bindings).empty;
    for (groups.items) |group| {
        var b = Bindings{ .entries = .empty };
        var key_i: usize = 0;
        var agg_i: usize = 0;
        for (items.items) |item| {
            switch (item) {
                .pass => |p| {
                    try b.put(self.allocator, p.name, group.keys.items[key_i]);
                    key_i += 1;
                },
                .key => |k| {
                    try b.put(self.allocator, k.name, group.keys.items[key_i]);
                    key_i += 1;
                },
                .agg => |a| {
                    try b.put(self.allocator, a.name, .{ .value = aggResult(a.kind, group.aggs.items[agg_i]) });
                    agg_i += 1;
                },
            }
        }
        try out.append(self.allocator, b);
    }

    // WHERE filter (always present; `true` when absent).
    var filtered = std.ArrayList(Bindings).empty;
    for (out.items) |*b| {
        if (try expressions.evalBool(self, info.where_expr, b)) {
            try filtered.append(self.allocator, b.*);
        }
    }
    out = filtered;

    if (info.distinct) dedupBindings(self, &out);

    if (info.order_by) |ob| try sortBindings(self, &out, ob);

    if (info.skip) |sk| try applyBindingsSkip(self, &out, sk);
    if (info.limit) |lim| try applyBindingsLimit(self, &out, lim);

    self.with_rows = out;
}

pub fn findOrCreateWithGroup(self: *Executor, groups: *std.ArrayList(WithGroup), keys: []const Binding, items: []const WithItem) ExecError!*WithGroup {
    for (groups.items) |*g| {
        if (bindingKeysEq(g.keys.items, keys)) return g;
    }
    var group = WithGroup{ .keys = .empty, .aggs = .empty };
    for (keys) |k| try group.keys.append(self.allocator, k);
    for (items) |item| {
        switch (item) {
            .pass, .key => {},
            .agg => |a| try group.aggs.append(self.allocator, AggState{ .kind = a.kind }),
        }
    }
    try groups.append(self.allocator, group);
    return &groups.items[groups.items.len - 1];
}

pub fn dedupBindings(self: *Executor, rows: *std.ArrayList(Bindings)) void {
    _ = self;
    var i: usize = 0;
    while (i < rows.items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < rows.items.len) {
            if (bindingsEq(rows.items[i], rows.items[j])) {
                _ = rows.swapRemove(j);
            } else {
                j += 1;
            }
        }
    }
}

pub fn applyBindingsSkip(self: *Executor, rows: *std.ArrayList(Bindings), skip: Index) ExecError!void {
    const n = try expressions.evalCountExpr(self, self.ast.nodeChildren(skip)[0]);
    if (n >= rows.items.len) {
        rows.shrinkRetainingCapacity(0);
        return;
    }
    var i: usize = 0;
    while (i + n < rows.items.len) : (i += 1) {
        rows.items[i] = rows.items[i + n];
    }
    rows.shrinkRetainingCapacity(rows.items.len - n);
}

pub fn applyBindingsLimit(self: *Executor, rows: *std.ArrayList(Bindings), limit: Index) ExecError!void {
    const n = try expressions.evalCountExpr(self, self.ast.nodeChildren(limit)[0]);
    if (n < rows.items.len) rows.shrinkRetainingCapacity(n);
}

pub fn sortBindings(self: *Executor, rows: *std.ArrayList(Bindings), ob: Index) ExecError!void {
    const n = rows.items.len;
    if (n <= 1) return;

    const items = self.ast.nodeChildren(ob);
    var asc = std.ArrayList(bool).empty;
    defer asc.deinit(self.allocator);
    for (items) |item| try asc.append(self.allocator, self.ast.data(item).order_item.ascending);

    var keys = std.ArrayList(std.ArrayList(Value)).empty;
    defer {
        for (keys.items) |*k| k.deinit(self.allocator);
        keys.deinit(self.allocator);
    }
    for (rows.items) |*b| {
        var ks = std.ArrayList(Value).empty;
        for (items) |item| {
            try ks.append(self.allocator, try expressions.eval(self, self.ast.nodeChildren(item)[0], b));
        }
        try keys.append(self.allocator, ks);
    }

    var idx = std.ArrayList(usize).empty;
    defer idx.deinit(self.allocator);
    var k: usize = 0;
    while (k < n) : (k += 1) try idx.append(self.allocator, k);

    const ctx = WithSortCtx{ .keys = keys.items, .asc = asc.items };
    std.sort.pdq(usize, idx.items, ctx, withLessThanIdx);

    var new_rows = std.ArrayList(Bindings).empty;
    for (idx.items) |i| try new_rows.append(self.allocator, rows.items[i]);
    rows.* = new_rows;
}

pub const ReturnInfo = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    distinct: bool,
};

pub fn returnInfo(self: *Executor, rc: Index) ReturnInfo {
    var info = ReturnInfo{
        .projection = 0,
        .order_by = null,
        .skip = null,
        .limit = null,
        .distinct = self.ast.data(rc).return_.distinct,
    };
    for (self.ast.nodeChildren(rc)) |child| {
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

pub fn postProcess(self: *Executor, rc: Index) ExecError!void {
    const info = returnInfo(self, rc);

    if (self.has_agg) {
        try aggregation.aggregate(self);
    }

    if (info.distinct) dedup(self);

    if (info.order_by) |ob| {
        try sortRows(self, ob);
    }

    if (info.skip) |sk| {
        const n = try expressions.evalCountExpr(self, self.ast.nodeChildren(sk)[0]);
        if (n >= self.rows.items.len) {
            self.rows.shrinkRetainingCapacity(0);
            self.row_keys.shrinkRetainingCapacity(0);
        } else if (n > 0) {
            var i: usize = 0;
            while (i + n < self.rows.items.len) : (i += 1) {
                self.rows.items[i] = self.rows.items[i + n];
                self.row_keys.items[i] = self.row_keys.items[i + n];
            }
            self.rows.shrinkRetainingCapacity(self.rows.items.len - n);
            self.row_keys.shrinkRetainingCapacity(self.row_keys.items.len - n);
        }
    }

    if (info.limit) |lim| {
        const n = try expressions.evalCountExpr(self, self.ast.nodeChildren(lim)[0]);
        if (n < self.rows.items.len) self.rows.shrinkRetainingCapacity(n);
    }
}

pub fn dedup(self: *Executor) void {
    var i: usize = 0;
    while (i < self.rows.items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < self.rows.items.len) {
            if (eqlSequences(self.rows.items[i].items, self.rows.items[j].items)) {
                _ = self.rows.swapRemove(j);
                _ = self.row_keys.swapRemove(j);
            } else {
                j += 1;
            }
        }
    }
}

pub fn sortRows(self: *Executor, ob: Index) ExecError!void {
    const n = self.rows.items.len;
    if (n <= 1) return;

    const items = self.ast.nodeChildren(ob);
    var asc = std.ArrayList(bool).empty;
    defer asc.deinit(self.allocator);
    for (items) |item| try asc.append(self.allocator, self.ast.data(item).order_item.ascending);

    var idx = std.ArrayList(usize).empty;
    defer idx.deinit(self.allocator);
    var k: usize = 0;
    while (k < n) : (k += 1) try idx.append(self.allocator, k);

    const ctx = SortCtx{ .keys = self.row_keys.items, .asc = asc.items };
    std.sort.pdq(usize, idx.items, ctx, lessThanIdx);

    var new_rows = std.ArrayList(Row).empty;
    var new_keys = std.ArrayList([]const Value).empty;
    for (idx.items) |i| {
        try new_rows.append(self.allocator, self.rows.items[i]);
        try new_keys.append(self.allocator, self.row_keys.items[i]);
    }
    self.rows = new_rows;
    self.row_keys = new_keys;
}

/// One `WITH` projection item: a variable passthrough (keeps its node/edge/value
/// binding), a scalar key expression, or an aggregation. `name` is the variable
/// it binds in the new scope (alias, or the variable name for a passthrough).
pub const WithItem = union(enum) {
    pass: struct { name: []const u8, src_name: []const u8 },
    key: struct { name: []const u8, expr: Index },
    agg: struct { name: []const u8, kind: AggKind, arg: ?Index },
};

/// A `WITH` group: binding-valued keys plus the usual aggregation states.
pub const WithGroup = struct {
    keys: std.ArrayList(Binding),
    aggs: std.ArrayList(AggState),
};

pub const WithInfo = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    where_expr: Index,
    distinct: bool,
};

pub fn hasWithKey(items: []const WithItem) bool {
    for (items) |item| if (item != .agg) return true;
    return false;
}

pub const SortCtx = struct {
    keys: []const []const Value,
    asc: []const bool,
};

pub fn lessThanIdx(ctx: SortCtx, a: usize, b: usize) bool {
    const ka = ctx.keys[a];
    const kb = ctx.keys[b];
    for (ka, kb, ctx.asc) |va, vb, asc| {
        const ord = Value.order(va, vb);
        if (ord == .lt) return asc;
        if (ord == .gt) return !asc;
    }
    return false;
}

pub const WithSortCtx = struct {
    keys: []const std.ArrayList(Value),
    asc: []const bool,
};

pub fn withLessThanIdx(ctx: WithSortCtx, a: usize, b: usize) bool {
    const ka = ctx.keys[a].items;
    const kb = ctx.keys[b].items;
    for (ka, kb, ctx.asc) |va, vb, asc| {
        const ord = Value.order(va, vb);
        if (ord == .lt) return asc;
        if (ord == .gt) return !asc;
    }
    return false;
}
