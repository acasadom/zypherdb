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
const value_encoding = @import("value_encoding.zig");
const node_record = @import("node_record.zig");
const NodeRecord = node_record.NodeRecord;

pub const NodeId = key_encoding.NodeId;
pub const Direction = key_encoding.Direction;
pub const EdgeKey = key_encoding.EdgeKey;
pub const Value = @import("../value.zig").Value;

/// Errors of graph writes: storage failures, or a value that cannot be stored
/// as a property (see `value_encoding.isStorable`).
pub const GraphError = StorageError || error{UnsupportedPropertyType};

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
        if (!try self.hasNode(id)) try self.writeRecord(id, "");
        if (label.len > 0) try self.addLabel(id, label);
    }

    /// Adds a label to a node (its record and the label index). Idempotent.
    pub fn addLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse NodeRecord.empty;
        if (record.hasLabel(label)) return;
        try self.writeRecord(id, try node_record.withLabel(scratch.allocator(), record, label, true));

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendLabelKey(&key, self.allocator, label, id);
        try self.store.put(key.items, "");
    }

    /// Removes a label from a node (its record and the label index). Idempotent.
    pub fn removeLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse return;
        if (!record.hasLabel(label)) return;
        try self.writeRecord(id, try node_record.withLabel(scratch.allocator(), record, label, false));

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendLabelKey(&key, self.allocator, label, id);
        try self.store.del(key.items);
    }

    /// The record of node `id` (null if there is no such node): a view into
    /// the store inside a transaction, else a copy made with `scratch`.
    fn readRecord(self: *Graph, id: NodeId, scratch: Allocator) StorageError!?NodeRecord {
        if (self.store.inTransaction()) {
            const bytes = (try self.store.viewNode(id)) orelse return null;
            return .{ .bytes = bytes };
        }
        const bytes = (try self.store.getNode(id)) orelse return null;
        defer self.store.allocator.free(bytes);
        return .{ .bytes = try scratch.dupe(u8, bytes) };
    }

    fn writeRecord(self: *Graph, id: NodeId, bytes: []const u8) StorageError!void {
        try self.store.putNode(id, bytes);
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
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        // Copied: deleting keys invalidates views into the store.
        const view = try self.readRecord(id, scratch.allocator()) orelse return;
        const record = NodeRecord{ .bytes = try scratch.allocator().dupe(u8, view.bytes) };
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        var labels = record.labels();
        while (labels.next()) |label| {
            key.clearRetainingCapacity();
            try key_encoding.appendLabelKey(&key, self.allocator, label, id);
            try self.store.del(key.items);
        }
        var properties = record.properties();
        while (properties.next()) |property| {
            try self.deleteIndexEntry(id, property.name, try value_encoding.decodeValue(property.encoded_value, scratch.allocator()));
        }
        try self.store.deleteNode(id);
    }

    fn deleteEdgesInDirection(self: *Graph, id: NodeId, direction: Direction) StorageError!void {
        // Collect first, so the scan cursor is not open across the deletes.
        var edges = std.ArrayList(struct { src: NodeId, dst: NodeId, edge_type: []u8 }).empty;
        defer {
            for (edges.items) |edge| self.allocator.free(edge.edge_type);
            edges.deinit(self.allocator);
        }
        var iterator = try self.edgesOf(id, direction);
        defer iterator.deinit();
        while (try iterator.next()) |key| {
            const outgoing = key.direction == .out;
            try edges.append(self.allocator, .{
                .src = if (outgoing) id else key.neighbour,
                .dst = if (outgoing) key.neighbour else id,
                .edge_type = try self.allocator.dupe(u8, key.edge_type),
            });
        }
        for (edges.items) |edge| try self.deleteEdge(edge.src, edge.dst, edge.edge_type);
    }

    /// Deletes the edge `src -> dst` of type `edge_type`: both directions, its
    /// properties and their index entries, and its type count. Idempotent.
    /// O(log N · (1 + properties)).
    pub fn deleteEdge(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!void {
        if (!try self.hasEdge(src, dst, edge_type)) return;

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgeKey(&key, self.allocator, src, .out, edge_type, dst);
        try self.store.del(key.items);
        key.clearRetainingCapacity();
        try key_encoding.appendEdgeKey(&key, self.allocator, dst, .in, edge_type, src);
        try self.store.del(key.items);

        // Collect the properties first, so the cursor is not open across deletes.
        var properties = std.ArrayList(struct { name: []u8, value: []u8 }).empty;
        defer {
            for (properties.items) |p| {
                self.allocator.free(p.name);
                self.allocator.free(p.value);
            }
            properties.deinit(self.allocator);
        }
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendEdgePropertyPrefix(&prefix, self.allocator, src, dst, edge_type);
        var scan = try self.store.scanPrefix(prefix.items);
        while (try scan.next()) |entry| {
            try properties.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, entry.key[prefix.items.len..]),
                .value = try self.allocator.dupe(u8, entry.value),
            });
        }
        scan.deinit();

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        for (properties.items) |p| {
            try self.deleteEdgeIndexEntry(p.name, try value_encoding.decodeValue(p.value, scratch.allocator()), src, dst, edge_type);
            key.clearRetainingCapacity();
            try key_encoding.appendEdgePropertyKey(&key, self.allocator, src, dst, edge_type, p.name);
            try self.store.del(key.items);
        }

        try self.bumpEdgeType(edge_type, false);
    }

    pub fn hasNode(self: *Graph, id: NodeId) StorageError!bool {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        return try self.readRecord(id, scratch.allocator()) != null;
    }

    pub fn hasLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!bool {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse return false;
        return record.hasLabel(label);
    }

    /// Stores a typed property `name` on node `id`. Idempotent. Maintains the
    /// property index. Setting `null` removes the property (as in Cypher); a
    /// list fails with `UnsupportedPropertyType`. O(log N).
    pub fn setProperty(self: *Graph, id: NodeId, name: []const u8, value: Value) GraphError!void {
        if (value == .null) return self.removeProperty(id, name);
        if (!value_encoding.isStorable(value)) return error.UnsupportedPropertyType;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse NodeRecord.empty;
        var encoded = std.ArrayList(u8).empty;
        try value_encoding.encodeValue(&encoded, scratch.allocator(), value);
        const updated = try node_record.withProperty(scratch.allocator(), record, name, encoded.items);
        // Remove the previous index entry, if any (read before the record changes).
        if (record.property(name)) |old| try self.deleteIndexEntry(id, name, try value_encoding.decodeValue(old, scratch.allocator()));
        try self.writeRecord(id, updated);
        try self.putIndexEntry(id, name, value);
    }

    /// Removes a typed property `name` from node `id` (and its index entry).
    /// Idempotent.
    pub fn removeProperty(self: *Graph, id: NodeId, name: []const u8) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse return;
        const old = record.property(name) orelse return;
        const old_value = try value_encoding.decodeValue(old, scratch.allocator());
        const updated = try node_record.withProperty(scratch.allocator(), record, name, null);
        try self.writeRecord(id, updated);
        try self.deleteIndexEntry(id, name, old_value);
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
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse return null;
        const encoded = record.property(name) orelse return null;
        return try value_encoding.decodeValue(encoded, allocator);
    }

    /// The stored value at `key`, decoded with `allocator`: read in place
    /// inside a transaction, copied out of a one-off one otherwise.
    fn readValue(self: *Graph, key: []const u8, allocator: Allocator) StorageError!?Value {
        if (self.store.inTransaction()) {
            const raw = (try self.store.view(key)) orelse return null;
            return try value_encoding.decodeValue(raw, allocator);
        }
        const raw = (try self.store.get(key)) orelse return null;
        defer self.store.allocator.free(raw);
        return try value_encoding.decodeValue(raw, allocator);
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
    /// `edge_type`. Idempotent. Maintains the edge-property index. Setting
    /// `null` removes the property; a list fails with
    /// `UnsupportedPropertyType`. O(log N).
    pub fn setEdgeProperty(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8, name: []const u8, value: Value) GraphError!void {
        if (value == .null) return self.removeEdgeProperty(src, dst, edge_type, name);
        if (!value_encoding.isStorable(value)) return error.UnsupportedPropertyType;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        if (try self.getEdgeProperty(src, dst, edge_type, name, scratch.allocator())) |old| try self.deleteEdgeIndexEntry(name, old, src, dst, edge_type);

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendEdgePropertyKey(&key, self.allocator, src, dst, edge_type, name);

        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(self.allocator);
        try value_encoding.encodeValue(&encoded, self.allocator, value);
        try self.store.put(key.items, encoded.items);

        try self.putEdgeIndexEntry(name, value, src, dst, edge_type);
    }

    /// Removes a typed property from the directed edge `src -> dst` of type
    /// `edge_type`. Idempotent.
    pub fn removeEdgeProperty(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8, name: []const u8) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        if (try self.getEdgeProperty(src, dst, edge_type, name, scratch.allocator())) |old| try self.deleteEdgeIndexEntry(name, old, src, dst, edge_type);
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
        var key_buffer: [256]u8 = undefined;
        var key_memory = std.heap.BufferFirstAllocator.init(&key_buffer, self.allocator);
        const key_allocator = key_memory.allocator();
        var key = std.ArrayList(u8).empty;
        defer key.deinit(key_allocator);
        try key_encoding.appendEdgePropertyKey(&key, key_allocator, src, dst, edge_type, name);
        return self.readValue(key.items, allocator);
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

    /// Iterates every node (labeled or not), in ascending node-id order: a
    /// scan of the node records. O(log N + nodes).
    pub fn allNodes(self: *Graph) StorageError!NodeIdIterator {
        return .{ .inner = try self.store.scanNodes(), .native_keys = true };
    }

    /// Iterates the labels of node `id` (views into the store). O(log N + labels).
    pub fn labelsOf(self: *Graph, id: NodeId) StorageError!LabelIterator {
        const held = try self.holdRecord(id);
        return .{ .inner = held.record.labels(), .held = held };
    }

    /// Iterates the properties of node `id`, in name order (views into the
    /// store). O(log N + properties).
    pub fn propertiesOf(self: *Graph, id: NodeId) StorageError!PropertyIterator {
        const held = try self.holdRecord(id);
        return .{ .source = .{ .record = held.record.properties() }, .held = held };
    }

    /// A node's record for an iterator to read: a view inside a transaction,
    /// else a copy the iterator frees.
    fn holdRecord(self: *Graph, id: NodeId) StorageError!HeldRecord {
        if (self.store.inTransaction()) return .{ .record = .{ .bytes = (try self.store.viewNode(id)) orelse "" } };
        const bytes = (try self.store.getNode(id)) orelse return .{ .record = .empty };
        return .{ .record = .{ .bytes = bytes }, .owner = self.store.allocator };
    }

    /// Iterates the properties of the edge `src -> dst` of type `edge_type`, in
    /// name order (views into the store). O(log N + properties).
    pub fn edgePropertiesOf(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!PropertyIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendEdgePropertyPrefix(&prefix, self.allocator, src, dst, edge_type);
        return .{ .source = .{ .keys = .{ .inner = try self.store.scanPrefix(prefix.items), .prefix_length = prefix.items.len } } };
    }

    /// Iterates the edges of node `id` in `direction`, of every type, as
    /// `EdgeKey`s (`edge_type` is a view into the store). O(log N + degree).
    pub fn edgesOf(self: *Graph, id: NodeId, direction: Direction) StorageError!EdgeKeyIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try prefix.append(self.allocator, key_encoding.edge_marker);
        try key_encoding.appendNodeId(&prefix, self.allocator, id);
        try prefix.append(self.allocator, @backingInt(direction));
        return .{ .inner = try self.store.scanPrefix(prefix.items), .prefix_length = prefix.items.len };
    }

    /// Iterates the edges of node `id` in `direction` with type `edge_type`,
    /// as `EdgeKey`s. O(log N + edges of that type).
    pub fn edgesOfType(self: *Graph, id: NodeId, direction: Direction, edge_type: []const u8) StorageError!EdgeKeyIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendEdgePrefix(&prefix, self.allocator, id, direction, edge_type);
        return .{ .inner = try self.store.scanPrefix(prefix.items), .prefix_length = prefix.items.len };
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
    /// The keys are node ids in native byte order (the node table's).
    native_keys: bool = false,

    pub fn deinit(self: *NodeIdIterator) void {
        self.inner.deinit();
    }

    /// Returns the next node id, or `null` at the end.
    pub fn next(self: *NodeIdIterator) StorageError!?NodeId {
        while (try self.inner.next()) |entry| {
            if (self.key_length) |len| {
                if (entry.key.len != len) continue;
            }
            if (self.native_keys) return std.mem.readInt(NodeId, entry.key[0..8], .native);
            return key_encoding.readNodeId(entry.key[entry.key.len - key_encoding.node_id_length ..]);
        }
        return null;
    }
};

