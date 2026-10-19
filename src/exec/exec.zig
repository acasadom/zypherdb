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
const NodeIdIterator = @import("../storage/graph.zig").NodeIdIterator;
const KvError = @import("../storage/kv_store.zig").KvError;
const Diagnostic = @import("../diag.zig").Diagnostic;
const ErrorCode = @import("../diag.zig").ErrorCode;

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
    labels: []const []const u8,
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
    edge_scan: struct { edge: usize }, // bind both endpoints from an edge-prop seek
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
    value: Value, // scalar bound by a WITH projection
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

    fn remove(self: *Bindings, name: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    fn getNode(self: *const Bindings, name: []const u8) ?NodeId {
        return switch (self.get(name) orelse return null) {
            .node => |id| id,
            .edge, .value => null,
        };
    }

    fn getEdge(self: *const Bindings, name: []const u8) ?EdgeRef {
        return switch (self.get(name) orelse return null) {
            .node, .value => null,
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
    list: std.ArrayList(Value) = .empty,
};

const Group = struct {
    keys: std.ArrayList(Value),
    aggs: std.ArrayList(AggState),
};

/// One `WITH` projection item: a variable passthrough (keeps its node/edge/value
/// binding), a scalar key expression, or an aggregation. `name` is the variable
/// it binds in the new scope (alias, or the variable name for a passthrough).
const WithItem = union(enum) {
    pass: struct { name: []const u8, src_name: []const u8 },
    key: struct { name: []const u8, expr: Index },
    agg: struct { name: []const u8, kind: AggKind, arg: ?Index },
};

/// A `WITH` group: binding-valued keys plus the usual aggregation states.
const WithGroup = struct {
    keys: std.ArrayList(Binding),
    aggs: std.ArrayList(AggState),
};

const WithInfo = struct {
    projection: Index,
    order_by: ?Index,
    skip: ?Index,
    limit: ?Index,
    where_expr: Index,
    distinct: bool,
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

    // WITH pipeline context.
    with_clause: ?Index,
    with_rows: std.ArrayList(Bindings),
    collecting: bool,

    // OPTIONAL MATCH context.
    optional_match: ?Index,
    optional_vars: std.ArrayList([]const u8),
    main_vars: std.ArrayList([]const u8),
    in_optional: bool,
    optional_matched: bool,

    // UNWIND context.
    unwind: ?Index,

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
            .with_clause = null,
            .with_rows = .empty,
            .collecting = false,
            .optional_match = null,
            .optional_vars = .empty,
            .main_vars = .empty,
            .in_optional = false,
            .optional_matched = false,
            .unwind = null,
            .row_keys = .empty,
            .has_agg = false,
            .proj_items = .empty,
            .groups = .empty,
            .diag = null,
        };
    }

    fn fail(self: *Executor, code: ErrorCode, comptime fmt: []const u8, args: anytype) void {
        if (self.diag) |d| d.set(code, 0, fmt, args);
    }

    pub fn run(self: *Executor, query: Index) ExecError![]const Row {
        self.rows.clearRetainingCapacity();
        self.row_keys = .empty;
        self.groups = .empty;
        self.has_agg = false;
        self.proj_items = .empty;
        self.with_rows = .empty;
        self.collecting = false;
        self.optional_match = null;
        self.optional_vars = .empty;
        self.main_vars = .empty;
        self.in_optional = false;
        self.optional_matched = false;
        self.unwind = null;

        var pre_match: ?Index = null;
        var post_match: ?Index = null;
        self.with_clause = null;
        self.update_clauses = .empty;
        self.return_clause = null;
        for (self.ast.nodeChildren(query)) |c| {
            switch (self.ast.kind(c)) {
                .match_clause => {
                    if (self.with_clause == null) {
                        pre_match = c;
                    } else {
                        post_match = c;
                    }
                },
                .optional_match_clause => self.optional_match = c,
                .unwind_clause => self.unwind = c,
                .with_clause => self.with_clause = c,
                .create_clause, .merge_clause, .set_clause, .delete_clause, .remove_clause => try self.update_clauses.append(self.allocator, c),
                .return_clause => self.return_clause = c,
                else => {},
            }
        }
        if (self.optional_match) |om| {
            try self.collectOptionalVars(om);
        }
        if (pre_match) |pm| {
            try self.collectClauseVars(pm, &self.main_vars);
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

        // All writes of this query commit (or abort) atomically; a read-only
        // query batches its reads into a single read transaction (snapshot),
        // avoiding one LMDB transaction per read (the #1 performance win).
        const has_writes = self.update_clauses.items.len > 0;
        if (has_writes) {
            try self.graph.beginWrite();
        } else {
            try self.graph.beginRead();
        }
        errdefer if (has_writes) self.graph.abortWrite() else self.graph.abortRead();

        if (self.with_clause) |wc| {
            // Phase 1: collect the pre-WITH match bindings.
            self.collecting = true;
            var start = Bindings{ .entries = .empty };
            if (pre_match) |pm| {
                try self.runMatch(pm, &start);
            } else {
                self.has_match = false;
                try self.leaf(&start);
            }
            self.collecting = false;

            // Phase 2: project/aggregate/filter/sort/paginate with WITH.
            try self.applyWith(wc);

            // Phase 3: run the post-WITH clauses against each projected row.
            for (self.with_rows.items) |row| {
                var bindings = Bindings{ .entries = .empty };
                try bindings.entries.appendSlice(self.allocator, row.entries.items);
                if (post_match) |pm| {
                    try self.runMatch(pm, &bindings);
                } else {
                    self.has_match = false;
                    try self.finishBody(&bindings);
                }
            }
        } else {
            var bindings = Bindings{ .entries = .empty };
            if (pre_match) |pm| {
                try self.runMatch(pm, &bindings);
            } else {
                self.has_match = false;
                try self.leaf(&bindings);
            }
        }

        if (has_writes) try self.graph.commitWrite() else self.graph.commitRead();

        if (self.return_clause) |rc| {
            try self.postProcess(rc);
        }

        return self.rows.items;
    }

    /// Runs one MATCH clause (its patterns + WHERE) from `bindings`, recursing
    /// through `matchPatterns`/`execStep` down to `leaf`.
    fn runMatch(self: *Executor, mc: Index, bindings: *Bindings) ExecError!void {
        const mc_children = self.ast.nodeChildren(mc);
        self.has_match = true;
        // children = [pattern0, ..., patternN, where_expr]
        self.patterns = mc_children[0 .. mc_children.len - 1];
        self.where_expr = mc_children[mc_children.len - 1];
        try self.matchPatterns(0, bindings);
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
                .labels = np.labels,
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
        if (self.shouldEdgeAnchor()) {
            try self.buildEdgeSteps();
        } else {
            try self.buildSteps(self.chooseAnchor());
        }
    }

    /// Uses the edge-property index as the anchor when the pattern is a single
    /// edge with an equality seek and both endpoints are unbound/unselective.
    fn shouldEdgeAnchor(self: *Executor) bool {
        if (self.nodes.items.len != 2 or self.edges.items.len != 1) return false;
        if (self.edges.items[0].seeks.items.len == 0) return false;
        const a = self.nodes.items[0];
        const b = self.nodes.items[1];
        if (a.bound or b.bound) return false;
        if (a.labels.len > 0 or b.labels.len > 0) return false;
        if (a.seeks.items.len > 0 or b.seeks.items.len > 0) return false;
        return true;
    }

    fn buildEdgeSteps(self: *Executor) ExecError!void {
        self.steps = .empty;
        try self.steps.append(self.allocator, .{ .edge_scan = .{ .edge = 0 } });
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
        if (node.labels.len == 0) return std.math.maxInt(usize);
        var best: usize = std.math.maxInt(usize);
        for (node.labels) |l| {
            const c = self.graph.labelCount(l) catch std.math.maxInt(usize);
            if (c < best) best = c;
        }
        // Cap by the rarest incident edge type: the number of results is bounded
        // by the number of edges of that type, not just the label size.
        if (node_idx > 0) {
            if (self.edges.items[node_idx - 1].etype.len > 0) {
                const c = self.graph.edgeTypeCount(self.edges.items[node_idx - 1].etype) catch std.math.maxInt(usize);
                if (c < best) best = c;
            }
        }
        if (node_idx < self.edges.items.len) {
            if (self.edges.items[node_idx].etype.len > 0) {
                const c = self.graph.edgeTypeCount(self.edges.items[node_idx].etype) catch std.math.maxInt(usize);
                if (c < best) best = c;
            }
        }
        return best;
    }

    /// Candidate nodes for a pattern: the first label's index, or every node
    /// when the pattern is unlabeled. Callers verify the remaining labels.
    fn seedNodes(self: *Executor, labels: []const []const u8) KvError!NodeIdIterator {
        if (labels.len > 0) return self.graph.nodesWithLabel(labels[0]);
        return self.graph.allNodes();
    }

    /// True if `id` carries every label in `labels` (empty = always true).
    fn hasAllLabels(self: *Executor, id: NodeId, labels: []const []const u8) KvError!bool {
        for (labels) |l| {
            if (!(try self.graph.hasLabel(id, l))) return false;
        }
        return true;
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
            return self.leaf(bindings);
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
                        if (!(try self.hasAllLabels(id, node.labels))) continue;
                        try bindings.put(self.allocator, node.var_name, .{ .node = id });
                        if (!try self.nodeSeeksMatch(s.node, id, bindings)) continue;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                } else {
                    // Scan the first label as the seed, then verify the rest.
                    var it = try self.seedNodes(node.labels);
                    defer it.deinit();
                    while (try it.next()) |id| {
                        if (!(try self.hasAllLabels(id, node.labels))) continue;
                        try bindings.put(self.allocator, node.var_name, .{ .node = id });
                        if (!try self.nodeSeeksMatch(s.node, id, bindings)) continue;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                }
            },
            .edge_scan => |es| {
                const edge = self.edges.items[es.edge];
                const seek = edge.seeks.items[0];
                const value = try self.eval(seek.value, bindings);
                var it = try self.graph.edgesByProp(seek.prop, value);
                defer it.deinit();
                const left = self.nodes.items[es.edge];
                const right = self.nodes.items[es.edge + 1];
                while (try it.next()) |e| {
                    if (edge.etype.len > 0 and !std.mem.eql(u8, e.etype, edge.etype)) continue;
                    const left_id: NodeId = if (edge.fwd_dir == .out) e.src else e.dst;
                    const right_id: NodeId = if (edge.fwd_dir == .out) e.dst else e.src;
                    try bindings.put(self.allocator, left.var_name, .{ .node = left_id });
                    try bindings.put(self.allocator, right.var_name, .{ .node = right_id });
                    if (edge.var_name.len > 0) {
                        try bindings.put(self.allocator, edge.var_name, .{ .edge = .{ .src = e.src, .dst = e.dst, .etype = edge.etype } });
                    }
                    if (!try self.edgeSeeksMatch(edge, e.src, e.dst, bindings)) continue;
                    if (!try self.nodeSeeksMatch(es.edge, left_id, bindings)) continue;
                    if (!try self.nodeSeeksMatch(es.edge + 1, right_id, bindings)) continue;
                    try self.execStep(step_idx + 1, pat_idx, bindings);
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
                        if (!(try self.hasAllLabels(nid, to_node.labels))) continue;
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

    /// Leaf of a match: apply the MATCH `WHERE`, then either outer-join through
    /// OPTIONAL MATCH, collect the bindings (WITH pipeline), or apply updates +
    /// RETURN.
    fn leaf(self: *Executor, bindings: *Bindings) ExecError!void {
        if (self.has_match and !try self.evalBool(self.where_expr, bindings)) return;
        if (self.in_optional) {
            self.optional_matched = true;
            return self.afterOptional(bindings);
        }
        if (self.optional_match != null) {
            return self.runOptional(bindings);
        }
        if (self.unwind != null) {
            return self.runUnwind(bindings);
        }
        return self.afterOptional(bindings);
    }

    /// Continuation after (optional) matching: collect or finish.
    fn afterOptional(self: *Executor, bindings: *Bindings) ExecError!void {
        if (self.collecting) {
            return self.collect(bindings);
        }
        try self.finishBody(bindings);
    }

    /// UNWIND: for each element of the evaluated list, bind the variable and
    /// continue (collect or finish). A null list yields no rows.
    fn runUnwind(self: *Executor, bindings: *Bindings) ExecError!void {
        const u = self.unwind.?;
        const expr = self.ast.nodeChildren(u)[0];
        const var_name = self.ast.data(u).unwind.var_name;
        const v = try self.eval(expr, bindings);
        switch (v) {
            .list => |items| {
                for (items) |item| {
                    try bindings.put(self.allocator, var_name, .{ .value = item });
                    try self.afterOptional(bindings);
                }
            },
            .null => {},
            else => return error.TypeMismatch,
        }
    }

    /// Outer-joins the OPTIONAL MATCH pattern onto `bindings`: emits one row per
    /// match, or (if none match) one row with the optional variables bound to
    /// null.
    fn runOptional(self: *Executor, bindings: *Bindings) ExecError!void {
        const om = self.optional_match.?;
        const om_children = self.ast.nodeChildren(om);

        // Save the in-flight match context; the optional match reuses the same
        // slots (`patterns`/`nodes`/`edges`/`steps`/`where_expr`/`has_match`).
        const saved_patterns = self.patterns;
        const saved_where = self.where_expr;
        const saved_has_match = self.has_match;
        const saved_nodes = self.nodes;
        const saved_edges = self.edges;
        const saved_steps = self.steps;
        const saved_in_optional = self.in_optional;

        self.in_optional = true;
        self.optional_matched = false;
        self.patterns = om_children[0 .. om_children.len - 1];
        self.where_expr = om_children[om_children.len - 1];
        self.has_match = true;

        // Unbind optional-only variables left over from a previous outer
        // iteration so they are matched fresh (shared variables stay bound).
        for (self.optional_vars.items) |name| {
            if (!self.isMainVar(name)) bindings.remove(name);
        }

        try self.matchPatterns(0, bindings);

        if (!self.optional_matched) {
            try self.bindOptionalNulls(bindings);
            try self.afterOptional(bindings);
        }

        // Restore the outer match context.
        self.patterns = saved_patterns;
        self.where_expr = saved_where;
        self.has_match = saved_has_match;
        self.nodes = saved_nodes;
        self.edges = saved_edges;
        self.steps = saved_steps;
        self.in_optional = saved_in_optional;
    }

    /// Collects the variable names introduced by the OPTIONAL MATCH patterns.
    fn collectOptionalVars(self: *Executor, om: Index) ExecError!void {
        self.optional_vars = .empty;
        try self.collectClauseVars(om, &self.optional_vars);
    }

    /// Appends every node/edge variable name of a MATCH/OPTIONAL MATCH clause's
    /// patterns to `out`.
    fn collectClauseVars(self: *Executor, clause: Index, out: *std.ArrayList([]const u8)) ExecError!void {
        const kids = self.ast.nodeChildren(clause);
        for (kids[0 .. kids.len - 1]) |pattern| {
            const chain = self.ast.nodeChildren(pattern);
            for (chain) |c| {
                switch (self.ast.kind(c)) {
                    .node_pattern => {
                        const v = self.ast.data(c).node_pattern.var_name;
                        if (v.len > 0) try out.append(self.allocator, v);
                    },
                    .edge_pattern => {
                        const v = self.ast.data(c).edge_pattern.var_name;
                        if (v.len > 0) try out.append(self.allocator, v);
                    },
                    else => {},
                }
            }
        }
    }

    fn isMainVar(self: *Executor, name: []const u8) bool {
        for (self.main_vars.items) |v| {
            if (std.mem.eql(u8, v, name)) return true;
        }
        return false;
    }

    /// Binds every optional-only variable to null (unmatched outer row, or a
    /// match whose WHERE filtered it out). Shared variables stay bound.
    fn bindOptionalNulls(self: *Executor, bindings: *Bindings) ExecError!void {
        for (self.optional_vars.items) |name| {
            if (self.isMainVar(name)) continue;
            try bindings.put(self.allocator, name, .{ .value = .null });
        }
    }

    /// Appends a deep copy of `bindings` to `with_rows` (used by WITH).
    fn collect(self: *Executor, bindings: *Bindings) ExecError!void {
        var copy = Bindings{ .entries = .empty };
        try copy.entries.appendSlice(self.allocator, bindings.entries.items);
        try self.with_rows.append(self.allocator, copy);
    }

    fn finishBody(self: *Executor, bindings: *Bindings) ExecError!void {
        for (self.update_clauses.items) |clause| {
            switch (self.ast.kind(clause)) {
                .create_clause => try self.applyCreate(self.ast.nodeChildren(clause)[0], bindings),
                .merge_clause => try self.applyMerge(clause, bindings),
                .set_clause => try self.applySet(clause, bindings),
                .delete_clause => try self.applyDelete(clause, bindings),
                .remove_clause => try self.applyRemove(clause, bindings),
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

    fn withInfo(self: *Executor, wc: Index) WithInfo {
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
    fn applyWith(self: *Executor, wc: Index) ExecError!void {
        const info = self.withInfo(wc);

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
                    .key => |k| try keys.append(self.allocator, .{ .value = try self.eval(k.expr, bindings) }),
                    .agg => |a| {
                        if (a.arg == null) {
                            try args.append(self.allocator, .{ .int = 0 }); // count(*) always counts
                        } else if (a.kind == .count) {
                            try args.append(self.allocator, try self.evalCountArg(a.arg.?, bindings));
                        } else {
                            try args.append(self.allocator, try self.eval(a.arg.?, bindings));
                        }
                    },
                }
            }
            const group = try self.findOrCreateWithGroup(&groups, keys.items, items.items);
            var arg_i: usize = 0;
            for (group.aggs.items) |*state| {
                try self.updateAgg(state, args.items[arg_i]);
                arg_i += 1;
            }
        }

        // No grouping keys: zero input rows still aggregate into one row.
        if (groups.items.len == 0 and !hasWithKey(items.items)) {
            _ = try self.findOrCreateWithGroup(&groups, &.{}, items.items);
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
            if (try self.evalBool(info.where_expr, b)) {
                try filtered.append(self.allocator, b.*);
            }
        }
        out = filtered;

        if (info.distinct) self.dedupBindings(&out);

        if (info.order_by) |ob| try self.sortBindings(&out, ob);

        if (info.skip) |sk| try self.applyBindingsSkip(&out, sk);
        if (info.limit) |lim| try self.applyBindingsLimit(&out, lim);

        self.with_rows = out;
    }

    fn findOrCreateWithGroup(self: *Executor, groups: *std.ArrayList(WithGroup), keys: []const Binding, items: []const WithItem) ExecError!*WithGroup {
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

    fn dedupBindings(self: *Executor, rows: *std.ArrayList(Bindings)) void {
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

    fn applyBindingsSkip(self: *Executor, rows: *std.ArrayList(Bindings), skip: Index) ExecError!void {
        const n = try self.evalCountExpr(self.ast.nodeChildren(skip)[0]);
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

    fn applyBindingsLimit(self: *Executor, rows: *std.ArrayList(Bindings), limit: Index) ExecError!void {
        const n = try self.evalCountExpr(self.ast.nodeChildren(limit)[0]);
        if (n < rows.items.len) rows.shrinkRetainingCapacity(n);
    }

    fn sortBindings(self: *Executor, rows: *std.ArrayList(Bindings), ob: Index) ExecError!void {
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
                try ks.append(self.allocator, try self.eval(self.ast.nodeChildren(item)[0], b));
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

    /// Evaluates a non-negative integer literal (used by SKIP and LIMIT).
    fn evalCountExpr(self: *Executor, expr: Index) ExecError!usize {
        var empty = Bindings{ .entries = .empty };
        return switch (try self.eval(expr, &empty)) {
            .int => |n| if (n < 0) 0 else @as(usize, @intCast(n)),
            else => 0,
        };
    }

    fn accumulate(self: *Executor, bindings: *Bindings) ExecError!void {
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
    fn evalAggArg(self: *Executor, kind: AggKind, arg: ?Index, bindings: *Bindings) ExecError!Value {
        if (arg == null) return .{ .int = 0 }; // count(*) always counts
        if (kind == .count) return self.evalCountArg(arg.?, bindings);
        return self.eval(arg.?, bindings);
    }

    /// Evaluates `count(x)`: a bound node/edge variable is non-null; a scalar or
    /// property access may be null.
    fn evalCountArg(self: *Executor, expr: Index, bindings: *Bindings) ExecError!Value {
        if (self.ast.kind(expr) == .variable) {
            const name = self.ast.data(expr).text;
            switch (bindings.get(name) orelse return error.UnknownVar) {
                .node, .edge => return .{ .int = 0 }, // bound -> non-null sentinel
                .value => |v| return v, // may be null
            }
        }
        return self.eval(expr, bindings);
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
        switch (state.kind) {
            .count => {
                if (!isNull(arg)) state.count += 1;
            },
            .sum => {
                if (!isNull(arg)) state.sum += try asInt(arg);
            },
            .min => {
                if (isNull(arg)) return;
                if (state.min) |m| {
                    if (compareValue(arg, m) == .lt) state.min = arg;
                } else state.min = arg;
            },
            .max => {
                if (isNull(arg)) return;
                if (state.max) |m| {
                    if (compareValue(arg, m) == .gt) state.max = arg;
                } else state.max = arg;
            },
            .collect => {
                try state.list.append(self.allocator, arg);
            },
        }
    }

    fn aggregate(self: *Executor) ExecError!void {
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

    const ReturnInfo = struct {
        projection: Index,
        order_by: ?Index,
        skip: ?Index,
        limit: ?Index,
        distinct: bool,
    };

    fn returnInfo(self: *Executor, rc: Index) ReturnInfo {
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

    fn postProcess(self: *Executor, rc: Index) ExecError!void {
        const info = self.returnInfo(rc);

        if (self.has_agg) {
            try self.aggregate();
        }

        if (info.distinct) self.dedup();

        if (info.order_by) |ob| {
            try self.sortRows(ob);
        }

        if (info.skip) |sk| {
            const n = try self.evalCountExpr(self.ast.nodeChildren(sk)[0]);
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
            const n = try self.evalCountExpr(self.ast.nodeChildren(lim)[0]);
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

    fn applyMerge(self: *Executor, mc: Index, bindings: *Bindings) ExecError!void {
        const kids = self.ast.nodeChildren(mc);
        const pattern = kids[0];
        const on_create = kids[1];
        const on_match = kids[2];
        const chain = self.ast.nodeChildren(pattern);
        const num_nodes = (chain.len + 1) / 2;

        var created = false;
        for (0..num_nodes) |i| {
            const np_idx = chain[i * 2];
            const np = self.ast.data(np_idx).node_pattern;
            if (np.var_name.len == 0 or bindings.getNode(np.var_name) != null) continue;
            if (try self.findMatchingNode(np_idx, bindings)) |id| {
                try bindings.put(self.allocator, np.var_name, .{ .node = id });
            } else {
                const id = try self.createNode(np_idx, bindings);
                try bindings.put(self.allocator, np.var_name, .{ .node = id });
                created = true;
            }
        }
        try self.applyEdges(chain, num_nodes, bindings, true);

        // ON CREATE / ON MATCH SET (an empty set clause is a no-op).
        if (created) {
            try self.applySet(on_create, bindings);
        } else {
            try self.applySet(on_match, bindings);
        }
    }

    /// Creates a node from a `node_pattern` and returns its fresh id.
    fn createNode(self: *Executor, np_idx: Index, bindings: *Bindings) ExecError!NodeId {
        const np = self.ast.data(np_idx).node_pattern;
        const id = try self.graph.allocNodeId();
        try self.graph.addNode(id, ""); // node marker
        for (np.labels) |label| try self.graph.addLabel(id, label);
        for (self.ast.nodeChildren(np_idx)) |prop_idx| {
            const prop_name = self.ast.data(prop_idx).text;
            const value = try self.eval(self.ast.nodeChildren(prop_idx)[0], bindings);
            try self.graph.setProp(id, prop_name, value);
        }
        return id;
    }

    /// Finds an existing node matching the labels + property map, if any.
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
                if (!(try self.hasAllLabels(id, np.labels))) continue;
                if (try self.nodePropsMatch(np_idx, id, bindings)) return id;
            }
            return null;
        }

        var it = try self.seedNodes(np.labels);
        defer it.deinit();
        while (try it.next()) |id| {
            if (!(try self.hasAllLabels(id, np.labels))) continue;
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
                .value => return error.TypeMismatch,
            }
        }
    }

    fn applyRemove(self: *Executor, remove_clause: Index, bindings: *Bindings) ExecError!void {
        for (self.ast.nodeChildren(remove_clause)) |item| {
            switch (self.ast.kind(item)) {
                .property_access => {
                    const prop = self.ast.data(item).text;
                    const name = self.ast.data(self.ast.nodeChildren(item)[0]).text;
                    switch (bindings.get(name) orelse return error.UnknownVar) {
                        .node => |id| try self.graph.removeProp(id, prop),
                        .edge => |e| try self.graph.removeEdgeProp(e.src, e.dst, e.etype, prop),
                        .value => return error.TypeMismatch,
                    }
                },
                .label_ref => {
                    const label = self.ast.data(item).text;
                    const name = self.ast.data(self.ast.nodeChildren(item)[0]).text;
                    const id = bindings.getNode(name) orelse return error.UnknownVar;
                    try self.graph.removeLabel(id, label);
                },
                else => {},
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
                        self.fail(.node_still_connected, "node '{s}' still has relationships (use DETACH DELETE)", .{name});
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
            .null => false, // a null predicate filters the row out
            else => error.TypeMismatch,
        };
    }

    /// True if `needle` equals any element of the `list_literal` node. A null
    /// needle matches nothing (`null IN [...]` is null, treated as false here).
    fn inList(self: *Executor, needle: Value, list_node: Index, bindings: *Bindings) ExecError!bool {
        if (isNull(needle)) return false;
        for (self.ast.nodeChildren(list_node)) |item| {
            const v = try self.eval(item, bindings);
            if (valueEq(needle, v)) return true;
        }
        return false;
    }

    fn eval(self: *Executor, expr: Index, bindings: *Bindings) ExecError!Value {
        return switch (self.ast.kind(expr)) {
            .int_literal => .{ .int = self.ast.data(expr).int },
            .string_literal => .{ .str = self.ast.data(expr).text },
            .bool_literal => .{ .boolean = self.ast.data(expr).boolean },
            .list_literal => blk: {
                var items = std.ArrayList(Value).empty;
                for (self.ast.nodeChildren(expr)) |item| {
                    try items.append(self.allocator, try self.eval(item, bindings));
                }
                break :blk .{ .list = items.items };
            },
            .size_fn => blk: {
                const v = try self.eval(self.ast.nodeChildren(expr)[0], bindings);
                const n: usize = switch (v) {
                    .list => |items| items.len,
                    .str => |s| s.len,
                    .null => return error.TypeMismatch,
                    else => return error.TypeMismatch,
                };
                break :blk .{ .int = @intCast(n) };
            },
            .case_expr => blk: {
                const kids = self.ast.nodeChildren(expr);
                const else_present = (kids.len % 2) == 1;
                const num_pairs = kids.len / 2;
                var p: usize = 0;
                while (p < num_pairs) : (p += 1) {
                    if (try self.evalBool(kids[p * 2], bindings)) {
                        break :blk try self.eval(kids[p * 2 + 1], bindings);
                    }
                }
                if (else_present) {
                    break :blk try self.eval(kids[kids.len - 1], bindings);
                }
                break :blk .{ .null = {} };
            },
            .variable => blk: {
                const name = self.ast.data(expr).text;
                switch (bindings.get(name) orelse {
                    self.fail(.unknown_var, "unknown variable '{s}'", .{name});
                    return error.UnknownVar;
                }) {
                    .value => |v| break :blk v,
                    .node, .edge => return error.TypeMismatch,
                }
            },
            .property_access => blk: {
                const obj = self.ast.nodeChildren(expr)[0];
                if (self.ast.kind(obj) != .variable) return error.InvalidExpr;
                const name = self.ast.data(obj).text;
                const prop = self.ast.data(expr).text;
                switch (bindings.get(name) orelse {
                    self.fail(.unknown_var, "unknown variable '{s}'", .{name});
                    return error.UnknownVar;
                }) {
                    .node => |id| {
                        const v = (try self.graph.getProp(id, prop, self.allocator)) orelse {
                            self.fail(.missing_prop, "node has no property '{s}'", .{prop});
                            return error.MissingProp;
                        };
                        break :blk v;
                    },
                    .edge => |e| {
                        const v = (try self.graph.getEdgeProp(e.src, e.dst, e.etype, prop, self.allocator)) orelse {
                            self.fail(.missing_prop, "relationship has no property '{s}'", .{prop});
                            return error.MissingProp;
                        };
                        break :blk v;
                    },
                    .value => |v| {
                        // A property access on null yields null.
                        if (isNull(v)) break :blk .{ .null = {} };
                        return error.TypeMismatch;
                    },
                }
            },
            .binary_op => blk: {
                const op = self.ast.data(expr).bin_op;
                const kids = self.ast.nodeChildren(expr);
                if (op == .in_) {
                    // RHS is a list literal, not a scalar value.
                    const l = try self.eval(kids[0], bindings);
                    break :blk .{ .boolean = try self.inList(l, kids[1], bindings) };
                }
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
        .null => switch (r) {
            .null => true,
            else => false,
        },
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
        .list => |lv| switch (r) {
            .list => |rv| listEq(lv, rv),
            else => false,
        },
    };
}

fn listEq(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!valueEq(av, bv)) return false;
    }
    return true;
}

fn rowsEq(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!valueEq(av, bv)) return false;
    }
    return true;
}

fn hasProjKey(items: []const ProjItem) bool {
    for (items) |item| if (item == .key) return true;
    return false;
}

fn hasWithKey(items: []const WithItem) bool {
    for (items) |item| if (item != .agg) return true;
    return false;
}

fn aggResult(kind: AggKind, state: AggState) Value {
    return switch (kind) {
        .count => .{ .int = @intCast(state.count) },
        .sum => .{ .int = state.sum },
        .min => state.min orelse .{ .null = {} },
        .max => state.max orelse .{ .null = {} },
        .collect => .{ .list = state.list.items },
    };
}

/// Position of a value's type in the openCypher global sort order (ascending):
/// list < string < boolean < number < null.
fn typeRank(v: Value) u8 {
    return switch (v) {
        .list => 0,
        .str => 1,
        .boolean => 2,
        .int => 3,
        .null => 4,
    };
}

/// A total order over `Value` (the openCypher orderability used by ORDER BY,
/// min and max): values of different types order by `typeRank`; lists compare
/// lexicographically, strings by byte (= Unicode code point, for UTF-8), and
/// `false < true`. Consistent with `valueEq`: `.eq` exactly when equal.
fn compareValue(a: Value, b: Value) std.math.Order {
    const rank_order = std.math.order(typeRank(a), typeRank(b));
    if (rank_order != .eq) return rank_order;
    return switch (a) {
        .null => .eq,
        .int => |x| std.math.order(x, b.int),
        .str => |x| std.mem.order(u8, x, b.str),
        .boolean => |x| std.math.order(@intFromBool(x), @intFromBool(b.boolean)),
        .list => |x| compareLists(x, b.list),
    };
}

fn compareLists(a: []const Value, b: []const Value) std.math.Order {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        const element_order = compareValue(x, y);
        if (element_order != .eq) return element_order;
    }
    return std.math.order(a.len, b.len);
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

const WithSortCtx = struct {
    keys: []const std.ArrayList(Value),
    asc: []const bool,
};

fn withLessThanIdx(ctx: WithSortCtx, a: usize, b: usize) bool {
    const ka = ctx.keys[a].items;
    const kb = ctx.keys[b].items;
    for (ka, kb, ctx.asc) |va, vb, asc| {
        const ord = compareValue(va, vb);
        if (ord == .lt) return asc;
        if (ord == .gt) return !asc;
    }
    return false;
}

fn bindingEq(a: Binding, b: Binding) bool {
    return switch (a) {
        .node => |x| switch (b) {
            .node => |y| x == y,
            else => false,
        },
        .edge => |x| switch (b) {
            .edge => |y| x.src == y.src and x.dst == y.dst and std.mem.eql(u8, x.etype, y.etype),
            else => false,
        },
        .value => |x| switch (b) {
            .value => |y| valueEq(x, y),
            else => false,
        },
    };
}

fn bindingsEq(a: Bindings, b: Bindings) bool {
    if (a.entries.items.len != b.entries.items.len) return false;
    for (a.entries.items) |ea| {
        const eb = b.get(ea.name) orelse return false;
        if (!bindingEq(ea.value, eb)) return false;
    }
    return true;
}

fn bindingKeysEq(a: []const Binding, b: []const Binding) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!bindingEq(av, bv)) return false;
    }
    return true;
}

fn applyBinOp(op: BinOp, l: Value, r: Value) ExecError!Value {
    return switch (op) {
        .eq, .ne, .lt, .gt, .le, .ge, .starts_with, .ends_with, .contains => blk: {
            // Three-valued logic: any null operand yields null.
            if (isNull(l) or isNull(r)) break :blk .{ .null = {} };
            break :blk switch (op) {
                .eq => .{ .boolean = valueEq(l, r) },
                .ne => .{ .boolean = !valueEq(l, r) },
                .lt, .gt, .le, .ge => blk2: {
                    const li = try asInt(l);
                    const ri = try asInt(r);
                    break :blk2 .{ .boolean = switch (op) {
                        .lt => li < ri,
                        .gt => li > ri,
                        .le => li <= ri,
                        .ge => li >= ri,
                        else => unreachable,
                    } };
                },
                .starts_with, .ends_with, .contains => blk2: {
                    const ls = try asStr(l);
                    const rs = try asStr(r);
                    break :blk2 .{ .boolean = switch (op) {
                        .starts_with => std.mem.startsWith(u8, ls, rs),
                        .ends_with => std.mem.endsWith(u8, ls, rs),
                        .contains => std.mem.indexOf(u8, ls, rs) != null,
                        else => unreachable,
                    } };
                },
                else => unreachable,
            };
        },
        .and_ => blk: {
            const lb = try asBoolOpt(l);
            const rb = try asBoolOpt(r);
            if (lb == false or rb == false) break :blk .{ .boolean = false };
            if (lb == null or rb == null) break :blk .{ .null = {} };
            break :blk .{ .boolean = true };
        },
        .or_ => blk: {
            const lb = try asBoolOpt(l);
            const rb = try asBoolOpt(r);
            if (lb == true or rb == true) break :blk .{ .boolean = true };
            if (lb == null or rb == null) break :blk .{ .null = {} };
            break :blk .{ .boolean = false };
        },
        .in_ => unreachable, // handled in `eval` (RHS is a list literal)
    };
}

fn applyUnOp(op: UnOp, v: Value) ExecError!Value {
    return switch (op) {
        .not_ => if (isNull(v)) .{ .null = {} } else .{ .boolean = !try asBool(v) },
    };
}

fn asInt(v: Value) ExecError!i64 {
    return switch (v) {
        .int => |n| n,
        else => error.TypeMismatch,
    };
}

fn asStr(v: Value) ExecError![]const u8 {
    return switch (v) {
        .str => |s| s,
        else => error.TypeMismatch,
    };
}

fn asBool(v: Value) ExecError!bool {
    return switch (v) {
        .boolean => |b| b,
        else => error.TypeMismatch,
    };
}

/// Three-valued boolean coercion: `null` for null, an error for non-boolean.
fn asBoolOpt(v: Value) ExecError!?bool {
    return switch (v) {
        .boolean => |b| b,
        .null => null,
        else => error.TypeMismatch,
    };
}

fn isNull(v: Value) bool {
    return switch (v) {
        .null => true,
        else => false,
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

test "string predicates and IN membership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // STARTS WITH.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WHERE m.title STARTS WITH 'The' RETURN m.title", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
    });

    // ENDS WITH.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WHERE m.title ENDS WITH 'Wick' RETURN m.title", &.{
        &.{.{ .str = "John Wick" }},
    });

    // CONTAINS.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WHERE m.title CONTAINS 'Matrix' RETURN m.title", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
    });

    // IN with strings.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.name IN ['Keanu Reeves', 'Tom Hanks'] RETURN p.name", &.{
        &.{.{ .str = "Keanu Reeves" }},
        &.{.{ .str = "Tom Hanks" }},
    });

    // IN with ints.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.born IN [1961, 1964] RETURN p.name", &.{
        &.{.{ .str = "Keanu Reeves" }},
        &.{.{ .str = "Laurence Fishburne" }},
    });

    // IN with no match.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.name IN ['Nobody'] RETURN p.name", &.{});
}

