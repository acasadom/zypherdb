//! Pattern matching: the operators that match a pattern's plan (scan,
//! expand, edge-index scan, bound-node check, path) over the graph, each
//! handing every match on to the next operator of its chain. A
//! variable-length edge (`*min..max`) expands depth-first (a shortest one
//! breadth-first: shortest_paths.zig).
//!
//! What each pattern node and edge is matched to on the current search
//! branch is kept in the executor (`node_ids`, `matched_edges`), at the
//! pattern's offsets: later operators of the pattern read it, so anonymous
//! nodes need no variable.

const std = @import("std");
const NodeId = @import("../storage/graph.zig").NodeId;
const Direction = @import("../storage/graph.zig").Direction;
const NodeIdIterator = @import("../storage/graph.zig").NodeIdIterator;
const EdgeKeyIterator = @import("../storage/graph.zig").EdgeKeyIterator;
const Graph = @import("../storage/graph.zig").Graph;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const Relationship = @import("../value.zig").Relationship;
const NodeRecord = @import("../storage/node_record.zig").NodeRecord;
const property_indexes = @import("../storage/property_indexes.zig");

const Plan = @import("../planning/Plan.zig");
const PatternPlan = Plan.PatternPlan;
const PatternNode = Plan.PatternNode;
const PatternEdge = Plan.PatternEdge;
const OperatorIndex = Plan.OperatorIndex;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const no_slot = @import("bindings.zig").no_slot;
const expressions = @import("expressions.zig");
const operators = @import("operators.zig");
const shortest_paths = @import("shortest_paths.zig");

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

/// A pattern of the plan being run.
pub fn patternOf(self: *Executor, index: Plan.PatternIndex) *const PatternPlan {
    return &self.plan.patterns[index];
}

fn setNode(self: *Executor, pattern: *const PatternPlan, position: usize, id: NodeId) void {
    self.node_ids[pattern.first_node + position] = id;
}

fn nodeId(self: *Executor, pattern: *const PatternPlan, position: usize) NodeId {
    return self.node_ids[pattern.first_node + position];
}

/// A node bound before its pattern (by an earlier pattern or clause) must
/// still satisfy the pattern's labels and properties
/// (`MATCH (a) WITH a MATCH (a:X)`). Bound to null, or to something else
/// than a node, it matches nothing.
pub fn checkBoundNode(self: *Executor, reference: Plan.NodeReference, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const pattern = patternOf(self, reference.pattern);
    const node = pattern.nodes[reference.node];
    const id = bindings.getNode(node.slot) orelse return;
    setNode(self, pattern, reference.node, id);
    if (!try hasAllLabels(self, id, node.labels)) return;
    if (!try nodeSeeksMatch(self, node, id, bindings)) return;
    try operators.feed(self, next, bindings);
}

/// Binds the pattern's anchor node from its candidates (an index lookup on
/// an indexed equality predicate, else a range lookup on an indexed range,
/// else its first label, else every node), keeping those that carry every
/// label and satisfy every equality (the WHERE checks the ranges).
pub fn scanNodes(self: *Executor, reference: Plan.NodeReference, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const pattern = patternOf(self, reference.pattern);
    const node = pattern.nodes[reference.node];
    var from_label_index = false;
    var iterator = if (node.seek_index) |use| seek: {
        const seek = node.seeks[use.position];
        break :seek try self.graph.nodesByIndex(use.index_id, try expressions.evaluate(self, seek.value, bindings));
    } else if (try rangeCandidates(self, node, bindings)) |in_range| in_range else label: {
        from_label_index = node.labels.len > 0;
        break :label try seedNodes(self, node.labels);
    };
    defer iterator.deinit();
    // Nodes from the label index of the first label carry it: check only the others.
    const unchecked_labels = if (from_label_index) node.labels[1..] else node.labels;

    while (try iterator.next()) |id| {
        if (!(try hasAllLabels(self, id, unchecked_labels))) continue;
        const saved = bindings.mark();
        defer bindings.restore(saved);
        if (!try bindings.bindNode(self.allocator, node.slot, id)) continue;
        setNode(self, pattern, reference.node, id);
        if (!try nodeSeeksMatch(self, node, id, bindings)) continue;
        try operators.feed(self, next, bindings);
    }
}

