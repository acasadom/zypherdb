//! Key encoding: how graph data is laid out as keys of the key-value store.
//!
//! Keys are byte strings laid out so that "give me the neighbours of node X"
//! is a single prefix scan. Every key starts with a one-byte marker naming
//! its kind.
//!
//! Key layout (all integers big-endian, fixed width):
//!
//! Node records (a node's labels and properties, see node_record.zig) and
//! relationship records (`src | dst | edge_type`) are not here: each lives
//! in a table of its own, keyed by the id as an integer (see
//! key_value_store.zig).
//! - edge (per direction):   `e | node_id | dir | 0x00 | edge_type | 0x00 | neighbour_id | relationship_id`
//!
//! `node_id` and `relationship_id` are fixed-width u64s, so lexicographic
//! byte order equals numeric order and no id is ever a prefix of another.
//! `dir` is a single byte (`'o'`/`'i'`), and `edge_type` is a string
//! delimited by `0x00` (edge types are identifiers, so they never contain
//! `0x00`). Each relationship has an id of its own, so two relationships of
//! one type between the same nodes (parallel ones) are two keys.
//!
//! The markers below list the remaining kinds (labels, property and edge
//! indexes, edge-type counters).

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = @import("../value.zig").Value;
const encodeIndexValue = @import("value_encoding.zig").encodeIndexValue;

/// Node identifiers are fixed-width u64.
pub const NodeId = u64;

/// Relationship identifiers are fixed-width u64, counted apart from nodes.
pub const RelationshipId = u64;

/// Traversal direction relative to the node a key is stored under.
pub const Direction = enum(u8) {
    out = 'o',
    in = 'i',
};

/// Decoded fields of an edge key. `edge_type` is a view into the key and is only
/// valid while the key itself is alive.
pub const EdgeKey = struct {
    id: NodeId,
    direction: Direction,
    edge_type: []const u8,
    neighbour: NodeId,
    relationship: RelationshipId,
    /// The neighbour's labels, as stored with the key (a record's label
    /// section), or null if the key does not carry them.
    neighbour_labels: ?[]const u8 = null,
};

pub const edge_marker: u8 = 'e';
pub const label_marker: u8 = 'l';
pub const index_marker: u8 = 'p';
pub const edge_property_marker: u8 = 'f';
pub const edge_index_marker: u8 = 'g';
pub const edge_type_marker: u8 = 't';
pub const label_count_marker: u8 = 'c';
pub const separator: u8 = 0x00;
pub const node_id_length: usize = @sizeOf(NodeId);

/// Key storing the next node id to allocate (8-byte big-endian counter).
pub const counter_key: []const u8 = "!";
/// Key storing the next relationship id to allocate (8-byte big-endian counter).
pub const relationship_counter_key: []const u8 = "!relationships";
/// The storage format's version (see `Graph.checkFormat`).
pub const format_key: []const u8 = "!format";

// ---------------------------------------------------------------------------
// Key encoding
// ---------------------------------------------------------------------------

pub fn appendNodeId(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId) !void {
    var buffer: [node_id_length]u8 = undefined;
    std.mem.writeInt(NodeId, &buffer, id, .big);
    try list.appendSlice(allocator, &buffer);
}

pub fn readNodeId(bytes: []const u8) NodeId {
    std.debug.assert(bytes.len == node_id_length);
    return std.mem.readInt(NodeId, @ptrCast(bytes.ptr), .big);
}

/// Appends the key for a label-index entry: `l | label | 0x00 | node_id`.
pub fn appendLabelKey(list: *std.ArrayList(u8), allocator: Allocator, label: []const u8, id: NodeId) !void {
    try list.append(allocator, label_marker);
    try list.appendSlice(allocator, label);
    try list.append(allocator, separator);
    try appendNodeId(list, allocator, id);
}

/// Appends the key for a property-index entry:
/// `p | property | 0x00 | value | node_id`.
pub fn appendIndexKey(list: *std.ArrayList(u8), allocator: Allocator, property: []const u8, value: Value, id: NodeId) !void {
    try appendIndexPrefix(list, allocator, property, value);
    try appendNodeId(list, allocator, id);
}

/// Appends the lookup prefix for "prop == value": `p | property | 0x00 | value`.
pub fn appendIndexPrefix(list: *std.ArrayList(u8), allocator: Allocator, property: []const u8, value: Value) !void {
    try list.append(allocator, index_marker);
    try list.appendSlice(allocator, property);
    try list.append(allocator, separator);
    try encodeIndexValue(list, allocator, value);
}

/// Appends a relationship's record: `src | dst | edge_type`.
pub fn appendRelationshipRecord(list: *std.ArrayList(u8), allocator: Allocator, src: NodeId, dst: NodeId, edge_type: []const u8) !void {
    try appendNodeId(list, allocator, src);
    try appendNodeId(list, allocator, dst);
    try list.appendSlice(allocator, edge_type);
}