test "WITH pipeline: aggregation, filter, passthrough and pagination" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // WITH aggregation + WHERE filter on the aggregate.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 RETURN p.name, cnt", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .int = 3 } },
    });

    // WITH passthrough + continued MATCH traversal.
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 MATCH (p)-[:ACTED_IN]->(m2:Movie) RETURN m2.title", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
        &.{.{ .str = "John Wick" }},
    });

    // WITH scalar alias projection.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) WITH p.name AS n RETURN n", &.{
        &.{.{ .str = "Keanu Reeves" }},
    });

    // WITH ORDER BY + SKIP + LIMIT (pagination mid-query).
    try expectOrdered(&ast, &g, "MATCH (p:Person) WITH p ORDER BY p.name SKIP 1 LIMIT 2 RETURN p.name", &.{
        &.{.{ .str = "Keanu Reeves" }},
        &.{.{ .str = "Lana Wachowski" }},
    });
}

test "SKIP pagination in RETURN" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectOrdered(&ast, &g, "MATCH (m:Movie) RETURN m.title ORDER BY m.released SKIP 1 LIMIT 2", &.{
        &.{.{ .str = "The Matrix" }},
        &.{.{ .str = "The Matrix Reloaded" }},
    });

    // SKIP without LIMIT.
    try expectOrdered(&ast, &g, "MATCH (m:Movie) RETURN m.title ORDER BY m.released SKIP 3", &.{
        &.{.{ .str = "John Wick" }},
    });
}

