//! Uniqueness constraints (`REQUIRE n.p IS UNIQUE`): no two nodes with the
//! constraint's label have the same values of its properties. A node that
//! lacks one of them is not concerned (as in Neo4j).
//!
//! A write is checked before it is made, against the constraint's own
//! property index (on its label and first property): a node
//! that would get a label or a property value another node of that label
//! already has fails with `error.ConstraintViolation`, and nothing is
//! written. Values are compared as the index compares them, on every
//! property: 1 and 1.0 are one value. Each check is O(log N + nodes with
//! that value). Checking before
//! writing is stricter than at commit: swapping two nodes' values in one
//! query fails.

const std = @import("std");

const Graph = @import("graph.zig").Graph;
const NodeId = @import("graph.zig").NodeId;
const StorageError = @import("key_value_store.zig").StorageError;
const fulltext = @import("fulltext.zig");
const NodeRecord = @import("node_record.zig").NodeRecord;
const value_encoding = @import("value_encoding.zig");

/// Fails with `error.ConstraintViolation` (and the graph's violation
/// message) if node `id`, with `record` as its new record, would break a
/// uniqueness constraint.
pub fn checkNode(graph: *Graph, id: NodeId, record: NodeRecord) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return; // no definition was ever made
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.allOfKind(graph, arena, .unique)) |definition| {
        const other = try duplicateOf(graph, arena, definition, id, record) orelse continue;
        graph.setViolation("node {d} cannot have the same {s} as node {d}: constraint '{s}' makes it unique for :{s}", .{ id, propertyList(arena, definition) catch "properties", other, definition.name, definition.labels_or_types[0] });
        return error.ConstraintViolation;
    }
}

/// Fails with `error.ConstraintViolation` if the graph already breaks
/// `definition` (a constraint just created, its index built). O(nodes with
/// its label).
pub fn checkExisting(graph: *Graph, definition: fulltext.Definition) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var nodes = try graph.nodesWithLabel(definition.labels_or_types[0]);
    defer nodes.deinit();
    while (try nodes.next()) |id| {
        const record = NodeRecord{ .bytes = try graph.recordCopy(id, arena) };
        const other = try duplicateOf(graph, arena, definition, id, record) orelse continue;
        graph.setViolation("cannot create constraint '{s}': nodes {d} and {d} have the same {s}", .{ definition.name, @min(id, other), @max(id, other), propertyList(arena, definition) catch "properties" });
        return error.ConstraintViolation;
    }
}

/// Another node of the constraint's label with the same values as `record`
/// (the record node `id` has or would have), if there is one.
fn duplicateOf(graph: *Graph, arena: std.mem.Allocator, definition: fulltext.Definition, id: NodeId, record: NodeRecord) StorageError!?NodeId {
    const label = definition.labels_or_types[0];
    if (!record.hasLabel(label)) return null;
    const values = try arena.alloc([]const u8, definition.properties.len);
    for (values, definition.properties) |*value, property| value.* = record.property(property) orelse return null;

    var candidates = try graph.nodesByIndex(definition.index_id, try value_encoding.decodeValue(values[0], arena));
    defer candidates.deinit();
    candidate: while (try candidates.next()) |other| {
        if (other == id) continue;
        const other_record = NodeRecord{ .bytes = try graph.recordCopy(other, arena) };
        if (!other_record.hasLabel(label)) continue;
        // Long values share index keys: compare every property.
        for (definition.properties, values) |property, value| {
            const other_value = other_record.property(property) orelse continue :candidate;
            if (!try sameToTheIndex(arena, other_value, value)) continue :candidate;
        }
        return other;
    }
    return null;
}

/// True if two stored values are one to the property index (1 and 1.0 are),
/// as the lookup of the first property compares them.
fn sameToTheIndex(arena: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error!bool {
    if (std.mem.eql(u8, a, b)) return true;
    var keys: [2]std.ArrayList(u8) = .{ .empty, .empty };
    for (&keys, [_][]const u8{ a, b }) |*key, encoded| try value_encoding.encodeIndexValue(key, arena, try value_encoding.decodeValue(encoded, arena));
    return std.mem.eql(u8, keys[0].items, keys[1].items);
}

/// `a` or `(a, b)`: the constraint's properties, for a message.
fn propertyList(arena: std.mem.Allocator, definition: fulltext.Definition) std.mem.Allocator.Error![]const u8 {
    if (definition.properties.len == 1) return definition.properties[0];
    const joined = try std.mem.join(arena, ", ", definition.properties);
    return std.fmt.allocPrint(arena, "({s})", .{joined});
}
