//! The graph: nodes, labels, typed edges and properties, with their indexes,
//! stored as keys in a `KeyValueStore` (see key_encoding.zig for the layout).
//!
//! Index-free adjacency: each directed, typed edge is stored twice, keyed by
//! its source (outgoing) and by its target (incoming), so the neighbours of a
//! node in either direction are one prefix scan.
//!
//! Costs. With N keys in the store, a point lookup or write is one B+-tree
//! descent in the storage engine, O(log N); a scan yielding k entries is O(log N + k). Each
//! operation below states its cost in those terms.
//!
//! Iterators (`NodeIdIterator`, `EdgeIterator`) share one concept:
//! `next() StorageError!?T` yields the next item or null at the end, and
//! `deinit()` releases the engine's cursor. Slices inside a yielded item (an edge
//! type) are views into the store, valid only until the next `next` call.
//! Iterators opened inside a transaction must be `deinit`ed before it ends.

const std = @import("std");

const KeyValueStore = @import("key_value_store.zig").KeyValueStore;
const StorageError = @import("key_value_store.zig").StorageError;
const PrefixIterator = @import("key_value_store.zig").PrefixIterator;

const Allocator = std.mem.Allocator;

const key_encoding = @import("key_encoding.zig");
const value_encoding = @import("value_encoding.zig");
const fulltext_postings = @import("fulltext_postings.zig");
const fulltext = @import("fulltext.zig");
const property_indexes = @import("property_indexes.zig");
const constraints = @import("constraints.zig");
const node_record = @import("node_record.zig");
const layout = @import("layout.zig");
const NodeRecord = node_record.NodeRecord;

pub const NodeId = key_encoding.NodeId;
pub const RelationshipId = key_encoding.RelationshipId;
pub const RelationshipRecord = key_encoding.RelationshipRecord;
pub const Direction = key_encoding.Direction;
pub const EdgeKey = key_encoding.EdgeKey;
pub const Value = @import("../value.zig").Value;

/// Errors of graph writes: storage failures, or a value that cannot be stored
/// as a property (see `value_encoding.isStorable`).
/// `UnsupportedPropertyType`: a value no property can hold; `ValueTooLarge`:
/// one whose stored form is longer than `layout.max_value_length`.
pub const GraphError = StorageError || error{ UnsupportedPropertyType, ValueTooLarge };

// ---------------------------------------------------------------------------
// Graph (index-free adjacency over KeyValueStore)
// ---------------------------------------------------------------------------