test "OPTIONAL MATCH: outer join and nulls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Unmatched optional pattern yields a null title.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Lana Wachowski'}) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) RETURN p.name, m.title", &.{
        &.{ .{ .str = "Lana Wachowski" }, .{ .null = {} } },
    });

    // Full outer join: each person with every acted movie, or null when none.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) RETURN p.name, m.title", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "The Matrix" } },
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "The Matrix Reloaded" } },
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "John Wick" } },
        &.{ .{ .str = "Carrie-Anne Moss" }, .{ .str = "The Matrix" } },
        &.{ .{ .str = "Laurence Fishburne" }, .{ .str = "The Matrix" } },
        &.{ .{ .str = "Lana Wachowski" }, .{ .null = {} } },
        &.{ .{ .str = "Tom Hanks" }, .{ .str = "Forrest Gump" } },
    });

    // count skips nulls: people with no DIRECTED movie count as 0.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m:Movie) RETURN p.name, count(m)", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .int = 0 } },
        &.{ .{ .str = "Carrie-Anne Moss" }, .{ .int = 0 } },
        &.{ .{ .str = "Laurence Fishburne" }, .{ .int = 0 } },
        &.{ .{ .str = "Lana Wachowski" }, .{ .int = 2 } },
        &.{ .{ .str = "Tom Hanks" }, .{ .int = 0 } },
    });

    // WHERE inside OPTIONAL MATCH: a person whose matches are all filtered out
    // still yields one null row (the outer-join fallback).
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2010 RETURN p.name, m.title", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "John Wick" } },
        &.{ .{ .str = "Carrie-Anne Moss" }, .{ .null = {} } },
        &.{ .{ .str = "Laurence Fishburne" }, .{ .null = {} } },
        &.{ .{ .str = "Lana Wachowski" }, .{ .null = {} } },
        &.{ .{ .str = "Tom Hanks" }, .{ .null = {} } },
    });

    // A null comparison in a post-join filter (via WITH) drops the row.
    try expectQuery(&ast, &g, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) WITH p, m WHERE m.released >= 2010 RETURN p.name, m.title", &.{
        &.{ .{ .str = "Keanu Reeves" }, .{ .str = "John Wick" } },
    });
}