/// The fields of a relationship's record (`edge_type` is a view into it).
pub const RelationshipRecord = struct { src: NodeId, dst: NodeId, edge_type: []const u8 };

pub fn decodeRelationshipRecord(record: []const u8) RelationshipRecord {
    return .{ .src = readNodeId(record[0..node_id_length]), .dst = readNodeId(record[node_id_length .. 2 * node_id_length]), .edge_type = record[2 * node_id_length ..] };
}

/// Appends the key for a relationship property: `f | relationship_id | property`.
pub fn appendEdgePropertyKey(list: *std.ArrayList(u8), allocator: Allocator, relationship: RelationshipId, property: []const u8) !void {
    try appendEdgePropertyPrefix(list, allocator, relationship);
    try list.appendSlice(allocator, property);
}

/// Appends the prefix of all properties of a relationship: `f | relationship_id`.
pub fn appendEdgePropertyPrefix(list: *std.ArrayList(u8), allocator: Allocator, relationship: RelationshipId) !void {
    try list.append(allocator, edge_property_marker);
    try appendNodeId(list, allocator, relationship);
}

/// Appends the shared prefix of all edge keys for `(id, direction, edge_type)`, up to
/// and including the trailing `0x00` before the neighbour id.
pub fn appendEdgePrefix(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, direction: Direction, edge_type: []const u8) !void {
    try list.append(allocator, edge_marker);
    try appendNodeId(list, allocator, id);
    try list.append(allocator, @backingInt(direction));
    try list.append(allocator, separator);
    try list.appendSlice(allocator, edge_type);
    try list.append(allocator, separator);
}

/// Appends the lookup prefix for "edge prop == value":
/// `g | property | 0x00 | value`.
pub fn appendEdgeIndexPrefix(list: *std.ArrayList(u8), allocator: Allocator, property: []const u8, value: Value) !void {
    try list.append(allocator, edge_index_marker);
    try list.appendSlice(allocator, property);
    try list.append(allocator, separator);
    try encodeIndexValue(list, allocator, value);
}

/// Appends the edge-property index key:
/// `g | property | 0x00 | value | relationship_id`.
pub fn appendEdgeIndexKey(list: *std.ArrayList(u8), allocator: Allocator, property: []const u8, value: Value, relationship: RelationshipId) !void {
    try appendEdgeIndexPrefix(list, allocator, property, value);
    try appendNodeId(list, allocator, relationship);
}

/// Appends the prefix of the edge keys of `(id, direction, edge_type)` to one
/// neighbour: the relationships of that type between the two nodes.
pub fn appendEdgeBetweenPrefix(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, direction: Direction, edge_type: []const u8, neighbour: NodeId) !void {
    try appendEdgePrefix(list, allocator, id, direction, edge_type);
    try appendNodeId(list, allocator, neighbour);
}

/// Appends the key for one stored direction of an edge:
/// `e | node_id | dir | 0x00 | edge_type | 0x00 | neighbour_id | relationship_id`.
pub fn appendEdgeKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, direction: Direction, edge_type: []const u8, neighbour: NodeId, relationship: RelationshipId) !void {
    try appendEdgeBetweenPrefix(list, allocator, id, direction, edge_type, neighbour);
    try appendNodeId(list, allocator, relationship);
}

/// Decodes an edge key produced by `appendEdgeKey`.
pub fn decodeEdgeKey(key: []const u8) EdgeKey {
    std.debug.assert(key[0] == edge_marker);
    const id = readNodeId(key[1 .. 1 + node_id_length]);
    const direction: Direction = @fromBackingInt(@intCast(key[1 + node_id_length]));
    const edge_type_start = 1 + node_id_length + 1 + 1; // after marker + id + dir + separator
    std.debug.assert(key[edge_type_start - 1] == separator);
    const edge_type_length = std.mem.indexOfScalar(u8, key[edge_type_start..], separator) orelse unreachable;
    const edge_type = key[edge_type_start .. edge_type_start + edge_type_length];
    const neighbour_start = edge_type_start + edge_type_length + 1;
    const neighbour = readNodeId(key[neighbour_start .. neighbour_start + node_id_length]);
    const relationship = readNodeId(key[neighbour_start + node_id_length .. neighbour_start + 2 * node_id_length]);
    return .{ .id = id, .direction = direction, .edge_type = edge_type, .neighbour = neighbour, .relationship = relationship };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "edge key encodes and decodes round-trip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);

    try appendEdgeKey(&list, testing.allocator, 0x1234_5678_9abc_def0, .out, "ACTED_IN", 42, 7);

    const decoded = decodeEdgeKey(list.items);
    try testing.expectEqual(@as(NodeId, 0x1234_5678_9abc_def0), decoded.id);
    try testing.expectEqual(Direction.out, decoded.direction);
    try testing.expectEqualStrings("ACTED_IN", decoded.edge_type);
    try testing.expectEqual(@as(NodeId, 42), decoded.neighbour);
    try testing.expectEqual(@as(RelationshipId, 7), decoded.relationship);
}
