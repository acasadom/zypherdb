//! Graph key encoding and a minimal index-free adjacency layer over `KvStore`.
//!
//! Keys are byte strings laid out so that "give me the neighbours of node X"
//! is a single LMDB prefix scan (index-free adjacency, IFA). Each directed,
//! typed edge is stored twice — once keyed by its source (outgoing) and once
//! by its target (incoming) — so both directions are O(1) prefix scans.
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

const std = @import("std");

const KvStore = @import("kv_store.zig").KvStore;
const KvError = @import("kv_store.zig").KvError;
const PrefixIterator = @import("kv_store.zig").PrefixIterator;

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

const node_marker: u8 = 'n';
const edge_marker: u8 = 'e';
const label_marker: u8 = 'l';
const sep: u8 = 0x00;
const id_len: usize = @sizeOf(NodeId);

// ---------------------------------------------------------------------------
// Value encoding (property values)
// ---------------------------------------------------------------------------

/// A typed property/expression value. `boolean` is produced during evaluation
/// but is never stored as a property (properties are `int` or `str`).
pub const Value = union(enum) {
    int: i64,
    str: []const u8,
    boolean: bool,
};

const value_int: u8 = 0x01;
const value_str: u8 = 0x02;

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
        .boolean => unreachable, // booleans are not stored as properties
    }
}

/// Decodes a stored value, returning a `Value` whose `str` variant is an owned
/// copy allocated with `allocator` (free it, or use an arena).
fn decodeOwnedValue(raw: []const u8, allocator: Allocator) !Value {
    return switch (raw[0]) {
        value_int => .{ .int = std.mem.readInt(i64, @ptrCast(raw[1..9].ptr), .big) },
        value_str => .{ .str = try allocator.dupe(u8, raw[1..]) },
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// Key encoding
// ---------------------------------------------------------------------------

fn appendNodeId(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId) !void {
    var buf: [id_len]u8 = undefined;
    std.mem.writeInt(NodeId, &buf, id, .big);
    try list.appendSlice(allocator, &buf);
}

fn readNodeId(bytes: []const u8) NodeId {
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

/// Appends the shared prefix of all edge keys for `(id, dir, etype)`, up to
/// and including the trailing `0x00` before the neighbour id.
fn appendEdgePrefix(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, dir: Direction, etype: []const u8) !void {
    try list.append(allocator, edge_marker);
    try appendNodeId(list, allocator, id);
    try list.append(allocator, @backingInt(dir));
    try list.append(allocator, sep);
    try list.appendSlice(allocator, etype);
    try list.append(allocator, sep);
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
// Graph (index-free adjacency over KvStore)
// ---------------------------------------------------------------------------

/// Thin graph view over a `KvStore`, implementing index-free adjacency:
/// `addEdge` writes both directions, `neighbours` is a single prefix scan.
pub const Graph = struct {
    store: *KvStore,
    allocator: Allocator,

    pub fn init(store: *KvStore, allocator: Allocator) Graph {
        return .{ .store = store, .allocator = allocator };
    }

    /// Marks `id` as an existing node with the given `label` (empty string for
    /// an unlabeled node). Idempotent. A non-empty label also writes a
    /// label-index entry so `nodesWithLabel` can find it.
    pub fn addNode(self: *Graph, id: NodeId, label: []const u8) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodeKey(&key, self.allocator, id);
        try self.store.put(key.items, "");

        if (label.len > 0) {
            key.clearRetainingCapacity();
            try appendLabelKey(&key, self.allocator, label, id);
            try self.store.put(key.items, "");
        }
    }

    pub fn hasNode(self: *Graph, id: NodeId) KvError!bool {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodeKey(&key, self.allocator, id);
        return self.store.exists(key.items);
    }

    pub fn hasLabel(self: *Graph, id: NodeId, label: []const u8) KvError!bool {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendLabelKey(&key, self.allocator, label, id);
        return self.store.exists(key.items);
    }

    /// Stores a typed property `name` on node `id`. Idempotent.
    pub fn setProp(self: *Graph, id: NodeId, name: []const u8, value: Value) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodePropKey(&key, self.allocator, id, name);

        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(self.allocator);
        try encodeValue(&encoded, self.allocator, value);

        try self.store.put(key.items, encoded.items);
    }

    /// Reads a typed property `name` of node `id`, or `null` if absent. The
    /// `str` variant is an owned copy allocated with `allocator`.
    pub fn getProp(self: *Graph, id: NodeId, name: []const u8, allocator: Allocator) KvError!?Value {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodePropKey(&key, self.allocator, id, name);
        const raw = (try self.store.get(key.items)) orelse return null;
        defer self.store.allocator.free(raw);
        return try decodeOwnedValue(raw, allocator);
    }

    /// Adds a directed, typed edge, storing both directions. Idempotent.
    pub fn addEdge(self: *Graph, src: NodeId, dst: NodeId, etype: []const u8) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);

        try appendEdgeKey(&key, self.allocator, src, .out, etype, dst);
        try self.store.put(key.items, "");

        key.clearRetainingCapacity();
        try appendEdgeKey(&key, self.allocator, dst, .in, etype, src);
        try self.store.put(key.items, "");
    }

    /// Iterates the neighbours of `id` in the given `dir` and `etype`, in
    /// ascending neighbour-id order (LMDB's lexicographic order).
    pub fn neighbours(self: *Graph, id: NodeId, dir: Direction, etype: []const u8) KvError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try appendEdgePrefix(&prefix, self.allocator, id, dir, etype);
        const it = try self.store.scanPrefix(prefix.items);
        return .{ .inner = it };
    }

    /// Iterates all nodes carrying `label`, in ascending node-id order.
    pub fn nodesWithLabel(self: *Graph, label: []const u8) KvError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try prefix.append(self.allocator, label_marker);
        try prefix.appendSlice(self.allocator, label);
        try prefix.append(self.allocator, sep);
        const it = try self.store.scanPrefix(prefix.items);
        return .{ .inner = it };
    }

    /// Number of nodes carrying `label`.
    pub fn labelCount(self: *Graph, label: []const u8) KvError!usize {
        var it = try self.nodesWithLabel(label);
        defer it.deinit();
        var count: usize = 0;
        while (try it.next()) |_| count += 1;
        return count;
    }
};

