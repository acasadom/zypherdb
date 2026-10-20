//! Pattern matching: runs the planned steps (scan, expand, edge-index scan)
//! over the graph, reporting each complete match to `Executor.matchFound`.
//! A variable-length edge (`*min..max`) expands depth-first; a pattern named
//! as a path (`p = ...`) binds its path once every step has matched.

const std = @import("std");
const NodeId = @import("../storage/graph.zig").NodeId;
const Direction = @import("../storage/graph.zig").Direction;
const NodeIdIterator = @import("../storage/graph.zig").NodeIdIterator;
const EdgeKeyIterator = @import("../storage/graph.zig").EdgeKeyIterator;
const Graph = @import("../storage/graph.zig").Graph;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const planner = @import("planner.zig");
const expressions = @import("expressions.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;
const Relationship = @import("../value.zig").Relationship;
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
        if (!(try self.read_cache.hasLabel(self.graph, self.allocator, id, l))) return false;
    }
    return true;
}

pub fn matchPatterns(self: *Executor, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    if (pattern_index == self.patterns.len) {
        return self.matchFound(bindings);
    }
    // Each pattern of the MATCH plans into the executor's slots; keep the
    // enclosing pattern's plan to put back, since it is still being run.
    const saved_nodes = self.nodes;
    const saved_edges = self.edges;
    const saved_steps = self.steps;
    const saved_path_variable = self.path_variable;
    defer {
        self.nodes = saved_nodes;
        self.edges = saved_edges;
        self.steps = saved_steps;
        self.path_variable = saved_path_variable;
    }
    try planner.setupPattern(self, self.patterns[pattern_index], bindings);
    // A node bound by an earlier clause must still satisfy this pattern's
    // labels and properties (`MATCH (a) WITH a MATCH (a:X)`).
    for (self.nodes.items, 0..) |*node, node_index| {
        if (!node.bound) continue;
        const id = bindings.getNode(node.variable_name) orelse return error.UnknownVariable;
        node.id = id;
        if (!try hasAllLabels(self, id, node.labels)) return;
        if (!try nodeSeeksMatch(self, node_index, id, bindings)) return;
    }
    try runStep(self, 0, pattern_index, bindings);
}

pub fn runStep(self: *Executor, step_index: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    if (step_index == self.steps.items.len) {
        if (self.path_variable.len == 0) return matchPatterns(self, pattern_index + 1, bindings);
        const saved = bindings.mark();
        defer bindings.restore(saved);
        if (!try bindings.bindValue(self.allocator, self.path_variable, try matchedPath(self))) return;
        return matchPatterns(self, pattern_index + 1, bindings);
    }
    const next_step = step_index + 1;
    switch (self.steps.items[step_index]) {
        .scan => |scan| try scanNodes(self, scan.node, next_step, pattern_index, bindings),
        .edge_scan => |edge_scan| try scanEdgeIndex(self, edge_scan.edge, next_step, pattern_index, bindings),
        .expand => |expand| try expandEdge(self, expand.from, expand.to, next_step, pattern_index, bindings),
    }
}

/// Binds the pattern's anchor node from its candidates (an index lookup on
/// its first equality predicate, else its first label, else every node),
/// keeping those that carry every label and satisfy every predicate.
fn scanNodes(self: *Executor, node_index: usize, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    const node = self.nodes.items[node_index];
    var iterator = if (node.seeks.items.len > 0) seek: {
        const seek = node.seeks.items[0];
        break :seek try self.graph.nodesByProperty(seek.property, try expressions.evaluate(self, seek.value, bindings));
    } else try seedNodes(self, node.labels);
    defer iterator.deinit();
    // Nodes from the label index of the first label carry it: check only the others.
    const unchecked_labels = if (node.seeks.items.len == 0 and node.labels.len > 0) node.labels[1..] else node.labels;

    while (try iterator.next()) |id| {
        if (!(try hasAllLabels(self, id, unchecked_labels))) continue;
        const saved = bindings.mark();
        defer bindings.restore(saved);
        if (!try bindings.bindNode(self.allocator, node.variable_name, id)) continue;
        self.nodes.items[node_index].id = id;
        if (!try nodeSeeksMatch(self, node_index, id, bindings)) continue;
        try runStep(self, next_step, pattern_index, bindings);
    }
}

