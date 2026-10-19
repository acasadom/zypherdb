//! Key encoding: how graph data is laid out as LMDB keys.
//!
//! Keys are byte strings laid out so that "give me the neighbours of node X"
//! is a single prefix scan. Every key starts with a one-byte marker naming
//! its kind.
//!
//! Key layout (all integers big-endian, fixed width):
//!
//! - node marker:            `n | node_id`
//! - node property:          `n | node_id | 0x00 | prop_name`
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

/// Decoded fields of an edge key. `etype` is a view into the key and is only
/// valid while the key itself is alive.
pub const EdgeKey = struct {
    id: NodeId,
    dir: Direction,
    etype: []const u8,
    neighbour: NodeId,
};

pub const node_marker: u8 = 'n';
pub const edge_marker: u8 = 'e';
pub const label_marker: u8 = 'l';
pub const rev_label_marker: u8 = 'L';
pub const index_marker: u8 = 'p';
pub const edge_prop_marker: u8 = 'f';
pub const edge_index_marker: u8 = 'g';
pub const edge_type_marker: u8 = 't';
pub const sep: u8 = 0x00;
pub const id_len: usize = @sizeOf(NodeId);

/// Key storing the next node id to allocate (8-byte big-endian counter).
pub const counter_key: []const u8 = "!";

// ---------------------------------------------------------------------------
// Value encoding (property values)
// ---------------------------------------------------------------------------

pub const Value = @import("../value.zig").Value;

pub const value_int: u8 = 0x01;
pub const value_str: u8 = 0x02;

/// Appends the storage encoding of `value`: `tag | payload`.
pub fn encodeValue(list: *std.ArrayList(u8), allocator: Allocator, value: Value) !void {
    switch (value) {
        .int => |v| {
            try list.append(allocator, value_int);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, v, .big);
            try list.appendSlice(allocator, &buf);
        },
        .str => |s| {
            try list.append(allocator, value_str);
            try list.appendSlice(allocator, s);
        },
        .boolean, .null, .list => unreachable, // not stored as properties
    }
}

/// Decodes a stored value, returning a `Value` whose `str` variant is an owned
/// copy allocated with `allocator` (free it, or use an arena).
pub fn decodeOwnedValue(raw: []const u8, allocator: Allocator) !Value {
    return switch (raw[0]) {
        value_int => .{ .int = std.mem.readInt(i64, @ptrCast(raw[1..9].ptr), .big) },
        value_str => .{ .str = try allocator.dupe(u8, raw[1..]) },
        else => unreachable,
    };
}

/// Decodes a stored value without copying; `str` is a view into `raw`.
pub fn decodeValue(raw: []const u8) Value {
    return switch (raw[0]) {
        value_int => .{ .int = std.mem.readInt(i64, @ptrCast(raw[1..9].ptr), .big) },
        value_str => .{ .str = raw[1..] },
        else => unreachable,
    };
}

/// Appends the property-index encoding of `value`: strings get a trailing
/// `0x00` so a lookup prefix for "X" cannot also match "XY"; ints are fixed
/// width and need no delimiter.
pub fn encodeIndexValue(list: *std.ArrayList(u8), allocator: Allocator, value: Value) !void {
    switch (value) {
        .int => |v| {
            try list.append(allocator, value_int);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(i64, &buf, v, .big);
            try list.appendSlice(allocator, &buf);
        },
        .str => |s| {
            try list.append(allocator, value_str);
            try list.appendSlice(allocator, s);
            try list.append(allocator, sep);
        },
        .boolean, .null, .list => unreachable, // not stored as properties
    }
}

// ---------------------------------------------------------------------------
// Key encoding
// ---------------------------------------------------------------------------

pub fn appendNodeId(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId) !void {
    var buf: [id_len]u8 = undefined;
    std.mem.writeInt(NodeId, &buf, id, .big);
    try list.appendSlice(allocator, &buf);
}

pub fn readNodeId(bytes: []const u8) NodeId {
    std.debug.assert(bytes.len == id_len);
    return std.mem.readInt(NodeId, @ptrCast(bytes.ptr), .big);
}

/// Appends the key for a node existence marker: `n | node_id`.
pub fn appendNodeKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId) !void {
    try list.append(allocator, node_marker);
    try appendNodeId(list, allocator, id);
}

/// Appends the key for a node property: `n | node_id | 0x00 | prop_name`.
pub fn appendNodePropKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, prop: []const u8) !void {
    try appendNodeKey(list, allocator, id);
    try list.append(allocator, sep);
    try list.appendSlice(allocator, prop);
}

/// Appends the key for a label-index entry: `l | label | 0x00 | node_id`.
pub fn appendLabelKey(list: *std.ArrayList(u8), allocator: Allocator, label: []const u8, id: NodeId) !void {
    try list.append(allocator, label_marker);
    try list.appendSlice(allocator, label);
    try list.append(allocator, sep);
    try appendNodeId(list, allocator, id);
}