test "lists: collect, size, list literals and UNWIND" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // size of a list literal.
    try expectQuery(&ast, &g, "RETURN size([1, 2, 3])", &.{
        &.{.{ .int = 3 }},
    });

    // size of a string.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) RETURN size(p.name)", &.{
        &.{.{ .int = 12 }},
    });

    // collect every movie title (scan order = ascending id).
    try expectQuery(&ast, &g, "MATCH (m:Movie) RETURN collect(m.title)", &.{
        &.{.{ .list = &.{
            .{ .str = "The Matrix" },
            .{ .str = "The Matrix Reloaded" },
            .{ .str = "John Wick" },
            .{ .str = "Forrest Gump" },
        } }},
    });

    // collect then size through WITH.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WITH collect(m.title) AS titles RETURN size(titles)", &.{
        &.{.{ .int = 4 }},
    });

    // UNWIND a list literal (no MATCH).
    try expectQuery(&ast, &g, "UNWIND [1, 2, 3] AS x RETURN x", &.{
        &.{.{ .int = 1 }},
        &.{.{ .int = 2 }},
        &.{.{ .int = 3 }},
    });

    // UNWIND after MATCH.
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) UNWIND [1, 2] AS x RETURN x", &.{
        &.{.{ .int = 1 }},
        &.{.{ .int = 2 }},
    });
}