/// Binds both endpoints of a single-edge pattern from the edge-property index.
fn scanEdgeIndex(self: *Executor, edge_index: usize, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    const edge = self.edges.items[edge_index];
    const seek = edge.seeks.items[0];
    var iterator = try self.graph.edgesByProperty(seek.property, try expressions.evaluate(self, seek.value, bindings));
    defer iterator.deinit();
    while (try iterator.next()) |found| {
        if (!edge.allowsType(found.edge_type)) continue;
        const ref = Relationship{ .src = found.src, .dst = found.dst, .edge_type = try self.allocator.dupe(u8, found.edge_type) };
        // The left pattern node is the source when the pattern points right;
        // an undirected pattern takes both orientations (a self-loop once).
        const forward = edge.undirected or edge.forward_direction == .out;
        const backward = (edge.undirected and ref.src != ref.dst) or edge.forward_direction == .in;
        if (forward) try bindEdgeEndpoints(self, edge_index, ref, ref.src, ref.dst, next_step, pattern_index, bindings);
        if (backward) try bindEdgeEndpoints(self, edge_index, ref, ref.dst, ref.src, next_step, pattern_index, bindings);
    }
}

fn bindEdgeEndpoints(self: *Executor, edge_index: usize, ref: Relationship, left_id: NodeId, right_id: NodeId, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (!try bindings.bindNode(self.allocator, self.nodes.items[edge_index].variable_name, left_id)) return;
    if (!try bindings.bindNode(self.allocator, self.nodes.items[edge_index + 1].variable_name, right_id)) return;
    self.nodes.items[edge_index].id = left_id;
    self.nodes.items[edge_index + 1].id = right_id;
    if (!try nodeSeeksMatch(self, edge_index, left_id, bindings)) return;
    if (!try nodeSeeksMatch(self, edge_index + 1, right_id, bindings)) return;
    try followEdge(self, edge_index, ref, next_step, pattern_index, bindings);
}

/// Follows the edge between pattern nodes `from` (bound) and `to`: verifies it
/// when `to` is already bound, otherwise binds `to` to each neighbour.
fn expandEdge(self: *Executor, from: usize, to: usize, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    const edge_index = @min(from, to);
    if (self.edges.items[edge_index].variable_length) return expandVariableLength(self, from, to, next_step, pattern_index, bindings);
    const from_id = self.nodes.items[from].id;
    const edge = self.edges.items[edge_index];
    const to_node = self.nodes.items[to];
    const traversal: Direction = if (from < to) edge.forward_direction else opposite(edge.forward_direction);

    var edges = MatchingEdges.init(self.graph, from_id, edge, traversal);
    defer edges.deinit();
    while (try edges.next()) |found| {
        if (!(try hasAllLabels(self, found.neighbour, to_node.labels))) continue;
        const saved = bindings.mark();
        defer bindings.restore(saved);
        // A `to` variable bound already (earlier in the pattern or the
        // query) must be this neighbour; otherwise bind it.
        if (!try bindings.bindNode(self.allocator, to_node.variable_name, found.neighbour)) continue;
        self.nodes.items[to].id = found.neighbour;
        if (!try nodeSeeksMatch(self, to, found.neighbour, bindings)) continue;
        const ref = Relationship{ .src = found.ref.src, .dst = found.ref.dst, .edge_type = try self.ownedEdgeType(edge, found.ref.edge_type) };
        try followEdge(self, edge_index, ref, next_step, pattern_index, bindings);
    }
}

