//! The graph: nodes, labels, typed edges and properties, with their indexes,
//! stored as keys in a `KeyValueStore` (see key_encoding.zig for the layout).
//!
//! Index-free adjacency: each directed, typed edge is stored twice, keyed by
//! its source (outgoing) and by its target (incoming), so the neighbours of a
//! node in either direction are one prefix scan.
//!
//! Costs. With N keys in the store, a point lookup or write is one LMDB
//! B+-tree descent, O(log N); a scan yielding k entries is O(log N + k). Each
//! operation below states its cost in those terms.
//!
//! Iterators (`NodeIdIterator`, `EdgeIterator`) share one concept:
//! `next() StorageError!?T` yields the next item or null at the end, and
//! `deinit()` releases the LMDB cursor. Slices inside a yielded item (an edge
//! type) are views into the store, valid only until the next `next` call.
//! Iterators opened inside a transaction must be `deinit`ed before it ends.

const std = @import("std");

const KeyValueStore = @import("key_value_store.zig").KeyValueStore;
const StorageError = @import("key_value_store.zig").StorageError;
const PrefixIterator = @import("key_value_store.zig").PrefixIterator;

const Allocator = std.mem.Allocator;

const key_encoding = @import("key_encoding.zig");

pub const NodeId = key_encoding.NodeId;
pub const Direction = key_encoding.Direction;
pub const EdgeKey = key_encoding.EdgeKey;
pub const Value = key_encoding.Value;

// ---------------------------------------------------------------------------
// Graph (index-free adjacency over KeyValueStore)
// ---------------------------------------------------------------------------

