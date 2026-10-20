//! A per-query cache of node labels and properties read from storage.
//!
//! Graph queries often reach the same nodes again and again (every member
//! of a group reaches the group), and each read is a B-tree search. Within a
//! read-only query the data cannot change (it reads one snapshot), so a value
//! read once can be kept for the rest of the query. A query that writes runs
//! with the cache off.
//!
//! Keys hold the name's address, not its text: names come from the query's
//! AST, which stores each once, so equal names mostly share an address (and
//! two addresses for one name only cost a second read).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("../storage/graph.zig").Graph;
const NodeId = @import("../storage/graph.zig").NodeId;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;

pub const ReadCache = struct {
    enabled: bool = false,
    labels: std.AutoHashMapUnmanaged(Key, bool) = .empty,
    properties: std.AutoHashMapUnmanaged(Key, ?Value) = .empty,

    const Key = struct { id: NodeId, name: usize, length: usize };

    fn key(id: NodeId, name: []const u8) Key {
        return .{ .id = id, .name = @intFromPtr(name.ptr), .length = name.len };
    }

    /// `graph.hasLabel`, remembered.
    pub fn hasLabel(self: *ReadCache, graph: *Graph, allocator: Allocator, id: NodeId, label: []const u8) (StorageError || Allocator.Error)!bool {
        if (!self.enabled) return graph.hasLabel(id, label);
        const entry = try self.labels.getOrPut(allocator, key(id, label));
        if (!entry.found_existing) entry.value_ptr.* = try graph.hasLabel(id, label);
        return entry.value_ptr.*;
    }

    /// `graph.getProperty` (allocating with `allocator`), remembered.
    pub fn property(self: *ReadCache, graph: *Graph, allocator: Allocator, id: NodeId, name: []const u8) (StorageError || Allocator.Error)!?Value {
        if (!self.enabled) return graph.getProperty(id, name, allocator);
        const entry = try self.properties.getOrPut(allocator, key(id, name));
        if (!entry.found_existing) entry.value_ptr.* = try graph.getProperty(id, name, allocator);
        return entry.value_ptr.*;
    }
};
