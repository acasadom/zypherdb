//! Naive Volcano-style executor for the openCypher subset.
//!
//! The pattern is matched as nested loops: scan the anchor node (first node of
//! the pattern, by label), then expand edge by edge, then apply the filters
//! (`WHERE` plus every node's inline property map) and project the `RETURN`
//! items. No predicate pushdown and no anchor selection yet — that is the next
//! step. The anchor is always the pattern's first node, so its label must be
//! non-empty (unlabeled all-node scans are not implemented yet).

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

pub const Executor = struct {
    ast: *Ast,
    graph: *Graph,
    arena: std.heap.ArenaAllocator,
    rows: std.ArrayList(Row),

    // Per-run context.
    chain: []const Index, // pattern children: node0, edge0, node1, ...
    var_names: std.ArrayList([]const u8), // slot -> variable name
    where_expr: Index,
    projection: Index,

    pub fn init(ast: *Ast, graph: *Graph, allocator: Allocator) Executor {
        return .{
            .ast = ast,
            .graph = graph,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .rows = .empty,
            .chain = &.{},
            .var_names = .empty,
            .where_expr = 0,
            .projection = 0,
        };
    }

    pub fn deinit(self: *Executor) void {
        self.arena.deinit();
    }

    /// Runs the `query` (an AST `query` node) and returns its projected rows,
    /// valid until `deinit`.
    pub fn run(self: *Executor, query: Index) ExecError![]const Row {
        self.rows.clearRetainingCapacity();

        const qc = self.ast.nodeChildren(query);
        self.chain = self.ast.nodeChildren(qc[0]);
        self.where_expr = qc[1];
        self.projection = qc[2];

        self.var_names = .empty;
        for (self.chain, 0..) |c, i| {
            if (i % 2 == 0) {
                try self.var_names.append(self.arena.allocator(), self.ast.data(c).node_pattern.var_name);
            }
        }

        const num_nodes = (self.chain.len + 1) / 2;
        var row = std.ArrayList(?NodeId).empty;
        for (0..num_nodes) |_| try row.append(self.arena.allocator(), null);

        const anchor_label = self.ast.data(self.chain[0]).node_pattern.label;
        var it = try self.graph.nodesWithLabel(anchor_label);
        defer it.deinit();
        while (try it.next()) |id| {
            row.items[0] = id;
            try self.expandChain(0, &row);
        }

        return self.rows.items;
    }

    /// Binds node `edge_idx + 1` from the neighbours of node `edge_idx`, then
    /// recurses; at the last edge it emits a projected row.
    fn expandChain(self: *Executor, edge_idx: usize, row: *std.ArrayList(?NodeId)) ExecError!void {
        const num_edges = self.chain.len / 2;
        if (edge_idx == num_edges) {
            return self.emit(row);
        }

        const from_id = row.items[edge_idx].?;
        const edge = self.ast.data(self.chain[edge_idx * 2 + 1]).edge_pattern;
        const dir: Direction = switch (edge.direction) {
            .left_to_right => .out,
            .right_to_left => .in,
        };

        var it = try self.graph.neighbours(from_id, dir, edge.etype);
        defer it.deinit();
        while (try it.next()) |nid| {
            const label = self.ast.data(self.chain[(edge_idx + 1) * 2]).node_pattern.label;
            if (label.len > 0 and !(try self.graph.hasLabel(nid, label))) continue;
            row.items[edge_idx + 1] = nid;
            try self.expandChain(edge_idx + 1, row);
        }
    }

    fn emit(self: *Executor, row: *std.ArrayList(?NodeId)) ExecError!void {
        if (!try self.evalBool(self.where_expr, row)) return;
        if (!try self.nodesMatch(row)) return;

        var out = std.ArrayList(Value).empty;
        for (self.ast.nodeChildren(self.projection)) |item| {
            const expr = self.ast.nodeChildren(item)[0];
            const v = try self.eval(expr, row);
            try out.append(self.arena.allocator(), v);
        }
        try self.rows.append(self.arena.allocator(), out);
    }

    /// True if every node's inline property map matches its binding.
    fn nodesMatch(self: *Executor, row: *std.ArrayList(?NodeId)) ExecError!bool {
        for (self.chain, 0..) |c, i| {
            if (i % 2 != 0) continue; // edges carry no properties here
            const var_name = self.ast.data(c).node_pattern.var_name;
            const slot = self.slotOf(var_name) orelse return error.UnknownVar;
            const id = row.items[slot].?;
            if (!try self.nodePropsMatch(c, id, row)) return false;
        }
        return true;
    }

    fn nodePropsMatch(self: *Executor, node_pattern_idx: Index, id: NodeId, row: *std.ArrayList(?NodeId)) ExecError!bool {
        for (self.ast.nodeChildren(node_pattern_idx)) |prop_idx| {
            const prop_name = self.ast.data(prop_idx).text;
            const value_expr = self.ast.nodeChildren(prop_idx)[0];
            const expected = try self.eval(value_expr, row);
            const actual = (try self.graph.getProp(id, prop_name, self.arena.allocator())) orelse return false;
            if (!valueEq(actual, expected)) return false;
        }
        return true;
    }

    fn slotOf(self: *Executor, name: []const u8) ?usize {
        for (self.var_names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
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
                const v = (try self.graph.getProp(id, prop, self.arena.allocator())) orelse return error.MissingProp;
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
    var exec = Executor.init(ast, g, testing.allocator);
    defer exec.deinit();
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