/// Thin graph view over a `KeyValueStore`, implementing index-free adjacency:
/// `addEdge` writes both directions, `neighbours` is a single prefix scan.
pub const Graph = struct {
    store: *KeyValueStore,
    allocator: Allocator,

    pub fn init(store: *KeyValueStore, allocator: Allocator) Graph {
        return .{ .store = store, .allocator = allocator };
    }

    /// Begins an atomic write transaction; see `commitWrite`/`abortWrite`. All
    /// mutations until then are batched into one transaction.
    pub fn beginWrite(self: *Graph) StorageError!void {
        return self.store.beginWrite();
    }

    pub fn commitWrite(self: *Graph) StorageError!void {
        return self.store.commitWrite();
    }

    pub fn abortWrite(self: *Graph) void {
        self.store.abortWrite();
    }

    /// True if an explicit write transaction is currently active.
    pub fn inWriteTransaction(self: *Graph) bool {
        return self.store.active_write_transaction != null;
    }

    /// Begins an atomic read transaction (snapshot); see `commitRead`/`abortRead`.
    /// All reads until then are batched into one transaction.
    pub fn beginRead(self: *Graph) StorageError!void {
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
    pub fn addNode(self: *Graph, id: NodeId, label: []const u8) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendNodeKey(&key, self.allocator, id);
        try self.store.put(key.items, "");

        if (label.len > 0) try self.addLabel(id, label);
    }

    /// Adds a label to a node (forward + reverse index). Idempotent.
    pub fn addLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendLabelKey(&key, self.allocator, label, id);
        try self.store.put(key.items, "");

        key.clearRetainingCapacity();
        try key_encoding.appendReverseLabelKey(&key, self.allocator, id, label);
        try self.store.put(key.items, "");
    }

    /// Removes a label from a node (forward + reverse index). Idempotent.
    pub fn removeLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendLabelKey(&key, self.allocator, label, id);
        try self.store.del(key.items);

        key.clearRetainingCapacity();
        try key_encoding.appendReverseLabelKey(&key, self.allocator, id, label);
        try self.store.del(key.items);
    }

    /// Allocates a fresh, never-used node id (persistent counter). O(log N).
    pub fn allocateNodeId(self: *Graph) StorageError!NodeId {
        var next: NodeId = 0;
        const raw = try self.store.get(key_encoding.counter_key);
        if (raw) |r| {
            defer self.allocator.free(r);
            if (r.len == key_encoding.node_id_length) next = key_encoding.readNodeId(r);
        }
        var buffer: [key_encoding.node_id_length]u8 = undefined;
        std.mem.writeInt(NodeId, &buffer, next + 1, .big);
        try self.store.put(key_encoding.counter_key, &buffer);
        return next;
    }

    /// Deletes a node; fails with `error.NodeStillConnected` if it still has
    /// relationships (use `deleteNodeDetach` to remove them too).
    pub fn deleteNode(self: *Graph, id: NodeId) StorageError!void {
        if (try self.hasAnyEdge(id)) return error.NodeStillConnected;
        return self.deleteNodeOnly(id);
    }

    /// Deletes a node and detaches it: removes all its edges (both directions)
    /// and edge properties, its label-index entry, properties and marker.
    /// O(log N · (degree + properties + labels)).
    pub fn deleteNodeDetach(self: *Graph, id: NodeId) StorageError!void {
        try self.deleteEdgesInDirection(id, .out);
        try self.deleteEdgesInDirection(id, .in);
        return self.deleteNodeOnly(id);
    }

    /// True if the node is the endpoint of at least one edge. O(log N).
    pub fn hasAnyEdge(self: *Graph, id: NodeId) StorageError!bool {
        var out_prefix = std.ArrayList(u8).empty;
        defer out_prefix.deinit(self.allocator);
        try out_prefix.append(self.allocator, key_encoding.edge_marker);
        try key_encoding.appendNodeId(&out_prefix, self.allocator, id);
        try out_prefix.append(self.allocator, @backingInt(Direction.out));
        if (try self.store.countPrefix(out_prefix.items) > 0) return true;

        var in_prefix = std.ArrayList(u8).empty;
        defer in_prefix.deinit(self.allocator);
        try in_prefix.append(self.allocator, key_encoding.edge_marker);
        try key_encoding.appendNodeId(&in_prefix, self.allocator, id);
        try in_prefix.append(self.allocator, @backingInt(Direction.in));
        return try self.store.countPrefix(in_prefix.items) > 0;
    }

    fn deleteNodeOnly(self: *Graph, id: NodeId) StorageError!void {
        // Enumerate and remove all labels (forward + reverse index).
        var labels = std.ArrayList([]u8).empty;
        defer {
            for (labels.items) |l| self.allocator.free(l);
            labels.deinit(self.allocator);
        }
        var lprefix = std.ArrayList(u8).empty;
        defer lprefix.deinit(self.allocator);
        try lprefix.append(self.allocator, key_encoding.reverse_label_marker);
        try key_encoding.appendNodeId(&lprefix, self.allocator, id);
        try lprefix.append(self.allocator, key_encoding.separator);
        var lit = try self.store.scanPrefix(lprefix.items);
        while (try lit.next()) |entry| {
            try labels.append(self.allocator, try self.allocator.dupe(u8, entry.key[lprefix.items.len..]));
        }
        lit.deinit();
        for (labels.items) |label| try self.removeLabel(id, label);

        var nprefix = std.ArrayList(u8).empty;
        defer nprefix.deinit(self.allocator);
        try key_encoding.appendNodeKey(&nprefix, self.allocator, id);

        // Remove property-index entries before deleting the properties.
        var pprefix = std.ArrayList(u8).empty;
        defer pprefix.deinit(self.allocator);
        try key_encoding.appendNodePropertyKey(&pprefix, self.allocator, id, "");
        var pit = try self.store.scanPrefix(pprefix.items);
        defer pit.deinit();
        while (try pit.next()) |entry| {
            const property_name = entry.key[1 + key_encoding.node_id_length + 1 ..];
            try self.deleteIndexEntry(id, property_name, key_encoding.decodeValue(entry.value));
        }

        try self.deleteKeysUnder(nprefix.items);
    }

    fn deleteEdgesInDirection(self: *Graph, id: NodeId, direction: Direction) StorageError!void {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try prefix.append(self.allocator, key_encoding.edge_marker);
        try key_encoding.appendNodeId(&prefix, self.allocator, id);
        try prefix.append(self.allocator, @backingInt(direction));

        var keys = std.ArrayList([]u8).empty;
        defer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }
        var iterator = try self.store.scanPrefix(prefix.items);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, entry.key));
        }

        for (keys.items) |k| {
            const ek = key_encoding.decodeEdgeKey(k);
            try self.store.del(k);

            const rev_dir: Direction = if (ek.direction == .out) .in else .out;
            var rev = std.ArrayList(u8).empty;
            defer rev.deinit(self.allocator);
            try key_encoding.appendEdgeKey(&rev, self.allocator, ek.neighbour, rev_dir, ek.edge_type, ek.id);
            try self.store.del(rev.items);

            // Delete the edge's properties and their index entries (canonical
            // src -> dst). Collect first so the cursor isn't open across deletes.
            const src = if (ek.direction == .out) ek.id else ek.neighbour;
            const dst = if (ek.direction == .out) ek.neighbour else ek.id;
            var epp = std.ArrayList(u8).empty;
            defer epp.deinit(self.allocator);
            try key_encoding.appendEdgePropertyPrefix(&epp, self.allocator, src, dst, ek.edge_type);

            var properties = std.ArrayList(struct { name: []u8, value: []u8 }).empty;
            defer {
                for (properties.items) |p| {
                    self.allocator.free(p.name);
                    self.allocator.free(p.value);
                }
                properties.deinit(self.allocator);
            }
            var epit = try self.store.scanPrefix(epp.items);
            while (try epit.next()) |entry| {
                try properties.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, entry.key[epp.items.len..]),
                    .value = try self.allocator.dupe(u8, entry.value),
                });
            }
            epit.deinit();

            for (properties.items) |p| {
                try self.deleteEdgeIndexEntry(p.name, key_encoding.decodeValue(p.value), src, dst, ek.edge_type);
                var pk = std.ArrayList(u8).empty;
                defer pk.deinit(self.allocator);
                try key_encoding.appendEdgePropertyKey(&pk, self.allocator, src, dst, ek.edge_type, p.name);
                try self.store.del(pk.items);
            }

            try self.bumpEdgeType(ek.edge_type, false);
        }
    }

    /// Deletes every key under `prefix` (collected first so the scan cursor is
    /// not open across the deletes).
    fn deleteKeysUnder(self: *Graph, prefix: []const u8) StorageError!void {
        var keys = std.ArrayList([]u8).empty;
        defer {
            for (keys.items) |k| self.allocator.free(k);
            keys.deinit(self.allocator);
        }
        var iterator = try self.store.scanPrefix(prefix);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, entry.key));
        }
        for (keys.items) |k| try self.store.del(k);
    }

    pub fn hasNode(self: *Graph, id: NodeId) StorageError!bool {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendNodeKey(&key, self.allocator, id);
        return self.store.exists(key.items);
    }

    pub fn hasLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!bool {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendLabelKey(&key, self.allocator, label, id);
        return self.store.exists(key.items);
    }

    /// Stores a typed property `name` on node `id`. Idempotent. Maintains the
    /// property index. O(log N).
    pub fn setProperty(self: *Graph, id: NodeId, name: []const u8, value: Value) StorageError!void {
        // Remove the previous index entry, if any.
        if (try self.getProperty(id, name, self.allocator)) |old| {
            defer switch (old) {
                .string => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteIndexEntry(id, name, old);
        }

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendNodePropertyKey(&key, self.allocator, id, name);

        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(self.allocator);
        try key_encoding.encodeValue(&encoded, self.allocator, value);
        try self.store.put(key.items, encoded.items);

        try self.putIndexEntry(id, name, value);
    }

    /// Removes a typed property `name` from node `id` (and its index entry).
    /// Idempotent.
    pub fn removeProperty(self: *Graph, id: NodeId, name: []const u8) StorageError!void {
        if (try self.getProperty(id, name, self.allocator)) |old| {
            defer switch (old) {
                .string => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteIndexEntry(id, name, old);
        }
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendNodePropertyKey(&key, self.allocator, id, name);
        try self.store.del(key.items);
    }

    /// Iterates all nodes whose property `name` equals `value` (via the
    /// property index), in ascending node-id order. O(log N + matches).
    pub fn nodesByProperty(self: *Graph, name: []const u8, value: Value) StorageError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendIndexPrefix(&prefix, self.allocator, name, value);
        const iterator = try self.store.scanPrefix(prefix.items);
        return .{ .inner = iterator };
    }

    fn putIndexEntry(self: *Graph, id: NodeId, name: []const u8, value: Value) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendIndexKey(&key, self.allocator, name, value, id);
        try self.store.put(key.items, "");
    }

    fn deleteIndexEntry(self: *Graph, id: NodeId, name: []const u8, value: Value) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendIndexKey(&key, self.allocator, name, value, id);
        try self.store.del(key.items);
    }

    /// Reads a typed property `name` of node `id`, or `null` if absent. A
    /// `string` value is an owned copy allocated with `allocator`. O(log N).
    pub fn getProperty(self: *Graph, id: NodeId, name: []const u8, allocator: Allocator) StorageError!?Value {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendNodePropertyKey(&key, self.allocator, id, name);
        const raw = (try self.store.get(key.items)) orelse return null;
        defer self.store.allocator.free(raw);
        return try key_encoding.decodeOwnedValue(raw, allocator);
    }

    /// Adds a directed, typed edge, storing both directions. Idempotent. Also
    /// maintains the edge-type cardinality counter. O(log N).
    pub fn addEdge(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!void {
        if (try self.hasEdge(src, dst, edge_type)) return;

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);

        try key_encoding.appendEdgeKey(&key, self.allocator, src, .out, edge_type, dst);
        try self.store.put(key.items, "");

        key.clearRetainingCapacity();
        try key_encoding.appendEdgeKey(&key, self.allocator, dst, .in, edge_type, src);
        try self.store.put(key.items, "");

        try self.bumpEdgeType(edge_type, true);
    }

    /// Number of directed edges carrying `edge_type` (a maintained counter).
    /// O(log N).
    pub fn edgeTypeCount(self: *Graph, edge_type: []const u8) StorageError!usize {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key.append(self.allocator, key_encoding.edge_type_marker);
        try key.appendSlice(self.allocator, edge_type);
        const raw = (try self.store.get(key.items)) orelse return 0;
        defer self.store.allocator.free(raw);
        if (raw.len == key_encoding.node_id_length) return @intCast(std.mem.readInt(u64, @ptrCast(raw.ptr), .big));
        return 0;
    }

    fn bumpEdgeType(self: *Graph, edge_type: []const u8, increment: bool) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key.append(self.allocator, key_encoding.edge_type_marker);
        try key.appendSlice(self.allocator, edge_type);

        var count: u64 = 0;
        if (try self.store.get(key.items)) |raw| {
            defer self.store.allocator.free(raw);
            if (raw.len == key_encoding.node_id_length) count = std.mem.readInt(u64, @ptrCast(raw.ptr), .big);
        }
        count = if (increment) count + 1 else (if (count > 0) count - 1 else 0);

        var buffer: [key_encoding.node_id_length]u8 = undefined;
        std.mem.writeInt(u64, &buffer, count, .big);
        try self.store.put(key.items, &buffer);
    }

    /// True if the directed, typed edge `src -> dst` exists.
    pub fn hasEdge(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!bool {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgeKey(&key, self.allocator, src, .out, edge_type, dst);
        return self.store.exists(key.items);
    }

    /// Stores a typed property on the directed edge `src -> dst` of type
    /// `edge_type`. Idempotent. Maintains the edge-property index.
    pub fn setEdgeProperty(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8, name: []const u8, value: Value) StorageError!void {
        if (try self.getEdgeProperty(src, dst, edge_type, name, self.allocator)) |old| {
            defer switch (old) {
                .string => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteEdgeIndexEntry(name, old, src, dst, edge_type);
        }

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgePropertyKey(&key, self.allocator, src, dst, edge_type, name);

        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(self.allocator);
        try key_encoding.encodeValue(&encoded, self.allocator, value);
        try self.store.put(key.items, encoded.items);

        try self.putEdgeIndexEntry(name, value, src, dst, edge_type);
    }

    /// Removes a typed property from the directed edge `src -> dst` of type
    /// `edge_type`. Idempotent.
    pub fn removeEdgeProperty(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8, name: []const u8) StorageError!void {
        if (try self.getEdgeProperty(src, dst, edge_type, name, self.allocator)) |old| {
            defer switch (old) {
                .string => |s| self.allocator.free(s),
                else => {},
            };
            try self.deleteEdgeIndexEntry(name, old, src, dst, edge_type);
        }
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgePropertyKey(&key, self.allocator, src, dst, edge_type, name);
        try self.store.del(key.items);
    }

    fn putEdgeIndexEntry(self: *Graph, property: []const u8, value: Value, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgeIndexKey(&key, self.allocator, property, value, src, dst, edge_type);
        try self.store.put(key.items, "");
    }

    fn deleteEdgeIndexEntry(self: *Graph, property: []const u8, value: Value, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!void {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgeIndexKey(&key, self.allocator, property, value, src, dst, edge_type);
        try self.store.del(key.items);
    }

    /// Iterates all directed edges whose property `name` equals `value` (via the
    /// edge-property index), in ascending (src, dst) order. O(log N + matches).
    pub fn edgesByProperty(self: *Graph, name: []const u8, value: Value) StorageError!EdgeIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendEdgeIndexPrefix(&prefix, self.allocator, name, value);
        const value_length = prefix.items.len;
        const iterator = try self.store.scanPrefix(prefix.items);
        return .{ .inner = iterator, .value_length = value_length };
    }

    /// Reads a typed property of the directed edge `src -> dst` of type
    /// `edge_type`, or `null` if absent.
    pub fn getEdgeProperty(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8, name: []const u8, allocator: Allocator) StorageError!?Value {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgePropertyKey(&key, self.allocator, src, dst, edge_type, name);
        const raw = (try self.store.get(key.items)) orelse return null;
        defer self.store.allocator.free(raw);
        return try key_encoding.decodeOwnedValue(raw, allocator);
    }

    /// Iterates the neighbours of `id` in the given `direction` and `edge_type`,
    /// in ascending neighbour-id order (LMDB's lexicographic order).
    /// O(log N + degree).
    pub fn neighbours(self: *Graph, id: NodeId, direction: Direction, edge_type: []const u8) StorageError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendEdgePrefix(&prefix, self.allocator, id, direction, edge_type);
        const iterator = try self.store.scanPrefix(prefix.items);
        return .{ .inner = iterator };
    }

    /// Iterates all nodes carrying `label`, in ascending node-id order.
    /// O(log N + nodes with the label).
    pub fn nodesWithLabel(self: *Graph, label: []const u8) StorageError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try prefix.append(self.allocator, key_encoding.label_marker);
        try prefix.appendSlice(self.allocator, label);
        try prefix.append(self.allocator, key_encoding.separator);
        const iterator = try self.store.scanPrefix(prefix.items);
        return .{ .inner = iterator };
    }

    /// Iterates every node (labeled or not), in ascending node-id order. Scans
    /// the `n | node_id` existence markers, skipping the property keys that
    /// share the `n` prefix. O(log N + nodes + node properties).
    pub fn allNodes(self: *Graph) StorageError!NodeIdIterator {
        const iterator = try self.store.scanPrefix(&.{key_encoding.node_marker});
        return .{ .inner = iterator, .key_length = 1 + key_encoding.node_id_length };
    }

    /// Number of nodes carrying `label`. Counts by scanning the label index:
    /// O(log N + nodes with the label). The planner calls it once per query
    /// and label, so a maintained counter (like `edgeTypeCount`) would make
    /// planning O(log N) on large labels.
    pub fn labelCount(self: *Graph, label: []const u8) StorageError!usize {
        var iterator = try self.nodesWithLabel(label);
        defer iterator.deinit();
        var count: usize = 0;
        while (try iterator.next()) |_| count += 1;
        return count;
    }
};

