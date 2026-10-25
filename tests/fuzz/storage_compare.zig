//! Compares the database with the storage fuzzer's model through the
//! `Graph` API: the nodes, their labels and properties, the relationships
//! with their ends, types and properties, each node's edges in the order a
//! scan gives them, and the label and type counts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;
const value_encoding = zypherdb.value_encoding;

const model_module = @import("model.zig");
const Model = model_module.Model;
const NodeId = model_module.NodeId;
const RelationshipId = model_module.RelationshipId;
const Properties = model_module.Properties;

/// The labels and types whose counts are compared.
pub const Pools = struct { labels: []const []const u8, types: []const []const u8 };

/// How the database differs from `model`, or null if it does not. Runs in
/// the active transaction, or in a read transaction of its own.
pub fn difference(arena: Allocator, graph: *Graph, model: *const Model, pools: Pools) !?[]const u8 {
    const own_transaction = !graph.store.inTransaction();
    if (own_transaction) try graph.beginRead();
    defer if (own_transaction) graph.commitRead();
    if (try nodesDifference(arena, graph, model)) |found| return found;
    if (try relationshipsDifference(arena, graph, model)) |found| return found;
    for (model.nodes.keys()) |id| {
        if (try edgesDifference(arena, graph, model, id, .out)) |found| return found;
        if (try edgesDifference(arena, graph, model, id, .in)) |found| return found;
    }
    for (pools.labels) |label| {
        const count = try graph.labelCount(label);
        if (count != model.labelCount(label)) return try std.fmt.allocPrint(arena, "{d} node(s) with label {s}, expected {d}", .{ count, label, model.labelCount(label) });
    }
    for (pools.types) |edge_type| {
        const count = try graph.edgeTypeCount(edge_type);
        if (count != model.typeCount(edge_type)) return try std.fmt.allocPrint(arena, "{d} relationship(s) of type {s}, expected {d}", .{ count, edge_type, model.typeCount(edge_type) });
    }
    return null;
}

fn nodesDifference(arena: Allocator, graph: *Graph, model: *const Model) !?[]const u8 {
    var ids = std.ArrayList(NodeId).empty;
    {
        var nodes = try graph.allNodes();
        defer nodes.deinit();
        while (try nodes.next()) |id| try ids.append(arena, id);
    }
    const expected = try sortedIds(arena, model.nodes.keys());
    if (!std.mem.eql(NodeId, ids.items, expected)) return try std.fmt.allocPrint(arena, "nodes {any}, expected {any}", .{ ids.items, expected });
    for (expected) |id| {
        const node = model.nodes.get(id).?;
        var labels = std.ArrayList([]const u8).empty;
        {
            var iterator = try graph.labelsOf(id);
            defer iterator.deinit();
            while (try iterator.next()) |label| try labels.append(arena, try arena.dupe(u8, label));
        }
        const expected_labels = try sortedNames(arena, node.labels.keys());
        if (!eqlNames(labels.items, expected_labels)) return try std.fmt.allocPrint(arena, "node {d} has labels {s}, expected {s}", .{ id, try join(arena, labels.items), try join(arena, expected_labels) });
        var properties = try graph.propertiesOf(id);
        defer properties.deinit();
        if (try propertiesDifference(arena, &properties, node.properties)) |found| return try std.fmt.allocPrint(arena, "node {d}: {s}", .{ id, found });
    }
    return null;
}

fn relationshipsDifference(arena: Allocator, graph: *Graph, model: *const Model) !?[]const u8 {
    var ids = std.ArrayList(RelationshipId).empty;
    {
        var records = try graph.store.scanRelationships();
        defer records.deinit();
        while (try records.next()) |entry| try ids.append(arena, std.mem.readInt(RelationshipId, entry.key[0..8], .native));
    }
    const expected = try sortedIds(arena, model.relationships.keys());
    if (!std.mem.eql(RelationshipId, ids.items, expected)) return try std.fmt.allocPrint(arena, "relationships {any}, expected {any}", .{ ids.items, expected });
    for (expected) |id| {
        const want = model.relationships.get(id).?;
        const have = (try graph.relationship(id, arena)).?;
        if (have.src != want.src or have.dst != want.dst or !std.mem.eql(u8, have.edge_type, want.edge_type)) {
            return try std.fmt.allocPrint(arena, "relationship {d} is ({d})-[:{s}]->({d}), expected ({d})-[:{s}]->({d})", .{ id, have.src, have.edge_type, have.dst, want.src, want.edge_type, want.dst });
        }
        var properties = try graph.edgePropertiesOf(id);
        defer properties.deinit();
        if (try propertiesDifference(arena, &properties, want.properties)) |found| return try std.fmt.allocPrint(arena, "relationship {d}: {s}", .{ id, found });
    }
    return null;
}

