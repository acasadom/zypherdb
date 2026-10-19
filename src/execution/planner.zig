//! Pattern planning: turns a MATCH pattern into a chain of nodes and edges,
//! pushes equality predicates down to them, and orders the binding steps from
//! the most selective anchor.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Direction = @import("../storage/graph.zig").Direction;
const NodeId = @import("../storage/graph.zig").NodeId;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;
const Relationship = @import("../value.zig").Relationship;

pub fn setupPattern(self: *Executor, pattern: Index, bindings: *Bindings) ExecutionError!void {
    const chain = self.ast.nodeChildren(pattern);
    const num_nodes = (chain.len + 1) / 2;

    self.nodes = .empty;
    self.edges = .empty;
    for (0..num_nodes) |i| {
        const node_pattern_index = chain[i * 2];
        const node_pattern = self.ast.data(node_pattern_index).node_pattern;
        var node = PatternNode{
            .variable_name = node_pattern.variable_name,
            .labels = node_pattern.labels,
            .seeks = .empty,
            .bound = node_pattern.variable_name.len > 0 and bindings.getNode(node_pattern.variable_name) != null,
        };
        for (self.ast.nodeChildren(node_pattern_index)) |property_node| {
            const property_name = self.ast.data(property_node).text;
            const value = self.ast.nodeChildren(property_node)[0];
            try node.seeks.append(self.allocator, .{ .property = property_name, .value = value });
        }
        try self.nodes.append(self.allocator, node);

        if (i + 1 < num_nodes) {
            const edge_pattern_index = chain[i * 2 + 1];
            const edge_pattern = self.ast.data(edge_pattern_index).edge_pattern;
            const forward_direction: Direction = switch (edge_pattern.direction) {
                .left_to_right, .undirected => .out,
                .right_to_left => .in,
            };
            var edge = PatternEdge{
                .edge_types = edge_pattern.edge_types,
                .variable_length = edge_pattern.variable_length,
                .min_hops = edge_pattern.min_hops,
                .max_hops = edge_pattern.max_hops,
                .forward_direction = forward_direction,
                .undirected = edge_pattern.direction == .undirected,
                .variable_name = edge_pattern.variable_name,
                .bound = if (edge_pattern.variable_name.len > 0) bindings.getRelationship(edge_pattern.variable_name) else null,
                .seeks = .empty,
            };
            for (self.ast.nodeChildren(edge_pattern_index)) |property_node| {
                const property_name = self.ast.data(property_node).text;
                const value = self.ast.nodeChildren(property_node)[0];
                try edge.seeks.append(self.allocator, .{ .property = property_name, .value = value });
            }
            try self.edges.append(self.allocator, edge);
        }
    }

    self.path_variable = self.ast.data(pattern).text;
    try collectWhereSeeks(self, self.where_expression);
    if (shouldEdgeAnchor(self)) {
        try buildEdgeSteps(self);
    } else {
        try buildSteps(self, chooseAnchor(self));
    }
}

/// Uses the edge-property index as the anchor when the pattern is a single
/// edge with an equality seek and both endpoints are unbound/unselective.
pub fn shouldEdgeAnchor(self: *Executor) bool {
    if (self.nodes.items.len != 2 or self.edges.items.len != 1) return false;
    if (self.edges.items[0].seeks.items.len == 0 or self.edges.items[0].variable_length) return false;
    const a = self.nodes.items[0];
    const b = self.nodes.items[1];
    if (a.bound or b.bound) return false;
    if (a.labels.len > 0 or b.labels.len > 0) return false;
    if (a.seeks.items.len > 0 or b.seeks.items.len > 0) return false;
    return true;
}

pub fn buildEdgeSteps(self: *Executor) ExecutionError!void {
    self.steps = .empty;
    try self.steps.append(self.allocator, .{ .edge_scan = .{ .edge = 0 } });
}

pub fn nodeIndex(self: *Executor, name: []const u8) ?usize {
    for (self.nodes.items, 0..) |n, i| {
        if (std.mem.eql(u8, n.variable_name, name)) return i;
    }
    return null;
}

pub fn tryAddSeek(self: *Executor, access_expression: Index, value_expression: Index) ExecutionError!bool {
    if (self.ast.kind(access_expression) != .property_access) return false;
    const object = self.ast.nodeChildren(access_expression)[0];
    if (self.ast.kind(object) != .variable) return false;
    switch (self.ast.kind(value_expression)) {
        // Constant for the whole query, so usable as an index lookup.
        .integer_literal, .string_literal, .boolean_literal, .parameter => {},
        else => return false,
    }
    const variable_name = self.ast.data(object).text;
    const node_index = nodeIndex(self, variable_name) orelse return false;
    const property = self.ast.data(access_expression).text;
    try self.nodes.items[node_index].seeks.append(self.allocator, .{ .property = property, .value = value_expression });
    return true;
}