/// Backward-compatible name for `NodeIdIterator` (neighbour scans).
pub const NeighbourIterator = NodeIdIterator;

/// Iterator over directed edges (`src`, `dst`) decoded from edge-property index
/// keys. Owns the underlying LMDB transaction/cursor.
/// An iterator over the keys under one prefix that yields `decode(entry,
/// prefix_length)` for each. It follows the module's iterator contract.
fn KeyRangeIterator(comptime Item: type, comptime decode: fn (PrefixIterator.Entry, usize) Item) type {
    return struct {
        inner: PrefixIterator,
        prefix_length: usize,

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
        }

        /// Returns the next item, or `null` at the end.
        pub fn next(self: *@This()) StorageError!?Item {
            const entry = try self.inner.next() orelse return null;
            return decode(entry, self.prefix_length);
        }
    };
}

/// A stored property: its name and encoded value (views into the store).
pub const Property = struct {
    name: []const u8,
    encoded_value: []const u8,

    /// The value, with its strings and lists allocated with `allocator`.
    pub fn value(self: Property, allocator: Allocator) Allocator.Error!Value {
        return value_encoding.decodeValue(self.encoded_value, allocator);
    }
};

/// A node record an iterator reads, and who frees it (null: a view).
const HeldRecord = struct {
    record: NodeRecord,
    owner: ?Allocator = null,

    fn release(self: HeldRecord) void {
        if (self.owner) |allocator| allocator.free(self.record.bytes);
    }
};

