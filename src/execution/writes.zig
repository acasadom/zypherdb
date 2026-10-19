//! Write clauses: CREATE, MERGE, SET, REMOVE and DELETE.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const ExecError = Executor.ExecError;

const Bindings = @import("bindings.zig").Bindings;

pub fn applyCreate(self: *Executor, pattern: Index, bindings: *Bindings) ExecError!void {
    const chain = self.ast.nodeChildren(pattern);
    const num_nodes = (chain.len + 1) / 2;

    for (0..num_nodes) |i| {
        const np_idx = chain[i * 2];
        const np = self.ast.data(np_idx).node_pattern;
        if (np.var_name.len == 0 or bindings.getNode(np.var_name) != null) continue;
        const id = try self.createNode(np_idx, bindings);
        try bindings.put(self.allocator, np.var_name, .{ .node = id });
    }
    try self.applyEdges(chain, num_nodes, bindings, false);
}

pub fn applyMerge(self: *Executor, mc: Index, bindings: *Bindings) ExecError!void {
    const kids = self.ast.nodeChildren(mc);
    const pattern = kids[0];
    const on_create = kids[1];
    const on_match = kids[2];
    const chain = self.ast.nodeChildren(pattern);
    const num_nodes = (chain.len + 1) / 2;

    var created = false;
    for (0..num_nodes) |i| {
        const np_idx = chain[i * 2];
        const np = self.ast.data(np_idx).node_pattern;
        if (np.var_name.len == 0 or bindings.getNode(np.var_name) != null) continue;
        if (try self.findMatchingNode(np_idx, bindings)) |id| {
            try bindings.put(self.allocator, np.var_name, .{ .node = id });
        } else {
            const id = try self.createNode(np_idx, bindings);
            try bindings.put(self.allocator, np.var_name, .{ .node = id });
            created = true;
        }
    }
    try self.applyEdges(chain, num_nodes, bindings, true);

    // ON CREATE / ON MATCH SET (an empty set clause is a no-op).
    if (created) {
        try self.applySet(on_create, bindings);
    } else {
        try self.applySet(on_match, bindings);
    }
}

/// Creates a node from a `node_pattern` and returns its fresh id.
pub fn createNode(self: *Executor, np_idx: Index, bindings: *Bindings) ExecError!NodeId {
    const np = self.ast.data(np_idx).node_pattern;
    const id = try self.graph.allocNodeId();
    try self.graph.addNode(id, ""); // node marker
    for (np.labels) |label| try self.graph.addLabel(id, label);
    for (self.ast.nodeChildren(np_idx)) |prop_idx| {
        const prop_name = self.ast.data(prop_idx).text;
        const value = try self.eval(self.ast.nodeChildren(prop_idx)[0], bindings);
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
        const value = try self.eval(self.ast.nodeChildren(props[0])[0], bindings);
        var it = try self.graph.nodesByProp(prop_name, value);
        defer it.deinit();
        while (try it.next()) |id| {
            if (!(try self.hasAllLabels(id, np.labels))) continue;
            if (try self.nodePropsMatch(np_idx, id, bindings)) return id;
        }
        return null;
    }

    var it = try self.seedNodes(np.labels);
    defer it.deinit();
    while (try it.next()) |id| {
        if (!(try self.hasAllLabels(id, np.labels))) continue;
        if (try self.nodePropsMatch(np_idx, id, bindings)) return id;
    }
    return null;
}

pub fn nodePropsMatch(self: *Executor, np_idx: Index, id: NodeId, bindings: *Bindings) ExecError!bool {
    for (self.ast.nodeChildren(np_idx)) |prop_idx| {
        const prop_name = self.ast.data(prop_idx).text;
        const value = try self.eval(self.ast.nodeChildren(prop_idx)[0], bindings);
        const actual = (try self.graph.getProp(id, prop_name, self.allocator)) orelse return false;
        if (!Value.eql(actual, value)) return false;
    }
    return true;
}

pub fn applyEdges(self: *Executor, chain: []const Index, num_nodes: usize, bindings: *Bindings, merge: bool) ExecError!void {
    for (0..num_nodes - 1) |i| {
        const ep_idx = chain[i * 2 + 1];
        const ep = self.ast.data(ep_idx).edge_pattern;
        const left_name = self.ast.data(chain[i * 2]).node_pattern.var_name;
        const right_name = self.ast.data(chain[i * 2 + 2]).node_pattern.var_name;
        const left_id = bindings.getNode(left_name) orelse return error.UnknownVar;
        const right_id = bindings.getNode(right_name) orelse return error.UnknownVar;
        const src: NodeId = if (ep.direction == .left_to_right) left_id else right_id;
        const dst: NodeId = if (ep.direction == .left_to_right) right_id else left_id;
        if (merge and (try self.graph.hasEdge(src, dst, ep.etype))) continue;
        try self.graph.addEdge(src, dst, ep.etype);
        for (self.ast.nodeChildren(ep_idx)) |prop_idx| {
            const prop_name = self.ast.data(prop_idx).text;
            const value = try self.eval(self.ast.nodeChildren(prop_idx)[0], bindings);
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
        const value = try self.eval(value_expr, bindings);
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