/// Iterator over node ids decoded from the trailing 8 bytes of scanned keys
/// (edge keys or label-index keys). Owns the underlying LMDB
/// transaction/cursor; `deinit` releases them.
pub const NodeIdIterator = struct {
    inner: PrefixIterator,

    pub fn deinit(self: *NodeIdIterator) void {
        self.inner.deinit();
    }

    /// Returns the next node id, or `null` at the end.
    pub fn next(self: *NodeIdIterator) KvError!?NodeId {
        const entry = try self.inner.next() orelse return null;
        return readNodeId(entry.key[entry.key.len - id_len ..]);
    }
};

/// Backward-compatible name for `NodeIdIterator` (neighbour scans).
pub const NeighbourIterator = NodeIdIterator;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testPath(tmp: *testing.TmpDir, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
}

fn openStore(tmp: *testing.TmpDir, buf: []u8) !KvStore {
    const path = testPath(tmp, buf);
    return KvStore.open(testing.allocator, path);
}

fn expectNext(it: *NeighbourIterator, expected: NodeId) !void {
    const got = try it.next();
    try testing.expect(got != null);
    try testing.expectEqual(expected, got.?);
}

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

test "neighbours scans outgoing, incoming and type-filtered edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    const keanu: NodeId = 1;
    const lana: NodeId = 2;
    const matrix: NodeId = 100;
    const reloaded: NodeId = 101;
    const wick: NodeId = 102;

    try g.addNode(keanu, "");
    try g.addNode(lana, "");
    try g.addNode(matrix, "");
    try g.addNode(reloaded, "");
    try g.addNode(wick, "");

    try g.addEdge(keanu, matrix, "ACTED_IN");
    try g.addEdge(keanu, reloaded, "ACTED_IN");
    try g.addEdge(keanu, wick, "ACTED_IN");
    try g.addEdge(lana, matrix, "DIRECTED");

    // Outgoing ACTED_IN of keanu, in ascending neighbour-id order.
    var it = try g.neighbours(keanu, .out, "ACTED_IN");
    defer it.deinit();
    try expectNext(&it, matrix);
    try expectNext(&it, reloaded);
    try expectNext(&it, wick);
    try testing.expect((try it.next()) == null);

    // Incoming ACTED_IN of matrix: only keanu.
    var it2 = try g.neighbours(matrix, .in, "ACTED_IN");
    defer it2.deinit();
    try expectNext(&it2, keanu);
    try testing.expect((try it2.next()) == null);

    // Incoming DIRECTED of matrix: only lana (type filter isolates it).
    var it3 = try g.neighbours(matrix, .in, "DIRECTED");
    defer it3.deinit();
    try expectNext(&it3, lana);
    try testing.expect((try it3.next()) == null);

    // A node with no edges of the requested type yields no neighbours.
    var it4 = try g.neighbours(lana, .in, "ACTED_IN");
    defer it4.deinit();
    try testing.expect((try it4.next()) == null);
}

test "addNode and hasNode track node existence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try testing.expect(!try g.hasNode(7));
    try g.addNode(7, "");
    try testing.expect(try g.hasNode(7));
    try testing.expect(!try g.hasNode(8));
}

test "labels, properties and value encoding" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "Person");
    try g.addNode(2, "Person");
    try g.addNode(100, "Movie");

    // label index
    var it = try g.nodesWithLabel("Person");
    defer it.deinit();
    try expectNext(&it, 1);
    try expectNext(&it, 2);
    try testing.expect((try it.next()) == null);

    try testing.expect(try g.hasLabel(100, "Movie"));
    try testing.expect(!try g.hasLabel(100, "Person"));

    // properties: string and int round-trip
    try g.setProp(1, "name", .{ .str = "Keanu Reeves" });
    try g.setProp(1, "born", .{ .int = 1964 });

    const name = (try g.getProp(1, "name", testing.allocator)).?;
    defer testing.allocator.free(name.str);
    try testing.expectEqualStrings("Keanu Reeves", name.str);

    const born = (try g.getProp(1, "born", testing.allocator)).?;
    try testing.expectEqual(@as(i64, 1964), born.int);

    // absent property -> null
    try testing.expect((try g.getProp(1, "nope", testing.allocator)) == null);
}