/// Binds the matched edge (if the pattern names it), checks its predicates and
/// that the MATCH has not used it already, then continues with the next step.
fn followEdge(self: *Executor, edge_index: usize, ref: Relationship, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    const edge = &self.edges.items[edge_index];
    // A variable bound by an earlier clause only matches that same edge.
    if (edge.bound) |bound| {
        if (!bound.eql(ref)) return;
    }
    if (edgeUsed(self, ref)) return;
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (edge.variable_name.len > 0 and edge.bound == null) try bindings.put(self.allocator, edge.variable_name, .{ .relationship = ref });
    if (!try edgeSeeksMatch(self, edge.*, ref, bindings)) return;
    edge.single_match[0] = ref;
    edge.matched = &edge.single_match;
    try self.used_edges.append(self.allocator, ref);
    defer _ = self.used_edges.pop();
    try runStep(self, next_step, pattern_index, bindings);
}

/// Relationship uniqueness: one MATCH never uses the same edge twice.
fn edgeUsed(self: *Executor, ref: Relationship) bool {
    for (self.used_edges.items) |used| {
        if (used.eql(ref)) return true;
    }
    return false;
}

/// One variable-length expansion: pattern positions `from` (bound) to `to`,
/// through the edge between them.
const Expansion = struct { from: usize, to: usize, edge_index: usize, next_step: usize, pattern_index: usize };

/// Follows a variable-length edge depth-first: every path of `min_hops` to
/// `max_hops` edges from `from` whose edges fit the pattern (type,
/// direction, properties) and are not used elsewhere in the MATCH, ending at
/// a node that fits `to`. The edge variable is bound to the list of the
/// path's relationships, in pattern order. Expected O(paths explored).
fn expandVariableLength(self: *Executor, from: usize, to: usize, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    var trail = std.ArrayList(Relationship).empty;
    const expansion = Expansion{ .from = from, .to = to, .edge_index = @min(from, to), .next_step = next_step, .pattern_index = pattern_index };
    try walk(self, expansion, self.nodes.items[from].id, &trail, bindings);
}

fn walk(self: *Executor, expansion: Expansion, current: NodeId, trail: *std.ArrayList(Relationship), bindings: *Bindings) ExecutionError!void {
    const edge = self.edges.items[expansion.edge_index];
    if (trail.items.len >= edge.min_hops) try reachEnd(self, expansion, current, trail.items, bindings);
    if (edge.max_hops) |max| if (trail.items.len >= max) return;

    const traversal: Direction = if (expansion.from < expansion.to) edge.forward_direction else opposite(edge.forward_direction);
    var edges = MatchingEdges.init(self.graph, current, edge, traversal);
    defer edges.deinit();
    while (try edges.next()) |found| {
        const ref = Relationship{ .src = found.ref.src, .dst = found.ref.dst, .edge_type = try self.ownedEdgeType(edge, found.ref.edge_type) };
        if (edgeUsed(self, ref)) continue;
        if (!try edgeSeeksMatch(self, edge, ref, bindings)) continue;
        try self.used_edges.append(self.allocator, ref);
        defer _ = self.used_edges.pop();
        try trail.append(self.allocator, ref);
        defer _ = trail.pop();
        try walk(self, expansion, found.neighbour, trail, bindings);
    }
}

/// A variable-length path reached `end`: if it fits the `to` node, bind it
/// and the edge variable, and continue with the next step.
fn reachEnd(self: *Executor, expansion: Expansion, end: NodeId, trail: []const Relationship, bindings: *Bindings) ExecutionError!void {
    const to_node = self.nodes.items[expansion.to];
    if (!try hasAllLabels(self, end, to_node.labels)) return;
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (!try bindings.bindNode(self.allocator, to_node.variable_name, end)) return;
    self.nodes.items[expansion.to].id = end;
    if (!try nodeSeeksMatch(self, expansion.to, end, bindings)) return;

    // In pattern order: a walk from right to left found the edges reversed.
    const ordered = try self.allocator.dupe(Relationship, trail);
    if (expansion.from > expansion.to) std.mem.reverse(Relationship, ordered);
    const edge = &self.edges.items[expansion.edge_index];
    edge.matched = ordered;
    if (edge.variable_name.len > 0) {
        const relationships = try self.allocator.alloc(Value, ordered.len);
        for (relationships, ordered) |*value, relationship| value.* = .{ .relationship = relationship };
        if (!try bindings.bindValue(self.allocator, edge.variable_name, .{ .list = relationships })) return;
    }
    try runStep(self, expansion.next_step, expansion.pattern_index, bindings);
}