test "multi-label, REMOVE, CASE and MERGE ON CREATE/MATCH" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Multi-label: a node carries both labels; matching requires all of them.
    try expectQuery(&ast, &g, "CREATE (n:Person:Employee {name: 'A'})", &.{});
    try expectQuery(&ast, &g, "CREATE (m:Person {name: 'B'})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person:Employee) RETURN n.name", &.{
        &.{.{ .str = "A" }},
    });
    try expectQuery(&ast, &g, "MATCH (n:Employee) RETURN n.name", &.{
        &.{.{ .str = "A" }},
    });
    try expectQuery(&ast, &g, "MATCH (n:Person) RETURN n.name", &.{
        &.{.{ .str = "A" }},
        &.{.{ .str = "B" }},
    });

    // REMOVE a label.
    try expectQuery(&ast, &g, "MATCH (n:Person:Employee) REMOVE n:Employee", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Employee) RETURN n.name", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person) RETURN n.name", &.{
        &.{.{ .str = "A" }},
        &.{.{ .str = "B" }},
    });

    // REMOVE a property (and its index entry).
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'A'}) REMOVE n.name", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'A'}) RETURN n.name", &.{});

    // CASE expression.
    try expectQuery(&ast, &g, "RETURN CASE WHEN 1 > 0 THEN 'yes' ELSE 'no' END", &.{
        &.{.{ .str = "yes" }},
    });

    // MERGE ON CREATE / ON MATCH SET.
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'X'}) ON CREATE SET n.c = 1 ON MATCH SET n.m = 1", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'X'}) RETURN n.c", &.{
        &.{.{ .int = 1 }},
    });
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'X'}) ON CREATE SET n.c = 2 ON MATCH SET n.m = 1", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'X'}) RETURN n.m", &.{
        &.{.{ .int = 1 }},
    });
}

