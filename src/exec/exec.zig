//! Volcano-style executor for the openCypher subset, now with write clauses.
//!
//! A query is a list of clauses (`match`, `create`, `set`, `delete`, `return`).
//! The `MATCH` clause is planned as before (anchor selection, predicate
//! pushdown) and produces variable bindings; then each `CREATE`/`SET`/`DELETE`
//! clause is applied to every binding, and finally `RETURN` projects (if
//! present). A query with no `MATCH` is applied to a single empty binding, so a
//! standalone `CREATE ...` works.
//!
//! Bindings map variable names to node ids dynamically, since `CREATE`
//! introduces new variables at runtime.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = @import("../ast/ast.zig").Ast;
const Index = @import("../ast/ast.zig").Index;
const NodeKind = @import("../ast/ast.zig").NodeKind;
const BinOp = @import("../ast/ast.zig").BinOp;
const UnOp = @import("../ast/ast.zig").UnOp;
const AggKind = @import("../ast/ast.zig").AggKind;
const Graph = @import("../storage/graph.zig").Graph;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../storage/graph.zig").Value;
const Direction = @import("../storage/graph.zig").Direction;
const KvError = @import("../storage/kv_store.zig").KvError;
const Diagnostic = @import("../diag.zig").Diagnostic;

pub const ExecError = KvError || error{
    UnknownVar,
    MissingProp,
    InvalidExpr,
    TypeMismatch,
};

/// A projected row: one `Value` per RETURN item.
pub const Row = std.ArrayList(Value);

/// An equality predicate `node.prop = value_expr` pushed down to a node.
const Seek = struct {
    prop: []const u8,
    value: Index, // AST literal expr
};

const ChainNode = struct {
    var_name: []const u8,
    label: []const u8,
    seeks: std.ArrayList(Seek),
    bound: bool, // already bound by an earlier pattern in this query
};

const ChainEdge = struct {
    etype: []const u8,
    fwd_dir: Direction, // direction when traversing node_i -> node_{i+1}
    var_name: []const u8,
    seeks: std.ArrayList(Seek), // inline property equality filters
};

const BindStep = union(enum) {
    scan: struct { node: usize },
    expand: struct { from: usize, to: usize },
};

/// Reference to a directed edge, used to bind relationship variables.
const EdgeRef = struct {
    src: NodeId,
    dst: NodeId,
    etype: []const u8,
};

const Binding = union(enum) {
    node: NodeId,
    edge: EdgeRef,
};

/// Dynamic variable-name -> value bindings (nodes and relationships).
const Bindings = struct {
    entries: std.ArrayList(struct { name: []const u8, value: Binding }),

    fn get(self: *const Bindings, name: []const u8) ?Binding {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }

    fn put(self: *Bindings, allocator: Allocator, name: []const u8, value: Binding) !void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                e.value = value;
                return;
            }
        }
        try self.entries.append(allocator, .{ .name = name, .value = value });
    }

    fn getNode(self: *const Bindings, name: []const u8) ?NodeId {
        return switch (self.get(name) orelse return null) {
            .node => |id| id,
            .edge => null,
        };
    }

    fn getEdge(self: *const Bindings, name: []const u8) ?EdgeRef {
        return switch (self.get(name) orelse return null) {
            .node => null,
            .edge => |e| e,
        };
    }
};

/// One projection item: either a grouping key or an aggregation.
const ProjItem = union(enum) {
    key: Index, // expression index
    agg: struct { kind: AggKind, arg: ?Index }, // arg = null for count(*)
};

const AggState = struct {
    kind: AggKind,
    count: usize = 0,
    sum: i64 = 0,
    min: ?Value = null,
    max: ?Value = null,
};

const Group = struct {
    keys: std.ArrayList(Value),
    aggs: std.ArrayList(AggState),
};

