//! The storage fuzzer's model: the graph as plain maps in memory, which the
//! fuzzer changes as each operation must change the database, and which
//! predicts the operations that must fail.
//!
//! Values are not owned: they live in the fuzzer's arena for the whole run,
//! so a copy of the model (a transaction's snapshot) shares them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");
const Value = zypherdb.Value;
const value_encoding = zypherdb.value_encoding;

pub const NodeId = u64;
pub const RelationshipId = u64;

pub const Properties = std.StringArrayHashMapUnmanaged(Value);

pub const Node = struct {
    labels: std.StringArrayHashMapUnmanaged(void) = .empty,
    properties: Properties = .empty,

    fn clone(self: Node, allocator: Allocator) Allocator.Error!Node {
        return .{ .labels = try self.labels.clone(allocator), .properties = try self.properties.clone(allocator) };
    }

    fn deinit(self: *Node, allocator: Allocator) void {
        self.labels.deinit(allocator);
        self.properties.deinit(allocator);
    }
};

pub const Relationship = struct {
    src: NodeId,
    dst: NodeId,
    edge_type: []const u8,
    properties: Properties = .empty,
};

/// A full-text index or a uniqueness constraint (the names share one
/// namespace).
pub const Definition = struct {
    name: []const u8,
    kind: enum { fulltext, range, unique },
    labels_or_types: []const []const u8,
    properties: []const []const u8,
};

pub const Model = struct {
    allocator: Allocator,
    nodes: std.AutoArrayHashMapUnmanaged(NodeId, Node) = .empty,
    relationships: std.AutoArrayHashMapUnmanaged(RelationshipId, Relationship) = .empty,
    definitions: std.ArrayList(Definition) = .empty,
    /// Every node id handed out or chosen so far is below this one: the
    /// database must never hand out an id again.
    node_ids_above: NodeId = 0,
    relationship_ids_above: RelationshipId = 0,

    pub fn init(allocator: Allocator) Model {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Model) void {
        for (self.nodes.values()) |*node| node.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        for (self.relationships.values()) |*relationship| relationship.properties.deinit(self.allocator);
        self.relationships.deinit(self.allocator);
        self.definitions.deinit(self.allocator);
    }

    pub fn clone(self: *const Model) Allocator.Error!Model {
        var copy = Model{ .allocator = self.allocator, .node_ids_above = self.node_ids_above, .relationship_ids_above = self.relationship_ids_above };
        errdefer copy.deinit();
        for (self.nodes.keys(), self.nodes.values()) |id, node| try copy.nodes.put(self.allocator, id, try node.clone(self.allocator));
        for (self.relationships.keys(), self.relationships.values()) |id, relationship| {
            var copied = relationship;
            copied.properties = try relationship.properties.clone(self.allocator);
            try copy.relationships.put(self.allocator, id, copied);
        }
        try copy.definitions.appendSlice(self.allocator, self.definitions.items);
        return copy;
    }

    pub fn addNode(self: *Model, id: NodeId) Allocator.Error!void {
        try self.nodes.put(self.allocator, id, .{});
        self.node_ids_above = @max(self.node_ids_above, id + 1);
    }

    pub fn hasRelationships(self: *const Model, id: NodeId) bool {
        for (self.relationships.values()) |relationship| {
            if (relationship.src == id or relationship.dst == id) return true;
        }
        return false;
    }

    /// Removes node `id` and its relationships.
    pub fn deleteNode(self: *Model, id: NodeId) void {
        var i: usize = 0;
        while (i < self.relationships.count()) {
            const relationship = self.relationships.values()[i];
            if (relationship.src == id or relationship.dst == id) {
                self.deleteRelationshipAt(i);
            } else i += 1;
        }
        var node = (self.nodes.fetchSwapRemove(id) orelse return).value;
        node.deinit(self.allocator);
    }

    pub fn addRelationship(self: *Model, id: RelationshipId, relationship: Relationship) Allocator.Error!void {
        try self.relationships.put(self.allocator, id, relationship);
        self.relationship_ids_above = @max(self.relationship_ids_above, id + 1);
    }

    pub fn deleteRelationship(self: *Model, id: RelationshipId) void {
        self.deleteRelationshipAt(self.relationships.getIndex(id) orelse return);
    }

    fn deleteRelationshipAt(self: *Model, index: usize) void {
        self.relationships.values()[index].properties.deinit(self.allocator);
        self.relationships.swapRemoveAt(index);
    }

    pub fn findDefinition(self: *const Model, name: []const u8) ?usize {
        for (self.definitions.items, 0..) |definition, i| if (std.mem.eql(u8, definition.name, name)) return i;
        return null;
    }

    /// The constraint node `id` would break with these labels and
    /// properties, if any.
    pub fn violation(self: *const Model, scratch: Allocator, id: NodeId, labels: anytype, properties: Properties) Allocator.Error!?[]const u8 {
        for (self.definitions.items) |definition| {
            if (definition.kind != .unique or !labels.contains(definition.labels_or_types[0])) continue;
            const values = try uniqueKey(scratch, definition, properties) orelse continue;
            for (self.nodes.keys(), self.nodes.values()) |other_id, other| {
                if (other_id == id or !other.labels.contains(definition.labels_or_types[0])) continue;
                const other_values = try uniqueKey(scratch, definition, other.properties) orelse continue;
                if (std.mem.eql(u8, values, other_values)) return definition.name;
            }
        }
        return null;
    }

    /// True if two nodes already break `definition` (a constraint about to
    /// be created).
    pub fn broken(self: *const Model, scratch: Allocator, definition: Definition) Allocator.Error!bool {
        var seen = std.StringHashMapUnmanaged(void).empty;
        for (self.nodes.values()) |node| {
            if (!node.labels.contains(definition.labels_or_types[0])) continue;
            const values = try uniqueKey(scratch, definition, node.properties) orelse continue;
            if ((try seen.getOrPut(scratch, values)).found_existing) return true;
        }
        return false;
    }

    pub fn labelCount(self: *const Model, label: []const u8) usize {
        var count: usize = 0;
        for (self.nodes.values()) |node| count += @intFromBool(node.labels.contains(label));
        return count;
    }

    pub fn typeCount(self: *const Model, edge_type: []const u8) usize {
        var count: usize = 0;
        for (self.relationships.values()) |relationship| count += @intFromBool(std.mem.eql(u8, relationship.edge_type, edge_type));
        return count;
    }
};

/// The constraint's values as compared: their index encodings (1 and 1.0
/// alike), or null if a property is missing.
fn uniqueKey(scratch: Allocator, definition: Definition, properties: Properties) Allocator.Error!?[]const u8 {
    var key = std.ArrayList(u8).empty;
    for (definition.properties) |property| {
        try value_encoding.encodeIndexValue(&key, scratch, properties.get(property) orelse return null);
    }
    return key.items;
}
