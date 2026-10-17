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
};

const BindStep = union(enum) {
    scan: struct { node: usize },
    expand: struct { from: usize, to: usize },
};

/// Dynamic variable-name -> node-id bindings.
const Bindings = struct {
    entries: std.ArrayList(struct { name: []const u8, id: NodeId }),

    fn get(self: *const Bindings, name: []const u8) ?NodeId {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.id;
        }
        return null;
    }

    fn put(self: *Bindings, allocator: Allocator, name: []const u8, id: NodeId) !void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                e.id = id;
                return;
            }
        }
        try self.entries.append(allocator, .{ .name = name, .id = id });
    }
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
    return_projection: ?Index,

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
            .return_projection = null,
            .diag = null,
        };
    }

    fn fail(self: *Executor, comptime fmt: []const u8, args: anytype) void {
        if (self.diag) |d| d.set(0, fmt, args);
    }

    pub fn run(self: *Executor, query: Index) ExecError![]const Row {
        self.rows.clearRetainingCapacity();

        var match_clause: ?Index = null;
        self.update_clauses = .empty;
        self.return_projection = null;
        for (self.ast.nodeChildren(query)) |c| {
            switch (self.ast.kind(c)) {
                .match_clause => match_clause = c,
                .create_clause, .merge_clause, .set_clause, .delete_clause => try self.update_clauses.append(self.allocator, c),
                .return_clause => self.return_projection = self.ast.nodeChildren(c)[0],
                else => {},
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
                .bound = bindings.get(np.var_name) != null,
            };
            for (self.ast.nodeChildren(np_idx)) |prop_idx| {
                const prop_name = self.ast.data(prop_idx).text;
                const value = self.ast.nodeChildren(prop_idx)[0];
                try node.seeks.append(self.allocator, .{ .prop = prop_name, .value = value });
            }
            try self.nodes.append(self.allocator, node);

            if (i + 1 < num_nodes) {
                const ep = self.ast.data(chain[i * 2 + 1]).edge_pattern;
                const fwd_dir: Direction = switch (ep.direction) {
                    .left_to_right => .out,
                    .right_to_left => .in,
                };
                try self.edges.append(self.allocator, .{ .etype = ep.etype, .fwd_dir = fwd_dir });
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
                        try bindings.put(self.allocator, node.var_name, id);
                        if (!try self.nodeSeeksMatch(s.node, id, bindings)) continue;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                } else {
                    var it = try self.graph.nodesWithLabel(node.label);
                    defer it.deinit();
                    while (try it.next()) |id| {
                        try bindings.put(self.allocator, node.var_name, id);
                        if (!try self.nodeSeeksMatch(s.node, id, bindings)) continue;
                        try self.execStep(step_idx + 1, pat_idx, bindings);
                    }
                }
            },
            .expand => |e| {
                const from_name = self.nodes.items[e.from].var_name;
                const from_id = bindings.get(from_name) orelse return error.UnknownVar;
                const edge = self.edges.items[@min(e.from, e.to)];
                const to_node = self.nodes.items[e.to];

                if (to_node.bound) {
                    // Verify the already-bound neighbour satisfies this edge.
                    const to_id = bindings.get(to_node.var_name) orelse return error.UnknownVar;
                    const sd = edgeSrcDst(edge.fwd_dir, e.from, e.to, from_id, to_id);
                    if (try self.graph.hasEdge(sd.src, sd.dst, edge.etype)) {
                        if (try self.nodeSeeksMatch(e.to, to_id, bindings)) {
                            try self.execStep(step_idx + 1, pat_idx, bindings);
                        }
                    }
                } else {
                    const dir: Direction = if (e.from < e.to) edge.fwd_dir else opposite(edge.fwd_dir);
                    var it = try self.graph.neighbours(from_id, dir, edge.etype);
                    defer it.deinit();
                    while (try it.next()) |nid| {
                        if (to_node.label.len > 0 and !(try self.graph.hasLabel(nid, to_node.label))) continue;
                        try bindings.put(self.allocator, to_node.var_name, nid);
                        if (!try self.nodeSeeksMatch(e.to, nid, bindings)) continue;
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

        if (self.return_projection) |proj| {
            var out = std.ArrayList(Value).empty;
            for (self.ast.nodeChildren(proj)) |item| {
                const v = try self.eval(self.ast.nodeChildren(item)[0], bindings);
                try out.append(self.allocator, v);
            }
            try self.rows.append(self.allocator, out);
        }
    }

    fn applyCreate(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
        const chain = self.ast.nodeChildren(pattern);
        const num_nodes = (chain.len + 1) / 2;

        for (0..num_nodes) |i| {
            const np_idx = chain[i * 2];
            const np = self.ast.data(np_idx).node_pattern;
            if (np.var_name.len == 0 or bindings.get(np.var_name) != null) continue;
            const id = try self.createNode(np_idx, bindings);
            try bindings.put(self.allocator, np.var_name, id);
        }
        try self.applyEdges(chain, num_nodes, bindings, false);
    }

    fn applyMerge(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
        const chain = self.ast.nodeChildren(pattern);
        const num_nodes = (chain.len + 1) / 2;

        for (0..num_nodes) |i| {
            const np_idx = chain[i * 2];
            const np = self.ast.data(np_idx).node_pattern;
            if (np.var_name.len == 0 or bindings.get(np.var_name) != null) continue;
            const id = (try self.findMatchingNode(np_idx, bindings)) orelse (try self.createNode(np_idx, bindings));
            try bindings.put(self.allocator, np.var_name, id);
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
            const ep = self.ast.data(chain[i * 2 + 1]).edge_pattern;
            const left_name = self.ast.data(chain[i * 2]).node_pattern.var_name;
            const right_name = self.ast.data(chain[i * 2 + 2]).node_pattern.var_name;
            const left_id = bindings.get(left_name) orelse return error.UnknownVar;
            const right_id = bindings.get(right_name) orelse return error.UnknownVar;
            const src: NodeId = if (ep.direction == .left_to_right) left_id else right_id;
            const dst: NodeId = if (ep.direction == .left_to_right) right_id else left_id;
            if (merge and (try self.graph.hasEdge(src, dst, ep.etype))) continue;
            try self.graph.addEdge(src, dst, ep.etype);
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
            const id = bindings.get(name) orelse return error.UnknownVar;
            const value = try self.eval(value_expr, bindings);
            try self.graph.setProp(id, prop, value);
        }
    }

    fn applyDelete(self: *Executor, delete_clause: Index, bindings: *Bindings) ExecError!void {
        for (self.ast.nodeChildren(delete_clause)) |item| {
            const obj = self.ast.nodeChildren(item)[0];
            const name = self.ast.data(obj).text;
            const id = bindings.get(name) orelse return error.UnknownVar;
            try self.graph.deleteNode(id);
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
                const id = bindings.get(name) orelse {
                    self.fail("unknown variable '{s}'", .{name});
                    return error.UnknownVar;
                };
                const prop = self.ast.data(expr).text;
                const v = (try self.graph.getProp(id, prop, self.allocator)) orelse {
                    self.fail("node has no property '{s}'", .{prop});
                    return error.MissingProp;
                };
                break :blk v;
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