/// Thin graph view over a `KeyValueStore`, implementing index-free adjacency:
/// `addEdge` writes both directions, `neighbours` is a single prefix scan.
pub const Graph = struct {
    store: *KeyValueStore,
    allocator: Allocator,
    /// What the last `error.ConstraintViolation` broke.
    violation: [256]u8 = undefined,
    violation_length: usize = 0,

    pub fn init(store: *KeyValueStore, allocator: Allocator) Graph {
        return .{ .store = store, .allocator = allocator };
    }

    /// The message of the last `error.ConstraintViolation`.
    pub fn violationMessage(self: *const Graph) []const u8 {
        return self.violation[0..self.violation_length];
    }

    pub fn setViolation(self: *Graph, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.violation, fmt, args) catch &self.violation;
        self.violation_length = written.len;
    }

    /// The storage format this code writes and reads. A database in another
    /// format is refused. 1 is the format of the first release; a later
    /// change to how keys or values are written raises it.
    pub const format_version: u32 = 1;

    /// Stamps a new database with this code's format, and refuses one
    /// written in another (`error.IncompatibleFormat`). Call it after
    /// opening, before anything else.
    pub fn checkFormat(self: *Graph) StorageError!void {
        if (try self.store.get(key_encoding.format_key)) |raw| {
            defer self.store.allocator.free(raw);
            if (raw.len != 4 or std.mem.readInt(u32, raw[0..4], .big) != format_version) return error.IncompatibleFormat;
            return;
        }
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, format_version, .big);
        try self.store.put(key_encoding.format_key, &bytes);
    }

    /// Begins an atomic write transaction; see `commitWrite`/`abortWrite`. All
    /// mutations until then are batched into one transaction.
    pub fn beginWrite(self: *Graph) StorageError!void {
        return self.store.beginWrite();
    }

    /// Commits the write transaction, with the relationship ids it allocated
    /// (every commit of a write transaction goes through here).
    pub fn commitWrite(self: *Graph) StorageError!void {
        if (self.store.write_transaction_memo.next_relationship_id) |next| {
            try self.setCounter(key_encoding.relationship_counter_key, next);
        }
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
        if (!try self.hasNode(id)) {
            try self.writeRecord(id, "");
            // A caller-chosen id is never handed out by `allocateNodeId` later.
            if (id >= try self.nextNodeId()) try self.setNextNodeId(id +| 1);
        }
        if (label.len > 0) try self.addLabel(id, label);
    }

    /// Adds a label to a node (its record and the label index). Idempotent.
    /// Fails with `TooManyLabels` past `layout.max_labels`.
    pub fn addLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!void {
        layout.assertName(label); // callers refuse others
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse NodeRecord.empty;
        if (record.hasLabel(label)) return;
        if (record.labelCount() == layout.max_labels) return error.TooManyLabels;
        const old = try self.keptRecord(record, scratch.allocator());
        const updated = try node_record.withLabel(scratch.allocator(), record, label, true);
        try constraints.checkNode(self, id, .{ .bytes = updated });
        try self.writeRecord(id, updated);
        try fulltext_postings.nodeChanged(self, id, old, .{ .bytes = updated }, null);
        try property_indexes.nodeChanged(self, id, old, .{ .bytes = updated }, null);

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendLabelKey(&key, self.allocator, label, id);
        try self.store.put(key.items, "");
        try self.bumpLabelCount(label, true);
        try self.refreshNeighbourLabels(id);
    }

    /// Removes a label from a node (its record and the label index). Idempotent.
    pub fn removeLabel(self: *Graph, id: NodeId, label: []const u8) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse return;
        if (!record.hasLabel(label)) return;
        const old = try self.keptRecord(record, scratch.allocator());
        const updated = try node_record.withLabel(scratch.allocator(), record, label, false);
        try self.writeRecord(id, updated);
        try fulltext_postings.nodeChanged(self, id, old, .{ .bytes = updated }, null);
        try property_indexes.nodeChanged(self, id, old, .{ .bytes = updated }, null);

        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try key_encoding.appendLabelKey(&key, self.allocator, label, id);
        try self.store.del(key.items);
        try self.bumpLabelCount(label, false);
        try self.refreshNeighbourLabels(id);
    }

    /// `record` as it must be kept across a write to its node: a copy if a
    /// full-text index may need the old record (a write can move the view's
    /// page), else the view itself, which nothing reads afterwards.
    fn keptRecord(self: *Graph, record: NodeRecord, scratch: Allocator) StorageError!NodeRecord {
        if (try fulltext.schemaVersion(self) == 0) return record;
        return .{ .bytes = try scratch.dupe(u8, record.bytes) };
    }

    /// A copy of node `id`'s record, made with `allocator` ("" if no such node).
    pub fn recordCopy(self: *Graph, id: NodeId, allocator: Allocator) StorageError![]const u8 {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse return "";
        return allocator.dupe(u8, record.bytes);
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
        const next = try self.nextNodeId();
        try self.setNextNodeId(next + 1);
        return next;
    }

    /// The id `allocateNodeId` gives next.
    fn nextNodeId(self: *Graph) StorageError!NodeId {
        return self.counter(key_encoding.counter_key);
    }

    fn setNextNodeId(self: *Graph, next: NodeId) StorageError!void {
        return self.setCounter(key_encoding.counter_key, next);
    }

    /// Allocates a fresh, never-used relationship id (persistent counter).
    /// Inside a write transaction the counter is read once and written when
    /// it commits, so an id costs nothing more; otherwise O(log N).
    fn allocateRelationshipId(self: *Graph) StorageError!RelationshipId {
        const memo = &self.store.write_transaction_memo;
        if (self.store.active_write_transaction != null) {
            const next = memo.next_relationship_id orelse try self.counter(key_encoding.relationship_counter_key);
            memo.next_relationship_id = next + 1;
            return next;
        }
        const next = try self.counter(key_encoding.relationship_counter_key);
        try self.setCounter(key_encoding.relationship_counter_key, next + 1);
        return next;
    }

    /// The 8-byte big-endian counter at `key` (0 if absent).
    fn counter(self: *Graph, key: []const u8) StorageError!u64 {
        const raw = (try self.store.get(key)) orelse return 0;
        defer self.allocator.free(raw);
        return if (raw.len == 8) std.mem.readInt(u64, raw[0..8], .big) else 0;
    }

    fn setCounter(self: *Graph, key: []const u8, value: u64) StorageError!void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, value, .big);
        try self.store.put(key, &buffer);
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
            try self.bumpLabelCount(label, false);
        }
        try property_indexes.nodeChanged(self, id, record, NodeRecord.empty, null);
        try fulltext_postings.nodeChanged(self, id, record, NodeRecord.empty, null);
        try self.store.deleteNode(id);
    }

    fn deleteEdgesInDirection(self: *Graph, id: NodeId, direction: Direction) StorageError!void {
        // Collect first, so the scan cursor is not open across the deletes.
        var relationships = std.ArrayList(RelationshipId).empty;
        defer relationships.deinit(self.allocator);
        {
            var iterator = try self.edgesOf(id, direction);
            defer iterator.deinit();
            while (try iterator.next()) |key| try relationships.append(self.allocator, key.relationship);
        }
        for (relationships.items) |relationship_id| try self.deleteEdge(relationship_id);
    }

    /// Deletes relationship `id`: both edge keys, its record, its properties
    /// and their index entries, and its type count. Idempotent.
    /// O(log N · (1 + properties)).
    pub fn deleteEdge(self: *Graph, id: RelationshipId) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const stored = try self.relationship(id, arena) orelse return;

        var key = std.ArrayList(u8).empty;
        try key_encoding.appendEdgeKey(&key, arena, stored.src, .out, stored.edge_type, stored.dst, id);
        try self.store.del(key.items);
        key.clearRetainingCapacity();
        try key_encoding.appendEdgeKey(&key, arena, stored.dst, .in, stored.edge_type, stored.src, id);
        try self.store.del(key.items);
        try self.store.deleteRelationship(id);

        // Collect the properties first, so the cursor is not open across deletes.
        const Stored = struct { name: []const u8, value: Value };
        var properties = std.ArrayList(Stored).empty;
        {
            var iterator = try self.edgePropertiesOf(id);
            defer iterator.deinit();
            while (try iterator.next()) |property| {
                try properties.append(arena, .{ .name = try arena.dupe(u8, property.name), .value = try property.value(arena) });
            }
        }
        for (properties.items) |property| {
            try fulltext_postings.relationshipPropertyChanged(self, id, stored.edge_type, property.name, property.value, null);
            try property_indexes.relationshipPropertyChanged(self, id, stored.edge_type, property.name, property.value, null);
            key.clearRetainingCapacity();
            try key_encoding.appendEdgePropertyKey(&key, arena, id, property.name);
            try self.store.del(key.items);
        }

        try self.bumpEdgeType(stored.edge_type, false);
    }

    /// Relationship `id`'s ends and type (the type copied with `allocator`),
    /// or null if there is no such relationship. O(log N).
    pub fn relationship(self: *Graph, id: RelationshipId, allocator: Allocator) StorageError!?RelationshipRecord {
        const in_transaction = self.store.inTransaction();
        if (!in_transaction) try self.store.beginRead();
        defer if (!in_transaction) self.store.abortRead();
        const raw = (try self.store.viewRelationship(id)) orelse return null;
        return try copyRecord(raw, allocator);
    }

    fn copyRecord(raw: []const u8, allocator: Allocator) Allocator.Error!RelationshipRecord {
        const record = key_encoding.decodeRelationshipRecord(raw);
        return .{ .src = record.src, .dst = record.dst, .edge_type = try allocator.dupe(u8, record.edge_type) };
    }

    /// True if relationship `id` exists. O(log N).
    pub fn hasRelationship(self: *Graph, id: RelationshipId) StorageError!bool {
        const in_transaction = self.store.inTransaction();
        if (!in_transaction) try self.store.beginRead();
        defer if (!in_transaction) self.store.abortRead();
        return try self.store.viewRelationship(id) != null;
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
    /// list fails with `UnsupportedPropertyType`, a value too long
    /// `ValueTooLarge`. O(log N).
    pub fn setProperty(self: *Graph, id: NodeId, name: []const u8, value: Value) GraphError!void {
        if (value == .null) return self.removeProperty(id, name);
        if (!value_encoding.isStorable(value)) return error.UnsupportedPropertyType;
        layout.assertName(name); // callers refuse others
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse NodeRecord.empty;
        var encoded = std.ArrayList(u8).empty;
        try value_encoding.encodeValue(&encoded, scratch.allocator(), value);
        if (encoded.items.len > layout.max_value_length) return error.ValueTooLarge;
        const updated = try node_record.withProperty(scratch.allocator(), record, name, encoded.items);
        try constraints.checkNode(self, id, .{ .bytes = updated });
        const old_record = try self.keptRecord(record, scratch.allocator());
        try self.writeRecord(id, updated);
        try property_indexes.nodeChanged(self, id, old_record, .{ .bytes = updated }, name);
        try fulltext_postings.nodeChanged(self, id, old_record, .{ .bytes = updated }, name);
    }

    /// Removes a typed property `name` from node `id` (and its index entry).
    /// Idempotent.
    pub fn removeProperty(self: *Graph, id: NodeId, name: []const u8) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const record = try self.readRecord(id, scratch.allocator()) orelse return;
        if (record.property(name) == null) return;
        const updated = try node_record.withProperty(scratch.allocator(), record, name, null);
        const old_record = try self.keptRecord(record, scratch.allocator());
        try self.writeRecord(id, updated);
        try property_indexes.nodeChanged(self, id, old_record, .{ .bytes = updated }, name);
        try fulltext_postings.nodeChanged(self, id, old_record, .{ .bytes = updated }, name);
    }

    /// Iterates the nodes the node index `index_id` holds under `value`, in
    /// ascending node-id order: a superset of those whose property equals it
    /// (long values share keys), so callers recheck. O(log N + matches).
    pub fn nodesByIndex(self: *Graph, index_id: u32, value: Value) StorageError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try property_indexes.appendValuePrefix(&prefix, self.allocator, index_id, value);
        const iterator = try self.store.scanPrefix(prefix.items);
        return .{ .inner = iterator };
    }

    /// The nodes whose indexed property may lie between `lower` and `upper`
    /// (either may be null: unbounded), from node index `index_id`: a superset
    /// of the nodes where the comparison holds, so callers still check it.
    /// Numbers (integers and floats, which compare with each other), strings,
    /// dates, times and date-times have ranges; for other values this is null
    /// (scan instead).
    /// O(log N + the nodes in range).
    pub fn nodesInRange(self: *Graph, index_id: u32, lower: ?Value, upper: ?Value) StorageError!?NodeIdIterator {
        const bound = lower orelse upper orelse return null;
        switch (bound) {
            .int, .float => {
                for ([_]?Value{ lower, upper }) |b| if (b) |v| switch (v) {
                    .int => {},
                    .float => |x| if (std.math.isNan(x)) return try self.emptyRange(index_id),
                    else => return null,
                };
                // Integral floats are indexed as integers: integers and the
                // other floats are two key ranges.
                const low_int: i64 = if (lower) |v| floorInteger(v) else std.math.minInt(i64);
                const high_int: i64 = if (upper) |v| ceilInteger(v) else std.math.maxInt(i64);
                var iterator = try self.indexRange(index_id, .int, value_encoding.orderedInteger(low_int), value_encoding.orderedInteger(high_int));
                errdefer iterator.deinit();
                const low_float = value_encoding.orderedFloat(if (lower) |v| asFloat(v) else -std.math.inf(f64));
                const high_float = value_encoding.orderedFloat(if (upper) |v| asFloat(v) else std.math.inf(f64));
                iterator.second = (try self.indexRange(index_id, .float, low_float, high_float)).inner;
                return iterator;
            },
            .date, .local_time, .time, .local_date_time, .date_time => {
                for ([_]?Value{ lower, upper }) |b| if (b) |v| if (std.meta.activeTag(v) != std.meta.activeTag(bound)) return null;
                const low: i64 = if (lower) |v| temporalKey(v) else std.math.minInt(i64);
                const high: i64 = if (upper) |v| temporalKey(v) else std.math.maxInt(i64);
                return try self.indexRange(index_id, temporalTag(bound), value_encoding.orderedInteger(low), value_encoding.orderedInteger(high));
            },
            .string => {
                for ([_]?Value{ lower, upper }) |b| if (b) |v| if (v != .string) return null;
                return try self.stringRange(index_id, lower, upper);
            },
            else => return null,
        }
    }

    /// The keys of index `index_id` holding a string between `lower` and
    /// `upper` (strings or null). A string's index form (its bytes, then a
    /// 0x00, cut at `property_indexes.max_value_bytes`) never sorts after a
    /// greater string's, so the forms of the bounds bound the keys: long
    /// values are found by their kept bytes, a superset callers recheck.
    fn stringRange(self: *Graph, index_id: u32, lower: ?Value, upper: ?Value) StorageError!?NodeIdIterator {
        // A form that is a proper prefix of the upper bound's would sort before
        // it only up to the entity id that follows: that takes a 0x00 inside a
        // string, which scans instead.
        if (upper) |v| if (std.mem.indexOfScalar(u8, v.string, 0) != null) return null;
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try property_indexes.appendPrefix(&prefix, self.allocator, index_id);
        try prefix.append(self.allocator, @backingInt(value_encoding.Tag.string));
        var start = std.ArrayList(u8).empty;
        defer start.deinit(self.allocator);
        if (lower) |v| try property_indexes.appendValuePrefix(&start, self.allocator, index_id, v) else try start.appendSlice(self.allocator, prefix.items);
        var end = std.ArrayList(u8).empty;
        defer end.deinit(self.allocator);
        if (upper) |v| {
            try property_indexes.appendValuePrefix(&end, self.allocator, index_id, v);
            try end.appendNTimes(self.allocator, 0xff, key_encoding.node_id_length); // every node id
        }
        return .{ .inner = try self.store.scanRange(prefix.items, start.items, if (upper != null) end.items else null) };
    }

    /// The keys of index `index_id` holding a `tag` value whose ordered
    /// 8-byte encoding is between `low` and `high`, inclusive.
    fn indexRange(self: *Graph, index_id: u32, tag: value_encoding.Tag, low: u64, high: u64) StorageError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try property_indexes.appendPrefix(&prefix, self.allocator, index_id);
        try prefix.append(self.allocator, @backingInt(tag));
        var start = std.ArrayList(u8).empty;
        defer start.deinit(self.allocator);
        try start.appendSlice(self.allocator, prefix.items);
        try appendBig(&start, self.allocator, low);
        var upper = std.ArrayList(u8).empty;
        defer upper.deinit(self.allocator);
        try upper.appendSlice(self.allocator, prefix.items);
        try appendBig(&upper, self.allocator, high);
        try upper.appendNTimes(self.allocator, 0xff, key_encoding.node_id_length); // every node id
        return .{ .inner = try self.store.scanRange(prefix.items, start.items, upper.items) };
    }

    /// The first 8 bytes of a temporal value's index form, as an i64: what
    /// comparisons order it by (a time and a date-time by their instant, at
    /// any offset), or for the date-times its seconds (a superset: the
    /// nanoseconds that follow are rechecked by the caller).
    fn temporalKey(value: Value) i64 {
        return switch (value) {
            .date => |d| d.days,
            .local_time => |t| t.nanoseconds,
            .time => |t| t.utcNanoseconds(),
            .local_date_time => |t| t.seconds,
            .date_time => |t| t.seconds,
            else => unreachable,
        };
    }

    fn temporalTag(value: Value) value_encoding.Tag {
        return switch (value) {
            .date => .date,
            .local_time => .local_time,
            .time => .time,
            .local_date_time => .local_date_time,
            .date_time => .date_time,
            else => unreachable,
        };
    }

    /// An iterator over nothing (a range no value is in, as with a NaN bound).
    fn emptyRange(self: *Graph, index_id: u32) StorageError!NodeIdIterator {
        return self.indexRange(index_id, .int, 1, 0);
    }

    fn appendBig(list: *std.ArrayList(u8), allocator: Allocator, n: u64) Allocator.Error!void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, n, .big);
        try list.appendSlice(allocator, &buffer);
    }

    fn asFloat(value: Value) f64 {
        return switch (value) {
            .int => |n| @floatFromInt(n),
            .float => |x| x,
            else => unreachable,
        };
    }

    /// The largest integer at most `value` (saturating), and the smallest at least it.
    fn floorInteger(value: Value) i64 {
        return switch (value) {
            .int => |n| n,
            .float => |x| saturatingInteger(@floor(x)),
            else => unreachable,
        };
    }

    fn ceilInteger(value: Value) i64 {
        return switch (value) {
            .int => |n| n,
            .float => |x| saturatingInteger(@ceil(x)),
            else => unreachable,
        };
    }

    fn saturatingInteger(x: f64) i64 {
        if (x <= -9.223372036854775808e18) return std.math.minInt(i64);
        if (x >= 9.223372036854775807e18) return std.math.maxInt(i64);
        return @intFromFloat(x);
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

    /// Adds a relationship `src -> dst` of type `edge_type` and returns its
    /// new id: both edge keys, its record, its type count. Every call adds
    /// one (relationships between the same nodes may be parallel). O(log N).
    pub fn addEdge(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!RelationshipId {
        layout.assertName(edge_type); // callers refuse others
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const id = try self.allocateRelationshipId();
        try self.writeRelationship(id, src, dst, edge_type, scratch.allocator());
        try self.bumpEdgeType(edge_type, true);
        return id;
    }

    /// Writes relationship `id`'s two edge keys and its record.
    fn writeRelationship(self: *Graph, id: RelationshipId, src: NodeId, dst: NodeId, edge_type: []const u8, scratch: Allocator) StorageError!void {
        var key = std.ArrayList(u8).empty;
        try key_encoding.appendEdgeKey(&key, scratch, src, .out, edge_type, dst, id);
        try self.store.put(key.items, try self.neighbourLabels(dst, scratch));
        key.clearRetainingCapacity();
        try key_encoding.appendEdgeKey(&key, scratch, dst, .in, edge_type, src, id);
        try self.store.put(key.items, try self.neighbourLabels(src, scratch));
        var record = std.ArrayList(u8).empty;
        try key_encoding.appendRelationshipRecord(&record, scratch, src, dst, edge_type);
        try self.store.putRelationship(id, record.items);
    }

    /// The value of an edge key: the labels of the node at its other end, so
    /// an expansion checks a neighbour's labels without reading its record.
    /// A version byte, then the record's label section; an empty value (keys
    /// written before) means the labels are not known.
    fn neighbourLabels(self: *Graph, id: NodeId, scratch: Allocator) StorageError![]const u8 {
        const record = try self.readRecord(id, scratch) orelse NodeRecord.empty;
        const section = record.labelSection();
        const value = try scratch.alloc(u8, 1 + section.len);
        value[0] = neighbour_labels_version;
        @memcpy(value[1..], section);
        return value;
    }

    /// After node `id`'s labels change, rewrites the copy its neighbours'
    /// edge keys keep of them. O(degree): label changes are rare.
    fn refreshNeighbourLabels(self: *Graph, id: NodeId) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const value = try self.neighbourLabels(id, scratch.allocator());
        // Collect first, so no scan cursor is open across the writes.
        const Incident = struct { neighbour: NodeId, direction: Direction, edge_type: []const u8, relationship: RelationshipId };
        var incident = std.ArrayList(Incident).empty;
        for ([_]Direction{ .out, .in }) |direction| {
            var edges = try self.edgesOf(id, direction);
            defer edges.deinit();
            while (try edges.next()) |edge| {
                try incident.append(scratch.allocator(), .{
                    .neighbour = edge.neighbour,
                    // The neighbour's key for this edge points the other way.
                    .direction = if (direction == .out) .in else .out,
                    .edge_type = try scratch.allocator().dupe(u8, edge.edge_type),
                    .relationship = edge.relationship,
                });
            }
        }
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        for (incident.items) |edge| {
            key.clearRetainingCapacity();
            try key_encoding.appendEdgeKey(&key, self.allocator, edge.neighbour, edge.direction, edge.edge_type, id, edge.relationship);
            try self.store.put(key.items, value);
        }
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

    /// True if some relationship `src -> dst` of type `edge_type` exists.
    /// O(log N).
    pub fn hasEdge(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!bool {
        var buffer: [128]u8 = undefined;
        var memory = std.heap.BufferFirstAllocator.init(&buffer, self.allocator);
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(memory.allocator());
        try key_encoding.appendEdgeBetweenPrefix(&prefix, memory.allocator(), src, .out, edge_type, dst);
        return self.store.hasPrefix(prefix.items);
    }

    /// Iterates the relationships `src -> dst` of type `edge_type`, in id
    /// order, as `EdgeKey`s of `src`. O(log N + their number).
    pub fn edgesBetween(self: *Graph, src: NodeId, dst: NodeId, edge_type: []const u8) StorageError!EdgeKeyIterator {
        // Built on the stack: a match tests the edges to each candidate end.
        var buffer: [128]u8 = undefined;
        var memory = std.heap.BufferFirstAllocator.init(&buffer, self.allocator);
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(memory.allocator());
        try key_encoding.appendEdgeBetweenPrefix(&prefix, memory.allocator(), src, .out, edge_type, dst);
        return .{ .inner = try self.store.scanPrefix(prefix.items), .prefix_length = prefix.items.len };
    }

    /// Stores a typed property on relationship `id`. Idempotent. Maintains
    /// the edge-property index. Setting `null` removes the property; a value
    /// that cannot be stored fails with `UnsupportedPropertyType` (or
    /// `ValueTooLarge`). A missing
    /// relationship is left alone. O(log N).
    pub fn setEdgeProperty(self: *Graph, id: RelationshipId, name: []const u8, value: Value) GraphError!void {
        if (value == .null) return self.removeEdgeProperty(id, name);
        if (!value_encoding.isStorable(value)) return error.UnsupportedPropertyType;
        layout.assertName(name); // callers refuse others
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const stored = try self.relationship(id, arena) orelse return;
        const old = try self.getEdgeProperty(id, name, arena);

        var key = std.ArrayList(u8).empty;
        try key_encoding.appendEdgePropertyKey(&key, arena, id, name);
        var encoded = std.ArrayList(u8).empty;
        try value_encoding.encodeValue(&encoded, arena, value);
        if (encoded.items.len > layout.max_value_length) return error.ValueTooLarge;
        try self.store.put(key.items, encoded.items);

        try property_indexes.relationshipPropertyChanged(self, id, stored.edge_type, name, old, value);
        try fulltext_postings.relationshipPropertyChanged(self, id, stored.edge_type, name, old, value);
    }

    /// Removes a typed property from relationship `id`. Idempotent.
    pub fn removeEdgeProperty(self: *Graph, id: RelationshipId, name: []const u8) StorageError!void {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const old = try self.getEdgeProperty(id, name, arena) orelse return;
        const stored = try self.relationship(id, arena) orelse return;
        var key = std.ArrayList(u8).empty;
        try key_encoding.appendEdgePropertyKey(&key, arena, id, name);
        try self.store.del(key.items);
        try property_indexes.relationshipPropertyChanged(self, id, stored.edge_type, name, old, null);
        try fulltext_postings.relationshipPropertyChanged(self, id, stored.edge_type, name, old, null);
    }

    /// Iterates the relationships the relationship index `index_id` holds
    /// under `value`, in id order: a superset of those whose property equals
    /// it (long values share keys), so callers recheck. O(log N · (1 + matches)).
    pub fn edgesByIndex(self: *Graph, index_id: u32, value: Value) StorageError!EdgeIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try property_indexes.appendValuePrefix(&prefix, self.allocator, index_id, value);
        return .{ .graph = self, .inner = try self.store.scanPrefix(prefix.items), .record = .init(self.allocator) };
    }

    /// Reads a typed property of relationship `id`, or `null` if absent.
    pub fn getEdgeProperty(self: *Graph, id: RelationshipId, name: []const u8, allocator: Allocator) StorageError!?Value {
        var key_buffer: [256]u8 = undefined;
        var key_memory = std.heap.BufferFirstAllocator.init(&key_buffer, self.allocator);
        const key_allocator = key_memory.allocator();
        var key = std.ArrayList(u8).empty;
        defer key.deinit(key_allocator);
        try key_encoding.appendEdgePropertyKey(&key, key_allocator, id, name);
        return self.readValue(key.items, allocator);
    }

    /// Iterates the neighbours of `id` in the given `direction` and `edge_type`,
    /// in ascending neighbour-id order (the store's lexicographic order).
    /// O(log N + degree).
    pub fn neighbours(self: *Graph, id: NodeId, direction: Direction, edge_type: []const u8) StorageError!NodeIdIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendEdgePrefix(&prefix, self.allocator, id, direction, edge_type);
        const iterator = try self.store.scanPrefix(prefix.items);
        // The neighbour's id comes before the relationship's.
        return .{ .inner = iterator, .trailing_length = key_encoding.node_id_length };
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

    /// Iterates the properties of relationship `id`, in name order (views
    /// into the store). O(log N + properties).
    pub fn edgePropertiesOf(self: *Graph, id: RelationshipId) StorageError!PropertyIterator {
        var prefix = std.ArrayList(u8).empty;
        defer prefix.deinit(self.allocator);
        try key_encoding.appendEdgePropertyPrefix(&prefix, self.allocator, id);
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

    /// The labels some node carries, in byte order, from the label counters
    /// (copies made with `allocator`). O(labels ever used).
    pub fn labelNames(self: *Graph, allocator: Allocator) StorageError![]const []const u8 {
        return self.countedNames(key_encoding.label_count_marker, allocator);
    }

    /// The types some relationship has, in byte order (copies made with
    /// `allocator`). O(types ever used).
    pub fn relationshipTypeNames(self: *Graph, allocator: Allocator) StorageError![]const []const u8 {
        return self.countedNames(key_encoding.edge_type_marker, allocator);
    }

    /// The names under counter keys `marker | name` whose count is not zero.
    fn countedNames(self: *Graph, marker: u8, allocator: Allocator) StorageError![]const []const u8 {
        var names = std.ArrayList([]const u8).empty;
        var keys = try self.store.scanPrefix(&.{marker});
        defer keys.deinit();
        while (try keys.next()) |entry| {
            if (entry.value.len != key_encoding.node_id_length) continue;
            if (std.mem.readInt(u64, entry.value[0..8], .big) == 0) continue;
            try names.append(allocator, try allocator.dupe(u8, entry.key[1..]));
        }
        return names.items;
    }

    /// Number of nodes carrying `label`, from a maintained counter: O(log N).
    /// A database written before the counters existed has none for a label
    /// until its next change: then the label index is counted instead.
    pub fn labelCount(self: *Graph, label: []const u8) StorageError!usize {
        if (try self.storedLabelCount(label)) |count| return @intCast(count);
        return self.countLabelIndex(label);
    }

    fn storedLabelCount(self: *Graph, label: []const u8) StorageError!?u64 {
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendLabelCountKey(&key, self.allocator, label);
        const raw = (try self.store.get(key.items)) orelse return null;
        defer self.store.allocator.free(raw);
        if (raw.len != key_encoding.node_id_length) return null;
        return std.mem.readInt(u64, @ptrCast(raw.ptr), .big);
    }

    /// O(log N + nodes with the label).
    fn countLabelIndex(self: *Graph, label: []const u8) StorageError!usize {
        var iterator = try self.nodesWithLabel(label);
        defer iterator.deinit();
        var count: usize = 0;
        while (try iterator.next()) |_| count += 1;
        return count;
    }

    /// Updates `label`'s counter after a node gained (or lost) it and the
    /// label index changed. A missing counter starts from the index's count.
    fn bumpLabelCount(self: *Graph, label: []const u8, increment: bool) StorageError!void {
        const count: u64 = if (try self.storedLabelCount(label)) |stored|
            (if (increment) stored + 1 else stored -| 1)
        else
            try self.countLabelIndex(label);
        var key = std.ArrayList(u8).empty;
        defer key.deinit(self.allocator);
        try appendLabelCountKey(&key, self.allocator, label);
        var buffer: [key_encoding.node_id_length]u8 = undefined;
        std.mem.writeInt(u64, &buffer, count, .big);
        try self.store.put(key.items, &buffer);
    }

    fn appendLabelCountKey(key: *std.ArrayList(u8), allocator: Allocator, label: []const u8) Allocator.Error!void {
        try key.append(allocator, key_encoding.label_count_marker);
        try key.appendSlice(allocator, label);
    }
};

/// Iterator over node ids decoded from the trailing 8 bytes of scanned keys
/// (edge keys or label-index keys). Owns the underlying engine
/// transaction/cursor; `deinit` releases them.
pub const NodeIdIterator = struct {
    inner: PrefixIterator,
    /// A second key range, scanned after `inner` (see `Graph.nodesInRange`).
    second: ?PrefixIterator = null,
    /// When set, only keys of exactly this length are yielded (others skipped).
    key_length: ?usize = null,
    /// The keys are node ids in native byte order (the node table's).
    native_keys: bool = false,
    /// Bytes after the node id at the end of each key (an edge key's
    /// relationship id).
    trailing_length: usize = 0,

    pub fn deinit(self: *NodeIdIterator) void {
        self.inner.deinit();
        if (self.second) |*second| second.deinit();
    }

    /// Returns the next node id, or `null` at the end.
    pub fn next(self: *NodeIdIterator) StorageError!?NodeId {
        while (true) {
            while (try self.inner.next()) |entry| {
                if (self.key_length) |len| {
                    if (entry.key.len != len) continue;
                }
                if (self.native_keys) return std.mem.readInt(NodeId, entry.key[0..8], .native);
                const end = entry.key.len - self.trailing_length;
                return key_encoding.readNodeId(entry.key[end - key_encoding.node_id_length .. end]);
            }
            const second = self.second orelse return null;
            self.inner.deinit();
            self.inner = second;
            self.second = null;
        }
    }
};

/// Backward-compatible name for `NodeIdIterator` (neighbour scans).
pub const NeighbourIterator = NodeIdIterator;

/// Iterator over directed edges (`src`, `dst`) decoded from edge-property index
/// keys. Owns the underlying engine transaction/cursor.
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
        var key = key_encoding.decodeEdgeKey(entry.key);
        if (entry.value.len > 0 and entry.value[0] == neighbour_labels_version) key.neighbour_labels = entry.value[1..];
        return key;
    }
}.decode);

/// The format of the neighbour labels an edge key's value holds.
pub const neighbour_labels_version: u8 = 1;

/// The relationships an edge-property index scan finds, with their ends
/// and type (`edge_type` valid until the next `next` call).
pub const EdgeIterator = struct {
    graph: *Graph,
    inner: PrefixIterator,
    /// Holds the current relationship's type.
    record: std.heap.ArenaAllocator,

    pub const Found = struct { id: RelationshipId, src: NodeId, dst: NodeId, edge_type: []const u8 };

    pub fn deinit(self: *EdgeIterator) void {
        self.inner.deinit();
        self.record.deinit();
    }

    /// Returns the next relationship, or `null` at the end.
    pub fn next(self: *EdgeIterator) StorageError!?Found {
        while (try self.inner.next()) |entry| {
            const id = key_encoding.readNodeId(entry.key[entry.key.len - key_encoding.node_id_length ..]);
            _ = self.record.reset(.retain_capacity);
            const stored = try self.graph.relationship(id, self.record.allocator()) orelse continue;
            return .{ .id = id, .src = stored.src, .dst = stored.dst, .edge_type = stored.edge_type };
        }
        return null;
    }
};
