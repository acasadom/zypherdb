//! Pattern planning: turns a MATCH pattern into a chain of nodes and edges,
//! pushes equality and range predicates down to them, and orders the
//! operators that bind them from the most selective anchor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const Direction = @import("../storage/graph.zig").Direction;
const Statistics = @import("statistics.zig").Statistics;
const unknown = @import("statistics.zig").unknown;

const Plan = @import("Plan.zig");
const Operator = Plan.Operator;
const PatternNode = Plan.PatternNode;
const PatternEdge = Plan.PatternEdge;
const Seek = Plan.Seek;
const RangeSeek = Plan.RangeSeek;
const Scope = @import("scope.zig").Scope;

/// What planning a pattern reads: the query and the graph's counts.
pub const Context = struct {
    ast: *const Ast,
    statistics: *Statistics,
    allocator: Allocator,
};

/// Where the pattern sits in the plan being built.
pub const Placement = struct {
    index: Plan.PatternIndex,
    match: Plan.MatchIndex,
    first_node: u32,
    first_edge: u32,
};

/// Plans `pattern` (a `pattern` AST node), whose MATCH has the WHERE `where`
/// (null: none), with `scope` the variables bound before it. Appends the
/// operators that match it to `operators` and returns its plan.
pub fn plan(context: Context, pattern: Index, where: ?Index, scope: *const Scope, placement: Placement, operators: *std.ArrayList(Operator)) Allocator.Error!Plan.PatternPlan {
    var planner = Planner{ .context = context };
    try planner.collectElements(pattern, scope);
    if (where) |expression| try planner.collectWhereSeeks(expression);
    const path_variable = context.ast.data(pattern).text;
    if (where) |expression| planner.markPathReads(expression, path_variable);

    const allocator = context.allocator;
    const index = placement.index;
    for (planner.nodes.items, 0..) |node, node_index| {
        if (node.node.bound) try operators.append(allocator, .{ .bound_node = .{ .pattern = index, .node = @intCast(node_index) } });
    }
    if (planner.shouldEdgeAnchor()) {
        try operators.append(allocator, .{ .edge_index_scan = .{ .pattern = index, .edge = 0 } });
    } else {
        const anchor = try planner.chooseAnchor();
        // A bound anchor needs no scan: expand straight from its known value.
        if (!planner.nodes.items[anchor].node.bound) {
            try operators.append(allocator, .{ .node_scan = .{ .pattern = index, .node = @intCast(anchor) } });
        }
        var position: usize = anchor;
        while (position + 1 < planner.nodes.items.len) : (position += 1) {
            try operators.append(allocator, .{ .expand = .{ .pattern = index, .from = @intCast(position), .to = @intCast(position + 1) } });
        }
        position = anchor;
        while (position > 0) : (position -= 1) {
            try operators.append(allocator, .{ .expand = .{ .pattern = index, .from = @intCast(position), .to = @intCast(position - 1) } });
        }
    }
    if (path_variable.len > 0) try operators.append(allocator, .{ .project_path = index });

    return .{
        .nodes = try planner.frozenNodes(),
        .edges = try planner.frozenEdges(),
        .path_variable = path_variable,
        .match = placement.match,
        .first_node = placement.first_node,
        .first_edge = placement.first_edge,
    };
}

/// A node or edge being planned: its predicates still growing.
const NodeDraft = struct {
    node: PatternNode,
    seeks: std.ArrayList(Seek) = .empty,
    ranges: std.ArrayList(RangeSeek) = .empty,
};

const EdgeDraft = struct {
    edge: PatternEdge,
    seeks: std.ArrayList(Seek) = .empty,
};