pub const Executor = struct {
    ast: *Ast,
    graph: *Graph,
    allocator: Allocator,
    rows: std.ArrayList(Row),

    // Match context.
    patterns: []const Index, // the MATCH clause's patterns (one or more)
    nodes: std.ArrayList(ChainNode),
    edges: std.ArrayList(ChainEdge),
    steps: std.ArrayList(BindStep),
    where_expr: Index,
    has_match: bool,

    // Write context.
    update_clauses: std.ArrayList(Index),
    return_clause: ?Index,

    // Result post-processing.
    row_keys: std.ArrayList([]const Value),

    // Aggregation.
    has_agg: bool,
    proj_items: std.ArrayList(ProjItem),
    groups: std.ArrayList(Group),

    /// Optional sink for error messages (message + source position).
    diag: ?*Diagnostic,

    pub fn init(ast: *Ast, graph: *Graph, allocator: Allocator) Executor {
        return .{
            .ast = ast,
            .graph = graph,
            .allocator = allocator,
            .rows = .empty,
            .patterns = &.{},
            .nodes = .empty,
            .edges = .empty,
            .steps = .empty,
            .where_expr = 0,
            .has_match = false,
            .update_clauses = .empty,
            .return_clause = null,
            .row_keys = .empty,
            .has_agg = false,
            .proj_items = .empty,
            .groups = .empty,
            .diag = null,
        };
    }

    fn fail(self: *Executor, comptime fmt: []const u8, args: anytype) void {
        if (self.diag) |d| d.set(0, fmt, args);
    }

    pub fn run(self: *Executor, query: Index) ExecError![]const Row {
        self.rows.clearRetainingCapacity();
        self.row_keys = .empty;
        self.groups = .empty;
        self.has_agg = false;
        self.proj_items = .empty;

        var match_clause: ?Index = null;
        self.update_clauses = .empty;
        self.return_clause = null;
        for (self.ast.nodeChildren(query)) |c| {
            switch (self.ast.kind(c)) {
                .match_clause => match_clause = c,
                .create_clause, .merge_clause, .set_clause, .delete_clause => try self.update_clauses.append(self.allocator, c),
                .return_clause => self.return_clause = c,
                else => {},
            }
        }

        // Detect aggregations in the projection (grouping).
        if (self.return_clause) |rc| {
            const info = self.returnInfo(rc);
            for (self.ast.nodeChildren(info.projection)) |item| {
                const expr = self.ast.nodeChildren(item)[0];
                if (self.ast.kind(expr) == .agg) {
                    self.has_agg = true;
                    const kind = self.ast.data(expr).agg;
                    const kids = self.ast.nodeChildren(expr);
                    const arg: ?Index = if (kids.len > 0) kids[0] else null;
                    try self.proj_items.append(self.allocator, .{ .agg = .{ .kind = kind, .arg = arg } });
                } else {
                    try self.proj_items.append(self.allocator, .{ .key = expr });
                }
            }
        }

        // All writes of this query commit (or abort) atomically.
        const has_writes = self.update_clauses.items.len > 0;
        if (has_writes) try self.graph.beginWrite();
        errdefer if (has_writes) self.graph.abortWrite();

        var bindings = Bindings{ .entries = .empty };
        if (match_clause) |mc| {
            const mc_children = self.ast.nodeChildren(mc);
            self.has_match = true;
            // children = [pattern0, ..., patternN, where_expr]
            self.patterns = mc_children[0 .. mc_children.len - 1];
            self.where_expr = mc_children[mc_children.len - 1];
            try self.matchPatterns(0, &bindings);
        } else {
            self.has_match = false;
            try self.finish(&bindings);
        }

        if (has_writes) try self.graph.commitWrite();

        if (self.return_clause) |rc| {
            try self.postProcess(rc);
        }

        return self.rows.items;
    }

    // --- Planning ----------------------------------------------------------

    fn setupPattern(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
        const chain = self.ast.nodeChildren(pattern);
        const num_nodes = (chain.len + 1) / 2;

        self.nodes = .empty;
        self.edges = .empty;
        for (0..num_nodes) |i| {
            const np_idx = chain[i * 2];
            const np = self.ast.data(np_idx).node_pattern;
            var node = ChainNode{
                .var_name = np.var_name,
                .label = np.label,
                .seeks = .empty,
                .bound = bindings.getNode(np.var_name) != null,
            };
            for (self.ast.nodeChildren(np_idx)) |prop_idx| {
                const prop_name = self.ast.data(prop_idx).text;
                const value = self.ast.nodeChildren(prop_idx)[0];
                try node.seeks.append(self.allocator, .{ .prop = prop_name, .value = value });
            }
            try self.nodes.append(self.allocator, node);

            if (i + 1 < num_nodes) {
                const ep_idx = chain[i * 2 + 1];
                const ep = self.ast.data(ep_idx).edge_pattern;
                const fwd_dir: Direction = switch (ep.direction) {
                    .left_to_right => .out,
                    .right_to_left => .in,
                };
                var edge = ChainEdge{ .etype = ep.etype, .fwd_dir = fwd_dir, .var_name = ep.var_name, .seeks = .empty };
                for (self.ast.nodeChildren(ep_idx)) |prop_idx| {
                    const prop_name = self.ast.data(prop_idx).text;
                    const value = self.ast.nodeChildren(prop_idx)[0];
                    try edge.seeks.append(self.allocator, .{ .prop = prop_name, .value = value });
                }
                try self.edges.append(self.allocator, edge);
            }
        }

        try self.collectWhereSeeks(self.where_expr);
        try self.buildSteps(self.chooseAnchor());
    }

    fn nodeIndex(self: *Executor, name: []const u8) ?usize {
        for (self.nodes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.var_name, name)) return i;
        }
        return null;
    }

    fn tryAddSeek(self: *Executor, access_expr: Index, value_expr: Index) ExecError!bool {
        if (self.ast.kind(access_expr) != .property_access) return false;
        const obj = self.ast.nodeChildren(access_expr)[0];
        if (self.ast.kind(obj) != .variable) return false;
        switch (self.ast.kind(value_expr)) {
            .int_literal, .string_literal, .bool_literal => {},
            else => return false,
        }
        const var_name = self.ast.data(obj).text;
        const node_idx = self.nodeIndex(var_name) orelse return false;
        const prop = self.ast.data(access_expr).text;
        try self.nodes.items[node_idx].seeks.append(self.allocator, .{ .prop = prop, .value = value_expr });
        return true;
    }

    fn collectWhereSeeks(self: *Executor, expr: Index) ExecError!void {
        if (self.ast.kind(expr) != .binary_op) return;
        const op = self.ast.data(expr).bin_op;
        const kids = self.ast.nodeChildren(expr);
        switch (op) {
            .eq => {
                _ = try self.tryAddSeek(kids[0], kids[1]);
                _ = try self.tryAddSeek(kids[1], kids[0]);
            },
            .and_ => {
                try self.collectWhereSeeks(kids[0]);
                try self.collectWhereSeeks(kids[1]);
            },
            else => {},
        }
    }

    fn estimate(self: *Executor, node_idx: usize) usize {
        const node = self.nodes.items[node_idx];
        if (node.bound) return 0; // already known: a free start
        if (node.seeks.items.len > 0) return 1;
        if (node.label.len == 0) return std.math.maxInt(usize);
        return self.graph.labelCount(node.label) catch std.math.maxInt(usize);
    }

    fn chooseAnchor(self: *Executor) usize {
        var best: usize = 0;
        var best_est = self.estimate(0);
        for (1..self.nodes.items.len) |i| {
            const est = self.estimate(i);
            if (est < best_est) {
                best = i;
                best_est = est;
            }
        }
        return best;
    }

    fn buildSteps(self: *Executor, anchor: usize) ExecError!void {
        self.steps = .empty;
        // A bound anchor needs no scan: expand straight from its known value.
        if (!self.nodes.items[anchor].bound) {
            try self.steps.append(self.allocator, .{ .scan = .{ .node = anchor } });
        }

        var i: usize = anchor;
        while (i + 1 < self.nodes.items.len) : (i += 1) {
            try self.steps.append(self.allocator, .{ .expand = .{ .from = i, .to = i + 1 } });
        }
        i = anchor;
        while (i > 0) : (i -= 1) {
            try self.steps.append(self.allocator, .{ .expand = .{ .from = i, .to = i - 1 } });
        }
    }

    // --- Execution ---------------------------------------------------------

    fn matchPatterns(self: *Executor, pat_idx: usize, bindings: *Bindings) ExecError!void {
        if (pat_idx == self.patterns.len) {
            return self.finish(bindings);
        }
        try self.setupPattern(self.patterns[pat_idx], bindings);
        try self.execStep(0, pat_idx, bindings);
    }

    fn execStep(self: *Executor, step_idx: usize, pat_idx: usize, bindings: *Bindings) ExecError!void {
        if (step_idx == self.steps.items.len) {
            return self.matchPatterns(pat_idx + 1, bindings);
        }
        switch (self.steps.items[step_idx]) {
            .scan => |s| {
                const node = self.nodes.items[s.node];
                if (node.seeks.items.len > 0) {
                    // Index lookup on the first equality predicate.
                    const seek = node.seeks.items[0];
                    const value = try self.eval(seek.value, bindings);
                    var it = try self.graph.nodesByProp(seek.prop, value);
                    defer it.deinit();
                    while (try it.next()) |id| {
                        if (node.label.len > 0 and !(try self.graph.hasLabel(id, node.label))) continue;
                        try bindings.put(self.allocator, node.var_name, .{ .node = id });
                        if (!try self.nodeSeeksMatch(s.node, id, bindings)) continue;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                } else {
                    var it = try self.graph.nodesWithLabel(node.label);
                    defer it.deinit();
                    while (try it.next()) |id| {
                        try bindings.put(self.allocator, node.var_name, .{ .node = id });
                        if (!try self.nodeSeeksMatch(s.node, id, bindings)) continue;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                }
            },
            .expand => |e| {
                const from_name = self.nodes.items[e.from].var_name;
                const from_id = bindings.getNode(from_name) orelse return error.UnknownVar;
                const edge = self.edges.items[@min(e.from, e.to)];
                const to_node = self.nodes.items[e.to];

                if (to_node.bound) {
                    // Verify the already-bound neighbour satisfies this edge.
                    const to_id = bindings.getNode(to_node.var_name) orelse return error.UnknownVar;
                    const sd = edgeSrcDst(edge.fwd_dir, e.from, e.to, from_id, to_id);
                    if (try self.graph.hasEdge(sd.src, sd.dst, edge.etype)) {
                        if (edge.var_name.len > 0) {
                            try bindings.put(self.allocator, edge.var_name, .{ .edge = .{ .src = sd.src, .dst = sd.dst, .etype = edge.etype } });
                        }
                        if (!try self.nodeSeeksMatch(e.to, to_id, bindings)) return;
                        if (!try self.edgeSeeksMatch(edge, sd.src, sd.dst, bindings)) return;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                } else {
                    const dir: Direction = if (e.from < e.to) edge.fwd_dir else opposite(edge.fwd_dir);
                    var it = try self.graph.neighbours(from_id, dir, edge.etype);
                    defer it.deinit();
                    while (try it.next()) |nid| {
                        if (to_node.label.len > 0 and !(try self.graph.hasLabel(nid, to_node.label))) continue;
                        try bindings.put(self.allocator, to_node.var_name, .{ .node = nid });
                        if (!try self.nodeSeeksMatch(e.to, nid, bindings)) continue;
                        const sd = edgeSrcDst(edge.fwd_dir, e.from, e.to, from_id, nid);
                        if (edge.var_name.len > 0) {
                            try bindings.put(self.allocator, edge.var_name, .{ .edge = .{ .src = sd.src, .dst = sd.dst, .etype = edge.etype } });
                        }
                        if (!try self.edgeSeeksMatch(edge, sd.src, sd.dst, bindings)) continue;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                }
            },
        }
    }

    fn finish(self: *Executor, bindings: *Bindings) ExecError!void {
        if (self.has_match and !try self.evalBool(self.where_expr, bindings)) return;

        for (self.update_clauses.items) |clause| {
            switch (self.ast.kind(clause)) {
                .create_clause => try self.applyCreate(self.ast.nodeChildren(clause)[0], bindings),
                .merge_clause => try self.applyMerge(self.ast.nodeChildren(clause)[0], bindings),
                .set_clause => try self.applySet(clause, bindings),
                .delete_clause => try self.applyDelete(clause, bindings),
                else => {},
            }
        }

        if (self.return_clause) |rc| {
            const info = self.returnInfo(rc);

            if (self.has_agg) {
                try self.accumulate(bindings);
                return;
            }

            var out = std.ArrayList(Value).empty;
            for (self.ast.nodeChildren(info.projection)) |item| {
                const v = try self.eval(self.ast.nodeChildren(item)[0], bindings);
                try out.append(self.allocator, v);
            }
            try self.rows.append(self.allocator, out);

            // Evaluate the ORDER BY keys alongside the row (they may reference
            // variables that aren't projected).
            var keys = std.ArrayList(Value).empty;
            if (info.order_by) |ob| {
                for (self.ast.nodeChildren(ob)) |item| {
                    const v = try self.eval(self.ast.nodeChildren(item)[0], bindings);
                    try keys.append(self.allocator, v);
                }
            }
            try self.row_keys.append(self.allocator, keys.items);
        }
    }

    fn accumulate(self: *Executor, bindings: *Bindings) ExecError!void {
        var keys = std.ArrayList(Value).empty;
        var args = std.ArrayList(Value).empty;
        for (self.proj_items.items) |item| {
            switch (item) {
                .key => |expr| try keys.append(self.allocator, try self.eval(expr, bindings)),
                .agg => |a| {
                    // count ignores its argument (no nulls in this subset), and
                    // count(*) has none.
                    if (a.kind == .count or a.arg == null) {
                        try args.append(self.allocator, .{ .int = 0 });
                    } else {
                        try args.append(self.allocator, try self.eval(a.arg.?, bindings));
                    }
                },
            }
        }

        const group = try self.findOrCreateGroup(keys.items);
        var arg_i: usize = 0;
        for (group.aggs.items) |*state| {
            try self.updateAgg(state, args.items[arg_i]);
            arg_i += 1;
        }
    }

    fn findOrCreateGroup(self: *Executor, keys: []const Value) ExecError!*Group {
        for (self.groups.items) |*g| {
            if (rowsEq(g.keys.items, keys)) return g;
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

    fn updateAgg(self: *Executor, state: *AggState, arg: Value) ExecError!void {
        _ = self;
        switch (state.kind) {
            .count => state.count += 1,
            .sum => state.sum += try asInt(arg),
            .min => {
                if (state.min) |m| {
                    if (compareValue(arg, m) == .lt) state.min = arg;
                } else state.min = arg;
            },
            .max => {
                if (state.max) |m| {
                    if (compareValue(arg, m) == .gt) state.max = arg;
                } else state.max = arg;
            },
        }
    }

    fn aggregate(self: *Executor) ExecError!void {
        self.rows = .empty;
        self.row_keys = .empty;
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

    const ReturnInfo = struct {
        projection: Index,
        order_by: ?Index,
        limit: ?Index,
        distinct: bool,
    };

    fn returnInfo(self: *Executor, rc: Index) ReturnInfo {
        var info = ReturnInfo{
            .projection = 0,
            .order_by = null,
            .limit = null,
            .distinct = self.ast.data(rc).return_.distinct,
        };
        for (self.ast.nodeChildren(rc)) |child| {
            switch (self.ast.kind(child)) {
                .projection => info.projection = child,
                .order_by => info.order_by = child,
                .limit => info.limit = child,
                else => {},
            }
        }
        return info;
    }

    fn postProcess(self: *Executor, rc: Index) ExecError!void {
        const info = self.returnInfo(rc);

        if (self.has_agg) {
            try self.aggregate();
        }

        if (info.distinct) self.dedup();

        if (info.order_by) |ob| {
            try self.sortRows(ob);
        }

        if (info.limit) |lim| {
            const expr = self.ast.nodeChildren(lim)[0];
            var empty = Bindings{ .entries = .empty };
            const n = switch (try self.eval(expr, &empty)) {
                .int => |n| if (n < 0) 0 else @as(usize, @intCast(n)),
                else => 0,
            };
            if (n < self.rows.items.len) self.rows.shrinkRetainingCapacity(n);
        }
    }

    fn dedup(self: *Executor) void {
        var i: usize = 0;
        while (i < self.rows.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < self.rows.items.len) {
                if (rowsEq(self.rows.items[i].items, self.rows.items[j].items)) {
                    _ = self.rows.swapRemove(j);
                    _ = self.row_keys.swapRemove(j);
                } else {
                    j += 1;
                }
            }
        }
    }

    fn sortRows(self: *Executor, ob: Index) ExecError!void {
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

    fn applyCreate(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
        const chain = self.ast.nodeChildren(pattern);
        const num_nodes = (chain.len + 1) / 2;

        for (0..num_nodes) |i| {
            const np_idx = chain[i * 2];
            const np = self.ast.data(np_idx).node_pattern;
            if (np.var_name.len == 0 or bindings.getNode(np.var_name) != null) continue;
            const id = try self.createNode(np_idx, bindings);
            try bindings.put(self.allocator, np.var_name, .{ .node = id });
        }
        try self.applyEdges(chain, num_nodes, bindings, false);
    }

    fn applyMerge(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
        const chain = self.ast.nodeChildren(pattern);
        const num_nodes = (chain.len + 1) / 2;

        for (0..num_nodes) |i| {
            const np_idx = chain[i * 2];
            const np = self.ast.data(np_idx).node_pattern;
            if (np.var_name.len == 0 or bindings.getNode(np.var_name) != null) continue;
            const id = (try self.findMatchingNode(np_idx, bindings)) orelse (try self.createNode(np_idx, bindings));
            try bindings.put(self.allocator, np.var_name, .{ .node = id });
        }
        try self.applyEdges(chain, num_nodes, bindings, true);
    }

    /// Creates a node from a `node_pattern` and returns its fresh id.
    fn createNode(self: *Executor, np_idx: Index, bindings: *Bindings) ExecError!NodeId {
        const np = self.ast.data(np_idx).node_pattern;
        const id = try self.graph.allocNodeId();
        try self.graph.addNode(id, np.label);
        for (self.ast.nodeChildren(np_idx)) |prop_idx| {
            const prop_name = self.ast.data(prop_idx).text;
            const value = try self.eval(self.ast.nodeChildren(prop_idx)[0], bindings);
            try self.graph.setProp(id, prop_name, value);
        }
        return id;
    }

    /// Finds an existing node matching the label + property map, if any.
    fn findMatchingNode(self: *Executor, np_idx: Index, bindings: *Bindings) ExecError!?NodeId {
        const np = self.ast.data(np_idx).node_pattern;
        const props = self.ast.nodeChildren(np_idx);

        if (props.len > 0) {
            // Index lookup on the first property.
            const prop_name = self.ast.data(props[0]).text;
            const value = try self.eval(self.ast.nodeChildren(props[0])[0], bindings);
            var it = try self.graph.nodesByProp(prop_name, value);
            defer it.deinit();
            while (try it.next()) |id| {
                if (np.label.len > 0 and !(try self.graph.hasLabel(id, np.label))) continue;
                if (try self.nodePropsMatch(np_idx, id, bindings)) return id;
            }
            return null;
        }

        var it = try self.graph.nodesWithLabel(np.label);
        defer it.deinit();
        while (try it.next()) |id| {
            if (try self.nodePropsMatch(np_idx, id, bindings)) return id;
        }
        return null;
    }

    fn nodePropsMatch(self: *Executor, np_idx: Index, id: NodeId, bindings: *Bindings) ExecError!bool {
        for (self.ast.nodeChildren(np_idx)) |prop_idx| {
            const prop_name = self.ast.data(prop_idx).text;
            const value = try self.eval(self.ast.nodeChildren(prop_idx)[0], bindings);
            const actual = (try self.graph.getProp(id, prop_name, self.allocator)) orelse return false;
            if (!valueEq(actual, value)) return false;
        }
        return true;
    }

    fn applyEdges(self: *Executor, chain: []const Index, num_nodes: usize, bindings: *Bindings, merge: bool) ExecError!void {
        for (0..num_nodes - 1) |i| {
            const ep_idx = chain[i * 2 + 1];
            const ep = self.ast.data(ep_idx).edge_pattern;
            const left_name = self.ast.data(chain[i * 2]).node_pattern.var_name;
            const right_name = self.ast.data(chain[i * 2 + 2]).node_pattern.var_name;
            const left_id = bindings.getNode(left_name) orelse return error.UnknownVar;
            const right_id = bindings.getNode(right_name) orelse return error.UnknownVar;
            const src: NodeId = if (ep.direction == .left_to_right) left_id else right_id;
            const dst: NodeId = if (ep.direction == .left_to_right) right_id else left_id;
            if (merge and (try self.graph.hasEdge(src, dst, ep.etype))) continue;
            try self.graph.addEdge(src, dst, ep.etype);
            for (self.ast.nodeChildren(ep_idx)) |prop_idx| {
                const prop_name = self.ast.data(prop_idx).text;
                const value = try self.eval(self.ast.nodeChildren(prop_idx)[0], bindings);
                try self.graph.setEdgeProp(src, dst, ep.etype, prop_name, value);
            }
        }
    }

    fn applySet(self: *Executor, set_clause: Index, bindings: *Bindings) ExecError!void {
        for (self.ast.nodeChildren(set_clause)) |item| {
            const ic = self.ast.nodeChildren(item);
            const access = ic[0];
            const value_expr = ic[1];
            const prop = self.ast.data(access).text;
            const obj = self.ast.nodeChildren(access)[0];
            const name = self.ast.data(obj).text;
            const value = try self.eval(value_expr, bindings);
            switch (bindings.get(name) orelse return error.UnknownVar) {
                .node => |id| try self.graph.setProp(id, prop, value),
                .edge => |e| try self.graph.setEdgeProp(e.src, e.dst, e.etype, prop, value),
            }
        }
    }

    fn applyDelete(self: *Executor, delete_clause: Index, bindings: *Bindings) ExecError!void {
        const detach = self.ast.data(delete_clause).delete.detach;
        for (self.ast.nodeChildren(delete_clause)) |item| {
            const obj = self.ast.nodeChildren(item)[0];
            const name = self.ast.data(obj).text;
            const id = bindings.getNode(name) orelse return error.UnknownVar;
            if (detach) {
                try self.graph.deleteNodeDetach(id);
            } else {
                self.graph.deleteNode(id) catch |err| {
                    if (err == error.NodeStillConnected) {
                        self.fail("node '{s}' still has relationships (use DETACH DELETE)", .{name});
                    }
                    return err;
                };
            }
        }
    }

    fn nodeSeeksMatch(self: *Executor, node_idx: usize, id: NodeId, bindings: *Bindings) ExecError!bool {
        for (self.nodes.items[node_idx].seeks.items) |seek| {
            const expected = try self.eval(seek.value, bindings);
            const actual = (try self.graph.getProp(id, seek.prop, self.allocator)) orelse return false;
            if (!valueEq(actual, expected)) return false;
        }
        return true;
    }

    fn edgeSeeksMatch(self: *Executor, edge: ChainEdge, src: NodeId, dst: NodeId, bindings: *Bindings) ExecError!bool {
        for (edge.seeks.items) |seek| {
            const expected = try self.eval(seek.value, bindings);
            const actual = (try self.graph.getEdgeProp(src, dst, edge.etype, seek.prop, self.allocator)) orelse return false;
            if (!valueEq(actual, expected)) return false;
        }
        return true;
    }

    fn evalBool(self: *Executor, expr: Index, bindings: *Bindings) ExecError!bool {
        return switch (try self.eval(expr, bindings)) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    fn eval(self: *Executor, expr: Index, bindings: *Bindings) ExecError!Value {
        return switch (self.ast.kind(expr)) {
            .int_literal => .{ .int = self.ast.data(expr).int },
            .string_literal => .{ .str = self.ast.data(expr).text },
            .bool_literal => .{ .boolean = self.ast.data(expr).boolean },
            .property_access => blk: {
                const obj = self.ast.nodeChildren(expr)[0];
                if (self.ast.kind(obj) != .variable) return error.InvalidExpr;
                const name = self.ast.data(obj).text;
                const prop = self.ast.data(expr).text;
                switch (bindings.get(name) orelse {
                    self.fail("unknown variable '{s}'", .{name});
                    return error.UnknownVar;
                }) {
                    .node => |id| {
                        const v = (try self.graph.getProp(id, prop, self.allocator)) orelse {
                            self.fail("node has no property '{s}'", .{prop});
                            return error.MissingProp;
                        };
                        break :blk v;
                    },
                    .edge => |e| {
                        const v = (try self.graph.getEdgeProp(e.src, e.dst, e.etype, prop, self.allocator)) orelse {
                            self.fail("relationship has no property '{s}'", .{prop});
                            return error.MissingProp;
                        };
                        break :blk v;
                    },
                }
            },
            .binary_op => blk: {
                const op = self.ast.data(expr).bin_op;
                const kids = self.ast.nodeChildren(expr);
                const l = try self.eval(kids[0], bindings);
                const r = try self.eval(kids[1], bindings);
                break :blk try applyBinOp(op, l, r);
            },
            .unary_op => blk: {
                const op = self.ast.data(expr).un_op;
                const v = try self.eval(self.ast.nodeChildren(expr)[0], bindings);
                break :blk try applyUnOp(op, v);
            },
            else => error.InvalidExpr,
        };
    }
};

fn opposite(dir: Direction) Direction {
    return switch (dir) {
        .out => .in,
        .in => .out,
    };
}

/// Computes the written edge's source/destination ids, given the two endpoint
/// node indices (`from`/`to`) and their ids. `fwd_dir` is the direction when
/// traversing the lower index to the higher index.
fn edgeSrcDst(fwd_dir: Direction, from: usize, to: usize, from_id: NodeId, to_id: NodeId) struct { src: NodeId, dst: NodeId } {
    const left_id = if (from < to) from_id else to_id;
    const right_id = if (from < to) to_id else from_id;
    return switch (fwd_dir) {
        .out => .{ .src = left_id, .dst = right_id },
        .in => .{ .src = right_id, .dst = left_id },
    };
}

fn valueEq(l: Value, r: Value) bool {
    return switch (l) {
        .int => |lv| switch (r) {
            .int => |rv| lv == rv,
            else => false,
        },
        .str => |lv| switch (r) {
            .str => |rv| std.mem.eql(u8, lv, rv),
            else => false,
        },
        .boolean => |bv| switch (r) {
            .boolean => |rv| bv == rv,
            else => false,
        },
    };
}

fn rowsEq(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!valueEq(av, bv)) return false;
    }
    return true;
}

fn aggResult(kind: AggKind, state: AggState) Value {
    return switch (kind) {
        .count => .{ .int = @intCast(state.count) },
        .sum => .{ .int = state.sum },
        .min => state.min orelse .{ .int = 0 },
        .max => state.max orelse .{ .int = 0 },
    };
}

fn compareValue(a: Value, b: Value) std.math.Order {
    return switch (a) {
        .int => |av| switch (b) {
            .int => |bv| std.math.order(av, bv),
            else => .lt,
        },
        .str => |av| switch (b) {
            .str => |bv| std.mem.order(u8, av, bv),
            else => .gt,
        },
        .boolean => |av| switch (b) {
            .boolean => |bv| std.math.order(@intFromBool(av), @intFromBool(bv)),
            else => .lt,
        },
    };
}

const SortCtx = struct {
    keys: []const []const Value,
    asc: []const bool,
};

fn lessThanIdx(ctx: SortCtx, a: usize, b: usize) bool {
    const ka = ctx.keys[a];
    const kb = ctx.keys[b];
    for (ka, kb, ctx.asc) |va, vb, asc| {
        const ord = compareValue(va, vb);
        if (ord == .lt) return asc;
        if (ord == .gt) return !asc;
    }
    return false;
}

fn applyBinOp(op: BinOp, l: Value, r: Value) ExecError!Value {
    return switch (op) {
        .eq => .{ .boolean = valueEq(l, r) },
        .ne => .{ .boolean = !valueEq(l, r) },
        .and_ => .{ .boolean = try asBool(l) and try asBool(r) },
        .or_ => .{ .boolean = try asBool(l) or try asBool(r) },
        .lt, .gt, .le, .ge => blk: {
            const li = try asInt(l);
            const ri = try asInt(r);
            break :blk .{ .boolean = switch (op) {
                .lt => li < ri,
                .gt => li > ri,
                .le => li <= ri,
                .ge => li >= ri,
                else => unreachable,
            } };
        },
    };
}

fn applyUnOp(op: UnOp, v: Value) ExecError!Value {
    return switch (op) {
        .not_ => .{ .boolean = !try asBool(v) },
    };
}

fn asInt(v: Value) ExecError!i64 {
    return switch (v) {
        .int => |n| n,
        else => error.TypeMismatch,
    };
}

fn asBool(v: Value) ExecError!bool {
    return switch (v) {
        .boolean => |b| b,
        else => error.TypeMismatch,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const parser = @import("../parser/parser.zig");
const KvStore = @import("../storage/kv_store.zig").KvStore;

fn rowsEqual(r: []const Value, e: []const Value) bool {
    if (r.len != e.len) return false;
    for (r, e) |a, b| {
        if (!valueEq(a, b)) return false;
    }
    return true;
}

/// Asserts that `rows` equals `expected` as an unordered set of rows.
fn expectRows(rows: []const Row, expected: []const []const Value) !void {
    try testing.expectEqual(expected.len, rows.len);
    var used = try testing.allocator.alloc(bool, rows.len);
    defer testing.allocator.free(used);
    @memset(used, false);

    for (expected) |exp| {
        var found = false;
        for (rows, 0..) |r, i| {
            if (used[i]) continue;
            if (rowsEqual(r.items, exp)) {
                used[i] = true;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

fn openStore(tmp: *testing.TmpDir, buf: []u8) !KvStore {
    const path = std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
    return KvStore.open(testing.allocator, path);
}

/// Loads the vertical-slice "people and movies" dataset (STATUS.md §6).
fn loadSlice(g: *Graph) !void {
    const P = struct { id: NodeId, name: []const u8, born: i64 };
    const M = struct { id: NodeId, title: []const u8, released: i64 };
    const people = [_]P{
        .{ .id = 1, .name = "Keanu Reeves", .born = 1964 },
        .{ .id = 2, .name = "Carrie-Anne Moss", .born = 1967 },
        .{ .id = 3, .name = "Laurence Fishburne", .born = 1961 },
        .{ .id = 4, .name = "Lana Wachowski", .born = 1965 },
        .{ .id = 5, .name = "Tom Hanks", .born = 1956 },
    };
    const movies = [_]M{
        .{ .id = 100, .title = "The Matrix", .released = 1999 },
        .{ .id = 101, .title = "The Matrix Reloaded", .released = 2003 },
        .{ .id = 102, .title = "John Wick", .released = 2014 },
        .{ .id = 103, .title = "Forrest Gump", .released = 1994 },
    };
    for (people) |p| {
        try g.addNode(p.id, "Person");
        try g.setProp(p.id, "name", .{ .str = p.name });
        try g.setProp(p.id, "born", .{ .int = p.born });
    }
    for (movies) |m| {
        try g.addNode(m.id, "Movie");
        try g.setProp(m.id, "title", .{ .str = m.title });
        try g.setProp(m.id, "released", .{ .int = m.released });
    }
    const E = struct { a: NodeId, b: NodeId, t: []const u8 };
    const edges = [_]E{
        .{ .a = 1, .b = 100, .t = "ACTED_IN" },
        .{ .a = 1, .b = 101, .t = "ACTED_IN" },
        .{ .a = 1, .b = 102, .t = "ACTED_IN" },
        .{ .a = 2, .b = 100, .t = "ACTED_IN" },
        .{ .a = 3, .b = 100, .t = "ACTED_IN" },
        .{ .a = 5, .b = 103, .t = "ACTED_IN" },
        .{ .a = 4, .b = 100, .t = "DIRECTED" },
        .{ .a = 4, .b = 101, .t = "DIRECTED" },
    };
    for (edges) |e| try g.addEdge(e.a, e.b, e.t);
}

/// Parses `src`, runs it, and asserts the projected rows (as an unordered set).
fn expectQuery(ast: *Ast, g: *Graph, src: []const u8, expected: []const []const Value) !void {
    const query = try parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exec = Executor.init(ast, g, arena.allocator());
    const rows = try exec.run(query);
    try expectRows(rows, expected);
}

fn expectOrdered(ast: *Ast, g: *Graph, src: []const u8, expected: []const []const Value) !void {
    const query = try parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exec = Executor.init(ast, g, arena.allocator());
    const rows = try exec.run(query);
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |exp, r| {
        try testing.expect(rowsEq(r.items, exp));
    }
}

fn expectQueryError(ast: *Ast, g: *Graph, src: []const u8, expected_err: anyerror) !void {
    const query = try parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var exec = Executor.init(ast, g, arena.allocator());
    try testing.expectError(expected_err, exec.run(query));
}

test "runs the vertical-slice queries end to end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born", &.{
        &.{.{ .int = 1964 }},
    });
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "John Wick" }},
    });
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title AS movie", &.{
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "John Wick" }},
    });
    try expectQuery(&ast, &g, "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name", &.{
        &.{.{ .str = "Keanu Reeves" }},
        &.{.{ .str = "Carrie-Anne Moss" }},
        &.{.{ .str = "Laurence Fishburne" }},
    });
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE p.name = 'Keanu Reeves' AND m.released > 2000 RETURN p.name, m.title", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "The Matrix Reloaded" } },
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "John Wick" } },
    });
}

