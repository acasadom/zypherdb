//! Write clauses: CREATE, MERGE, SET, REMOVE and DELETE.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const Relationship = @import("../value.zig").Relationship;
const GraphError = @import("../storage/graph.zig").GraphError;
const layout = @import("../storage/layout.zig");

const Executor = @import("Executor.zig");
const pattern_matching = @import("pattern_matching.zig");
const expressions = @import("expressions.zig");
const functions = @import("functions.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;

pub fn applyCreate(self: *Executor, pattern: Index, bindings: *Bindings) ExecutionError!void {
    try createPattern(self, pattern, bindings, .create);
}

/// Who creates a pattern: CREATE, or MERGE when the pattern has no match
/// (it may reuse bound nodes as they are, and creates an undirected
/// relationship left to right).
pub const Creator = enum { create, merge };

/// Creates a pattern's unbound nodes and its relationships, binding their
/// variables in `bindings`.
pub fn createPattern(self: *Executor, pattern: Index, bindings: *Bindings, creator: Creator) ExecutionError!void {
    const chain = self.ast.nodeChildren(pattern);
    const node_ids = try self.allocator.alloc(NodeId, (chain.len + 1) / 2);
    for (node_ids, 0..) |*id, i| {
        const node_pattern_index = chain[i * 2];
        const slot = self.slotOf(node_pattern_index);
        if (bindings.getNode(slot)) |bound| {
            if (creator == .create) try checkReusedNode(self, node_pattern_index, chain.len == 1);
            id.* = bound;
            continue;
        }
        id.* = try createNode(self, node_pattern_index, bindings);
        try bindings.put(self.allocator, slot, .{ .node = id.* });
    }
    const relationships = try applyEdges(self, chain, node_ids, bindings, creator);
    // A path variable (`CREATE p = (a)-[:R]->(b)`) binds what was written.
    try bindings.put(self.allocator, self.slotOf(pattern), .{ .path = .{ .nodes = node_ids, .relationships = relationships } });
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

/// Creates a node from a `node_pattern` and returns its fresh id.
pub fn createNode(self: *Executor, node_pattern_index: Index, bindings: *Bindings) ExecutionError!NodeId {
    const node_pattern = self.ast.data(node_pattern_index).node_pattern;
    const id = try self.graph.allocateNodeId();
    try self.graph.addNode(id, ""); // node marker
    for (node_pattern.labels) |label| try addLabel(self, id, label);
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
pub fn applyEdges(self: *Executor, chain: []const Index, node_ids: []const NodeId, bindings: *Bindings, creator: Creator) ExecutionError![]const Relationship {
    const relationships = try self.allocator.alloc(Relationship, node_ids.len - 1);
    for (relationships, node_ids[0 .. node_ids.len - 1], node_ids[1..], 0..) |*relationship, left_id, right_id, i| {
        const edge_pattern_index = chain[i * 2 + 1];
        const edge_pattern = self.ast.data(edge_pattern_index).edge_pattern;
        const edge_type = edge_pattern.singleType() orelse {
            self.fail(.invalid_expression, "a created relationship needs exactly one type", .{});
            return error.InvalidExpression;
        };
        if (edge_pattern.variable_length) {
            self.fail(.invalid_expression, "CREATE and MERGE cannot write a variable-length relationship", .{});
            return error.InvalidExpression;
        }
        if (edge_pattern.direction == .undirected and creator == .create) {
            self.fail(.invalid_expression, "CREATE needs a relationship direction (-> or <-)", .{});
            return error.InvalidExpression;
        }
        // MERGE without a direction matches either way and creates left to right.
        const src: NodeId = if (edge_pattern.direction == .right_to_left) right_id else left_id;
        const dst: NodeId = if (edge_pattern.direction == .right_to_left) left_id else right_id;
        try requireStorableName(self, "relationship type", edge_type);
        const id = try self.graph.addEdge(src, dst, edge_type);
        for (self.ast.nodeChildren(edge_pattern_index)) |property_node| {
            const property_name = self.ast.data(property_node).text;
            const value = try expressions.evaluate(self, self.ast.nodeChildren(property_node)[0], bindings);
            try setEdgeProperty(self, id, property_name, value);
        }
        relationship.* = .{ .id = id, .src = src, .dst = dst, .edge_type = edge_type };
        try bindings.put(self.allocator, self.slotOf(edge_pattern_index), .{ .relationship = relationship.* });
    }
    return relationships;
}

pub fn applySet(self: *Executor, set_clause: Index, bindings: *Bindings) ExecutionError!void {
    for (self.ast.nodeChildren(set_clause)) |item| {
        const item_children = self.ast.nodeChildren(item);
        switch (self.ast.kind(item)) {
            .set_item => {
                const access = item_children[0];
                const property = self.ast.data(access).text;
                const entity = try writeTarget(self, self.ast.nodeChildren(access)[0], bindings, "SET");
                const value = try expressions.evaluate(self, item_children[1], bindings);
                try setProperty(self, entity, property, value);
            },
            .set_properties => {
                const entity = try writeTarget(self, item_children[0], bindings, "SET");
                const replace = !self.ast.data(item).boolean;
                try setProperties(self, entity, try expressions.evaluate(self, item_children[1], bindings), replace);
            },
            .label_reference => switch (try writeTarget(self, item_children[0], bindings, "SET")) {
                .node => |id| try addLabel(self, id, self.ast.data(item).text),
                .null => {},
                else => return labelsOnNodesOnly(self),
            },
            else => {},
        }
    }
}

/// The node or relationship a SET writes to (`null` from an OPTIONAL MATCH
/// that found nothing: the item does nothing).
/// What a SET, REMOVE or DELETE item writes to: `expression`'s value, a node
/// or a relationship, or null (from an OPTIONAL MATCH that found nothing:
/// the item then does nothing).
fn writeTarget(self: *Executor, expression: Index, bindings: *Bindings, clause: []const u8) ExecutionError!Value {
    const value = try expressions.evaluate(self, expression, bindings);
    return switch (value) {
        .node, .relationship, .null => value,
        else => {
            self.fail(.type_mismatch, "{s} writes to a node or a relationship, not to a {s}", .{ clause, value.typeName() });
            return error.TypeMismatch;
        },
    };
}

fn labelsOnNodesOnly(self: *Executor) ExecutionError {
    self.fail(.type_mismatch, "only nodes have labels", .{});
    return error.TypeMismatch;
}

fn setProperty(self: *Executor, target: Value, name: []const u8, value: Value) ExecutionError!void {
    switch (target) {
        .node => |id| try setNodeProperty(self, id, name, value),
        .relationship => |r| try setEdgeProperty(self, r.id, name, value),
        else => {},
    }
}

/// `SET n = source` (`replace`: drop every other property) or `SET n +=
/// source`, where `source` is a map, or a node or relationship whose
/// properties are copied. A null entry removes its property.
fn setProperties(self: *Executor, target: Value, source: Value, replace: bool) ExecutionError!void {
    if (target == .null) return;
    const entries: []const MapEntry = switch (source) {
        .map => |entries| entries,
        .node, .relationship => (try functions.propertiesOf(self, source)).map,
        .null => &.{},
        else => {
            self.fail(.type_mismatch, "SET n = / += needs a map, a node or a relationship", .{});
            return error.TypeMismatch;
        },
    };
    if (replace) {
        const current = try functions.propertiesOf(self, target);
        for (current.map) |entry| {
            if (Value.mapGet(entries, entry.key).isNull()) try setProperty(self, target, entry.key, .{ .null = {} });
        }
    }
    for (entries) |entry| try setProperty(self, target, entry.key, entry.value);
}

pub fn applyRemove(self: *Executor, remove_clause: Index, bindings: *Bindings) ExecutionError!void {
    for (self.ast.nodeChildren(remove_clause)) |item| {
        switch (self.ast.kind(item)) {
            .property_access => {
                const property = self.ast.data(item).text;
                switch (try writeTarget(self, self.ast.nodeChildren(item)[0], bindings, "REMOVE")) {
                    .node => |id| try self.graph.removeProperty(id, property),
                    .relationship => |r| try self.graph.removeEdgeProperty(r.id, property),
                    else => {},
                }
            },
            .label_reference => switch (try writeTarget(self, self.ast.nodeChildren(item)[0], bindings, "REMOVE")) {
                .node => |id| try self.graph.removeLabel(id, self.ast.data(item).text),
                .null => {},
                else => return labelsOnNodesOnly(self),
            },
            else => {},
        }
    }
}

pub fn applyDelete(self: *Executor, delete_clause: Index, bindings: *Bindings) ExecutionError!void {
    const detach = self.ast.data(delete_clause).delete.detach;
    const items = self.ast.nodeChildren(delete_clause);
    const values = try self.allocator.alloc(Value, items.len);
    for (values, items) |*value, item| value.* = try expressions.evaluate(self, self.ast.nodeChildren(item)[0], bindings);
    // Every relationship first, then the nodes: a node is refused only if
    // something this DELETE does not remove still connects it.
    for (values) |value| switch (value) {
        .relationship => |r| try self.graph.deleteEdge(r.id),
        .path => |path| for (path.relationships) |r| try self.graph.deleteEdge(r.id),
        .node, .null => {}, // null: e.g. from an OPTIONAL MATCH that found nothing
        else => {
            self.fail(.type_mismatch, "DELETE needs a node, a relationship or a path, not a {s}", .{value.typeName()});
            return error.TypeMismatch;
        },
    };
    for (values, items) |value, item| switch (value) {
        .node => |id| {
            // How a refusal names the node: by its variable, when it has one.
            const expression = self.ast.nodeChildren(item)[0];
            const name = if (self.ast.kind(expression) == .variable) self.ast.data(expression).text else "";
            try deleteNode(self, id, detach, name);
        },
        .path => |path| for (path.nodes) |id| try deleteNode(self, id, detach, ""),
        else => {},
    };
}

fn deleteNode(self: *Executor, id: NodeId, detach: bool, name: []const u8) ExecutionError!void {
    if (detach) return self.graph.deleteNodeDetach(id);
    self.graph.deleteNode(id) catch |err| {
        if (err == error.NodeStillConnected) {
            if (name.len > 0) {
                self.fail(.node_still_connected, "node '{s}' still has relationships (use DETACH DELETE)", .{name});
            } else {
                self.fail(.node_still_connected, "a node to delete still has relationships (use DETACH DELETE)", .{});
            }
        }
        return err;
    };
}

fn addLabel(self: *Executor, id: NodeId, label: []const u8) ExecutionError!void {
    try requireStorableName(self, "label", label);
    try self.graph.addLabel(id, label);
}

/// Refuses a label, relationship type or property name that storage cannot
/// keep: empty, or holding U+0000, the separator inside index keys. (Names in
/// a query are never empty; names from a map parameter can be.)
pub fn requireStorableName(self: *Executor, kind: []const u8, name: []const u8) ExecutionError!void {
    if (layout.isStorableName(name)) return;
    self.fail(.invalid_expression, "a {s} cannot be empty or contain the character U+0000", .{kind});
    return error.InvalidExpression;
}

/// Sets a node property, explaining an unstorable value in the diagnostic.
/// (Setting a property to null removes it: any name is accepted then.)
fn setNodeProperty(self: *Executor, id: NodeId, name: []const u8, value: Value) ExecutionError!void {
    if (!value.isNull()) try requireStorableName(self, "property name", name);
    self.graph.setProperty(id, name, value) catch |err| return reportPropertyError(self, name, err);
}

/// Sets an edge property, explaining an unstorable value in the diagnostic.
fn setEdgeProperty(self: *Executor, id: u64, name: []const u8, value: Value) ExecutionError!void {
    if (!value.isNull()) try requireStorableName(self, "property name", name);
    self.graph.setEdgeProperty(id, name, value) catch |err| return reportPropertyError(self, name, err);
}

fn reportPropertyError(self: *Executor, name: []const u8, err: GraphError) ExecutionError {
    if (err == error.UnsupportedPropertyType) {
        self.fail(.type_mismatch, "property '{s}': this value cannot be stored (a list must hold values of one kind and no nulls; nodes, relationships and paths are never stored)", .{name});
    }
    return err;
}

/// MERGE cannot match or create on a null property value (openCypher raises a
/// semantic error rather than guessing): checks every node and relationship
/// of `pattern`.
pub fn rejectNullProperties(self: *Executor, pattern: Index, bindings: *Bindings) ExecutionError!void {
    for (self.ast.nodeChildren(pattern)) |element| try rejectNullPropertiesOf(self, element, bindings);
}

fn rejectNullPropertiesOf(self: *Executor, pattern_index: Index, bindings: *Bindings) ExecutionError!void {
    for (self.ast.nodeChildren(pattern_index)) |property_node| {
        const value = try expressions.evaluate(self, self.ast.nodeChildren(property_node)[0], bindings);
        if (value == .null) {
            self.fail(.invalid_expression, "cannot MERGE on a null value for property '{s}'", .{self.ast.data(property_node).text});
            return error.InvalidExpression;
        }
    }
}