/// The nodes in range of the node's indexed range seek, with the bounds of
/// every range seek on its property, or null when there is none or the
/// bounds do not allow a range lookup (strings, booleans, a null): scan
/// instead.
fn rangeCandidates(self: *Executor, node: PatternNode, bindings: *Bindings) ExecutionError!?NodeIdIterator {
    const use = node.range_index orelse return null;
    const property = node.ranges[use.position].property;
    var lower: ?Value = null;
    var upper: ?Value = null;
    for (node.ranges) |range| {
        if (!std.mem.eql(u8, range.property, property)) continue;
        // Any one bound of each side keeps a superset of the matches.
        if (lower == null) if (range.lower) |expression| {
            lower = try expressions.evaluate(self, expression, bindings);
        };
        if (upper == null) if (range.upper) |expression| {
            upper = try expressions.evaluate(self, expression, bindings);
        };
    }
    return self.graph.nodesInRange(use.index_id, lower, upper);
}

/// Binds both endpoints of a single-edge pattern from the relationship index.
pub fn scanEdgeIndex(self: *Executor, reference: Plan.EdgeReference, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const pattern = patternOf(self, reference.pattern);
    const edge = pattern.edges[reference.edge];
    const use = edge.seek_index.?; // the planner anchors at an indexed edge only
    const seek = edge.seeks[use.position];
    var iterator = try self.graph.edgesByIndex(use.index_id, try expressions.evaluate(self, seek.value, bindings));
    defer iterator.deinit();
    while (try iterator.next()) |found| {
        if (!edge.allowsType(found.edge_type)) continue;
        const ref = Relationship{ .id = found.id, .src = found.src, .dst = found.dst, .edge_type = try self.allocator.dupe(u8, found.edge_type) };
        // The left pattern node is the source when the pattern points right;
        // an undirected pattern takes both orientations (a self-loop once).
        const forward = edge.undirected or edge.forward_direction == .out;
        const backward = (edge.undirected and ref.src != ref.dst) or edge.forward_direction == .in;
        if (forward) try bindEdgeEndpoints(self, pattern, reference.edge, ref, ref.src, ref.dst, next, bindings);
        if (backward) try bindEdgeEndpoints(self, pattern, reference.edge, ref, ref.dst, ref.src, next, bindings);
    }
}

fn bindEdgeEndpoints(self: *Executor, pattern: *const PatternPlan, edge_index: usize, ref: Relationship, left_id: NodeId, right_id: NodeId, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const saved = bindings.mark();
    defer bindings.restore(saved);
    const left = pattern.nodes[edge_index];
    const right = pattern.nodes[edge_index + 1];
    if (!try bindings.bindNode(self.allocator, left.slot, left_id)) return;
    if (!try bindings.bindNode(self.allocator, right.slot, right_id)) return;
    setNode(self, pattern, edge_index, left_id);
    setNode(self, pattern, edge_index + 1, right_id);
    if (!try nodeSeeksMatch(self, left, left_id, bindings)) return;
    if (!try nodeSeeksMatch(self, right, right_id, bindings)) return;
    try followEdge(self, pattern, edge_index, ref, next, bindings);
}

/// Follows the edge between pattern nodes `from` (bound) and `to`: verifies it
/// when `to` is already bound, otherwise binds `to` to each neighbour.
pub fn expand(self: *Executor, step: Plan.Expand, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const pattern = patternOf(self, step.pattern);
    const edge_index = @min(step.from, step.to);
    const edge = pattern.edges[edge_index];
    if (edge.variable_length) {
        const expansion = Expansion{ .pattern = pattern, .from = step.from, .to = step.to, .edge_index = edge_index, .next = next };
        if (edge.shortest != .none) return shortest_paths.expand(self, expansion, bindings);
        var trail = std.ArrayList(Relationship).empty;
        return walk(self, expansion, nodeId(self, pattern, step.from), &trail, bindings);
    }
    const from_id = nodeId(self, pattern, step.from);
    const traversal: Direction = if (step.from < step.to) edge.forward_direction else opposite(edge.forward_direction);

    // A target found by an index seek (`(:Door {id: $door})`) is reached
    // by testing the edges to its few candidates, not by reading every
    // neighbour's properties.
    if (edge.edge_types.len > 0) if (try indexedCandidates(self, pattern.nodes[step.to], bindings)) |candidates| {
        for (candidates) |candidate| {
            for (edge.edge_types) |edge_type| {
                for (edgeOrientations(edge, traversal, from_id, candidate)) |orientation| {
                    const ends = orientation orelse continue;
                    // Each relationship between them, parallel ones included
                    // (most candidates have none: a cheap test first).
                    if (!try self.graph.hasEdge(ends.src, ends.dst, edge_type)) continue;
                    var between = try self.graph.edgesBetween(ends.src, ends.dst, edge_type);
                    defer between.deinit();
                    while (try between.next()) |key| {
                        try tryNeighbour(self, pattern, step.to, edge_index, candidate, null, .{ .id = key.relationship, .src = ends.src, .dst = ends.dst, .edge_type = edge_type }, next, bindings);
                    }
                }
            }
        }
        return;
    };

    var edges = MatchingEdges.init(self.graph, from_id, edge, traversal);
    defer edges.deinit();
    while (try edges.next()) |found| {
        try tryNeighbour(self, pattern, step.to, edge_index, found.neighbour, found.neighbour_labels, found.ref, next, bindings);
    }
}