test "write clauses: CREATE, SET and DELETE" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // CREATE a node, then read it back.
    try expectQuery(&ast, &g, "CREATE (n:Person {name: 'Neo', born: 1964})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) RETURN n.born", &.{
        &.{.{ .int = 1964 }},
    });

    // SET a property.
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) SET n.born = 1970", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) RETURN n.born", &.{
        &.{.{ .int = 1970 }},
    });

    // CREATE two nodes + an edge in one statement.
    try expectQuery(&ast, &g, "CREATE (a:Person {name: 'X'})-[:KNOWS]->(b:Person {name: 'Y'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'X'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .str = "Y" }},
    });

    // MATCH + CREATE: bind an existing node, create a new one + edge.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'X'}) CREATE (a)-[:KNOWS]->(b:Person {name: 'Z'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'X'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .str = "Y" }},
        &.{.{ .str = "Z" }},
    });

    // DELETE a node (detach).
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) DELETE n", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) RETURN n.name", &.{});
}

test "MERGE gets-or-creates nodes and edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try g.addNode(1, "Person");
    try g.setProp(1, "name", .{ .str = "Keanu Reeves" });
    try g.setProp(1, "born", .{ .int = 1964 });

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // MERGE an existing node twice -> still exactly one.
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'Keanu Reeves'})", &.{});
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'Keanu Reeves'})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Keanu Reeves'}) RETURN n.name", &.{
        &.{.{ .str = "Keanu Reeves" }},
    });

    // MERGE a brand-new node -> created.
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'Zorg', born: 1900})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Zorg'}) RETURN n.born", &.{
        &.{.{ .int = 1900 }},
    });

    // MERGE an edge (get-or-create), then again -> still one edge.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'}) MERGE (a)-[:KNOWS]->(b:Person {name: 'Zorg'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .str = "Zorg" }},
    });
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'}) MERGE (a)-[:KNOWS]->(b:Person {name: 'Zorg'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .str = "Zorg" }},
    });
}