/// Appends the key for a reverse label-index entry: `L | node_id | 0x00 | label`
/// (so a node's labels can be enumerated on delete).
pub fn appendReverseLabelKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, label: []const u8) !void {
    try list.append(allocator, rev_label_marker);
    try appendNodeId(list, allocator, id);
    try list.append(allocator, sep);
    try list.appendSlice(allocator, label);
}

/// Appends the key for a property-index entry:
/// `p | prop | 0x00 | value | node_id`.
pub fn appendIndexKey(list: *std.ArrayList(u8), allocator: Allocator, prop: []const u8, value: Value, id: NodeId) !void {
    try appendIndexPrefix(list, allocator, prop, value);
    try appendNodeId(list, allocator, id);
}

/// Appends the lookup prefix for "prop == value": `p | prop | 0x00 | value`.
pub fn appendIndexPrefix(list: *std.ArrayList(u8), allocator: Allocator, prop: []const u8, value: Value) !void {
    try list.append(allocator, index_marker);
    try list.appendSlice(allocator, prop);
    try list.append(allocator, sep);
    try encodeIndexValue(list, allocator, value);
}

/// Appends the key for an edge property (canonical `src -> dst` orientation):
/// `f | src | dst | 0x00 | edge_type | 0x00 | prop`.
pub fn appendEdgePropKey(list: *std.ArrayList(u8), allocator: Allocator, src: NodeId, dst: NodeId, etype: []const u8, prop: []const u8) !void {
    try appendEdgePropPrefix(list, allocator, src, dst, etype);
    try list.appendSlice(allocator, prop);
}

/// Appends the prefix of all properties of an edge: `f | src | dst | 0x00 | edge_type | 0x00`.
pub fn appendEdgePropPrefix(list: *std.ArrayList(u8), allocator: Allocator, src: NodeId, dst: NodeId, etype: []const u8) !void {
    try list.append(allocator, edge_prop_marker);
    try appendNodeId(list, allocator, src);
    try appendNodeId(list, allocator, dst);
    try list.append(allocator, sep);
    try list.appendSlice(allocator, etype);
    try list.append(allocator, sep);
}

/// Appends the shared prefix of all edge keys for `(id, dir, etype)`, up to
/// and including the trailing `0x00` before the neighbour id.
pub fn appendEdgePrefix(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, dir: Direction, etype: []const u8) !void {
    try list.append(allocator, edge_marker);
    try appendNodeId(list, allocator, id);
    try list.append(allocator, @backingInt(dir));
    try list.append(allocator, sep);
    try list.appendSlice(allocator, etype);
    try list.append(allocator, sep);
}

/// Appends the lookup prefix for "edge prop == value":
/// `g | prop | 0x00 | value`.
pub fn appendEdgeIndexPrefix(list: *std.ArrayList(u8), allocator: Allocator, prop: []const u8, value: Value) !void {
    try list.append(allocator, edge_index_marker);
    try list.appendSlice(allocator, prop);
    try list.append(allocator, sep);
    try encodeIndexValue(list, allocator, value);
}

/// Appends the edge-property index key:
/// `g | prop | 0x00 | value | src | dst | 0x00 | edge_type`.
pub fn appendEdgeIndexKey(list: *std.ArrayList(u8), allocator: Allocator, prop: []const u8, value: Value, src: NodeId, dst: NodeId, etype: []const u8) !void {
    try appendEdgeIndexPrefix(list, allocator, prop, value);
    try appendNodeId(list, allocator, src);
    try appendNodeId(list, allocator, dst);
    try list.append(allocator, sep);
    try list.appendSlice(allocator, etype);
}

/// Appends the key for one stored direction of an edge:
/// `e | node_id | dir | 0x00 | edge_type | 0x00 | neighbour_id`.
pub fn appendEdgeKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, dir: Direction, etype: []const u8, neighbour: NodeId) !void {
    try appendEdgePrefix(list, allocator, id, dir, etype);
    try appendNodeId(list, allocator, neighbour);
}

/// Decodes an edge key produced by `appendEdgeKey`.
pub fn decodeEdgeKey(key: []const u8) EdgeKey {
    std.debug.assert(key[0] == edge_marker);
    const id = readNodeId(key[1 .. 1 + id_len]);
    const dir: Direction = @fromBackingInt(@intCast(key[1 + id_len]));
    const etype_start = 1 + id_len + 1 + 1; // after marker + id + dir + sep
    std.debug.assert(key[etype_start - 1] == sep);
    const etype_len = std.mem.indexOfScalar(u8, key[etype_start..], sep) orelse unreachable;
    const etype = key[etype_start .. etype_start + etype_len];
    const neighbour_start = etype_start + etype_len + 1;
    const neighbour = readNodeId(key[neighbour_start .. neighbour_start + id_len]);
    return .{ .id = id, .dir = dir, .etype = etype, .neighbour = neighbour };
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
    try testing.expectEqual(Direction.out, decoded.dir);
    try testing.expectEqualStrings("ACTED_IN", decoded.etype);
    try testing.expectEqual(@as(NodeId, 42), decoded.neighbour);
}
