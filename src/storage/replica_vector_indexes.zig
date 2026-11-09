//! A replica's vector indexes. The change log does not carry their keys
//! (`KeyValueStore.put`): a vector index costs a replica the work of
//! keeping it, not the master's log the bytes of every neighbour list it
//! rewrites. So a replica moves each entity in its own indexes as it
//! applies the write that changed it, as its master did when it made that
//! write: the same writes in the same order make the same HNSW graph
//! (an entity's level comes from its id). Applying a vector index's
//! definition starts populating it from the data there, as the master's
//! CREATE did, and in the background (vector_population.zig) the same way:
//! where population and writes interleave differently, the replica's graph
//! differs from its master's, each sound. Applying its removal drops its keys.

const std = @import("std");

const Graph = @import("graph.zig").Graph;
const KeyValueStore = @import("key_value_store.zig").KeyValueStore;
const StorageError = @import("key_value_store.zig").StorageError;
const NodeRecord = @import("node_record.zig").NodeRecord;
const change_log = @import("change_log.zig");
const fulltext = @import("fulltext.zig");
const key_encoding = @import("key_encoding.zig");
const value_encoding = @import("value_encoding.zig");
const vector_index = @import("vector_index.zig");
const vector_population = @import("vector_population.zig");

/// Told of each write of the change sets a replica applies
/// (`change_log.Application.add`), in one write transaction of `store`.
pub const Observer = struct {
    graph: Graph,
    /// What `before` saw that `after` needs, for the one write between.
    scratch: std.heap.ArenaAllocator,
    /// The node's record before a write to it.
    old_record: NodeRecord = .empty,
    /// The id of the vector index whose definition a write removes.
    dropped_index: ?u32 = null,

    pub fn init(store: *KeyValueStore) Observer {
        return .{ .graph = Graph.init(store, store.allocator), .scratch = .init(store.allocator) };
    }

    pub fn deinit(self: *Observer) void {
        self.scratch.deinit();
    }

    pub fn before(self: *Observer, change: change_log.Change) StorageError!void {
        _ = self.scratch.reset(.retain_capacity);
        self.old_record = .empty;
        self.dropped_index = null;
        switch (change.table) {
            .nodes => {
                if (!try vector_index.exist(&self.graph)) return;
                const old = try self.graph.store.viewNode(nodeId(change)) orelse return;
                self.old_record = .{ .bytes = try self.scratch.allocator().dupe(u8, old) };
            },
            .main => {
                if (change.operation != .delete or !isDefinition(change.key)) return;
                const old = try self.graph.store.view(change.key) orelse return;
                const definition = try fulltext.Definition.decode(change.key[1..], old, self.scratch.allocator());
                if (definition.kind == .vector) self.dropped_index = definition.index_id;
            },
            else => {},
        }
    }

    pub fn after(self: *Observer, change: change_log.Change) StorageError!void {
        switch (change.table) {
            .nodes => {
                if (!try vector_index.exist(&self.graph)) return;
                const new: NodeRecord = if (change.operation == .put) .{ .bytes = change.value } else .empty;
                try vector_index.nodeChanged(&self.graph, nodeId(change), self.old_record, new, null);
            },
            .main => try self.afterMain(change),
            else => {},
        }
    }

    fn afterMain(self: *Observer, change: change_log.Change) StorageError!void {
        const store = self.graph.store;
        if (std.mem.eql(u8, change.key, fulltext.schema_version_key)) {
            // The definitions changed: what this transaction knew of them is stale.
            store.write_transaction_memo.schema_version = null;
            store.forgetSchemaDefinitions();
            return;
        }
        if (isDefinition(change.key)) {
            if (self.dropped_index) |index_id| return vector_index.clear(&self.graph, index_id);
            if (change.operation != .put) return;
            const definition = try fulltext.Definition.decode(change.key[1..], change.value, self.scratch.allocator());
            if (definition.kind == .vector) try vector_population.start(&self.graph, definition);
            return;
        }
        // A relationship property: `f | relationship id | name`.
        if (change.key.len <= 9 or change.key[0] != key_encoding.edge_property_marker) return;
        if (!try vector_index.exist(&self.graph)) return;
        const id = std.mem.readInt(u64, change.key[1..9], .big);
        const name = change.key[9..];
        if (change.operation == .delete) return vector_index.relationshipPropertyRemoved(&self.graph, id, name);
        const arena = self.scratch.allocator();
        const stored = try self.graph.relationship(id, arena) orelse return;
        const value = try value_encoding.decodeValue(change.value, arena);
        try vector_index.relationshipPropertyChanged(&self.graph, id, stored.edge_type, name, value);
    }
};

/// The node a write to `.nodes` is to (applying it refuses a key of another
/// length).
fn nodeId(change: change_log.Change) u64 {
    if (change.key.len != @sizeOf(u64)) return 0;
    return std.mem.bytesToValue(u64, change.key[0..@sizeOf(u64)]);
}

fn isDefinition(key: []const u8) bool {
    return key.len > 1 and key[0] == fulltext.definition_marker;
}