test "MATCH multi-pattern: join and shared variables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // People with a KNOWS chain: A -> B -> C.
    try g.addNode(1, "Person");
    try g.setProp(1, "name", .{ .str = "A" });
    try g.addNode(2, "Person");
    try g.setProp(2, "name", .{ .str = "B" });
    try g.addNode(3, "Person");
    try g.setProp(3, "name", .{ .str = "C" });
    try g.addEdge(1, 2, "KNOWS");
    try g.addEdge(2, 3, "KNOWS");

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Shared variable across two patterns: a 2-hop path A -> ? -> ?.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[:KNOWS]->(b), (b)-[:KNOWS]->(c) RETURN c.name", &.{
        &.{.{ .str = "C" }},
    });

    // Join two independent matched nodes and connect them.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}), (c:Person {name: 'C'}) CREATE (a)-[:KNOWS]->(c)", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[:KNOWS]->(c:Person) RETURN c.name", &.{
        &.{.{ .str = "B" }},
        &.{.{ .str = "C" }},
    });
}

test "ORDER BY, LIMIT and DISTINCT" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // ORDER BY ascending.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "John Wick" }},
    });

    // ORDER BY descending.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released DESC", &.{
        &.{.{ .str = "John Wick" }},
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "The Matrix" }},
    });

    // LIMIT after ORDER BY.
    try expectOrdered(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title ORDER BY m.released LIMIT 2", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
    });

    // DISTINCT collapses duplicate projected rows.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie {title: 'The Matrix'}) RETURN DISTINCT m.title", &.{
        &.{.{ .str = "The Matrix" }},
    });
}

