//! Shortest paths: `shortestPath((a)-[*]-(b))` and `allShortestPaths(...)`,
//! a pattern of one variable-length relationship of which only the shortest
//! paths between its two end nodes match.
//!
//! When the MATCH's WHERE does not read the path (its variable, or the
//! relationship list), a breadth-first search from the bound end finds,
//! level by level, the distance of every node it reaches and the
//! relationships that first reach it; each end node that fits the pattern
//! then gets one shortest path, or all of them. O(nodes + relationships
//! reached).
//!
//! When the WHERE reads the path, the shortest path may not be one it
//! keeps: the paths are tried by increasing length, and an end node is done
//! at the first length where a path to it passed the WHERE. This explores
//! every path up to that length, as a variable-length match does.

const std = @import("std");
const NodeId = @import("../storage/graph.zig").NodeId;
const Direction = @import("../storage/graph.zig").Direction;
const Relationship = @import("../value.zig").Relationship;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const pattern_matching = @import("pattern_matching.zig");
const Expansion = pattern_matching.Expansion;
const MatchingEdges = pattern_matching.MatchingEdges;

/// Expands the shortest edge of `expansion`, from its bound end.
pub fn expand(self: *Executor, expansion: Expansion, bindings: *Bindings) ExecutionError!void {
    if (expansion.edge().where_reads_path) return byIncreasingLength(self, expansion, bindings);
    return breadthFirst(self, expansion, bindings);
}

/// The node the `to` end must be, if the row binds it already.
fn boundTarget(expansion: Expansion, bindings: *Bindings) ?NodeId {
    return bindings.getNode(expansion.pattern.nodes[expansion.to].slot);
}

/// The node the expansion starts from.
fn startNode(self: *Executor, expansion: Expansion) NodeId {
    return self.node_ids[expansion.pattern.first_node + expansion.from];
}

/// One way a node is first reached: from `from`, through `relationship`.
const Step = struct { from: NodeId, relationship: Relationship };

/// A node the search reached: its distance from the start, and the steps
/// that reach it at that distance (only the first for `shortestPath`).
const Reached = struct { distance: u32, steps: std.ArrayList(Step) };

fn breadthFirst(self: *Executor, expansion: Expansion, bindings: *Bindings) ExecutionError!void {
    const edge = expansion.edge();
    const start = startNode(self, expansion);
    const target = boundTarget(expansion, bindings);
    const direction = expansion.traversal();

    // Insertion-ordered: the ends come out in the order the search met them.
    var reached = std.AutoArrayHashMapUnmanaged(NodeId, Reached).empty;
    try reached.put(self.allocator, start, .{ .distance = 0, .steps = .empty });
    var frontier = std.ArrayList(NodeId).empty;
    try frontier.append(self.allocator, start);
    var level: u32 = 0;
    while (frontier.items.len > 0) {
        if (edge.max_hops) |max| if (level >= max) break;
        if (target) |end| if (end != start and reached.contains(end)) break;
        level += 1;
        var next = std.ArrayList(NodeId).empty;
        for (frontier.items) |current| {
            var edges = MatchingEdges.init(self.graph, current, edge, direction);
            defer edges.deinit();
            while (try edges.next()) |found| {
                const ref = Relationship{ .id = found.ref.id, .src = found.ref.src, .dst = found.ref.dst, .edge_type = try pattern_matching.ownedEdgeType(self, edge, found.ref.edge_type) };
                if (pattern_matching.edgeUsed(self, expansion.pattern.match, ref)) continue;
                if (!try pattern_matching.edgeSeeksMatch(self, edge, ref, bindings)) continue;
                const entry = try reached.getOrPut(self.allocator, found.neighbour);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{ .distance = level, .steps = .empty };
                    try entry.value_ptr.steps.append(self.allocator, .{ .from = current, .relationship = ref });
                    try next.append(self.allocator, found.neighbour);
                } else if (entry.value_ptr.distance == level and edge.shortest == .all) {
                    try entry.value_ptr.steps.append(self.allocator, .{ .from = current, .relationship = ref });
                }
            }
        }
        frontier = next;
    }

    var suffix = std.ArrayList(Relationship).empty;
    if (target) |end| {
        const found = reached.get(end) orelse return;
        if (found.distance >= edge.min_hops) try emitPaths(self, expansion, &reached, start, end, end, &suffix, bindings);
        return;
    }
    // `reached` does not change from here on, so its keys can be walked.
    for (reached.keys(), reached.values()) |end, found| {
        if (found.distance < edge.min_hops) continue;
        try emitPaths(self, expansion, &reached, start, end, end, &suffix, bindings);
    }
}

