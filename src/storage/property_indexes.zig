//! Property indexes: what `CREATE INDEX FOR (n:Label) ON (n.p)` (and a
//! uniqueness constraint, which owns one) makes, and how changes to the
//! graph keep them current.
//!
//! An index covers one label (or relationship type) and one property: the
//! entities with that label and property are its entries, ordered by value.
//! Keys:
//!
//!     p | index id (u32) | value | entity id (u64)
//!
//! The index id comes from the definition (fulltext.zig), so the keys of
//! one index are one prefix, and a label's name is not repeated in each key.
//! The value is in index form (`value_encoding.encodeIndexValue`: ordered,
//! integral floats as integers). A value longer than `max_value_bytes` keeps
//! only its first `max_value_bytes` and then `truncated_mark`: the storage
//! engine's keys are short (about 2 KB with 4 KB pages), and an index lookup
//! is a superset that callers recheck anyway. Two long values with one
//! prefix are one key prefix, found together.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("graph.zig").Graph;
const NodeId = @import("graph.zig").NodeId;
const RelationshipId = @import("graph.zig").RelationshipId;
const NodeRecord = @import("node_record.zig").NodeRecord;
const StorageError = @import("key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const value_encoding = @import("value_encoding.zig");
const key_encoding = @import("key_encoding.zig");
const fulltext = @import("fulltext.zig");

pub const marker: u8 = 'p';

/// The longest value an index key holds whole.
pub const max_value_bytes: usize = 512;

/// Follows the first `max_value_bytes` of a longer value. (A lookup may
/// also find other values' keys: every caller rechecks its candidates.)
pub const truncated_mark: u8 = 0xff;

/// Appends the first bytes of every key of index `index_id`.
pub fn appendPrefix(key: *std.ArrayList(u8), allocator: Allocator, index_id: u32) Allocator.Error!void {
    try key.append(allocator, marker);
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, index_id, .big);
    try key.appendSlice(allocator, &buffer);
}

/// Appends `value` as a key holds it: its index form, truncated past
/// `max_value_bytes`.
pub fn appendValue(key: *std.ArrayList(u8), allocator: Allocator, value: Value) Allocator.Error!void {
    const start = key.items.len;
    try value_encoding.encodeIndexValue(key, allocator, value);
    if (key.items.len - start <= max_value_bytes) return;
    key.shrinkRetainingCapacity(start + max_value_bytes);
    try key.append(allocator, truncated_mark);
}

/// Appends the prefix of the entries of index `index_id` whose value is
/// `value` (and of longer values that share its kept bytes).
pub fn appendValuePrefix(key: *std.ArrayList(u8), allocator: Allocator, index_id: u32, value: Value) Allocator.Error!void {
    try appendPrefix(key, allocator, index_id);
    try appendValue(key, allocator, value);
}

/// Appends the key of the entry of entity `id` with `value` in index `index_id`.
pub fn appendKey(key: *std.ArrayList(u8), allocator: Allocator, index_id: u32, value: Value, id: u64) Allocator.Error!void {
    try appendValuePrefix(key, allocator, index_id, value);
    try key_encoding.appendNodeId(key, allocator, id);
}

/// The definition of the index on `property` of `label_or_type` (nodes or
/// relationships, as `entity` says) among `definitions`, if there is one: a
/// range index first, else a uniqueness constraint's on its first property.
pub fn find(definitions: []const fulltext.Definition, entity: fulltext.Entity, label_or_type: []const u8, property: []const u8) ?fulltext.Definition {
    var found: ?fulltext.Definition = null;
    for (definitions) |definition| {
        if (!covers(definition, entity, label_or_type, property)) continue;
        if (definition.kind == .range) return definition;
        found = found orelse definition;
    }
    return found;
}

fn covers(definition: fulltext.Definition, entity: fulltext.Entity, label_or_type: []const u8, property: []const u8) bool {
    return definition.hasPropertyIndex() and definition.entity == entity and
        std.mem.eql(u8, definition.labels_or_types[0], label_or_type) and
        std.mem.eql(u8, definition.properties[0], property);
}

// --- Keeping the indexes current ----------------------------------------------

