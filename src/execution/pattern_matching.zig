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
const ExecError = Executor.ExecError;

const Bindings = @import("bindings.zig").Bindings;
const ChainEdge = @import("planner.zig").ChainEdge;

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

pub fn matchPatterns(self: *Executor, pat_idx: usize, bindings: *Bindings) ExecError!void {
    if (pat_idx == self.patterns.len) {
        return self.leaf(bindings);
    }
    try planner.setupPattern(self, self.patterns[pat_idx], bindings);
    try execStep(self, 0, pat_idx, bindings);
}

pub fn execStep(self: *Executor, step_idx: usize, pat_idx: usize, bindings: *Bindings) ExecError!void {
    if (step_idx == self.steps.items.len) {
        return matchPatterns(self, pat_idx + 1, bindings);
    }
    switch (self.steps.items[step_idx]) {
        .scan => |s| {
            const node = self.nodes.items[s.node];
            if (node.seeks.items.len > 0) {
                // Index lookup on the first equality predicate.
                const seek = node.seeks.items[0];
                const value = try expressions.eval(self, seek.value, bindings);
                var it = try self.graph.nodesByProp(seek.prop, value);
                defer it.deinit();
                while (try it.next()) |id| {
                    if (!(try hasAllLabels(self, id, node.labels))) continue;
                    try bindings.put(self.allocator, node.var_name, .{ .node = id });
                    if (!try nodeSeeksMatch(self, s.node, id, bindings)) continue;
                    try execStep(self, step_idx + 1, pat_idx, bindings);
                }
            } else {
                // Scan the first label as the seed, then verify the rest.
                var it = try seedNodes(self, node.labels);
                defer it.deinit();
                while (try it.next()) |id| {
                    if (!(try hasAllLabels(self, id, node.labels))) continue;
                    try bindings.put(self.allocator, node.var_name, .{ .node = id });
                    if (!try nodeSeeksMatch(self, s.node, id, bindings)) continue;
                    try execStep(self, step_idx + 1, pat_idx, bindings);
                }
            }
        },
        .edge_scan => |es| {
            const edge = self.edges.items[es.edge];
            const seek = edge.seeks.items[0];
            const value = try expressions.eval(self, seek.value, bindings);
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
                if (!try edgeSeeksMatch(self, edge, e.src, e.dst, bindings)) continue;
                if (!try nodeSeeksMatch(self, es.edge, left_id, bindings)) continue;
                if (!try nodeSeeksMatch(self, es.edge + 1, right_id, bindings)) continue;
                try execStep(self, step_idx + 1, pat_idx, bindings);
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
                    if (!try nodeSeeksMatch(self, e.to, to_id, bindings)) return;
                    if (!try edgeSeeksMatch(self, edge, sd.src, sd.dst, bindings)) return;
                    try execStep(self, step_idx + 1, pat_idx, bindings);
                }
            } else {
                const dir: Direction = if (e.from < e.to) edge.fwd_dir else opposite(edge.fwd_dir);
                var it = try self.graph.neighbours(from_id, dir, edge.etype);
                defer it.deinit();
                while (try it.next()) |nid| {
                    if (!(try hasAllLabels(self, nid, to_node.labels))) continue;
                    try bindings.put(self.allocator, to_node.var_name, .{ .node = nid });
                    if (!try nodeSeeksMatch(self, e.to, nid, bindings)) continue;
                    const sd = edgeSrcDst(edge.fwd_dir, e.from, e.to, from_id, nid);
                    if (edge.var_name.len > 0) {
                        try bindings.put(self.allocator, edge.var_name, .{ .edge = .{ .src = sd.src, .dst = sd.dst, .etype = edge.etype } });
                    }
                    if (!try edgeSeeksMatch(self, edge, sd.src, sd.dst, bindings)) continue;
                    try execStep(self, step_idx + 1, pat_idx, bindings);
                }
            }
        },
    }
}

/// UNWIND: for each element of the evaluated list, bind the variable and
/// continue (collect or finish). A null list yields no rows.
pub fn runUnwind(self: *Executor, bindings: *Bindings) ExecError!void {
    const u = self.unwind.?;
    const expr = self.ast.nodeChildren(u)[0];
    const var_name = self.ast.data(u).unwind.var_name;
    const v = try expressions.eval(self, expr, bindings);
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
pub fn runOptional(self: *Executor, bindings: *Bindings) ExecError!void {
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
        if (!isMainVar(self, name)) bindings.remove(name);
    }

    try matchPatterns(self, 0, bindings);

    if (!self.optional_matched) {
        try bindOptionalNulls(self, bindings);
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
pub fn collectOptionalVars(self: *Executor, om: Index) ExecError!void {
    self.optional_vars = .empty;
    try collectClauseVars(self, om, &self.optional_vars);
}

/// Appends every node/edge variable name of a MATCH/OPTIONAL MATCH clause's
/// patterns to `out`.
pub fn collectClauseVars(self: *Executor, clause: Index, out: *std.ArrayList([]const u8)) ExecError!void {
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

pub fn isMainVar(self: *Executor, name: []const u8) bool {
    for (self.main_vars.items) |v| {
        if (std.mem.eql(u8, v, name)) return true;
    }
    return false;
}

/// Binds every optional-only variable to null (unmatched outer row, or a
/// match whose WHERE filtered it out). Shared variables stay bound.
pub fn bindOptionalNulls(self: *Executor, bindings: *Bindings) ExecError!void {
    for (self.optional_vars.items) |name| {
        if (isMainVar(self, name)) continue;
        try bindings.put(self.allocator, name, .{ .value = .null });
    }
}

pub fn nodeSeeksMatch(self: *Executor, node_idx: usize, id: NodeId, bindings: *Bindings) ExecError!bool {
    for (self.nodes.items[node_idx].seeks.items) |seek| {
        const expected = try expressions.eval(self, seek.value, bindings);
        const actual = (try self.graph.getProp(id, seek.prop, self.allocator)) orelse return false;
        if (!Value.eql(actual, expected)) return false;
    }
    return true;
}

pub fn edgeSeeksMatch(self: *Executor, edge: ChainEdge, src: NodeId, dst: NodeId, bindings: *Bindings) ExecError!bool {
    for (edge.seeks.items) |seek| {
        const expected = try expressions.eval(self, seek.value, bindings);
        const actual = (try self.graph.getEdgeProp(src, dst, edge.etype, seek.prop, self.allocator)) orelse return false;
        if (!Value.eql(actual, expected)) return false;
    }
    return true;
}

pub fn opposite(dir: Direction) Direction {
    return switch (dir) {
        .out => .in,
        .in => .out,
    };
}

/// Computes the written edge's source/destination ids, given the two endpoint
/// node indices (`from`/`to`) and their ids. `fwd_dir` is the direction when
/// traversing the lower index to the higher index.
pub fn edgeSrcDst(fwd_dir: Direction, from: usize, to: usize, from_id: NodeId, to_id: NodeId) struct { src: NodeId, dst: NodeId } {
    const left_id = if (from < to) from_id else to_id;
    const right_id = if (from < to) to_id else from_id;
    return switch (fwd_dir) {
        .out => .{ .src = left_id, .dst = right_id },
        .in => .{ .src = right_id, .dst = left_id },
    };
}
