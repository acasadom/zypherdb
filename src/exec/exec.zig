//! Volcano-style executor for the openCypher subset.
//!
//! The pattern is matched as nested loops over a "bind step" plan: pick the
//! most selective node as the anchor (anchor selection), scan it by label,
//! then expand outward along the pattern in both directions. Equality
//! predicates — from inline node property maps and from `WHERE` equalities —
//! are pushed down and checked as soon as their node is bound. The residual
//! `WHERE` is evaluated on each complete match, then the `RETURN` items are
//! projected.
//!
//! Anchor selection is heuristic: a node with any equality predicate is
//! estimated as 1 match; otherwise its label's node count (via `labelCount`).
//! There is no property index yet, so a pushed-down equality is applied as a
//! scan-and-filter rather than a point lookup.

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
};

const ChainEdge = struct {
    etype: []const u8,
    fwd_dir: Direction, // direction when traversing node_i -> node_{i+1}
};

const BindStep = union(enum) {
    scan: struct { node: usize },
    expand: struct { from: usize, to: usize },
};

pub const Executor = struct {
    ast: *Ast,
    graph: *Graph,
    allocator: Allocator, // scratch allocator, owned by the caller
    rows: std.ArrayList(Row),

    // Per-run context.
    nodes: std.ArrayList(ChainNode),
    edges: std.ArrayList(ChainEdge),
    steps: std.ArrayList(BindStep),
    where_expr: Index,
    projection: Index,

    pub fn init(ast: *Ast, graph: *Graph, allocator: Allocator) Executor {
        return .{
            .ast = ast,
            .graph = graph,
            .allocator = allocator,
            .rows = .empty,
            .nodes = .empty,
            .edges = .empty,
            .steps = .empty,
            .where_expr = 0,
            .projection = 0,
        };
    }

    /// Runs the `query` (an AST `query` node) and returns its projected rows,
    /// valid until `deinit`.
    pub fn run(self: *Executor, query: Index) ExecError![]const Row {
        self.rows.clearRetainingCapacity();

        const qc = self.ast.nodeChildren(query);
        const pattern = qc[0];
        self.where_expr = qc[1];
        self.projection = qc[2];

        const chain = self.ast.nodeChildren(pattern);
        const num_nodes = (chain.len + 1) / 2;

        self.nodes = .empty;
        self.edges = .empty;
        for (0..num_nodes) |i| {
            const np_idx = chain[i * 2];
            const np = self.ast.data(np_idx).node_pattern;
            var node = ChainNode{ .var_name = np.var_name, .label = np.label, .seeks = .empty };
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

        const anchor = self.chooseAnchor();
        try self.buildSteps(anchor);

        var row = std.ArrayList(?NodeId).empty;
        for (0..num_nodes) |_| try row.append(self.allocator, null);

        try self.execStep(0, &row);
        return self.rows.items;
    }

    // --- Planning ----------------------------------------------------------

    fn nodeIndex(self: *Executor, name: []const u8) ?usize {
        for (self.nodes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.var_name, name)) return i;
        }
        return null;
    }

    /// If `access_expr` is `var.prop` and `value_expr` is a literal, records a
    /// seek on `var`'s node. Returns whether a seek was recorded.
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

    /// Extracts equality seeks from an AND tree (safe: OR/NOT are left to the
    /// residual WHERE).
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
        try self.steps.append(self.allocator, .{ .scan = .{ .node = anchor } });

        // Expand right (anchor -> ... -> last node).
        var i: usize = anchor;
        while (i + 1 < self.nodes.items.len) : (i += 1) {
            try self.steps.append(self.allocator, .{ .expand = .{ .from = i, .to = i + 1 } });
        }
        // Expand left (anchor -> ... -> first node).
        i = anchor;
        while (i > 0) : (i -= 1) {
            try self.steps.append(self.allocator, .{ .expand = .{ .from = i, .to = i - 1 } });
        }
    }

    // --- Execution ---------------------------------------------------------

    fn execStep(self: *Executor, step_idx: usize, row: *std.ArrayList(?NodeId)) ExecError!void {
        if (step_idx == self.steps.items.len) {
            return self.emit(row);
        }
        switch (self.steps.items[step_idx]) {
            .scan => |s| {
                const node = self.nodes.items[s.node];
                var it = try self.graph.nodesWithLabel(node.label);
                defer it.deinit();
                while (try it.next()) |id| {
                    row.items[s.node] = id;
                    if (!try self.nodeSeeksMatch(s.node, id, row)) continue;
                    try self.execStep(step_idx + 1, row);
                }
            },
            .expand => |e| {
                const from_id = row.items[e.from].?;
                const edge = self.edges.items[@min(e.from, e.to)];
                const dir: Direction = if (e.from < e.to) edge.fwd_dir else opposite(edge.fwd_dir);
                const node = self.nodes.items[e.to];

                var it = try self.graph.neighbours(from_id, dir, edge.etype);
                defer it.deinit();
                while (try it.next()) |nid| {
                    if (node.label.len > 0 and !(try self.graph.hasLabel(nid, node.label))) continue;
                    row.items[e.to] = nid;
                    if (!try self.nodeSeeksMatch(e.to, nid, row)) continue;
                    try self.execStep(step_idx + 1, row);
                }
            },
        }
    }

    fn nodeSeeksMatch(self: *Executor, node_idx: usize, id: NodeId, row: *std.ArrayList(?NodeId)) ExecError!bool {
        for (self.nodes.items[node_idx].seeks.items) |seek| {
            const expected = try self.eval(seek.value, row);
            const actual = (try self.graph.getProp(id, seek.prop, self.allocator)) orelse return false;
            if (!valueEq(actual, expected)) return false;
        }
        return true;
    }

    fn emit(self: *Executor, row: *std.ArrayList(?NodeId)) ExecError!void {
        if (!try self.evalBool(self.where_expr, row)) return;

        var out = std.ArrayList(Value).empty;
        for (self.ast.nodeChildren(self.projection)) |item| {
            const expr = self.ast.nodeChildren(item)[0];
            const v = try self.eval(expr, row);
            try out.append(self.allocator, v);
        }
        try self.rows.append(self.allocator, out);
    }

    fn slotOf(self: *Executor, name: []const u8) ?usize {
        for (self.nodes.items, 0..) |n, i| {
            if (std.mem.eql(u8, n.var_name, name)) return i;
        }
        return null;
    }

    fn evalBool(self: *Executor, expr: Index, row: *std.ArrayList(?NodeId)) ExecError!bool {
        return switch (try self.eval(expr, row)) {
            .boolean => |b| b,
            else => error.TypeMismatch,
        };
    }

    fn eval(self: *Executor, expr: Index, row: *std.ArrayList(?NodeId)) ExecError!Value {
        return switch (self.ast.kind(expr)) {
            .int_literal => .{ .int = self.ast.data(expr).int },
            .string_literal => .{ .str = self.ast.data(expr).text },
            .bool_literal => .{ .boolean = self.ast.data(expr).boolean },
            .property_access => blk: {
                const obj = self.ast.nodeChildren(expr)[0];
                if (self.ast.kind(obj) != .variable) return error.InvalidExpr;
                const name = self.ast.data(obj).text;
                const slot = self.slotOf(name) orelse return error.UnknownVar;
                const id = row.items[slot] orelse return error.UnknownVar;
                const prop = self.ast.data(expr).text;
                const v = (try self.graph.getProp(id, prop, self.allocator)) orelse return error.MissingProp;
                break :blk v;
            },
            .binary_op => blk: {
                const op = self.ast.data(expr).bin_op;
                const kids = self.ast.nodeChildren(expr);
                const l = try self.eval(kids[0], row);
                const r = try self.eval(kids[1], row);
                break :blk try applyBinOp(op, l, r);
            },
            .unary_op => blk: {
                const op = self.ast.data(expr).un_op;
                const v = try self.eval(self.ast.nodeChildren(expr)[0], row);
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
    const query = try parser.parse(ast, src);
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
