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
const sep: u8 = 0x00;
const id_len: usize = @sizeOf(NodeId);

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

    /// Marks `id` as an existing node. Idempotent.
    pub fn addNode(self: *Graph, id: NodeId) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodeKey(&key, self.allocator, id);
        try self.store.put(key.items, "");
    }

    pub fn hasNode(self: *Graph, id: NodeId) KvError!bool {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodeKey(&key, self.allocator, id);
        return self.store.exists(key.items);
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
    pub fn neighbours(self: *Graph, id: NodeId, dir: Direction, etype: []const u8) KvError!NeighbourIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try appendEdgePrefix(&prefix, self.allocator, id, dir, etype);
        const it = try self.store.scanPrefix(prefix.items);
        return .{ .inner = it };
    }
};

/// Iterator over neighbour ids from a `Graph.neighbours` scan. Owns the
/// underlying LMDB transaction/cursor; `deinit` releases them.
pub const NeighbourIterator = struct {
    inner: PrefixIterator,

    pub fn deinit(self: *NeighbourIterator) void {
        self.inner.deinit();
    }

    /// Returns the next neighbour id, or `null` at the end.
    pub fn next(self: *NeighbourIterator) KvError!?NodeId {
        const entry = try self.inner.next() orelse return null;
        return readNodeId(entry.key[entry.key.len - id_len ..]);
    }
};

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

    try g.addNode(keanu);
    try g.addNode(lana);
    try g.addNode(matrix);
    try g.addNode(reloaded);
    try g.addNode(wick);

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
    try g.addNode(7);
    try testing.expect(try g.hasNode(7));
    try testing.expect(!try g.hasNode(8));
}
