//! Write clauses: CREATE, MERGE, SET, REMOVE and DELETE.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;
const GraphError = @import("../storage/graph.zig").GraphError;

const Executor = @import("Executor.zig");
const pattern_matching = @import("pattern_matching.zig");
const expressions = @import("expressions.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;

pub fn applyCreate(self: *Executor, pattern: Index, bindings: *Bindings) ExecutionError!void {
    const chain = self.ast.nodeChildren(pattern);
    const node_ids = try self.allocator.alloc(NodeId, (chain.len + 1) / 2);
    for (node_ids, 0..) |*id, i| {
        const node_pattern_index = chain[i * 2];
        const variable_name = self.ast.data(node_pattern_index).node_pattern.variable_name;
        if (boundNode(bindings, variable_name)) |bound| {
            try checkReusedNode(self, node_pattern_index, chain.len == 1);
            id.* = bound;
            continue;
        }
        id.* = try createNode(self, node_pattern_index, bindings);
        if (variable_name.len > 0) try bindings.put(self.allocator, variable_name, .{ .node = id.* });
    }
    try applyEdges(self, chain, node_ids, bindings, false);
}

pub fn applyMerge(self: *Executor, merge_clause: Index, bindings: *Bindings) ExecutionError!void {
    const children = self.ast.nodeChildren(merge_clause);
    const pattern = children[0];
    const on_create = children[1];
    const on_match = children[2];
    const chain = self.ast.nodeChildren(pattern);
    const node_ids = try self.allocator.alloc(NodeId, (chain.len + 1) / 2);

    var created = false;
    for (node_ids, 0..) |*id, i| {
        const node_pattern_index = chain[i * 2];
        const variable_name = self.ast.data(node_pattern_index).node_pattern.variable_name;
        if (boundNode(bindings, variable_name)) |bound| {
            id.* = bound;
            continue;
        }
        try rejectNullProperties(self, node_pattern_index, bindings);
        if (try findMatchingNode(self, node_pattern_index, bindings)) |found| {
            id.* = found;
        } else {
            id.* = try createNode(self, node_pattern_index, bindings);
            created = true;
        }
        if (variable_name.len > 0) try bindings.put(self.allocator, variable_name, .{ .node = id.* });
    }
    try applyEdges(self, chain, node_ids, bindings, true);

    // ON CREATE / ON MATCH SET (an empty set clause does nothing).
    if (created) {
        try applySet(self, on_create, bindings);
    } else {
        try applySet(self, on_match, bindings);
    }
}

/// CREATE may reuse a bound node only as a relationship endpoint, as it is:
/// adding labels or properties to it, or "creating" it alone, is an error
/// (openCypher's VariableAlreadyBound).
fn checkReusedNode(self: *Executor, node_pattern_index: Index, alone: bool) ExecutionError!void {
    const node_pattern = self.ast.data(node_pattern_index).node_pattern;
    const adds_something = node_pattern.labels.len > 0 or self.ast.nodeChildren(node_pattern_index).len > 0;
    if (adds_something or alone) {
        self.fail(.invalid_expression, "variable '{s}' is already bound; CREATE cannot create it again", .{node_pattern.variable_name});
        return error.InvalidExpression;
    }
}

/// The node already bound to `variable_name`, if any; an anonymous node (empty
/// name) is never bound.
fn boundNode(bindings: *const Bindings, variable_name: []const u8) ?NodeId {
    if (variable_name.len == 0) return null;
    return bindings.getNode(variable_name);
}

/// Creates a node from a `node_pattern` and returns its fresh id.
pub fn createNode(self: *Executor, node_pattern_index: Index, bindings: *Bindings) ExecutionError!NodeId {
    const node_pattern = self.ast.data(node_pattern_index).node_pattern;
    const id = try self.graph.allocateNodeId();
    try self.graph.addNode(id, ""); // node marker
    for (node_pattern.labels) |label| try self.graph.addLabel(id, label);
    for (self.ast.nodeChildren(node_pattern_index)) |property_node| {
        const property_name = self.ast.data(property_node).text;
        const value = try expressions.evaluate(self, self.ast.nodeChildren(property_node)[0], bindings);
        try setNodeProperty(self, id, property_name, value);
    }
    return id;
}

/// Finds an existing node matching the labels + property map, if any.
pub fn findMatchingNode(self: *Executor, node_pattern_index: Index, bindings: *Bindings) ExecutionError!?NodeId {
    const node_pattern = self.ast.data(node_pattern_index).node_pattern;
    const properties = self.ast.nodeChildren(node_pattern_index);

    if (properties.len > 0) {
        // Index lookup on the first property.
        const property_name = self.ast.data(properties[0]).text;
        const value = try expressions.evaluate(self, self.ast.nodeChildren(properties[0])[0], bindings);
        var iterator = try self.graph.nodesByProperty(property_name, value);
        defer iterator.deinit();
        while (try iterator.next()) |id| {
            if (!(try pattern_matching.hasAllLabels(self, id, node_pattern.labels))) continue;
            if (try nodePropertiesMatch(self, node_pattern_index, id, bindings)) return id;
        }
        return null;
    }

    var iterator = try pattern_matching.seedNodes(self, node_pattern.labels);
    defer iterator.deinit();
    while (try iterator.next()) |id| {
        if (!(try pattern_matching.hasAllLabels(self, id, node_pattern.labels))) continue;
        if (try nodePropertiesMatch(self, node_pattern_index, id, bindings)) return id;
    }
    return null;
}

pub fn nodePropertiesMatch(self: *Executor, node_pattern_index: Index, id: NodeId, bindings: *Bindings) ExecutionError!bool {
    for (self.ast.nodeChildren(node_pattern_index)) |property_node| {
        const property_name = self.ast.data(property_node).text;
        const value = try expressions.evaluate(self, self.ast.nodeChildren(property_node)[0], bindings);
        const actual = (try self.graph.getProperty(id, property_name, self.allocator)) orelse return false;
        if (!Value.eql(actual, value)) return false;
    }
    return true;
}

/// Writes the edges of a CREATE/MERGE chain between the already resolved
/// `node_ids` (one per node position, so anonymous nodes work too). With
/// `merge`, an existing edge is kept instead of duplicated.
pub fn applyEdges(self: *Executor, chain: []const Index, node_ids: []const NodeId, bindings: *Bindings, merge: bool) ExecutionError!void {
    for (node_ids[0 .. node_ids.len - 1], node_ids[1..], 0..) |left_id, right_id, i| {
        const edge_pattern_index = chain[i * 2 + 1];
        const edge_pattern = self.ast.data(edge_pattern_index).edge_pattern;
        if (edge_pattern.edge_type.len == 0) {
            self.fail(.invalid_expression, "a created relationship needs exactly one type", .{});
            return error.InvalidExpression;
        }
        if (edge_pattern.direction == .undirected and !merge) {
            self.fail(.invalid_expression, "CREATE needs a relationship direction (-> or <-)", .{});
            return error.InvalidExpression;
        }
        // MERGE without a direction matches either way and creates left to right.
        const src: NodeId = if (edge_pattern.direction == .right_to_left) right_id else left_id;
        const dst: NodeId = if (edge_pattern.direction == .right_to_left) left_id else right_id;
        if (merge) {
            try rejectNullProperties(self, edge_pattern_index, bindings);
            if (try self.graph.hasEdge(src, dst, edge_pattern.edge_type)) continue;
            if (edge_pattern.direction == .undirected and try self.graph.hasEdge(dst, src, edge_pattern.edge_type)) continue;
        }
        try self.graph.addEdge(src, dst, edge_pattern.edge_type);
        for (self.ast.nodeChildren(edge_pattern_index)) |property_node| {
            const property_name = self.ast.data(property_node).text;
            const value = try expressions.evaluate(self, self.ast.nodeChildren(property_node)[0], bindings);
            try setEdgeProperty(self, src, dst, edge_pattern.edge_type, property_name, value);
        }
    }
}

pub fn applySet(self: *Executor, set_clause: Index, bindings: *Bindings) ExecutionError!void {
    for (self.ast.nodeChildren(set_clause)) |item| {
        const item_children = self.ast.nodeChildren(item);
        const access = item_children[0];
        const value_expression = item_children[1];
        const property = self.ast.data(access).text;
        const object = self.ast.nodeChildren(access)[0];
        const name = self.ast.data(object).text;
        const value = try expressions.evaluate(self, value_expression, bindings);
        switch (bindings.get(name) orelse return error.UnknownVariable) {
            .node => |id| try setNodeProperty(self, id, property, value),
            .relationship => |r| try setEdgeProperty(self, r.src, r.dst, r.edge_type, property, value),
            else => return error.TypeMismatch,
        }
    }
}

pub fn applyRemove(self: *Executor, remove_clause: Index, bindings: *Bindings) ExecutionError!void {
    for (self.ast.nodeChildren(remove_clause)) |item| {
        switch (self.ast.kind(item)) {
            .property_access => {
                const property = self.ast.data(item).text;
                const name = self.ast.data(self.ast.nodeChildren(item)[0]).text;
                switch (bindings.get(name) orelse return error.UnknownVariable) {
                    .node => |id| try self.graph.removeProperty(id, property),
                    .relationship => |r| try self.graph.removeEdgeProperty(r.src, r.dst, r.edge_type, property),
                    else => return error.TypeMismatch,
                }
            },
            .label_reference => {
                const label = self.ast.data(item).text;
                const name = self.ast.data(self.ast.nodeChildren(item)[0]).text;
                const id = bindings.getNode(name) orelse return error.UnknownVariable;
                try self.graph.removeLabel(id, label);
            },
            else => {},
        }
    }
}

pub fn applyDelete(self: *Executor, delete_clause: Index, bindings: *Bindings) ExecutionError!void {
    const detach = self.ast.data(delete_clause).delete.detach;
    for (self.ast.nodeChildren(delete_clause)) |item| {
        const object = self.ast.nodeChildren(item)[0];
        const name = self.ast.data(object).text;
        const id = switch (bindings.get(name) orelse return error.UnknownVariable) {
            .node => |id| id,
            .relationship => |r| {
                try self.graph.deleteEdge(r.src, r.dst, r.edge_type);
                continue;
            },
            .null => continue, // e.g. from an OPTIONAL MATCH that found nothing
            else => {
                self.fail(.type_mismatch, "DELETE needs a node or a relationship, '{s}' is neither", .{name});
                return error.TypeMismatch;
            },
        };
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

/// Sets a node property, explaining an unstorable value in the diagnostic.
fn setNodeProperty(self: *Executor, id: NodeId, name: []const u8, value: Value) ExecutionError!void {
    self.graph.setProperty(id, name, value) catch |err| return reportPropertyError(self, name, err);
}

/// Sets an edge property, explaining an unstorable value in the diagnostic.
fn setEdgeProperty(self: *Executor, src: NodeId, dst: NodeId, edge_type: []const u8, name: []const u8, value: Value) ExecutionError!void {
    self.graph.setEdgeProperty(src, dst, edge_type, name, value) catch |err| return reportPropertyError(self, name, err);
}

fn reportPropertyError(self: *Executor, name: []const u8, err: GraphError) ExecutionError {
    if (err == error.UnsupportedPropertyType) {
        self.fail(.type_mismatch, "property '{s}': lists cannot be stored as property values yet", .{name});
    }
    return err;
}

/// MERGE cannot match or create on a null property value (openCypher raises a
/// semantic error rather than guessing).
fn rejectNullProperties(self: *Executor, pattern_index: Index, bindings: *Bindings) ExecutionError!void {
    for (self.ast.nodeChildren(pattern_index)) |property_node| {
        const value = try expressions.evaluate(self, self.ast.nodeChildren(property_node)[0], bindings);
        if (value == .null) {
            self.fail(.invalid_expression, "cannot MERGE on a null value for property '{s}'", .{self.ast.data(property_node).text});
            return error.InvalidExpression;
        }
    }
}