/// The labels of a node, in byte order (views into its record).
pub const LabelIterator = struct {
    inner: node_record.LabelIterator,
    held: HeldRecord,

    pub fn deinit(self: *LabelIterator) void {
        self.held.release();
    }

    pub fn next(self: *LabelIterator) StorageError!?[]const u8 {
        return self.inner.next();
    }
};

/// The properties of a node (from its record) or of an edge (from its keys),
/// in name order.
pub const PropertyIterator = struct {
    source: union(enum) {
        record: node_record.PropertyIterator,
        keys: KeyRangeIterator(Property, struct {
            fn decode(entry: PrefixIterator.Entry, prefix_length: usize) Property {
                return .{ .name = entry.key[prefix_length..], .encoded_value = entry.value };
            }
        }.decode),
    },
    held: HeldRecord = .{ .record = .empty },

    pub fn deinit(self: *PropertyIterator) void {
        switch (self.source) {
            .record => {},
            .keys => |*keys| keys.deinit(),
        }
        self.held.release();
    }

    pub fn next(self: *PropertyIterator) StorageError!?Property {
        return switch (self.source) {
            .record => |*record| if (record.next()) |p| .{ .name = p.name, .encoded_value = p.encoded_value } else null,
            .keys => |*keys| keys.next(),
        };
    }
};

pub const EdgeKeyIterator = KeyRangeIterator(EdgeKey, struct {
    fn decode(entry: PrefixIterator.Entry, _: usize) EdgeKey {
        return key_encoding.decodeEdgeKey(entry.key);
    }
}.decode);

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
