//! A snapshot of the stored entities a query result refers to.
//!
//! Result rows hold node and relationship *references*. Before the query's
//! transaction ends, `capture` reads the labels and properties of every
//! entity the rows mention, so callers can present whole entities as the
//! query left them. An entity the query deleted keeps its identity but has
//! no labels or properties left (openCypher does not allow reading a deleted
//! entity's data).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("../storage/graph.zig").Graph;
const PropertyIterator = @import("../storage/graph.zig").PropertyIterator;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const Relationship = @import("../value.zig").Relationship;
const ElementContext = @import("../sequence_algorithms.zig").ElementContext;

/// A property with owned name and value.
pub const Property = struct { name: []const u8, value: Value };

pub const NodeData = struct {
    labels: []const []const u8,
    properties: []const Property,
};

pub const EntitySnapshot = struct {
    nodes: std.AutoHashMapUnmanaged(u64, NodeData) = .empty,
    relationships: std.HashMapUnmanaged(Relationship, []const Property, ElementContext(Relationship), std.hash_map.default_max_load_percentage) = .empty,

    /// Records every node and relationship in `values` (and inside lists).
    /// Each entity is read once. O(log N) per distinct entity, plus its size.
    pub fn capture(self: *EntitySnapshot, graph: *Graph, allocator: Allocator, values: []const Value) (StorageError || Allocator.Error)!void {
        for (values) |value| {
            switch (value) {
                .node => |id| {
                    const entry = try self.nodes.getOrPut(allocator, id);
                    if (!entry.found_existing) entry.value_ptr.* = try readNode(graph, allocator, id);
                },
                .relationship => |relationship| {
                    const entry = try self.relationships.getOrPutContext(allocator, relationship, .{});
                    if (!entry.found_existing) {
                        var properties = try graph.edgePropertiesOf(relationship.src, relationship.dst, relationship.edge_type);
                        defer properties.deinit();
                        entry.value_ptr.* = try copyProperties(&properties, allocator);
                    }
                },
                .list => |items| try self.capture(graph, allocator, items),
                else => {},
            }
        }
    }
};

fn readNode(graph: *Graph, allocator: Allocator, id: u64) (StorageError || Allocator.Error)!NodeData {
    var labels = std.ArrayList([]const u8).empty;
    var label_iterator = try graph.labelsOf(id);
    defer label_iterator.deinit();
    while (try label_iterator.next()) |label| try labels.append(allocator, try allocator.dupe(u8, label));

    var properties = try graph.propertiesOf(id);
    defer properties.deinit();
    return .{ .labels = labels.items, .properties = try copyProperties(&properties, allocator) };
}

/// Copies the properties out of the store (the iterator yields views).
fn copyProperties(properties: *PropertyIterator, allocator: Allocator) (StorageError || Allocator.Error)![]const Property {
    var copies = std.ArrayList(Property).empty;
    while (try properties.next()) |property| {
        try copies.append(allocator, .{
            .name = try allocator.dupe(u8, property.name),
            .value = try property.value.clone(allocator),
        });
    }
    return copies.items;
}
