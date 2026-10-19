//! Pattern matching: runs the planned steps (scan, expand, edge-index scan)
//! over the graph, plus OPTIONAL MATCH (outer join) and UNWIND.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const NodeId = @import("../storage/graph.zig").NodeId;
const Direction = @import("../storage/graph.zig").Direction;
const NodeIdIterator = @import("../storage/graph.zig").NodeIdIterator;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const planner = @import("planner.zig");
const expressions = @import("expressions.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;
const PatternEdge = @import("planner.zig").PatternEdge;

/// Candidate nodes for a pattern: the first label's index, or every node
/// when the pattern is unlabeled. Callers verify the remaining labels.
pub fn seedNodes(self: *Executor, labels: []const []const u8) StorageError!NodeIdIterator {
    if (labels.len > 0) return self.graph.nodesWithLabel(labels[0]);
    return self.graph.allNodes();
}

/// True if `id` carries every label in `labels` (empty = always true).
pub fn hasAllLabels(self: *Executor, id: NodeId, labels: []const []const u8) StorageError!bool {
    for (labels) |l| {
        if (!(try self.graph.hasLabel(id, l))) return false;
    }
    return true;
}

pub fn matchPatterns(self: *Executor, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    if (pattern_index == self.patterns.len) {
        return self.matchFound(bindings);
    }
    try planner.setupPattern(self, self.patterns[pattern_index], bindings);
    try runStep(self, 0, pattern_index, bindings);
}

pub fn runStep(self: *Executor, step_index: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    if (step_index == self.steps.items.len) {
        return matchPatterns(self, pattern_index + 1, bindings);
    }
    switch (self.steps.items[step_index]) {
        .scan => |s| {
            const node = self.nodes.items[s.node];
            if (node.seeks.items.len > 0) {
                // Index lookup on the first equality predicate.
                const seek = node.seeks.items[0];
                const value = try expressions.evaluate(self, seek.value, bindings);
                var iterator = try self.graph.nodesByProperty(seek.property, value);
                defer iterator.deinit();
                while (try iterator.next()) |id| {
                    if (!(try hasAllLabels(self, id, node.labels))) continue;
                    try bindings.put(self.allocator, node.variable_name, .{ .node = id });
                    if (!try nodeSeeksMatch(self, s.node, id, bindings)) continue;
                    try runStep(self, step_index + 1, pattern_index, bindings);
                }
            } else {
                // Scan the first label as the seed, then verify the rest.
                var iterator = try seedNodes(self, node.labels);
                defer iterator.deinit();
                while (try iterator.next()) |id| {
                    if (!(try hasAllLabels(self, id, node.labels))) continue;
                    try bindings.put(self.allocator, node.variable_name, .{ .node = id });
                    if (!try nodeSeeksMatch(self, s.node, id, bindings)) continue;
                    try runStep(self, step_index + 1, pattern_index, bindings);
                }
            }
        },
        .edge_scan => |es| {
            const edge = self.edges.items[es.edge];
            const seek = edge.seeks.items[0];
            const value = try expressions.evaluate(self, seek.value, bindings);
            var iterator = try self.graph.edgesByProperty(seek.property, value);
            defer iterator.deinit();
            const left = self.nodes.items[es.edge];
            const right = self.nodes.items[es.edge + 1];
            while (try iterator.next()) |e| {
                if (edge.edge_type.len > 0 and !std.mem.eql(u8, e.edge_type, edge.edge_type)) continue;
                const left_id: NodeId = if (edge.forward_direction == .out) e.src else e.dst;
                const right_id: NodeId = if (edge.forward_direction == .out) e.dst else e.src;
                try bindings.put(self.allocator, left.variable_name, .{ .node = left_id });
                try bindings.put(self.allocator, right.variable_name, .{ .node = right_id });
                if (edge.variable_name.len > 0) {
                    try bindings.put(self.allocator, edge.variable_name, .{ .edge = .{ .src = e.src, .dst = e.dst, .edge_type = edge.edge_type } });
                }
                if (!try edgeSeeksMatch(self, edge, e.src, e.dst, bindings)) continue;
                if (!try nodeSeeksMatch(self, es.edge, left_id, bindings)) continue;
                if (!try nodeSeeksMatch(self, es.edge + 1, right_id, bindings)) continue;
                try runStep(self, step_index + 1, pattern_index, bindings);
            }
        },
        .expand => |e| {
            const from_name = self.nodes.items[e.from].variable_name;
            const from_id = bindings.getNode(from_name) orelse return error.UnknownVariable;
            const edge = self.edges.items[@min(e.from, e.to)];
            const to_node = self.nodes.items[e.to];

            if (to_node.bound) {
                // Verify the already-bound neighbour satisfies this edge.
                const to_id = bindings.getNode(to_node.variable_name) orelse return error.UnknownVariable;
                const endpoints = edgeSrcDst(edge.forward_direction, e.from, e.to, from_id, to_id);
                if (try self.graph.hasEdge(endpoints.src, endpoints.dst, edge.edge_type)) {
                    if (edge.variable_name.len > 0) {
                        try bindings.put(self.allocator, edge.variable_name, .{ .edge = .{ .src = endpoints.src, .dst = endpoints.dst, .edge_type = edge.edge_type } });
                    }
                    if (!try nodeSeeksMatch(self, e.to, to_id, bindings)) return;
                    if (!try edgeSeeksMatch(self, edge, endpoints.src, endpoints.dst, bindings)) return;
                    try runStep(self, step_index + 1, pattern_index, bindings);
                }
            } else {
                const direction: Direction = if (e.from < e.to) edge.forward_direction else opposite(edge.forward_direction);
                var iterator = try self.graph.neighbours(from_id, direction, edge.edge_type);
                defer iterator.deinit();
                while (try iterator.next()) |neighbour_id| {
                    if (!(try hasAllLabels(self, neighbour_id, to_node.labels))) continue;
                    try bindings.put(self.allocator, to_node.variable_name, .{ .node = neighbour_id });
                    if (!try nodeSeeksMatch(self, e.to, neighbour_id, bindings)) continue;
                    const endpoints = edgeSrcDst(edge.forward_direction, e.from, e.to, from_id, neighbour_id);
                    if (edge.variable_name.len > 0) {
                        try bindings.put(self.allocator, edge.variable_name, .{ .edge = .{ .src = endpoints.src, .dst = endpoints.dst, .edge_type = edge.edge_type } });
                    }
                    if (!try edgeSeeksMatch(self, edge, endpoints.src, endpoints.dst, bindings)) continue;
                    try runStep(self, step_index + 1, pattern_index, bindings);
                }
            }
        },
    }
}

/// UNWIND: for each element of the evaluated list, bind the variable and
/// continue (collect or finish). A null list yields no rows.
pub fn runUnwind(self: *Executor, bindings: *Bindings) ExecutionError!void {
    const unwind = self.unwind.?;
    const expr = self.ast.nodeChildren(unwind)[0];
    const variable_name = self.ast.data(unwind).unwind.variable_name;
    const v = try expressions.evaluate(self, expr, bindings);
    switch (v) {
        .list => |items| {
            for (items) |item| {
                try bindings.put(self.allocator, variable_name, .{ .value = item });
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
pub fn runOptional(self: *Executor, bindings: *Bindings) ExecutionError!void {
    const optional_match = self.optional_match.?;
    const optional_match_children = self.ast.nodeChildren(optional_match);

    // Save the in-flight match context; the optional match reuses the same
    // slots (`patterns`/`nodes`/`edges`/`steps`/`where_expression`/`has_match`).
    const saved_patterns = self.patterns;
    const saved_where = self.where_expression;
    const saved_has_match = self.has_match;
    const saved_nodes = self.nodes;
    const saved_edges = self.edges;
    const saved_steps = self.steps;
    const saved_in_optional = self.in_optional;

    self.in_optional = true;
    self.optional_matched = false;
    self.patterns = optional_match_children[0 .. optional_match_children.len - 1];
    self.where_expression = optional_match_children[optional_match_children.len - 1];
    self.has_match = true;

    // Unbind optional-only variables left over from a previous outer
    // iteration so they are matched fresh (shared variables stay bound).
    for (self.optional_vars.items) |name| {
        if (!isMainVariable(self, name)) bindings.remove(name);
    }

    try matchPatterns(self, 0, bindings);

    if (!self.optional_matched) {
        try bindOptionalNulls(self, bindings);
        try self.afterOptional(bindings);
    }

    // Restore the outer match context.
    self.patterns = saved_patterns;
    self.where_expression = saved_where;
    self.has_match = saved_has_match;
    self.nodes = saved_nodes;
    self.edges = saved_edges;
    self.steps = saved_steps;
    self.in_optional = saved_in_optional;
}

/// Collects the variable names introduced by the OPTIONAL MATCH patterns.
pub fn collectOptionalVars(self: *Executor, optional_match: Index) ExecutionError!void {
    self.optional_vars = .empty;
    try collectClauseVars(self, optional_match, &self.optional_vars);
}

/// Appends every node/edge variable name of a MATCH/OPTIONAL MATCH clause's
/// patterns to `out`.
pub fn collectClauseVars(self: *Executor, clause: Index, out: *std.ArrayList([]const u8)) ExecutionError!void {
    const children = self.ast.nodeChildren(clause);
    for (children[0 .. children.len - 1]) |pattern| {
        const chain = self.ast.nodeChildren(pattern);
        for (chain) |c| {
            switch (self.ast.kind(c)) {
                .node_pattern => {
                    const v = self.ast.data(c).node_pattern.variable_name;
                    if (v.len > 0) try out.append(self.allocator, v);
                },
                .edge_pattern => {
                    const v = self.ast.data(c).edge_pattern.variable_name;
                    if (v.len > 0) try out.append(self.allocator, v);
                },
                else => {},
            }
        }
    }
}

pub fn isMainVariable(self: *Executor, name: []const u8) bool {
    for (self.main_vars.items) |v| {
        if (std.mem.eql(u8, v, name)) return true;
    }
    return false;
}

/// Binds every optional-only variable to null (unmatched outer row, or a
/// match whose WHERE filtered it out). Shared variables stay bound.
pub fn bindOptionalNulls(self: *Executor, bindings: *Bindings) ExecutionError!void {
    for (self.optional_vars.items) |name| {
        if (isMainVariable(self, name)) continue;
        try bindings.put(self.allocator, name, .{ .value = .null });
    }
}

pub fn nodeSeeksMatch(self: *Executor, node_index: usize, id: NodeId, bindings: *Bindings) ExecutionError!bool {
    for (self.nodes.items[node_index].seeks.items) |seek| {
        const expected = try expressions.evaluate(self, seek.value, bindings);
        const actual = (try self.graph.getProperty(id, seek.property, self.allocator)) orelse return false;
        if (!Value.eql(actual, expected)) return false;
    }
    return true;
}

pub fn edgeSeeksMatch(self: *Executor, edge: PatternEdge, src: NodeId, dst: NodeId, bindings: *Bindings) ExecutionError!bool {
    for (edge.seeks.items) |seek| {
        const expected = try expressions.evaluate(self, seek.value, bindings);
        const actual = (try self.graph.getEdgeProperty(src, dst, edge.edge_type, seek.property, self.allocator)) orelse return false;
        if (!Value.eql(actual, expected)) return false;
    }
    return true;
}

pub fn opposite(direction: Direction) Direction {
    return switch (direction) {
        .out => .in,
        .in => .out,
    };
}

/// Computes the written edge's source/destination ids, given the two endpoint
/// node indices (`from`/`to`) and their ids. `forward_direction` is the direction when
/// traversing the lower index to the higher index.
pub fn edgeSrcDst(forward_direction: Direction, from: usize, to: usize, from_id: NodeId, to_id: NodeId) struct { src: NodeId, dst: NodeId } {
    const left_id = if (from < to) from_id else to_id;
    const right_id = if (from < to) to_id else from_id;
    return switch (forward_direction) {
        .out => .{ .src = left_id, .dst = right_id },
        .in => .{ .src = right_id, .dst = left_id },
    };
}