pub fn collectWhereSeeks(self: *Executor, expr: Index) ExecutionError!void {
    if (self.ast.kind(expr) != .binary_operation) return;
    const operator = self.ast.data(expr).binary_operator;
    const children = self.ast.nodeChildren(expr);
    switch (operator) {
        .equal => {
            _ = try tryAddSeek(self, children[0], children[1]);
            _ = try tryAddSeek(self, children[1], children[0]);
        },
        .and_ => {
            try collectWhereSeeks(self, children[0]);
            try collectWhereSeeks(self, children[1]);
        },
        else => {},
    }
}

pub fn estimate(self: *Executor, node_index: usize) usize {
    const node = self.nodes.items[node_index];
    if (node.bound) return 0; // already known: a free start
    if (node.seeks.items.len > 0) return 1;
    if (node.labels.len == 0) return std.math.maxInt(usize);
    var best: usize = std.math.maxInt(usize);
    for (node.labels) |label| {
        const count = self.graph.labelCount(label) catch std.math.maxInt(usize);
        if (count < best) best = count;
    }
    // Cap by the rarest incident edge type: the number of results is bounded
    // by the number of edges of that type, not just the label size.
    if (node_index > 0) {
        const edge = self.edges.items[node_index - 1];
        if (edge.singleType()) |edge_type| {
            if (!edge.variable_length) {
                const count = self.graph.edgeTypeCount(edge_type) catch std.math.maxInt(usize);
                if (count < best) best = count;
            }
        }
    }
    if (node_index < self.edges.items.len) {
        const edge = self.edges.items[node_index];
        if (edge.singleType()) |edge_type| {
            if (!edge.variable_length) {
                const count = self.graph.edgeTypeCount(edge_type) catch std.math.maxInt(usize);
                if (count < best) best = count;
            }
        }
    }
    return best;
}

pub fn chooseAnchor(self: *Executor) usize {
    var best: usize = 0;
    var best_est = estimate(self, 0);
    for (1..self.nodes.items.len) |i| {
        const est = estimate(self, i);
        if (est < best_est) {
            best = i;
            best_est = est;
        }
    }
    return best;
}

pub fn buildSteps(self: *Executor, anchor: usize) ExecutionError!void {
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

/// An equality predicate `node.property = value_expression` pushed down to a node.
pub const Seek = struct {
    property: []const u8,
    value: Index, // AST literal expr
};

pub const PatternNode = struct {
    variable_name: []const u8,
    labels: []const []const u8,
    seeks: std.ArrayList(Seek),
    bound: bool, // already bound by an earlier pattern in this query
    /// The node this position is matched to on the current search branch
    /// (set by the step that binds it; read by later expansions, so anonymous
    /// nodes need no variable).
    id: NodeId = undefined,
};

pub const PatternEdge = struct {
    edge_types: []const []const u8, // empty: any type
    /// `*min..max`: a path of min..max edges (max null: unbounded).
    variable_length: bool,
    min_hops: u32,
    max_hops: ?u32,
    forward_direction: Direction, // direction when traversing node_i -> node_{i+1}
    undirected: bool, // `-[...]-`: either direction (forward_direction unused)
    variable_name: []const u8,
    bound: ?Relationship, // the edge its variable is already bound to, if any
    seeks: std.ArrayList(Seek), // inline property equality filters
    /// The relationships matched on the current search branch, in pattern
    /// (left to right) order: the path variable is built from them.
    matched: []const Relationship = &.{},
    single_match: [1]Relationship = undefined,

    /// True if an edge of type `edge_type` fits the pattern.
    pub fn allowsType(self: PatternEdge, edge_type: []const u8) bool {
        if (self.edge_types.len == 0) return true;
        for (self.edge_types) |allowed| {
            if (std.mem.eql(u8, allowed, edge_type)) return true;
        }
        return false;
    }

    /// The one type the pattern requires, if it names exactly one.
    pub fn singleType(self: PatternEdge) ?[]const u8 {
        return if (self.edge_types.len == 1) self.edge_types[0] else null;
    }
};

pub const PlanStep = union(enum) {
    scan: struct { node: usize },
    expand: struct { from: usize, to: usize },
    edge_scan: struct { edge: usize }, // bind both endpoints from an edge-property seek
};