test "relationship properties: CREATE, MATCH, SET and WHERE" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // CREATE an edge with a property.
    try expectQuery(&ast, &g, "CREATE (a:Person {name: 'A'})-[:KNOWS {weight: 5}]->(b:Person {name: 'B'})", &.{});

    // Read the relationship property.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) RETURN r.weight", &.{
        &.{.{ .int = 5 }},
    });

    // WHERE on a relationship property.
    try expectQuery(&ast, &g, "MATCH (a:Person)-[r:KNOWS]->(b:Person) WHERE r.weight > 3 RETURN b.name", &.{
        &.{.{ .str = "B" }},
    });

    // SET a relationship property.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) SET r.weight = 10", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) RETURN r.weight", &.{
        &.{.{ .int = 10 }},
    });

    // Inline relationship property filter.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS {weight: 10}]->(b:Person) RETURN b.name", &.{
        &.{.{ .str = "B" }},
    });
}

test "DELETE fails on connected nodes; DETACH DELETE removes edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:Person {name: 'A'})-[:KNOWS]->(b:Person {name: 'B'})", &.{});

    // Plain DELETE fails because 'A' still has a relationship.
    try expectQueryError(&ast, &g, "MATCH (a:Person {name: 'A'}) DELETE a", error.NodeStillConnected);
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}) RETURN a.name", &.{
        &.{.{ .str = "A" }},
    });

    // DETACH DELETE removes 'A' and its relationship.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}) DETACH DELETE a", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}) RETURN a.name", &.{});
    try expectQuery(&ast, &g, "MATCH (b:Person {name: 'B'}) RETURN b.name", &.{
        &.{.{ .str = "B" }},
    });
}

test "aggregations: count, sum, min and max with grouping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Count movies per actor (implicit GROUP BY p.name).
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN p.name, count(m)", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .int = 3 } },
        &.{ .{ .str = "Carrie-Anne Moss" }, .{ .int = 1 } },
        &.{ .{ .str = "Laurence Fishburne" }, .{ .int = 1 } },
        &.{ .{ .str = "Tom Hanks" }, .{ .int = 1 } },
    });

    // count(*) over all persons.
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN count(p)", &.{
        &.{.{ .int = 5 }},
    });

    // min/max released year.
    try expectQuery(&ast, &g, "MATCH (m:Movie) RETURN min(m.released), max(m.released)", &.{
        &.{ .{ .int = 1994 }, .{ .int = 2014 } },
    });

    // sum of birth years.
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN sum(p.born)", &.{
        &.{.{ .int = 9813 }},
    });
}