test "edge-property index anchors unlabeled edge patterns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // Unlabeled nodes connected by a typed edge carrying a property.
    try g.addNode(1, "");
    try g.setProp(1, "name", .{ .str = "A" });
    try g.addNode(2, "");
    try g.setProp(2, "name", .{ .str = "B" });
    try g.addNode(3, "");
    try g.setProp(3, "name", .{ .str = "C" });
    try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProp(1, 2, "KNOWS", "weight", .{ .int = 5 });
    try g.addEdge(1, 3, "KNOWS");
    try g.setEdgeProp(1, 3, "KNOWS", "weight", .{ .int = 9 });

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // The edge-property index anchors the match: only weight=5 edges match.
    try expectQuery(&ast, &g, "MATCH (a)-[r:KNOWS {weight: 5}]->(b) RETURN a.name, b.name", &.{
        &.{ .{ .str = "A" }, .{ .str = "B" } },
    });
}

test "unlabeled node patterns scan every node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:P {v: 1})", &.{});
    try expectQuery(&ast, &g, "CREATE (b {v: 2})", &.{});

    // MATCH without a label sees labeled and unlabeled nodes alike.
    try expectQuery(&ast, &g, "MATCH (n) RETURN n.v", &.{
        &.{.{ .int = 1 }},
        &.{.{ .int = 2 }},
    });
    try expectQuery(&ast, &g, "MATCH (n) WHERE n.v > 1 RETURN n.v", &.{
        &.{.{ .int = 2 }},
    });

    // A bare MERGE matches an existing node instead of creating a new one.
    try expectQuery(&ast, &g, "MERGE (n)", &.{});
    try expectQuery(&ast, &g, "MATCH (n) RETURN count(*)", &.{
        &.{.{ .int = 2 }},
    });
}