/// The shortest paths from `start` to `end` through `node` (walked back from
/// `end`; `suffix` holds the relationships after `node`, last first): one,
/// or every combination of the steps that reach each node.
fn emitPaths(self: *Executor, expansion: Expansion, reached: *const std.AutoArrayHashMapUnmanaged(NodeId, Reached), start: NodeId, end: NodeId, node: NodeId, suffix: *std.ArrayList(Relationship), bindings: *Bindings) ExecutionError!void {
    if (node == start) {
        const trail = try self.allocator.dupe(Relationship, suffix.items);
        std.mem.reverse(Relationship, trail);
        return reachEnd(self, expansion, end, trail, bindings);
    }
    const steps = reached.get(node).?.steps.items;
    const used = if (expansion.edge().shortest == .one) steps[0..1] else steps;
    for (used) |step| {
        try suffix.append(self.allocator, step.relationship);
        defer _ = suffix.pop();
        try emitPaths(self, expansion, reached, start, end, step.from, suffix, bindings);
    }
}

/// Continues with a path found: its relationships count as used for the
/// rest of the MATCH (relationship uniqueness), as a variable-length walk's do.
fn reachEnd(self: *Executor, expansion: Expansion, end: NodeId, trail: []const Relationship, bindings: *Bindings) ExecutionError!void {
    const mark = self.used_edges.items.len;
    defer self.used_edges.shrinkRetainingCapacity(mark);
    try pattern_matching.useEdges(self, expansion.pattern.match, trail);
    try pattern_matching.reachEnd(self, expansion, end, trail, bindings);
}

/// The WHERE reads the path: every path of length k, for k from the least
/// up, until each end has one that passed (or no path is that long).
fn byIncreasingLength(self: *Executor, expansion: Expansion, bindings: *Bindings) ExecutionError!void {
    const edge = expansion.edge();
    var search = DeepeningSearch{
        .executor = self,
        .expansion = expansion,
        .bindings = bindings,
        .target = boundTarget(expansion, bindings),
        .direction = expansion.traversal(),
    };
    var length = edge.min_hops;
    while (true) : (length += 1) {
        if (edge.max_hops) |max| if (length > max) break;
        search.any_path = false;
        search.passed_now.clearRetainingCapacity();
        var trail = std.ArrayList(Relationship).empty;
        try search.walk(startNode(self, expansion), length, &trail);
        for (search.passed_now.keys()) |end| try search.done.put(self.allocator, end, {});
        if (search.target) |end| if (search.done.contains(end)) break;
        if (!search.any_path) break;
    }
}

const DeepeningSearch = struct {
    executor: *Executor,
    expansion: Expansion,
    bindings: *Bindings,
    target: ?NodeId,
    direction: Direction,
    /// Ends that have a path that passed the WHERE at a shorter length.
    done: std.AutoArrayHashMapUnmanaged(NodeId, void) = .empty,
    /// Ends that have one at the length being tried.
    passed_now: std.AutoArrayHashMapUnmanaged(NodeId, void) = .empty,
    /// Whether some path has the length being tried.
    any_path: bool = false,

    fn walk(self: *DeepeningSearch, current: NodeId, remaining: u32, trail: *std.ArrayList(Relationship)) ExecutionError!void {
        const executor = self.executor;
        const edge = self.expansion.edge();
        if (remaining == 0) {
            self.any_path = true;
            if (self.done.contains(current)) return;
            if (self.target) |end| if (end != current) return;
            if (edge.shortest == .one and self.passed_now.contains(current)) return;
            const before = executor.accepted_matches;
            try pattern_matching.reachEnd(executor, self.expansion, current, try executor.allocator.dupe(Relationship, trail.items), self.bindings);
            if (executor.accepted_matches > before) try self.passed_now.put(executor.allocator, current, {});
            return;
        }
        var edges = MatchingEdges.init(executor.graph, current, edge, self.direction);
        defer edges.deinit();
        while (try edges.next()) |found| {
            const ref = Relationship{ .id = found.ref.id, .src = found.ref.src, .dst = found.ref.dst, .edge_type = try pattern_matching.ownedEdgeType(executor, edge, found.ref.edge_type) };
            if (pattern_matching.edgeUsed(executor, self.expansion.pattern.match, ref)) continue;
            if (!try pattern_matching.edgeSeeksMatch(executor, edge, ref, self.bindings)) continue;
            try executor.used_edges.append(executor.allocator, .{ .match = self.expansion.pattern.match, .relationship = ref });
            defer _ = executor.used_edges.pop();
            try trail.append(executor.allocator, ref);
            defer _ = trail.pop();
            try self.walk(found.neighbour, remaining - 1, trail);
        }
    }
};