const Planner = struct {
    context: Context,
    nodes: std.ArrayList(NodeDraft) = .empty,
    edges: std.ArrayList(EdgeDraft) = .empty,

    fn collectElements(self: *Planner, pattern: Index, scope: *const Scope) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const chain = ast.nodeChildren(pattern);
        const node_count = (chain.len + 1) / 2;
        for (0..node_count) |position| {
            const node_pattern_index = chain[position * 2];
            const node_pattern = ast.data(node_pattern_index).node_pattern;
            var draft = NodeDraft{ .node = .{
                .variable_name = node_pattern.variable_name,
                .labels = node_pattern.labels,
                .seeks = &.{},
                .ranges = &.{},
                .bound = scope.contains(node_pattern.variable_name),
            } };
            try appendPropertySeeks(self.context, node_pattern_index, &draft.seeks);
            try self.nodes.append(allocator, draft);

            if (position + 1 == node_count) break;
            const edge_pattern_index = chain[position * 2 + 1];
            const edge_pattern = ast.data(edge_pattern_index).edge_pattern;
            var edge_draft = EdgeDraft{ .edge = .{
                .edge_types = edge_pattern.edge_types,
                .variable_length = edge_pattern.variable_length,
                .min_hops = edge_pattern.min_hops,
                .max_hops = edge_pattern.max_hops,
                .shortest = edge_pattern.shortest,
                .forward_direction = switch (edge_pattern.direction) {
                    .left_to_right, .undirected => .out,
                    .right_to_left => .in,
                },
                .undirected = edge_pattern.direction == .undirected,
                .variable_name = edge_pattern.variable_name,
                .seeks = &.{},
            } };
            try appendPropertySeeks(self.context, edge_pattern_index, &edge_draft.seeks);
            try self.edges.append(allocator, edge_draft);
        }
    }

    fn frozenNodes(self: *Planner) Allocator.Error![]const PatternNode {
        const nodes = try self.context.allocator.alloc(PatternNode, self.nodes.items.len);
        for (nodes, self.nodes.items) |*node, draft| {
            node.* = draft.node;
            node.seeks = draft.seeks.items;
            node.ranges = draft.ranges.items;
        }
        return nodes;
    }

    fn frozenEdges(self: *Planner) Allocator.Error![]const PatternEdge {
        const edges = try self.context.allocator.alloc(PatternEdge, self.edges.items.len);
        for (edges, self.edges.items) |*edge, draft| {
            edge.* = draft.edge;
            edge.seeks = draft.seeks.items;
        }
        return edges;
    }

    /// A shortest path whose WHERE reads its path variable or its
    /// relationships must try the paths by increasing length.
    fn markPathReads(self: *Planner, where: Index, path_variable: []const u8) void {
        for (self.edges.items) |*draft| {
            if (draft.edge.shortest == .none) continue;
            draft.edge.where_reads_path = mentions(self.context.ast, where, path_variable) or mentions(self.context.ast, where, draft.edge.variable_name);
        }
    }

    /// Uses the edge-property index as the anchor when the pattern is a
    /// single edge with an equality seek and both endpoints are unbound and
    /// unselective.
    fn shouldEdgeAnchor(self: *const Planner) bool {
        if (self.nodes.items.len != 2 or self.edges.items.len != 1) return false;
        const edge = self.edges.items[0];
        if (edge.seeks.items.len == 0 or edge.edge.variable_length) return false;
        for (self.nodes.items) |draft| {
            if (draft.node.bound or draft.node.labels.len > 0 or draft.seeks.items.len > 0) return false;
        }
        return true;
    }

    fn nodeIndex(self: *const Planner, name: []const u8) ?usize {
        for (self.nodes.items, 0..) |draft, position| {
            if (std.mem.eql(u8, draft.node.variable_name, name)) return position;
        }
        return null;
    }

    /// Pulls `variable.property = value` and range comparisons out of the
    /// WHERE's AND tree, for nodes of this pattern.
    fn collectWhereSeeks(self: *Planner, expression: Index) Allocator.Error!void {
        const ast = self.context.ast;
        if (ast.kind(expression) != .binary_operation) return;
        const children = ast.nodeChildren(expression);
        switch (ast.data(expression).binary_operator) {
            .equal => {
                try self.addSeek(children[0], children[1]);
                try self.addSeek(children[1], children[0]);
            },
            // `n.x > v` and `v < n.x` bound n.x from below; `<` from above.
            .greater_than, .greater_or_equal => {
                try self.addRange(children[0], children[1], true);
                try self.addRange(children[1], children[0], false);
            },
            .less_than, .less_or_equal => {
                try self.addRange(children[0], children[1], false);
                try self.addRange(children[1], children[0], true);
            },
            .and_ => {
                try self.collectWhereSeeks(children[0]);
                try self.collectWhereSeeks(children[1]);
            },
            else => {},
        }
    }

    fn addSeek(self: *Planner, access_expression: Index, value_expression: Index) Allocator.Error!void {
        const target = self.seekTarget(access_expression, value_expression) orelse return;
        try self.nodes.items[target.node].seeks.append(self.context.allocator, .{ .property = target.property, .value = value_expression });
    }

    /// `node.property <op> value` (or reversed) as a range on the node: `value`
    /// is a lower bound for `>`/`>=`, an upper one for `<`/`<=`.
    fn addRange(self: *Planner, access_expression: Index, value_expression: Index, value_is_lower: bool) Allocator.Error!void {
        const target = self.seekTarget(access_expression, value_expression) orelse return;
        try self.nodes.items[target.node].ranges.append(self.context.allocator, .{
            .property = target.property,
            .lower = if (value_is_lower) value_expression else null,
            .upper = if (value_is_lower) null else value_expression,
        });
    }

    /// The pattern node and property of `access_expression` (`variable.property`
    /// of a node in this pattern), if `value_expression` is constant for the
    /// whole query, so usable as an index lookup.
    fn seekTarget(self: *const Planner, access_expression: Index, value_expression: Index) ?struct { node: usize, property: []const u8 } {
        const ast = self.context.ast;
        if (ast.kind(access_expression) != .property_access) return null;
        const object = ast.nodeChildren(access_expression)[0];
        if (ast.kind(object) != .variable) return null;
        switch (ast.kind(value_expression)) {
            .integer_literal, .float_literal, .string_literal, .boolean_literal, .parameter => {},
            else => return null,
        }
        const node_index = self.nodeIndex(ast.data(object).text) orelse return null;
        return .{ .node = node_index, .property = ast.data(access_expression).text };
    }

    /// How many candidates node `position` would produce as the anchor.
    fn estimate(self: *const Planner, position: usize) Allocator.Error!usize {
        const draft = self.nodes.items[position];
        if (draft.node.bound) return 0; // already known: a free start
        if (draft.seeks.items.len > 0) return 1;
        var best: usize = unknown;
        for (draft.node.labels) |label| best = @min(best, try self.context.statistics.labelCount(label));
        // A range keeps some of the nodes: a guess, without statistics, that is
        // enough to prefer it to a scan of the whole label.
        if (draft.ranges.items.len > 0) best = best / 4;
        if (draft.node.labels.len == 0 and draft.ranges.items.len == 0) return best;
        // Cap by the rarest incident edge type: the number of results is bounded
        // by the number of edges of that type, not just the label size.
        if (position > 0) best = @min(best, try self.edgeTypeCap(position - 1));
        if (position < self.edges.items.len) best = @min(best, try self.edgeTypeCap(position));
        return best;
    }

    fn edgeTypeCap(self: *const Planner, edge_position: usize) Allocator.Error!usize {
        const edge = self.edges.items[edge_position].edge;
        const edge_type = edge.singleType() orelse return unknown;
        if (edge.variable_length) return unknown;
        return self.context.statistics.edgeTypeCount(edge_type);
    }

    fn chooseAnchor(self: *const Planner) Allocator.Error!usize {
        var best: usize = 0;
        var best_estimate = try self.estimate(0);
        for (1..self.nodes.items.len) |position| {
            const candidate = try self.estimate(position);
            if (candidate < best_estimate) {
                best = position;
                best_estimate = candidate;
            }
        }
        return best;
    }
};

/// The `{name: value}` entries of a node or edge pattern, as seeks.
fn appendPropertySeeks(context: Context, element: Index, seeks: *std.ArrayList(Seek)) Allocator.Error!void {
    for (context.ast.nodeChildren(element)) |property_node| {
        try seeks.append(context.allocator, .{
            .property = context.ast.data(property_node).text,
            .value = context.ast.nodeChildren(property_node)[0],
        });
    }
}

/// True if `expression` reads the variable `name`.
pub fn mentions(ast: *const Ast, expression: Index, name: []const u8) bool {
    if (name.len == 0) return false;
    if (ast.kind(expression) == .variable and std.mem.eql(u8, ast.data(expression).text, name)) return true;
    for (ast.nodeChildren(expression)) |child| if (mentions(ast, child, name)) return true;
    return false;
}