/// After node `id` changed from `old` to `new` (an empty record: it did not or
/// no longer exists), updates every node index the change concerns.
/// `changed` names the one property that changed, or is null when labels did.
pub fn nodeChanged(graph: *Graph, id: NodeId, old: NodeRecord, new: NodeRecord, changed: ?[]const u8) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return; // no index was ever made
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.all(graph, arena)) |definition| {
        if (!definition.hasPropertyIndex() or definition.entity != .nodes) continue;
        const property = definition.properties[0];
        if (changed) |name| if (!std.mem.eql(u8, name, property)) continue;
        const label = definition.labels_or_types[0];
        const old_value = if (old.hasLabel(label)) old.property(property) else null;
        const new_value = if (new.hasLabel(label)) new.property(property) else null;
        if (old_value != null and new_value != null and std.mem.eql(u8, old_value.?, new_value.?)) continue;
        try replaceEntry(graph, arena, definition.index_id, id, try decoded(arena, old_value), try decoded(arena, new_value));
    }
}

/// After the property `name` of relationship `id` (of type `edge_type`)
/// changed from `old` to `new` (null: absent), updates the relationship
/// indexes it concerns.
pub fn relationshipPropertyChanged(graph: *Graph, id: RelationshipId, edge_type: []const u8, name: []const u8, old: ?Value, new: ?Value) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.all(graph, arena)) |definition| {
        if (!covers(definition, .relationships, edge_type, name)) continue;
        try replaceEntry(graph, arena, definition.index_id, id, old, new);
    }
}

/// Indexes what the graph already holds for a new index.
pub fn populate(graph: *Graph, definition: fulltext.Definition) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const property = definition.properties[0];
    // Collect first: indexing writes, and no scan may be open across writes.
    const Entry = struct { id: u64, value: []const u8 };
    var entries = std.ArrayList(Entry).empty;
    switch (definition.entity) {
        .nodes => {
            var nodes = try graph.nodesWithLabel(definition.labels_or_types[0]);
            defer nodes.deinit();
            while (try nodes.next()) |id| {
                const record = NodeRecord{ .bytes = try graph.recordCopy(id, arena) };
                const value = record.property(property) orelse continue;
                try entries.append(arena, .{ .id = id, .value = value });
            }
        },
        .relationships => {
            // Relationship properties are keys `f | relationship_id | name`.
            var keys = try graph.store.scanPrefix(&.{key_encoding.edge_property_marker});
            defer keys.deinit();
            while (try keys.next()) |entry| {
                if (!std.mem.eql(u8, entry.key[9..], property)) continue;
                const id = std.mem.readInt(u64, entry.key[1..9], .big);
                try entries.append(arena, .{ .id = id, .value = try arena.dupe(u8, entry.value) });
            }
        },
    }
    for (entries.items) |entry| {
        if (definition.entity == .relationships) {
            const stored = try graph.relationship(entry.id, arena) orelse continue;
            if (!std.mem.eql(u8, stored.edge_type, definition.labels_or_types[0])) continue;
        }
        try replaceEntry(graph, arena, definition.index_id, entry.id, null, try decoded(arena, entry.value));
    }
}

/// Removes every entry of index `index_id` (its definition is removed by the caller).
pub fn clear(graph: *Graph, index_id: u32) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var prefix = std.ArrayList(u8).empty;
    try appendPrefix(&prefix, arena, index_id);
    var stale = std.ArrayList([]const u8).empty;
    {
        var keys = try graph.store.scanPrefix(prefix.items);
        defer keys.deinit();
        while (try keys.next()) |entry| try stale.append(arena, try arena.dupe(u8, entry.key));
    }
    for (stale.items) |key| try graph.store.del(key);
}

/// Moves entity `id`'s entry in index `index_id` from value `old` to `new`
/// (null: no entry).
fn replaceEntry(graph: *Graph, arena: Allocator, index_id: u32, id: u64, old: ?Value, new: ?Value) StorageError!void {
    var old_key = std.ArrayList(u8).empty;
    if (old) |value| try appendKey(&old_key, arena, index_id, value, id);
    var new_key = std.ArrayList(u8).empty;
    if (new) |value| try appendKey(&new_key, arena, index_id, value, id);
    if (old != null and new != null and std.mem.eql(u8, old_key.items, new_key.items)) return;
    if (old != null) try graph.store.del(old_key.items);
    if (new != null) try graph.store.put(new_key.items, "");
}

/// A stored value, decoded (copied: it may be a view a write moves).
fn decoded(arena: Allocator, encoded: ?[]const u8) Allocator.Error!?Value {
    return if (encoded) |bytes| try value_encoding.decodeValue(bytes, arena) else null;
}