/// Continues the match with `neighbour` at pattern position `to`, reached
/// through `ref`, if it fits the node pattern there. `neighbour_labels` are
/// its labels as the edge key keeps them, if it does (no record read then).
fn tryNeighbour(self: *Executor, pattern: *const PatternPlan, to: usize, edge_index: usize, neighbour: NodeId, neighbour_labels: ?[]const u8, ref: Relationship, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const to_node = pattern.nodes[to];
    if (neighbour_labels) |section| {
        const known = NodeRecord{ .bytes = section };
        for (to_node.labels) |label| if (!known.hasLabel(label)) return;
    } else if (!(try hasAllLabels(self, neighbour, to_node.labels))) return;
    const saved = bindings.mark();
    defer bindings.restore(saved);
    // A `to` variable bound already (earlier in the pattern or the query)
    // must be this neighbour; otherwise bind it.
    if (!try bindings.bindNode(self.allocator, to_node.slot, neighbour)) return;
    setNode(self, pattern, to, neighbour);
    if (!try nodeSeeksMatch(self, to_node, neighbour, bindings)) return;
    const owned = Relationship{ .id = ref.id, .src = ref.src, .dst = ref.dst, .edge_type = try ownedEdgeType(self, pattern.edges[edge_index], ref.edge_type) };
    try followEdge(self, pattern, edge_index, owned, next, bindings);
}

/// Above this many index candidates, scanning the neighbours is cheaper.
const max_indexed_candidates = 8;

/// The nodes the index gives for the indexed seek of the unbound node
/// `node`, if it has one and they are few; null to scan the neighbours
/// instead. (Only for edges that name their types: an edge test needs the type.)
fn indexedCandidates(self: *Executor, node: PatternNode, bindings: *Bindings) ExecutionError!?[]const NodeId {
    const use = node.seek_index orelse return null;
    if (node.bound) return null;
    if (bindings.getNode(node.slot) != null) return null;
    const seek = node.seeks[use.position];
    var iterator = try self.graph.nodesByIndex(use.index_id, try expressions.evaluate(self, seek.value, bindings));
    defer iterator.deinit();
    var candidates = std.ArrayList(NodeId).empty;
    while (try iterator.next()) |id| {
        if (candidates.items.len == max_indexed_candidates) return null;
        try candidates.append(self.allocator, id);
    }
    return candidates.items;
}

const EdgeEnds = struct { src: NodeId, dst: NodeId };

/// The source and target an edge between `from` and `to_id` would have, for
/// each orientation the pattern edge allows (null: not this one).
fn edgeOrientations(edge: PatternEdge, traversal: Direction, from: NodeId, to_id: NodeId) [2]?EdgeEnds {
    const outgoing = EdgeEnds{ .src = from, .dst = to_id };
    const incoming = EdgeEnds{ .src = to_id, .dst = from };
    if (edge.undirected) return .{ outgoing, if (from == to_id) null else incoming };
    return .{ if (traversal == .out) outgoing else incoming, null };
}

/// The edge type to bind for a matched edge: the pattern's own (owned by the
/// AST) when it names one, else a copy of the stored type (a view into the
/// store that does not outlive the scan).
pub fn ownedEdgeType(self: *Executor, edge: PatternEdge, stored: []const u8) ExecutionError![]const u8 {
    if (edge.singleType()) |edge_type| return edge_type;
    return self.allocator.dupe(u8, stored);
}

