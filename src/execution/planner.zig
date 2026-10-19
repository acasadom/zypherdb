//! Pattern planning: turns a MATCH pattern into a chain of nodes and edges,
//! pushes equality predicates down to them, and orders the binding steps from
//! the most selective anchor.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Direction = @import("../storage/graph.zig").Direction;

const Executor = @import("Executor.zig");
const ExecError = Executor.ExecError;

const Bindings = @import("bindings.zig").Bindings;

pub fn setupPattern(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
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
pub fn shouldEdgeAnchor(self: *Executor) bool {
    if (self.nodes.items.len != 2 or self.edges.items.len != 1) return false;
    if (self.edges.items[0].seeks.items.len == 0) return false;
    const a = self.nodes.items[0];
    const b = self.nodes.items[1];
    if (a.bound or b.bound) return false;
    if (a.labels.len > 0 or b.labels.len > 0) return false;
    if (a.seeks.items.len > 0 or b.seeks.items.len > 0) return false;
    return true;
}

pub fn buildEdgeSteps(self: *Executor) ExecError!void {
    self.steps = .empty;
    try self.steps.append(self.allocator, .{ .edge_scan = .{ .edge = 0 } });
}

pub fn nodeIndex(self: *Executor, name: []const u8) ?usize {
    for (self.nodes.items, 0..) |n, i| {
        if (std.mem.eql(u8, n.var_name, name)) return i;
    }
    return null;
}

pub fn tryAddSeek(self: *Executor, access_expr: Index, value_expr: Index) ExecError!bool {
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

pub fn collectWhereSeeks(self: *Executor, expr: Index) ExecError!void {
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

pub fn estimate(self: *Executor, node_idx: usize) usize {
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

pub fn chooseAnchor(self: *Executor) usize {
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

pub fn buildSteps(self: *Executor, anchor: usize) ExecError!void {
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

/// An equality predicate `node.prop = value_expr` pushed down to a node.
pub const Seek = struct {
    prop: []const u8,
    value: Index, // AST literal expr
};

pub const ChainNode = struct {
    var_name: []const u8,
    labels: []const []const u8,
    seeks: std.ArrayList(Seek),
    bound: bool, // already bound by an earlier pattern in this query
};

pub const ChainEdge = struct {
    etype: []const u8,
    fwd_dir: Direction, // direction when traversing node_i -> node_{i+1}
    var_name: []const u8,
    seeks: std.ArrayList(Seek), // inline property equality filters
};

pub const BindStep = union(enum) {
    scan: struct { node: usize },
    expand: struct { from: usize, to: usize },
    edge_scan: struct { edge: usize }, // bind both endpoints from an edge-prop seek
};
