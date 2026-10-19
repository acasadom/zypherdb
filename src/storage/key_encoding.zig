//! Key encoding: how graph data is laid out as LMDB keys.
//!
//! Keys are byte strings laid out so that "give me the neighbours of node X"
//! is a single prefix scan. Every key starts with a one-byte marker naming
//! its kind.
//!
//! Key layout (all integers big-endian, fixed width):
//!
//! - node marker:            `n | node_id`
//! - node property:          `n | node_id | 0x00 | property_name`
//! - edge (per direction):   `e | node_id | dir | 0x00 | edge_type | 0x00 | neighbour_id`
//!
//! `node_id` is a fixed-width u64, so lexicographic byte order equals numeric
//! order and no id is ever a prefix of another. `dir` is a single byte
//! (`'o'`/`'i'`), and `edge_type` is a string delimited by `0x00` (edge types
//! are identifiers, so they never contain `0x00`).
//!
//! The markers below list the remaining kinds (labels, property and edge
//! indexes, edge-type counters).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Node identifiers are fixed-width u64.
pub const NodeId = u64;

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
};

pub const node_marker: u8 = 'n';
pub const edge_marker: u8 = 'e';
pub const label_marker: u8 = 'l';
pub const reverse_label_marker: u8 = 'L';
pub const index_marker: u8 = 'p';
pub const edge_property_marker: u8 = 'f';
pub const edge_index_marker: u8 = 'g';
pub const edge_type_marker: u8 = 't';
pub const separator: u8 = 0x00;
pub const node_id_length: usize = @sizeOf(NodeId);

/// Key storing the next node id to allocate (8-byte big-endian counter).
pub const counter_key: []const u8 = "!";

// ---------------------------------------------------------------------------
// Value encoding (property values)
// ---------------------------------------------------------------------------

pub const Value = @import("../value.zig").Value;

pub const value_tag_int: u8 = 0x01;
pub const value_tag_string: u8 = 0x02;
pub const value_tag_boolean: u8 = 0x03;
/// Index-lookup tag for a value that is never stored (`null`, a list): no
/// index entry carries it, so a lookup by such a value finds nothing.
pub const value_tag_never_stored: u8 = 0xff;

/// True if `value` can be stored as a property: `int`, `string` or
/// `boolean`. (`null` is never stored: setting a property to null removes it.)
pub fn isStorable(value: Value) bool {
    return switch (value) {
        .int, .string, .boolean => true,
        .null, .list, .node, .relationship, .map => false,
    };
}

/// Appends the storage encoding of `value`: `tag | payload`.
pub fn encodeValue(list: *std.ArrayList(u8), allocator: Allocator, value: Value) !void {
    switch (value) {
        .int => |v| {
            try list.append(allocator, value_tag_int);
            var buffer: [8]u8 = undefined;
            std.mem.writeInt(i64, &buffer, v, .big);
            try list.appendSlice(allocator, &buffer);
        },
        .string => |s| {
            try list.append(allocator, value_tag_string);
            try list.appendSlice(allocator, s);
        },
        .boolean => |b| try list.appendSlice(allocator, &.{ value_tag_boolean, @intFromBool(b) }),
        .null, .list, .node, .relationship, .map => unreachable, // callers check `isStorable` first
    }
}

/// Decodes a stored value, returning a `Value` whose `string` variant is an
/// owned copy allocated with `allocator` (free it, or use an arena).
pub fn decodeOwnedValue(raw: []const u8, allocator: Allocator) !Value {
    return switch (raw[0]) {
        value_tag_string => .{ .string = try allocator.dupe(u8, raw[1..]) },
        else => decodeValue(raw),
    };
}

/// Decodes a stored value without copying; a `string` is a view into `raw`.
pub fn decodeValue(raw: []const u8) Value {
    return switch (raw[0]) {
        value_tag_int => .{ .int = std.mem.readInt(i64, @ptrCast(raw[1..9].ptr), .big) },
        value_tag_string => .{ .string = raw[1..] },
        value_tag_boolean => .{ .boolean = raw[1] != 0 },
        else => unreachable,
    };
}