/// Binds the matched edge (if the pattern names it; a variable bound by an
/// earlier clause only matches that same edge), checks its predicates and
/// that the MATCH has not used it already, then continues with the next
/// operator.
fn followEdge(self: *Executor, pattern: *const PatternPlan, edge_index: usize, ref: Relationship, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const edge = pattern.edges[edge_index];
    if (edgeUsed(self, pattern.match, ref)) return;
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (!try bindings.bindValue(self.allocator, edge.slot, .{ .relationship = ref })) return;
    if (!try edgeSeeksMatch(self, edge, ref, bindings)) return;
    const slot = pattern.first_edge + edge_index;
    self.single_matches[slot] = ref;
    self.matched_edges[slot] = self.single_matches[slot .. slot + 1];
    try self.used_edges.append(self.allocator, .{ .match = pattern.match, .relationship = ref });
    defer _ = self.used_edges.pop();
    try operators.feed(self, next, bindings);
}

/// Relationship uniqueness: one MATCH never uses the same edge twice. The
/// relationships of the MATCH being matched are the last ones used.
pub fn edgeUsed(self: *Executor, match: Plan.MatchIndex, ref: Relationship) bool {
    var position = self.used_edges.items.len;
    while (position > 0) {
        position -= 1;
        const used = self.used_edges.items[position];
        if (used.match != match) return false;
        if (used.relationship.eql(ref)) return true;
    }
    return false;
}

/// Marks `trail` used by `match` (until the caller shrinks `used_edges` back).
pub fn useEdges(self: *Executor, match: Plan.MatchIndex, trail: []const Relationship) ExecutionError!void {
    for (trail) |relationship| try self.used_edges.append(self.allocator, .{ .match = match, .relationship = relationship });
}

/// One variable-length expansion: pattern positions `from` (bound) to `to`,
/// through the edge between them; `next` is the operator after it.
pub const Expansion = struct {
    pattern: *const PatternPlan,
    from: usize,
    to: usize,
    edge_index: usize,
    next: OperatorIndex,

    pub fn edge(self: Expansion) PatternEdge {
        return self.pattern.edges[self.edge_index];
    }

    pub fn traversal(self: Expansion) Direction {
        const forward = self.edge().forward_direction;
        return if (self.from < self.to) forward else opposite(forward);
    }
};

/// Follows a variable-length edge depth-first: every path of `min_hops` to
/// `max_hops` edges from `current` whose edges fit the pattern (type,
/// direction, properties) and are not used elsewhere in the MATCH, ending at
/// a node that fits `to`. The edge variable is bound to the list of the
/// path's relationships, in pattern order. Expected O(paths explored).
fn walk(self: *Executor, expansion: Expansion, current: NodeId, trail: *std.ArrayList(Relationship), bindings: *Bindings) ExecutionError!void {
    const edge = expansion.edge();
    if (trail.items.len >= edge.min_hops) try reachEnd(self, expansion, current, trail.items, bindings);
    if (edge.max_hops) |max| if (trail.items.len >= max) return;

    var edges = MatchingEdges.init(self.graph, current, edge, expansion.traversal());
    defer edges.deinit();
    while (try edges.next()) |found| {
        const ref = Relationship{ .id = found.ref.id, .src = found.ref.src, .dst = found.ref.dst, .edge_type = try ownedEdgeType(self, edge, found.ref.edge_type) };
        if (edgeUsed(self, expansion.pattern.match, ref)) continue;
        if (!try edgeSeeksMatch(self, edge, ref, bindings)) continue;
        try self.used_edges.append(self.allocator, .{ .match = expansion.pattern.match, .relationship = ref });
        defer _ = self.used_edges.pop();
        try trail.append(self.allocator, ref);
        defer _ = trail.pop();
        try walk(self, expansion, found.neighbour, trail, bindings);
    }
}

/// A variable-length path reached `end`: if it fits the `to` node, bind it
/// and the edge variable, and continue with the next operator.
pub fn reachEnd(self: *Executor, expansion: Expansion, end: NodeId, trail: []const Relationship, bindings: *Bindings) ExecutionError!void {
    const pattern = expansion.pattern;
    const to_node = pattern.nodes[expansion.to];
    if (!try hasAllLabels(self, end, to_node.labels)) return;
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (!try bindings.bindNode(self.allocator, to_node.slot, end)) return;
    setNode(self, pattern, expansion.to, end);
    if (!try nodeSeeksMatch(self, to_node, end, bindings)) return;

    // In pattern order: a walk from right to left found the edges reversed.
    const ordered = try self.allocator.dupe(Relationship, trail);
    if (expansion.from > expansion.to) std.mem.reverse(Relationship, ordered);
    self.matched_edges[pattern.first_edge + expansion.edge_index] = ordered;
    const slot = expansion.edge().slot;
    if (slot != no_slot) {
        const relationships = try self.allocator.alloc(Value, ordered.len);
        for (relationships, ordered) |*value, relationship| value.* = .{ .relationship = relationship };
        if (!try bindings.bindValue(self.allocator, slot, .{ .list = relationships })) return;
    }
    try operators.feed(self, expansion.next, bindings);
}