test "UTF-8 and quoted names round-trip through labels and properties" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:Pérsona {año: 1990, nombre: 'Ñandú'})-[:`TRABAJA EN`]->(z:`Zona Norte`)", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Pérsona)-[:`TRABAJA EN`]->(z:`Zona Norte`) RETURN p.año, p.`nombre`", &.{
        &.{ .{ .int = 1990 }, .{ .str = "Ñandú" } },
    });
    // A quoted keyword is a plain name.
    try expectQuery(&ast, &g, "CREATE (n:`MATCH` {`count`: 3})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:`MATCH`) RETURN n.`count`", &.{
        &.{.{ .int = 3 }},
    });
}

test "ungrouped aggregation over zero rows yields one row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadSlice(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "MATCH (x:Nope) RETURN count(*), count(x), sum(x.v), min(x.v), max(x.v)", &.{
        &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .null = {} }, .{ .null = {} } },
    });
    try expectQuery(&ast, &g, "MATCH (x:Nope) WITH count(x) AS c RETURN c", &.{
        &.{.{ .int = 0 }},
    });
    // With a grouping key, zero rows still yield zero groups.
    try expectQuery(&ast, &g, "MATCH (x:Nope) RETURN x.name, count(*)", &.{});
    try expectQuery(&ast, &g, "MATCH (x:Nope) WITH x.name AS n, count(*) AS c RETURN n, c", &.{});
}

