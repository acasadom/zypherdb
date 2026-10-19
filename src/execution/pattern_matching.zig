//! Pattern matching: runs the planned steps (scan, expand, edge-index scan)
//! over the graph, reporting each complete match to `Executor.matchFound`.

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
        if (!(try self.graph.hasLabel(id, l))) return false;
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
    defer {
        self.nodes = saved_nodes;
        self.edges = saved_edges;
        self.steps = saved_steps;
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

    while (try iterator.next()) |id| {
        if (!(try hasAllLabels(self, id, node.labels))) continue;
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
        if (edge.edge_type.len > 0 and !std.mem.eql(u8, found.edge_type, edge.edge_type)) continue;
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
    const edge = self.edges.items[edge_index];
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (!try bindings.bindNode(self.allocator, self.nodes.items[edge_index].variable_name, left_id)) return;
    if (!try bindings.bindNode(self.allocator, self.nodes.items[edge_index + 1].variable_name, right_id)) return;
    self.nodes.items[edge_index].id = left_id;
    self.nodes.items[edge_index + 1].id = right_id;
    if (!try nodeSeeksMatch(self, edge_index, left_id, bindings)) return;
    if (!try nodeSeeksMatch(self, edge_index + 1, right_id, bindings)) return;
    try followEdge(self, edge, ref, next_step, pattern_index, bindings);
}

/// Follows the edge between pattern nodes `from` (bound) and `to`: verifies it
/// when `to` is already bound, otherwise binds `to` to each neighbour.
fn expandEdge(self: *Executor, from: usize, to: usize, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    const from_id = self.nodes.items[from].id;
    const edge = self.edges.items[@min(from, to)];
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
        try followEdge(self, edge, ref, next_step, pattern_index, bindings);
    }
}

/// Binds the matched edge (if the pattern names it), checks its predicates and
/// that the MATCH has not used it already, then continues with the next step.
fn followEdge(self: *Executor, edge: PatternEdge, ref: Relationship, next_step: usize, pattern_index: usize, bindings: *Bindings) ExecutionError!void {
    // A variable bound by an earlier clause only matches that same edge.
    if (edge.bound) |bound| {
        if (!bound.eql(ref)) return;
    }
    // Relationship uniqueness: one MATCH never binds the same edge twice.
    for (self.used_edges.items) |used| {
        if (used.eql(ref)) return;
    }
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (edge.variable_name.len > 0 and edge.bound == null) try bindings.put(self.allocator, edge.variable_name, .{ .relationship = ref });
    if (!try edgeSeeksMatch(self, edge, ref, bindings)) return;
    try self.used_edges.append(self.allocator, ref);
    defer _ = self.used_edges.pop();
    try runStep(self, next_step, pattern_index, bindings);
}

/// The edges of one node that a pattern edge can follow: in the traversal
/// direction (or both, when undirected), of the pattern's type (or any).
/// Yields each with its far-side node. The yielded edge type is a view into
/// the store, valid until the next `next`.
const MatchingEdges = struct {
    graph: *Graph,
    from_id: NodeId,
    edge_type: []const u8,
    directions: [2]Direction,
    direction_count: usize,
    next_direction: usize = 0,
    current: ?EdgeKeyIterator = null,

    const Match = struct { neighbour: NodeId, ref: Relationship };

    fn init(graph: *Graph, from_id: NodeId, edge: PatternEdge, traversal: Direction) MatchingEdges {
        return .{
            .graph = graph,
            .from_id = from_id,
            .edge_type = edge.edge_type,
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
            self.current = if (self.edge_type.len > 0)
                try self.graph.edgesOfType(self.from_id, direction, self.edge_type)
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
