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
const rev_label_marker: u8 = 'L';
const index_marker: u8 = 'p';
const edge_prop_marker: u8 = 'f';
const edge_index_marker: u8 = 'g';
const edge_type_marker: u8 = 't';
const sep: u8 = 0x00;
const id_len: usize = @sizeOf(NodeId);

/// Key storing the next node id to allocate (8-byte big-endian counter).
const counter_key: []const u8 = "!";

// ---------------------------------------------------------------------------
// Value encoding (property values)
// ---------------------------------------------------------------------------

/// A typed property/expression value. `boolean`, `null` and `list` are produced
/// during evaluation but are never stored as properties (properties are `int`
/// or `str`).
pub const Value = union(enum) {
    int: i64,
    str: []const u8,
    boolean: bool,
    null: void,
    list: []const Value,
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
        .boolean, .null, .list => unreachable, // not stored as properties
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

/// Decodes a stored value without copying; `str` is a view into `raw`.
fn decodeValue(raw: []const u8) Value {
    return switch (raw[0]) {
        value_int => .{ .int = std.mem.readInt(i64, @ptrCast(raw[1..9].ptr), .big) },
        value_str => .{ .str = raw[1..] },
        else => unreachable,
    };
}

/// Appends the property-index encoding of `value`: strings get a trailing
/// `0x00` so a lookup prefix for "X" cannot also match "XY"; ints are fixed
/// width and need no delimiter.
fn encodeIndexValue(list: *std.ArrayList(u8), allocator: Allocator, value: Value) !void {
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

/// Appends the key for a reverse label-index entry: `L | node_id | 0x00 | label`
/// (so a node's labels can be enumerated on delete).
fn appendReverseLabelKey(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, label: []const u8) !void {
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
fn appendEdgePrefix(list: *std.ArrayList(u8), allocator: Allocator, id: NodeId, dir: Direction, etype: []const u8) !void {
    try list.append(allocator, edge_marker);
    try appendNodeId(list, allocator, id);
    try list.append(allocator, @backingInt(dir));
    try list.append(allocator, sep);
    try list.appendSlice(allocator, etype);
    try list.append(allocator, sep);
}

/// Appends the lookup prefix for "edge prop == value":
/// `g | prop | 0x00 | value`.
fn appendEdgeIndexPrefix(list: *std.ArrayList(u8), allocator: Allocator, prop: []const u8, value: Value) !void {
    try list.append(allocator, edge_index_marker);
    try list.appendSlice(allocator, prop);
    try list.append(allocator, sep);
    try encodeIndexValue(list, allocator, value);
}

/// Appends the edge-property index key:
/// `g | prop | 0x00 | value | src | dst | 0x00 | edge_type`.
fn appendEdgeIndexKey(list: *std.ArrayList(u8), allocator: Allocator, prop: []const u8, value: Value, src: NodeId, dst: NodeId, etype: []const u8) !void {
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

    /// Begins an atomic write transaction; see `commitWrite`/`abortWrite`. All
    /// mutations until then are batched into one transaction.
    pub fn beginWrite(self: *Graph) KvError!void {
        return self.store.beginWrite();
    }

    pub fn commitWrite(self: *Graph) KvError!void {
        return self.store.commitWrite();
    }

    pub fn abortWrite(self: *Graph) void {
        self.store.abortWrite();
    }

    /// Begins an atomic read transaction (snapshot); see `commitRead`/`abortRead`.
    /// All reads until then are batched into one transaction.
    pub fn beginRead(self: *Graph) KvError!void {
        return self.store.beginRead();
    }

    pub fn commitRead(self: *Graph) void {
        self.store.commitRead();
    }

    pub fn abortRead(self: *Graph) void {
        self.store.abortRead();
    }

    /// Marks `id` as an existing node with the given `label` (empty string for
    /// an unlabeled node). Idempotent. A non-empty label also writes the label
    /// index entries so `nodesWithLabel` can find it.
    pub fn addNode(self: *Graph, id: NodeId, label: []const u8) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodeKey(&key, self.allocator, id);
        try self.store.put(key.items, "");

        if (label.len > 0) try self.addLabel(id, label);
    }

    /// Adds a label to a node (forward + reverse index). Idempotent.
    pub fn addLabel(self: *Graph, id: NodeId, label: []const u8) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendLabelKey(&key, self.allocator, label, id);
        try self.store.put(key.items, "");

        key.clearRetainingCapacity();
        try appendReverseLabelKey(&key, self.allocator, id, label);
        try self.store.put(key.items, "");
    }

    /// Removes a label from a node (forward + reverse index). Idempotent.
    pub fn removeLabel(self: *Graph, id: NodeId, label: []const u8) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendLabelKey(&key, self.allocator, label, id);
        try self.store.del(key.items);

        key.clearRetainingCapacity();
        try appendReverseLabelKey(&key, self.allocator, id, label);
        try self.store.del(key.items);
    }

    /// Allocates a fresh, never-used node id (persistent counter).
    pub fn allocNodeId(self: *Graph) KvError!NodeId {
        var next: NodeId = 0;
        const raw = try self.store.get(counter_key);
        if (raw) |r| {
            defer self.allocator.free(r);
            if (r.len == id_len) next = readNodeId(r);
        }
        var buf: [id_len]u8 = undefined;
        std.mem.writeInt(NodeId, &buf, next + 1, .big);
        try self.store.put(counter_key, &buf);
        return next;
    }

    /// Deletes a node; fails with `error.NodeStillConnected` if it still has
    /// relationships (use `deleteNodeDetach` to remove them too).
    pub fn deleteNode(self: *Graph, id: NodeId) KvError!void {
        if (try self.hasAnyEdge(id)) return error.NodeStillConnected;
        return self.deleteNodeOnly(id);
    }

    /// Deletes a node and detaches it: removes all its edges (both directions)
    /// and edge properties, its label-index entry, properties and marker.
    pub fn deleteNodeDetach(self: *Graph, id: NodeId) KvError!void {
        try self.deleteEdgesInDirection(id, .out);
        try self.deleteEdgesInDirection(id, .in);
        return self.deleteNodeOnly(id);
    }

    /// True if the node is the endpoint of at least one edge.
    pub fn hasAnyEdge(self: *Graph, id: NodeId) KvError!bool {
        var out_prefix = std.ArrayList(u8).empty;
        defer out_prefix.deinit(self.allocator);
        try out_prefix.append(self.allocator, edge_marker);
        try appendNodeId(&out_prefix, self.allocator, id);
        try out_prefix.append(self.allocator, @backingInt(Direction.out));
        if (try self.store.countPrefix(out_prefix.items) > 0) return true;

        var in_prefix = std.ArrayList(u8).empty;
        defer in_prefix.deinit(self.allocator);
        try in_prefix.append(self.allocator, edge_marker);
        try appendNodeId(&in_prefix, self.allocator, id);
        try in_prefix.append(self.allocator, @backingInt(Direction.in));
        return try self.store.countPrefix(in_prefix.items) > 0;
    }

    fn deleteNodeOnly(self: *Graph, id: NodeId) KvError!void {
        // Enumerate and remove all labels (forward + reverse index).
        var labels = std.ArrayList([]u8).empty;
        defer {
            for (labels.items) |l| self.allocator.free(l);
            labels.deinit(self.allocator);
        }
        var lprefix = std.ArrayList(u8).empty;
        defer lprefix.deinit(self.allocator);
        try lprefix.append(self.allocator, rev_label_marker);
        try appendNodeId(&lprefix, self.allocator, id);
        try lprefix.append(self.allocator, sep);
        var lit = try self.store.scanPrefix(lprefix.items);
        while (try lit.next()) |entry| {
            try labels.append(self.allocator, try self.allocator.dupe(u8, entry.key[lprefix.items.len ..]));
        }
        lit.deinit();
        for (labels.items) |label| try self.removeLabel(id, label);

        var nprefix = std.ArrayList(u8).empty;
        defer nprefix.deinit(self.allocator);
        try appendNodeKey(&nprefix, self.allocator, id);

        // Remove property-index entries before deleting the properties.
        var pprefix = std.ArrayList(u8).empty;
        defer pprefix.deinit(self.allocator);
        try appendNodePropKey(&pprefix, self.allocator, id, "");
        var pit = try self.store.scanPrefix(pprefix.items);
        defer pit.deinit();
        while (try pit.next()) |entry| {
            const prop_name = entry.key[1 + id_len + 1 ..];
            try self.deleteIndexEntry(id, prop_name, decodeValue(entry.value));
        }

        try self.deleteKeysUnder(nprefix.items);
    }

    fn deleteEdgesInDirection(self: *Graph, id: NodeId, dir: Direction) KvError!void {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try prefix.append(self.allocator, edge_marker);
        try appendNodeId(&prefix, self.allocator, id);
        try prefix.append(self.allocator, @backingInt(dir));

        var keys = std.ArrayList([]u8).empty;
        defer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }
        var it = try self.store.scanPrefix(prefix.items);
        defer it.deinit();
        while (try it.next()) |entry| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, entry.key));
        }

        for (keys.items) |k| {
            const ek = decodeEdgeKey(k);
            try self.store.del(k);

            const rev_dir: Direction = if (ek.dir == .out) .in else .out;
            var rev = std.ArrayList(u8).empty;
            defer rev.deinit(self.allocator);
            try appendEdgeKey(&rev, self.allocator, ek.neighbour, rev_dir, ek.etype, ek.id);
            try self.store.del(rev.items);

            // Delete the edge's properties and their index entries (canonical
            // src -> dst). Collect first so the cursor isn't open across deletes.
            const src = if (ek.dir == .out) ek.id else ek.neighbour;
            const dst = if (ek.dir == .out) ek.neighbour else ek.id;
            var epp = std.ArrayList(u8).empty;
            defer epp.deinit(self.allocator);
            try appendEdgePropPrefix(&epp, self.allocator, src, dst, ek.etype);

            var props = std.ArrayList(struct { name: []u8, value: []u8 }).empty;
            defer {
                for (props.items) |p| {
                    self.allocator.free(p.name);
                    self.allocator.free(p.value);
                }
                props.deinit(self.allocator);
            }
            var epit = try self.store.scanPrefix(epp.items);
            while (try epit.next()) |entry| {
                try props.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, entry.key[epp.items.len ..]),
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            }
            epit.deinit();

            for (props.items) |p| {
                try self.deleteEdgeIndexEntry(p.name, decodeValue(p.value), src, dst, ek.etype);
                var pk = std.ArrayList(u8).empty;
                defer pk.deinit(self.allocator);
                try appendEdgePropKey(&pk, self.allocator, src, dst, ek.etype, p.name);
                try self.store.del(pk.items);
            }

            try self.bumpEdgeType(ek.etype, false);
        }
    }

    /// Deletes every key under `prefix` (collected first so the scan cursor is
    /// not open across the deletes).
    fn deleteKeysUnder(self: *Graph, prefix: []const u8) KvError!void {
        var keys = std.ArrayList([]u8).empty;
        defer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }
        var it = try self.store.scanPrefix(prefix);
        defer it.deinit();
        while (try it.next()) |entry| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, entry.key));
        }
        for (keys.items) |k| try self.store.del(k);
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

    /// Stores a typed property `name` on node `id`. Idempotent. Maintains the
    /// property index.
    pub fn setProp(self: *Graph, id: NodeId, name: []const u8, value: Value) KvError!void {
        // Remove the previous index entry, if any.
        if (try self.getProp(id, name, self.allocator)) |old| {
            defer switch (old) {
                .str => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteIndexEntry(id, name, old);
        }

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodePropKey(&key, self.allocator, id, name);

        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(self.allocator);
        try encodeValue(&encoded, self.allocator, value);
        try self.store.put(key.items, encoded.items);

        try self.putIndexEntry(id, name, value);
    }

    /// Removes a typed property `name` from node `id` (and its index entry).
    /// Idempotent.
    pub fn removeProp(self: *Graph, id: NodeId, name: []const u8) KvError!void {
        if (try self.getProp(id, name, self.allocator)) |old| {
            defer switch (old) {
                .str => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteIndexEntry(id, name, old);
        }
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendNodePropKey(&key, self.allocator, id, name);
        try self.store.del(key.items);
    }

    /// Iterates all nodes whose property `name` equals `value` (via the
    /// property index), in ascending node-id order.
    pub fn nodesByProp(self: *Graph, name: []const u8, value: Value) KvError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try appendIndexPrefix(&prefix, self.allocator, name, value);
        const it = try self.store.scanPrefix(prefix.items);
        return .{ .inner = it };
    }

    fn putIndexEntry(self: *Graph, id: NodeId, name: []const u8, value: Value) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendIndexKey(&key, self.allocator, name, value, id);
        try self.store.put(key.items, "");
    }

    fn deleteIndexEntry(self: *Graph, id: NodeId, name: []const u8, value: Value) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendIndexKey(&key, self.allocator, name, value, id);
        try self.store.del(key.items);
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

    /// Adds a directed, typed edge, storing both directions. Idempotent. Also
    /// maintains the edge-type cardinality counter.
    pub fn addEdge(self: *Graph, src: NodeId, dst: NodeId, etype: []const u8) KvError!void {
        if (try self.hasEdge(src, dst, etype)) return;

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);

        try appendEdgeKey(&key, self.allocator, src, .out, etype, dst);
        try self.store.put(key.items, "");

        key.clearRetainingCapacity();
        try appendEdgeKey(&key, self.allocator, dst, .in, etype, src);
        try self.store.put(key.items, "");

        try self.bumpEdgeType(etype, true);
    }

    /// Number of directed edges carrying `etype`.
    pub fn edgeTypeCount(self: *Graph, etype: []const u8) KvError!usize {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key.append(self.allocator, edge_type_marker);
        try key.appendSlice(self.allocator, etype);
        const raw = (try self.store.get(key.items)) orelse return 0;
        defer self.store.allocator.free(raw);
        if (raw.len == id_len) return @intCast(std.mem.readInt(u64, @ptrCast(raw.ptr), .big));
        return 0;
    }

    fn bumpEdgeType(self: *Graph, etype: []const u8, increment: bool) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key.append(self.allocator, edge_type_marker);
        try key.appendSlice(self.allocator, etype);

        var count: u64 = 0;
        if (try self.store.get(key.items)) |raw| {
            defer self.store.allocator.free(raw);
            if (raw.len == id_len) count = std.mem.readInt(u64, @ptrCast(raw.ptr), .big);
        }
        count = if (increment) count + 1 else (if (count > 0) count - 1 else 0);

        var buf: [id_len]u8 = undefined;
        std.mem.writeInt(u64, &buf, count, .big);
        try self.store.put(key.items, &buf);
    }

    /// True if the directed, typed edge `src -> dst` exists.
    pub fn hasEdge(self: *Graph, src: NodeId, dst: NodeId, etype: []const u8) KvError!bool {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendEdgeKey(&key, self.allocator, src, .out, etype, dst);
        return self.store.exists(key.items);
    }

    /// Stores a typed property on the directed edge `src -> dst` of type
    /// `etype`. Idempotent. Maintains the edge-property index.
    pub fn setEdgeProp(self: *Graph, src: NodeId, dst: NodeId, etype: []const u8, name: []const u8, value: Value) KvError!void {
        if (try self.getEdgeProp(src, dst, etype, name, self.allocator)) |old| {
            defer switch (old) {
                .str => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteEdgeIndexEntry(name, old, src, dst, etype);
        }

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendEdgePropKey(&key, self.allocator, src, dst, etype, name);

        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(self.allocator);
        try encodeValue(&encoded, self.allocator, value);
        try self.store.put(key.items, encoded.items);

        try self.putEdgeIndexEntry(name, value, src, dst, etype);
    }

    /// Removes a typed property from the directed edge `src -> dst` of type
    /// `etype`. Idempotent.
    pub fn removeEdgeProp(self: *Graph, src: NodeId, dst: NodeId, etype: []const u8, name: []const u8) KvError!void {
        if (try self.getEdgeProp(src, dst, etype, name, self.allocator)) |old| {
            defer switch (old) {
                .str => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteEdgeIndexEntry(name, old, src, dst, etype);
        }
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendEdgePropKey(&key, self.allocator, src, dst, etype, name);
        try self.store.del(key.items);
    }

    fn putEdgeIndexEntry(self: *Graph, prop: []const u8, value: Value, src: NodeId, dst: NodeId, etype: []const u8) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendEdgeIndexKey(&key, self.allocator, prop, value, src, dst, etype);
        try self.store.put(key.items, "");
    }

    fn deleteEdgeIndexEntry(self: *Graph, prop: []const u8, value: Value, src: NodeId, dst: NodeId, etype: []const u8) KvError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendEdgeIndexKey(&key, self.allocator, prop, value, src, dst, etype);
        try self.store.del(key.items);
    }

    /// Iterates all directed edges whose property `name` equals `value` (via the
    /// edge-property index), in ascending (src, dst) order.
    pub fn edgesByProp(self: *Graph, name: []const u8, value: Value) KvError!EdgeIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try appendEdgeIndexPrefix(&prefix, self.allocator, name, value);
        const value_len = prefix.items.len;
        const it = try self.store.scanPrefix(prefix.items);
        return .{ .inner = it, .value_len = value_len };
    }

    /// Reads a typed property of the directed edge `src -> dst` of type
    /// `etype`, or `null` if absent.
    pub fn getEdgeProp(self: *Graph, src: NodeId, dst: NodeId, etype: []const u8, name: []const u8, allocator: Allocator) KvError!?Value {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendEdgePropKey(&key, self.allocator, src, dst, etype, name);
        const raw = (try self.store.get(key.items)) orelse return null;
        defer self.store.allocator.free(raw);
        return try decodeOwnedValue(raw, allocator);
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

/// Iterator over directed edges (`src`, `dst`) decoded from edge-property index
/// keys. Owns the underlying LMDB transaction/cursor.
pub const EdgeIterator = struct {
    inner: PrefixIterator,
    value_len: usize,

    pub fn deinit(self: *EdgeIterator) void {
        self.inner.deinit();
    }

    /// Returns the next `(src, dst, etype)` edge, or `null` at the end.
    pub fn next(self: *EdgeIterator) KvError!?struct { src: NodeId, dst: NodeId, etype: []const u8 } {
        const entry = try self.inner.next() orelse return null;
        const src = readNodeId(entry.key[self.value_len .. self.value_len + id_len]);
        const dst = readNodeId(entry.key[self.value_len + id_len .. self.value_len + 2 * id_len]);
        const etype = entry.key[self.value_len + 2 * id_len + 1 ..];
        return .{ .src = src, .dst = dst, .etype = etype };
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

test "allocNodeId and deleteNode detach edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    const a = try g.allocNodeId();
    const b = try g.allocNodeId();
    try testing.expect(a != b);

    try g.addNode(a, "Person");
    try g.setProp(a, "name", .{ .str = "Neo" });
    try g.addNode(b, "Person");
    try g.addEdge(a, b, "KNOWS");

    try testing.expect(try g.hasLabel(a, "Person"));
    var it = try g.neighbours(a, .out, "KNOWS");
    defer it.deinit();
    try expectNext(&it, b);
    try testing.expect((try it.next()) == null);

    try g.deleteNodeDetach(a);

    try testing.expect(!try g.hasNode(a));
    try testing.expect(!try g.hasLabel(a, "Person"));
    try testing.expect(try g.hasNode(b));
    var it2 = try g.neighbours(b, .in, "KNOWS");
    defer it2.deinit();
    try testing.expect((try it2.next()) == null);
}

test "write transactions commit and abort atomically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // Commit path: batched writes are all visible, and the id counter advances
    // within the transaction (read-modify-write on the write txn).
    try g.beginWrite();
    const a = try g.allocNodeId();
    const b = try g.allocNodeId();
    try testing.expect(a != b);
    try g.addNode(a, "Person");
    try g.setProp(a, "name", .{ .str = "A" });
    try g.addEdge(a, b, "KNOWS");
    try g.commitWrite();

    try testing.expect(try g.hasNode(a));
    try testing.expect(try g.hasEdge(a, b, "KNOWS"));

    // Abort path: nothing is visible, and the counter increment is rolled back.
    try g.beginWrite();
    const c = try g.allocNodeId();
    try g.addNode(c, "Person");
    g.abortWrite();

    try testing.expect(!try g.hasNode(c));
    try testing.expectEqual(c, try g.allocNodeId()); // counter rolled back, so c is reused
}

test "property index: lookups, updates and deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "Person");
    try g.setProp(1, "name", .{ .str = "Keanu Reeves" });
    try g.addNode(2, "Person");
    try g.setProp(2, "name", .{ .str = "Carrie-Anne Moss" });
    try g.addNode(3, "Person");
    try g.setProp(3, "name", .{ .str = "Keanu Reeves" });

    // Two nodes share the name "Keanu Reeves".
    var it = try g.nodesByProp("name", .{ .str = "Keanu Reeves" });
    defer it.deinit();
    try expectNext(&it, 1);
    try expectNext(&it, 3);
    try testing.expect((try it.next()) == null);

    // Integer index lookup.
    try g.setProp(1, "born", .{ .int = 1964 });
    var it2 = try g.nodesByProp("born", .{ .int = 1964 });
    defer it2.deinit();
    try expectNext(&it2, 1);
    try testing.expect((try it2.next()) == null);

    // Updating a value moves the index entry.
    try g.setProp(3, "name", .{ .str = "Laurence Fishburne" });
    var it3 = try g.nodesByProp("name", .{ .str = "Keanu Reeves" });
    defer it3.deinit();
    try expectNext(&it3, 1);
    try testing.expect((try it3.next()) == null);

    // Deleting a node removes its index entries.
    try g.deleteNode(1);
    var it4 = try g.nodesByProp("name", .{ .str = "Keanu Reeves" });
    defer it4.deinit();
    try testing.expect((try it4.next()) == null);
}