/// The path the current branch matched: the pattern's nodes, with the
/// intermediate nodes of its variable-length edges, and its relationships.
fn matchedPath(self: *Executor) ExecutionError!Value {
    var nodes = std.ArrayList(NodeId).empty;
    var relationships = std.ArrayList(Relationship).empty;
    var current = self.nodes.items[0].id;
    try nodes.append(self.allocator, current);
    for (self.edges.items) |edge| {
        for (edge.matched) |relationship| {
            current = if (relationship.src == current) relationship.dst else relationship.src;
            try nodes.append(self.allocator, current);
            try relationships.append(self.allocator, relationship);
        }
    }
    return .{ .path = .{ .nodes = nodes.items, .relationships = relationships.items } };
}

/// The edges of one node that a pattern edge can follow: in the traversal
/// direction (or both, when undirected), of the pattern's type (or any).
/// Yields each with its far-side node. The yielded edge type is a view into
/// the store, valid until the next `next`.
const MatchingEdges = struct {
    graph: *Graph,
    from_id: NodeId,
    edge: PatternEdge,
    directions: [2]Direction,
    direction_count: usize,
    next_direction: usize = 0,
    current: ?EdgeKeyIterator = null,

    const Match = struct { neighbour: NodeId, ref: Relationship };

    fn init(graph: *Graph, from_id: NodeId, edge: PatternEdge, traversal: Direction) MatchingEdges {
        return .{
            .graph = graph,
            .from_id = from_id,
            .edge = edge,
            .directions = if (edge.undirected) .{ .out, .in } else .{ traversal, traversal },
            .direction_count = if (edge.undirected) 2 else 1,
        };
    }

    fn deinit(self: *MatchingEdges) void {
        if (self.current) |*iterator| iterator.deinit();
    }

    fn next(self: *MatchingEdges) StorageError!?Match {
        while (true) {
            if (self.current) |*iterator| {
                if (try iterator.next()) |key| {
                    if (!self.edge.allowsType(key.edge_type)) continue;
                    // An undirected self-loop shows up in both scans: keep one.
                    if (self.direction_count == 2 and key.direction == .in and key.neighbour == self.from_id) continue;
                    const outgoing = key.direction == .out;
                    return .{ .neighbour = key.neighbour, .ref = .{
                        .src = if (outgoing) self.from_id else key.neighbour,
                        .dst = if (outgoing) key.neighbour else self.from_id,
                        .edge_type = key.edge_type,
                    } };
                }
                iterator.deinit();
                self.current = null;
            }
            if (self.next_direction == self.direction_count) return null;
            const direction = self.directions[self.next_direction];
            self.next_direction += 1;
            // One type: scan just its key range; several or any: every edge.
            self.current = if (self.edge.singleType()) |edge_type|
                try self.graph.edgesOfType(self.from_id, direction, edge_type)
            else
                try self.graph.edgesOf(self.from_id, direction);
        }
    }
};

pub fn nodeSeeksMatch(self: *Executor, node_index: usize, id: NodeId, bindings: *Bindings) ExecutionError!bool {
    for (self.nodes.items[node_index].seeks.items) |seek| {
        const expected = try expressions.evaluate(self, seek.value, bindings);
        const actual = (try self.graph.getProperty(id, seek.property, self.allocator)) orelse return false;
        if (!Value.eql(actual, expected)) return false;
    }
    return true;
}

pub fn edgeSeeksMatch(self: *Executor, edge: PatternEdge, ref: Relationship, bindings: *Bindings) ExecutionError!bool {
    for (edge.seeks.items) |seek| {
        const expected = try expressions.evaluate(self, seek.value, bindings);
        const actual = (try self.graph.getEdgeProperty(ref.src, ref.dst, ref.edge_type, seek.property, self.allocator)) orelse return false;
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