/// Random values for the order-law tests: every type, with lists nested up
/// to `depth` and small domains so that equal values actually occur.
fn randomValue(random: std.Random, arena: std.mem.Allocator, depth: u8) !Value {
    const strings = [_][]const u8{ "", "a", "ab", "b", "é", "Z" };
    const kinds: u8 = if (depth == 0) 4 else 5;
    return switch (random.uintLessThan(u8, kinds)) {
        0 => .{ .null = {} },
        1 => .{ .int = random.intRangeAtMost(i64, -2, 2) },
        2 => .{ .str = strings[random.uintLessThan(usize, strings.len)] },
        3 => .{ .boolean = random.boolean() },
        else => blk: {
            const items = try arena.alloc(Value, random.uintLessThan(usize, 3));
            for (items) |*item| item.* = try randomValue(random, arena, depth - 1);
            break :blk .{ .list = items };
        },
    };
}

test "compareValue is a total order consistent with valueEq" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0xacde);
    const random = prng.random();

    var values: [60]Value = undefined;
    for (&values) |*v| v.* = try randomValue(random, arena, 2);

    for (values) |a| {
        // Reflexive.
        try testing.expectEqual(std.math.Order.eq, compareValue(a, a));
        for (values) |b| {
            const ab = compareValue(a, b);
            // Antisymmetric, and `.eq` exactly when the values are equal.
            try testing.expectEqual(ab.invert(), compareValue(b, a));
            try testing.expectEqual(ab == .eq, valueEq(a, b));
            for (values) |c| {
                // Transitive.
                if (ab != .gt and compareValue(b, c) != .gt) {
                    try testing.expect(compareValue(a, c) != .gt);
                }
            }
        }
    }
}

test "compareValue follows the openCypher global sort order" {
    const list: Value = .{ .list = &.{} };
    const str: Value = .{ .str = "a" };
    const boolean: Value = .{ .boolean = true };
    const int: Value = .{ .int = 1 };
    const null_value: Value = .{ .null = {} };
    const ascending = [_]Value{ list, str, boolean, int, null_value };
    for (ascending[0 .. ascending.len - 1], ascending[1..]) |lower, higher| {
        try testing.expectEqual(std.math.Order.lt, compareValue(lower, higher));
    }
    // Lists: lexicographic, a proper prefix first.
    const one: Value = .{ .int = 1 };
    const two: Value = .{ .int = 2 };
    try testing.expectEqual(std.math.Order.lt, compareValue(.{ .list = &.{one} }, .{ .list = &.{ one, two } }));
    try testing.expectEqual(std.math.Order.gt, compareValue(.{ .list = &.{two} }, .{ .list = &.{ one, two } }));
}
