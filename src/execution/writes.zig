//! Write clauses: CREATE, MERGE, SET, REMOVE and DELETE.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const pattern_matching = @import("pattern_matching.zig");
const expressions = @import("expressions.zig");
const ExecError = Executor.ExecError;

const Bindings = @import("bindings.zig").Bindings;

pub fn applyCreate(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
    const chain = self.ast.nodeChildren(pattern);
    const node_ids = try self.allocator.alloc(NodeId, (chain.len + 1) / 2);
    for (node_ids, 0..) |*id, i| {
        const np_idx = chain[i * 2];
        const var_name = self.ast.data(np_idx).node_pattern.var_name;
        if (boundNode(bindings, var_name)) |bound| {
            id.* = bound;
            continue;
        }
        id.* = try createNode(self, np_idx, bindings);
        if (var_name.len > 0) try bindings.put(self.allocator, var_name, .{ .node = id.* });
    }
    try applyEdges(self, chain, node_ids, bindings, false);
}

pub fn applyMerge(self: *Executor, mc: Index, bindings: *Bindings) ExecError!void {
    const kids = self.ast.nodeChildren(mc);
    const pattern = kids[0];
    const on_create = kids[1];
    const on_match = kids[2];
    const chain = self.ast.nodeChildren(pattern);
    const node_ids = try self.allocator.alloc(NodeId, (chain.len + 1) / 2);

    var created = false;
    for (node_ids, 0..) |*id, i| {
        const np_idx = chain[i * 2];
        const var_name = self.ast.data(np_idx).node_pattern.var_name;
        if (boundNode(bindings, var_name)) |bound| {
            id.* = bound;
            continue;
        }
        if (try findMatchingNode(self, np_idx, bindings)) |found| {
            id.* = found;
        } else {
            id.* = try createNode(self, np_idx, bindings);
            created = true;
        }
        if (var_name.len > 0) try bindings.put(self.allocator, var_name, .{ .node = id.* });
    }
    try applyEdges(self, chain, node_ids, bindings, true);

    // ON CREATE / ON MATCH SET (an empty set clause is a no-op).
    if (created) {
        try applySet(self, on_create, bindings);
    } else {
        try applySet(self, on_match, bindings);
    }
}

/// The node already bound to `var_name`, if any; an anonymous node (empty
/// name) is never bound.
fn boundNode(bindings: *const Bindings, var_name: []const u8) ?NodeId {
    if (var_name.len == 0) return null;
    return bindings.getNode(var_name);
}

/// Creates a node from a `node_pattern` and returns its fresh id.
pub fn createNode(self: *Executor, np_idx: Index, bindings: *Bindings) ExecError!NodeId {
    const np = self.ast.data(np_idx).node_pattern;
    const id = try self.graph.allocNodeId();
    try self.graph.addNode(id, ""); // node marker
    for (np.labels) |label| try self.graph.addLabel(id, label);
    for (self.ast.nodeChildren(np_idx)) |prop_idx| {
        const prop_name = self.ast.data(prop_idx).text;
        const value = try expressions.eval(self, self.ast.nodeChildren(prop_idx)[0], bindings);
        try self.graph.setProp(id, prop_name, value);
    }
    return id;
}

/// Finds an existing node matching the labels + property map, if any.
pub fn findMatchingNode(self: *Executor, np_idx: Index, bindings: *Bindings) ExecError!?NodeId {
    const np = self.ast.data(np_idx).node_pattern;
    const props = self.ast.nodeChildren(np_idx);

    if (props.len > 0) {
        // Index lookup on the first property.
        const prop_name = self.ast.data(props[0]).text;
        const value = try expressions.eval(self, self.ast.nodeChildren(props[0])[0], bindings);
        var it = try self.graph.nodesByProp(prop_name, value);
        defer it.deinit();
        while (try it.next()) |id| {
            if (!(try pattern_matching.hasAllLabels(self, id, np.labels))) continue;
            if (try nodePropsMatch(self, np_idx, id, bindings)) return id;
        }
        return null;
    }

    var it = try pattern_matching.seedNodes(self, np.labels);
    defer it.deinit();
    while (try it.next()) |id| {
        if (!(try pattern_matching.hasAllLabels(self, id, np.labels))) continue;
        if (try nodePropsMatch(self, np_idx, id, bindings)) return id;
    }
    return null;
}