/// Node `id`'s edges in `direction`, in scan order: by type, then
/// neighbour, then relationship id.
fn edgesDifference(arena: Allocator, graph: *Graph, model: *const Model, id: NodeId, direction: zypherdb.Direction) !?[]const u8 {
    const Edge = struct {
        edge_type: []const u8,
        neighbour: NodeId,
        relationship: RelationshipId,

        fn lessThan(_: void, a: @This(), b: @This()) bool {
            return switch (std.mem.order(u8, a.edge_type, b.edge_type)) {
                .lt => true,
                .gt => false,
                .eq => if (a.neighbour != b.neighbour) a.neighbour < b.neighbour else a.relationship < b.relationship,
            };
        }

        fn eql(a: @This(), b: @This()) bool {
            return std.mem.eql(u8, a.edge_type, b.edge_type) and a.neighbour == b.neighbour and a.relationship == b.relationship;
        }
    };
    var have = std.ArrayList(Edge).empty;
    {
        var edges = try graph.edgesOf(id, direction);
        defer edges.deinit();
        while (try edges.next()) |edge| try have.append(arena, .{ .edge_type = try arena.dupe(u8, edge.edge_type), .neighbour = edge.neighbour, .relationship = edge.relationship });
    }
    var want = std.ArrayList(Edge).empty;
    for (model.relationships.keys(), model.relationships.values()) |relationship_id, relationship| {
        const this_end, const other_end = if (direction == .out) .{ relationship.src, relationship.dst } else .{ relationship.dst, relationship.src };
        if (this_end == id) try want.append(arena, .{ .edge_type = relationship.edge_type, .neighbour = other_end, .relationship = relationship_id });
    }
    std.mem.sort(Edge, want.items, {}, Edge.lessThan);
    const same = have.items.len == want.items.len and for (have.items, want.items) |a, b| {
        if (!a.eql(b)) break false;
    } else true;
    if (same) return null;
    return try std.fmt.allocPrint(arena, "node {d} has {d} {t} edge(s), expected {d} (or not in that order)", .{ id, have.items.len, direction, want.items.len });
}

/// Compares stored properties (in name order) with the model's, by their
/// encodings: equal values, of equal types, NaN included.
fn propertiesDifference(arena: Allocator, properties: *zypherdb.graph.PropertyIterator, expected: Properties) !?[]const u8 {
    const names = try sortedNames(arena, expected.keys());
    var i: usize = 0;
    while (try properties.next()) |property| : (i += 1) {
        if (i >= names.len) return try std.fmt.allocPrint(arena, "property {s} is not in the model", .{property.name});
        if (!std.mem.eql(u8, property.name, names[i])) return try std.fmt.allocPrint(arena, "property {s}, expected {s}", .{ property.name, names[i] });
        var encoded = std.ArrayList(u8).empty;
        try value_encoding.encodeValue(&encoded, arena, expected.get(names[i]).?);
        if (!std.mem.eql(u8, property.encoded_value, encoded.items)) return try std.fmt.allocPrint(arena, "property {s} differs from the model", .{names[i]});
    }
    if (i < names.len) return try std.fmt.allocPrint(arena, "property {s} is missing", .{names[i]});
    return null;
}

fn sortedIds(arena: Allocator, ids: []const u64) Allocator.Error![]const u64 {
    const sorted = try arena.dupe(u64, ids);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return sorted;
}

fn sortedNames(arena: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const sorted = try arena.dupe([]const u8, names);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return sorted;
}

fn eqlNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn join(arena: Allocator, names: []const []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "[{s}]", .{try std.mem.join(arena, ", ", names)});
}