test "edge properties round-trip and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "Person");
    try g.addNode(2, "Person");
    try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProp(1, 2, "KNOWS", "weight", .{ .int = 5 });

    const w = (try g.getEdgeProp(1, 2, "KNOWS", "weight", testing.allocator)).?;
    try testing.expectEqual(@as(i64, 5), w.int);
    try testing.expect((try g.getEdgeProp(1, 2, "KNOWS", "nope", testing.allocator)) == null);

    // Detach-deleting a node removes its edge properties too.
    try g.deleteNodeDetach(1);
    try testing.expect(!try g.hasEdge(1, 2, "KNOWS"));
    try testing.expect((try g.getEdgeProp(1, 2, "KNOWS", "weight", testing.allocator)) == null);
}

test "edge-property index: seek, update and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "");
    try g.addNode(2, "");
    try g.addNode(3, "");
    try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProp(1, 2, "KNOWS", "weight", .{ .int = 5 });
    try g.addEdge(1, 3, "KNOWS");
    try g.setEdgeProp(1, 3, "KNOWS", "weight", .{ .int = 9 });

    // Index lookup returns the matching edge (src, dst, etype).
    var it = try g.edgesByProp("weight", .{ .int = 5 });
    defer it.deinit();
    const e = (try it.next()).?;
    try testing.expectEqual(@as(NodeId, 1), e.src);
    try testing.expectEqual(@as(NodeId, 2), e.dst);
    try testing.expectEqualStrings("KNOWS", e.etype);
    try testing.expect((try it.next()) == null);

    // Updating a value moves the index entry.
    try g.setEdgeProp(1, 2, "KNOWS", "weight", .{ .int = 9 });
    var it2 = try g.edgesByProp("weight", .{ .int = 5 });
    defer it2.deinit();
    try testing.expect((try it2.next()) == null);
    var it3 = try g.edgesByProp("weight", .{ .int = 9 });
    defer it3.deinit();
    _ = (try it3.next()).?;
    _ = (try it3.next()).?;
    try testing.expect((try it3.next()) == null);

    // Removing a property removes its index entry.
    try g.removeEdgeProp(1, 2, "KNOWS", "weight");
    var it4 = try g.edgesByProp("weight", .{ .int = 9 });
    defer it4.deinit();
    _ = (try it4.next()).?;
    try testing.expect((try it4.next()) == null);

    // Detach-delete removes remaining edge index entries.
    try g.deleteNodeDetach(1);
    var it5 = try g.edgesByProp("weight", .{ .int = 9 });
    defer it5.deinit();
    try testing.expect((try it5.next()) == null);
}

test "edge-type cardinality tracks add and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buf);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "");
    try g.addNode(2, "");
    try g.addNode(3, "");

    try testing.expectEqual(@as(usize, 0), try g.edgeTypeCount("KNOWS"));

    try g.addEdge(1, 2, "KNOWS");
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("KNOWS"));

    // Re-adding the same edge is idempotent.
    try g.addEdge(1, 2, "KNOWS");
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("KNOWS"));

    try g.addEdge(1, 3, "KNOWS");
    try g.addEdge(2, 3, "LIKES");
    try testing.expectEqual(@as(usize, 2), try g.edgeTypeCount("KNOWS"));
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("LIKES"));

    // Detach-deleting a node decrements its edge types.
    try g.deleteNodeDetach(1);
    try testing.expectEqual(@as(usize, 0), try g.edgeTypeCount("KNOWS"));
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("LIKES"));
}