pub fn nodePropsMatch(self: *Executor, np_idx: Index, id: NodeId, bindings: *Bindings) ExecError!bool {
    for (self.ast.nodeChildren(np_idx)) |prop_idx| {
        const prop_name = self.ast.data(prop_idx).text;
        const value = try expressions.eval(self, self.ast.nodeChildren(prop_idx)[0], bindings);
        const actual = (try self.graph.getProp(id, prop_name, self.allocator)) orelse return false;
        if (!Value.eql(actual, value)) return false;
    }
    return true;
}

/// Writes the edges of a CREATE/MERGE chain between the already resolved
/// `node_ids` (one per node position, so anonymous nodes work too). With
/// `merge`, an existing edge is kept instead of duplicated.
pub fn applyEdges(self: *Executor, chain: []const Index, node_ids: []const NodeId, bindings: *Bindings, merge: bool) ExecError!void {
    for (node_ids[0 .. node_ids.len - 1], node_ids[1..], 0..) |left_id, right_id, i| {
        const ep_idx = chain[i * 2 + 1];
        const ep = self.ast.data(ep_idx).edge_pattern;
        const src: NodeId = if (ep.direction == .left_to_right) left_id else right_id;
        const dst: NodeId = if (ep.direction == .left_to_right) right_id else left_id;
        if (merge and (try self.graph.hasEdge(src, dst, ep.etype))) continue;
        try self.graph.addEdge(src, dst, ep.etype);
        for (self.ast.nodeChildren(ep_idx)) |prop_idx| {
            const prop_name = self.ast.data(prop_idx).text;
            const value = try expressions.eval(self, self.ast.nodeChildren(prop_idx)[0], bindings);
            try self.graph.setEdgeProp(src, dst, ep.etype, prop_name, value);
        }
    }
}

pub fn applySet(self: *Executor, set_clause: Index, bindings: *Bindings) ExecError!void {
    for (self.ast.nodeChildren(set_clause)) |item| {
        const ic = self.ast.nodeChildren(item);
        const access = ic[0];
        const value_expr = ic[1];
        const prop = self.ast.data(access).text;
        const obj = self.ast.nodeChildren(access)[0];
        const name = self.ast.data(obj).text;
        const value = try expressions.eval(self, value_expr, bindings);
        switch (bindings.get(name) orelse return error.UnknownVar) {
            .node => |id| try self.graph.setProp(id, prop, value),
            .edge => |e| try self.graph.setEdgeProp(e.src, e.dst, e.etype, prop, value),
            .value => return error.TypeMismatch,
        }
    }
}

pub fn applyRemove(self: *Executor, remove_clause: Index, bindings: *Bindings) ExecError!void {
    for (self.ast.nodeChildren(remove_clause)) |item| {
        switch (self.ast.kind(item)) {
            .property_access => {
                const prop = self.ast.data(item).text;
                const name = self.ast.data(self.ast.nodeChildren(item)[0]).text;
                switch (bindings.get(name) orelse return error.UnknownVar) {
                    .node => |id| try self.graph.removeProp(id, prop),
                    .edge => |e| try self.graph.removeEdgeProp(e.src, e.dst, e.etype, prop),
                    .value => return error.TypeMismatch,
                }
            },
            .label_ref => {
                const label = self.ast.data(item).text;
                const name = self.ast.data(self.ast.nodeChildren(item)[0]).text;
                const id = bindings.getNode(name) orelse return error.UnknownVar;
                try self.graph.removeLabel(id, label);
            },
            else => {},
        }
    }
}

pub fn applyDelete(self: *Executor, delete_clause: Index, bindings: *Bindings) ExecError!void {
    const detach = self.ast.data(delete_clause).delete.detach;
    for (self.ast.nodeChildren(delete_clause)) |item| {
        const obj = self.ast.nodeChildren(item)[0];
        const name = self.ast.data(obj).text;
        const id = bindings.getNode(name) orelse return error.UnknownVar;
        if (detach) {
            try self.graph.deleteNodeDetach(id);
        } else {
            self.graph.deleteNode(id) catch |err| {
                if (err == error.NodeStillConnected) {
                    self.fail(.node_still_connected, "node '{s}' still has relationships (use DETACH DELETE)", .{name});
                }
                return err;
            };
        }
    }
}