/// Appends the property-index encoding of `value`: strings get a trailing
/// `0x00` so a lookup prefix for "X" cannot also match "XY"; ints are fixed
/// width and need no delimiter.
pub fn encodeIndexValue(list: *std.ArrayList(u8), allocator: Allocator, value: Value) !void {
    switch (value) {
        .int => |v| {
            try list.append(allocator, value_tag_int);
            var buffer: [8]u8 = undefined;
            std.mem.writeInt(i64, &buffer, v, .big);
            try list.appendSlice(allocator, &buffer);
        },
        .string => |s| {
            try list.append(allocator, value_tag_string);
            try list.appendSlice(allocator, s);
            try list.append(allocator, separator);
        },
        .boolean => |b| try list.appendSlice(allocator, &.{ value_tag_boolean, @intFromBool(b) }),
        // Never stored, so never indexed: the lookup prefix matches no entry.
        .null, .list, .node, .relationship, .map => try list.append(allocator, value_tag_never_stored),
    }
}

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

/// Appends the key for a node existence marker: `n | node_id`.
pub fn appendNodeKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId) !void {
    try list.append(allocator, node_marker);
    try appendNodeId(list, allocator, id);
}

/// Appends the key for a node property: `n | node_id | 0x00 | property_name`.
pub fn appendNodePropertyKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, property: []const u8) !void {
    try appendNodeKey(list, allocator, id);
    try list.append(allocator, separator);
    try list.appendSlice(allocator, property);
}

/// Appends the key for a label-index entry: `l | label | 0x00 | node_id`.
pub fn appendLabelKey(list: *std.ArrayList(u8), allocator: Allocator, label: []const u8, id: NodeId) !void {
    try list.append(allocator, label_marker);
    try list.appendSlice(allocator, label);
    try list.append(allocator, separator);
    try appendNodeId(list, allocator, id);
}

/// Appends the key for a reverse label-index entry: `L | node_id | 0x00 | label`
/// (so a node's labels can be enumerated on delete).
pub fn appendReverseLabelKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, label: []const u8) !void {
    try list.append(allocator, reverse_label_marker);
    try appendNodeId(list, allocator, id);
    try list.append(allocator, separator);
    try list.appendSlice(allocator, label);
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

/// Appends the key for an edge property (canonical `src -> dst` orientation):
/// `f | src | dst | 0x00 | edge_type | 0x00 | property`.
pub fn appendEdgePropertyKey(list: *std.ArrayList(u8), allocator: Allocator, src: NodeId, dst: NodeId, edge_type: []const u8, property: []const u8) !void {
    try appendEdgePropertyPrefix(list, allocator, src, dst, edge_type);
    try list.appendSlice(allocator, property);
}

/// Appends the prefix of all properties of an edge: `f | src | dst | 0x00 | edge_type | 0x00`.
pub fn appendEdgePropertyPrefix(list: *std.ArrayList(u8), allocator: Allocator, src: NodeId, dst: NodeId, edge_type: []const u8) !void {
    try list.append(allocator, edge_property_marker);
    try appendNodeId(list, allocator, src);
    try appendNodeId(list, allocator, dst);
    try list.append(allocator, separator);
    try list.appendSlice(allocator, edge_type);
    try list.append(allocator, separator);
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
/// `g | property | 0x00 | value | src | dst | 0x00 | edge_type`.
pub fn appendEdgeIndexKey(list: *std.ArrayList(u8), allocator: Allocator, property: []const u8, value: Value, src: NodeId, dst: NodeId, edge_type: []const u8) !void {
    try appendEdgeIndexPrefix(list, allocator, property, value);
    try appendNodeId(list, allocator, src);
    try appendNodeId(list, allocator, dst);
    try list.append(allocator, separator);
    try list.appendSlice(allocator, edge_type);
}

/// Appends the key for one stored direction of an edge:
/// `e | node_id | dir | 0x00 | edge_type | 0x00 | neighbour_id`.
pub fn appendEdgeKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, direction: Direction, edge_type: []const u8, neighbour: NodeId) !void {
    try appendEdgePrefix(list, allocator, id, direction, edge_type);
    try appendNodeId(list, allocator, neighbour);
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
    return .{ .id = id, .direction = direction, .edge_type = edge_type, .neighbour = neighbour };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "edge key encodes and decodes round-trip" {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(testing.allocator);

    try appendEdgeKey(&list, testing.allocator, 0x1234_5678_9abc_def0, .out, "ACTED_IN", 42);

    const decoded = decodeEdgeKey(list.items);
    try testing.expectEqual(@as(NodeId, 0x1234_5678_9abc_def0), decoded.id);
    try testing.expectEqual(Direction.out, decoded.direction);
    try testing.expectEqualStrings("ACTED_IN", decoded.edge_type);
    try testing.expectEqual(@as(NodeId, 42), decoded.neighbour);
}