/// Iterator over node ids decoded from the trailing 8 bytes of scanned keys
/// (edge keys or label-index keys). Owns the underlying LMDB
/// transaction/cursor; `deinit` releases them.
pub const NodeIdIterator = struct {
    inner: PrefixIterator,
    /// When set, only keys of exactly this length are yielded (others skipped).
    key_length: ?usize = null,

    pub fn deinit(self: *NodeIdIterator) void {
        self.inner.deinit();
    }

    /// Returns the next node id, or `null` at the end.
    pub fn next(self: *NodeIdIterator) StorageError!?NodeId {
        while (try self.inner.next()) |entry| {
            if (self.key_length) |len| {
                if (entry.key.len != len) continue;
            }
            return key_encoding.readNodeId(entry.key[entry.key.len - key_encoding.node_id_length ..]);
        }
        return null;
    }
};

/// Backward-compatible name for `NodeIdIterator` (neighbour scans).
pub const NeighbourIterator = NodeIdIterator;

/// Iterator over directed edges (`src`, `dst`) decoded from edge-property index
/// keys. Owns the underlying LMDB transaction/cursor.
pub const EdgeIterator = struct {
    inner: PrefixIterator,
    value_length: usize,

    pub fn deinit(self: *EdgeIterator) void {
        self.inner.deinit();
    }

    /// Returns the next `(src, dst, edge_type)` edge, or `null` at the end.
    pub fn next(self: *EdgeIterator) StorageError!?struct { src: NodeId, dst: NodeId, edge_type: []const u8 } {
        const entry = try self.inner.next() orelse return null;
        const src = key_encoding.readNodeId(entry.key[self.value_length .. self.value_length + key_encoding.node_id_length]);
        const dst = key_encoding.readNodeId(entry.key[self.value_length + key_encoding.node_id_length .. self.value_length + 2 * key_encoding.node_id_length]);
        const edge_type = entry.key[self.value_length + 2 * key_encoding.node_id_length + 1 ..];
        return .{ .src = src, .dst = dst, .edge_type = edge_type };
    }
};