/// Binds the pattern's path variable to the path the current branch matched:
/// the pattern's nodes, with the intermediate nodes of its variable-length
/// edges, and its relationships.
pub fn projectPath(self: *Executor, index: Plan.PatternIndex, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const pattern = patternOf(self, index);
    var nodes = std.ArrayList(NodeId).empty;
    var relationships = std.ArrayList(Relationship).empty;
    var current = nodeId(self, pattern, 0);
    try nodes.append(self.allocator, current);
    for (self.matched_edges[pattern.first_edge .. pattern.first_edge + pattern.edges.len]) |matched| {
        for (matched) |relationship| {
            current = if (relationship.src == current) relationship.dst else relationship.src;
            try nodes.append(self.allocator, current);
            try relationships.append(self.allocator, relationship);
        }
    }
    const saved = bindings.mark();
    defer bindings.restore(saved);
    if (!try bindings.bindValue(self.allocator, pattern.path_slot, .{ .path = .{ .nodes = nodes.items, .relationships = relationships.items } })) return;
    try operators.feed(self, next, bindings);
}

/// The edges of one node that a pattern edge can follow: in the traversal
/// direction (or both, when undirected), of the pattern's type (or any).
/// Yields each with its far-side node. The yielded edge type is a view into
/// the store, valid until the next `next`.
pub const MatchingEdges = struct {
    graph: *Graph,
    from_id: NodeId,
    edge: PatternEdge,
    directions: [2]Direction,
    direction_count: usize,
    next_direction: usize = 0,
    current: ?EdgeKeyIterator = null,

    const Match = struct { neighbour: NodeId, ref: Relationship, neighbour_labels: ?[]const u8 };

    pub fn init(graph: *Graph, from_id: NodeId, edge: PatternEdge, traversal: Direction) MatchingEdges {
        return .{
            .graph = graph,
            .from_id = from_id,
            .edge = edge,
            .directions = if (edge.undirected) .{ .out, .in } else .{ traversal, traversal },
            .direction_count = if (edge.undirected) 2 else 1,
        };
    }

    pub fn deinit(self: *MatchingEdges) void {
        if (self.current) |*iterator| iterator.deinit();
    }

    pub fn next(self: *MatchingEdges) StorageError!?Match {
        while (true) {
            if (self.current) |*iterator| {
                if (try iterator.next()) |key| {
                    if (!self.edge.allowsType(key.edge_type)) continue;
                    // An undirected self-loop shows up in both scans: keep one.
                    if (self.direction_count == 2 and key.direction == .in and key.neighbour == self.from_id) continue;
                    const outgoing = key.direction == .out;
                    return .{ .neighbour = key.neighbour, .neighbour_labels = key.neighbour_labels, .ref = .{
                        .id = key.relationship,
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

pub fn nodeSeeksMatch(self: *Executor, node: PatternNode, id: NodeId, bindings: *Bindings) ExecutionError!bool {
    for (node.seeks) |seek| {
        // A seek from the WHERE on a document path (`n.a.b = v`) is left to
        // the WHERE, which fails on a property that is not a map.
        if (std.mem.indexOfScalar(u8, seek.property, property_indexes.path_separator) != null) continue;
        const expected = try expressions.evaluate(self, seek.value, bindings);
        const actual = (try self.graph.getProperty(id, seek.property, self.allocator)) orelse return false;
        if (!Value.eql(actual, expected)) return false;
    }
    return true;
}

pub fn edgeSeeksMatch(self: *Executor, edge: PatternEdge, ref: Relationship, bindings: *Bindings) ExecutionError!bool {
    for (edge.seeks) |seek| {
        const expected = try expressions.evaluate(self, seek.value, bindings);
        const actual = (try self.graph.getEdgeProperty(ref.id, seek.property, self.allocator)) orelse return false;
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
