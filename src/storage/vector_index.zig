//! Vector indexes: an HNSW graph (src/vector/hnsw.zig) per index, kept in
//! the key-value store and written in the transaction of the change that
//! moves it, so readers see it as of their snapshot and replicas get it
//! with the change log.
//!
//! A vector index is on one label (or relationship type) and one
//! property, which holds a list of `dimensions` numbers. A write that
//! would give an indexed entity anything else there (another value, a
//! wrong length, NaN or infinity, all zeros under cosine) fails with
//! `error.ConstraintViolation` before anything is written: a silent skip
//! would hide an embedding model change as missing results. The property
//! keeps the numbers; the index a copy as f32 (normalized under cosine).
//!
//! Keys, after the marker `h` and the index id (u32, big-endian); the
//! values' integers and floats are little-endian:
//!
//!     H                       header: entry (u64), top level (u8),
//!                             live (u64), tombstones (u64)
//!     E entity                level (u8), live (u8), the vector (f32 each)
//!     N entity level(u8)      neighbours on that level (u64 each)

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("graph.zig").Graph;
const NodeId = @import("graph.zig").NodeId;
const RelationshipId = @import("graph.zig").RelationshipId;
const NodeRecord = @import("node_record.zig").NodeRecord;
const StorageError = @import("key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const value_encoding = @import("value_encoding.zig");
const fulltext = @import("fulltext.zig");
const similarity_functions = @import("../vector/similarity.zig");
const hnsw = @import("../vector/hnsw.zig");

pub const Similarity = similarity_functions.Similarity;
pub const marker: u8 = 'h';
pub const parameters = hnsw.Parameters{};

const header_tag: u8 = 'H';
const entity_tag: u8 = 'E';
const neighbours_tag: u8 = 'N';

/// Bytes of an entity record before its vector.
const entity_prefix_length = 2;

const Hnsw = hnsw.Hnsw(IndexStorage);

/// The HNSW storage context over one index's keys (see hnsw.zig).
/// Distances read vectors as views, copied to the context's two buffers.
pub const IndexStorage = struct {
    graph: *Graph,
    arena: Allocator,
    index_id: u32,
    similarity: Similarity,
    first: []f32,
    second: []f32,

    pub const Error = StorageError;

    pub fn init(graph: *Graph, arena: Allocator, definition: fulltext.Definition) Allocator.Error!IndexStorage {
        return .{
            .graph = graph,
            .arena = arena,
            .index_id = definition.index_id,
            .similarity = definition.similarity,
            .first = try arena.alloc(f32, definition.dimensions),
            .second = try arena.alloc(f32, definition.dimensions),
        };
    }

    fn prefix(self: *const IndexStorage, tag: u8) [6]u8 {
        var key: [6]u8 = undefined;
        key[0] = marker;
        std.mem.writeInt(u32, key[1..5], self.index_id, .big);
        key[5] = tag;
        return key;
    }

    pub fn entityKey(self: *const IndexStorage, id: u64) [14]u8 {
        var key: [14]u8 = undefined;
        key[0..6].* = self.prefix(entity_tag);
        std.mem.writeInt(u64, key[6..14], id, .big);
        return key;
    }

    fn neighboursKey(self: *const IndexStorage, id: u64, at: u8) [15]u8 {
        var key: [15]u8 = undefined;
        key[0..6].* = self.prefix(neighbours_tag);
        std.mem.writeInt(u64, key[6..14], id, .big);
        key[14] = at;
        return key;
    }

    /// The value of `key`: a view inside a transaction, else a copy.
    fn read(self: *IndexStorage, key: []const u8) StorageError!?[]const u8 {
        if (self.graph.store.inTransaction()) return self.graph.store.view(key);
        const owned = try self.graph.store.get(key) orelse return null;
        defer self.graph.store.allocator.free(owned);
        return try self.arena.dupe(u8, owned);
    }

    /// Entity `id`'s record, which must be there.
    fn entity(self: *IndexStorage, id: u64) StorageError![]const u8 {
        const key = self.entityKey(id);
        const record = try self.read(&key) orelse return error.ReadFailed;
        if (record.len != entity_prefix_length + 4 * self.first.len) return error.ReadFailed;
        return record;
    }

    /// The entity's record if it has one (live or a tombstone).
    pub fn entityRecord(self: *IndexStorage, id: u64) StorageError!?[]const u8 {
        const key = self.entityKey(id);
        return self.read(&key);
    }

    fn vectorInto(self: *IndexStorage, id: u64, into: []f32) StorageError!void {
        const bytes = (try self.entity(id))[entity_prefix_length..];
        for (into, 0..) |*element, i| element.* = @bitCast(std.mem.readInt(u32, bytes[4 * i ..][0..4], .little));
    }

    pub fn distanceTo(self: *IndexStorage, query: []const f32, id: u64) StorageError!f32 {
        try self.vectorInto(id, self.first);
        return similarity_functions.distance(self.similarity, query, self.first);
    }

    pub fn distanceBetween(self: *IndexStorage, a: u64, b: u64) StorageError!f32 {
        try self.vectorInto(a, self.first);
        try self.vectorInto(b, self.second);
        return similarity_functions.distance(self.similarity, self.first, self.second);
    }

    pub fn isLive(self: *IndexStorage, id: u64) StorageError!bool {
        return (try self.entity(id))[1] == 1;
    }

    pub fn level(self: *IndexStorage, id: u64) StorageError!u8 {
        return (try self.entity(id))[0];
    }

    pub fn neighbours(self: *IndexStorage, arena: Allocator, id: u64, at: u8) StorageError![]u64 {
        const key = self.neighboursKey(id, at);
        const bytes = try self.read(&key) orelse return error.ReadFailed;
        if (bytes.len % 8 != 0) return error.ReadFailed;
        const ids = try arena.alloc(u64, bytes.len / 8);
        for (ids, 0..) |*neighbour, i| neighbour.* = std.mem.readInt(u64, bytes[8 * i ..][0..8], .little);
        return ids;
    }

    pub fn setNeighbours(self: *IndexStorage, id: u64, at: u8, ids: []const u64) StorageError!void {
        const bytes = try self.arena.alloc(u8, 8 * ids.len);
        for (ids, 0..) |neighbour, i| std.mem.writeInt(u64, bytes[8 * i ..][0..8], neighbour, .little);
        const key = self.neighboursKey(id, at);
        try self.graph.store.put(&key, bytes);
    }

    pub fn header(self: *IndexStorage) StorageError!?hnsw.Header {
        const key = self.prefix(header_tag);
        const bytes = try self.read(&key) orelse return null;
        if (bytes.len != 25) return error.ReadFailed;
        return .{
            .entry = std.mem.readInt(u64, bytes[0..8], .little),
            .top_level = bytes[8],
            .live = std.mem.readInt(u64, bytes[9..17], .little),
            .tombstones = std.mem.readInt(u64, bytes[17..25], .little),
        };
    }

    pub fn setHeader(self: *IndexStorage, value: ?hnsw.Header) StorageError!void {
        const key = self.prefix(header_tag);
        const header_value = value orelse return self.graph.store.del(&key);
        var bytes: [25]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], header_value.entry, .little);
        bytes[8] = header_value.top_level;
        std.mem.writeInt(u64, bytes[9..17], header_value.live, .little);
        std.mem.writeInt(u64, bytes[17..25], header_value.tombstones, .little);
        try self.graph.store.put(&key, &bytes);
    }

    /// Stores entity `id`'s record: its level, whether it is live, its vector.
    fn putEntity(self: *IndexStorage, id: u64, entity_level: u8, live: bool, vector: []const f32) StorageError!void {
        const bytes = try self.arena.alloc(u8, entity_prefix_length + 4 * vector.len);
        bytes[0] = entity_level;
        bytes[1] = @intFromBool(live);
        for (vector, 0..) |element, i| std.mem.writeInt(u32, bytes[entity_prefix_length + 4 * i ..][0..4], @bitCast(element), .little);
        const key = self.entityKey(id);
        try self.graph.store.put(&key, bytes);
    }
};

// --- Values -------------------------------------------------------------------

/// What an indexed property must hold, or why it does not (a phrase
/// whose subject is the value: "has 2 elements").
pub const Checked = union(enum) {
    /// No value: the entity is not in the index.
    absent,
    vector: []const f32,
    invalid: []const u8,
};

/// The vector `value` gives index `definition`, prepared as the index keeps
/// it (in `arena`), or why it cannot be one.
pub fn check(arena: Allocator, definition: fulltext.Definition, value: ?Value) Allocator.Error!Checked {
    const present = value orelse return .absent;
    if (present == .null) return .absent;
    if (present != .list) return .{ .invalid = "is not a list of numbers" };
    const items = present.list;
    if (items.len != definition.dimensions) {
        return .{ .invalid = try std.fmt.allocPrint(arena, "has {d} elements", .{items.len}) };
    }
    const numbers = try arena.alloc(f64, items.len);
    for (numbers, items) |*number, item| number.* = switch (item) {
        .int => |int| @floatFromInt(int),
        .float => |float| float,
        else => return .{ .invalid = "is not a list of numbers" },
    };
    const vector = try arena.alloc(f32, items.len);
    if (similarity_functions.prepare(definition.similarity, numbers, vector)) |invalid| return .{ .invalid = invalid.message() };
    return .{ .vector = vector };
}

fn decodedProperty(arena: Allocator, record: NodeRecord, property: []const u8) Allocator.Error!?Value {
    const encoded = record.property(property) orelse return null;
    return try value_encoding.decodeValue(encoded, arena);
}

fn fail(graph: *Graph, definition: fulltext.Definition, what: []const u8, id: u64, reason: []const u8) StorageError {
    graph.setViolation("{s} {d} cannot have this {s}: vector index '{s}' takes a list of {d} numbers, and this one {s}", .{ what, id, definition.properties[0], definition.name, definition.dimensions, reason });
    return error.ConstraintViolation;
}

// --- Checking writes before they are made --------------------------------------

/// Fails with `error.ConstraintViolation` if node `id`, with `record` as its
/// new record, would hold something other than a vector where an index wants one.
pub fn checkNode(graph: *Graph, id: NodeId, record: NodeRecord) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.cachedDefinitions(graph)) |definition| {
        if (definition.kind != .vector or definition.entity != .nodes) continue;
        if (!record.hasLabel(definition.labels_or_types[0])) continue;
        const checked = try check(arena, definition, try decodedProperty(arena, record, definition.properties[0]));
        if (checked == .invalid) return fail(graph, definition, "node", id, checked.invalid);
    }
}

/// The relationship twin of `checkNode`, for property `name` of relationship
/// `id` (of type `edge_type`) about to hold `value`.
pub fn checkRelationshipProperty(graph: *Graph, id: RelationshipId, edge_type: []const u8, name: []const u8, value: Value) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.cachedDefinitions(graph)) |definition| {
        if (definition.kind != .vector or definition.entity != .relationships) continue;
        if (!std.mem.eql(u8, definition.labels_or_types[0], edge_type) or !std.mem.eql(u8, definition.properties[0], name)) continue;
        const checked = try check(arena, definition, value);
        if (checked == .invalid) return fail(graph, definition, "relationship", id, checked.invalid);
    }
}

// --- Keeping the indexes current ----------------------------------------------

/// After node `id` changed from `old` to `new` (an empty record: it did not
/// or no longer exists), moves it in every vector index the change
/// concerns. `changed` names the one property that changed, or is null when
/// labels did. The new record was checked (`checkNode`).
pub fn nodeChanged(graph: *Graph, id: NodeId, old: NodeRecord, new: NodeRecord, changed: ?[]const u8) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.cachedDefinitions(graph)) |definition| {
        if (definition.kind != .vector or definition.entity != .nodes) continue;
        const property = definition.properties[0];
        if (changed) |name| if (!std.mem.eql(u8, name, property)) continue;
        const label = definition.labels_or_types[0];
        if (!old.hasLabel(label) and !new.hasLabel(label)) continue;
        const value = if (new.hasLabel(label)) try decodedProperty(arena, new, property) else null;
        try place(graph, arena, definition, id, value);
    }
}

/// After property `name` of relationship `id` (of type `edge_type`) changed
/// to `new` (null: absent), moves it in the vector indexes it concerns.
pub fn relationshipPropertyChanged(graph: *Graph, id: RelationshipId, edge_type: []const u8, name: []const u8, new: ?Value) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.cachedDefinitions(graph)) |definition| {
        if (definition.kind != .vector or definition.entity != .relationships) continue;
        if (!std.mem.eql(u8, definition.labels_or_types[0], edge_type) or !std.mem.eql(u8, definition.properties[0], name)) continue;
        try place(graph, arena, definition, id, new);
    }
}

/// Puts entity `id` where `value` (checked) puts it in index `definition`:
/// in with its vector, or out (a tombstone).
fn place(graph: *Graph, arena: Allocator, definition: fulltext.Definition, id: u64, value: ?Value) StorageError!void {
    var storage = try IndexStorage.init(graph, arena, definition);
    const stored = try storage.entityRecord(id);
    const was_live = if (stored) |record| record[1] == 1 else false;
    switch (try check(arena, definition, value)) {
        .invalid => unreachable, // checked before the write
        .absent => {
            if (!was_live) return;
            const record = try arena.dupe(u8, stored.?);
            try storage.putEntity(id, record[0], false, try vectorOfRecord(arena, record));
            try Hnsw.remove(&storage, arena, parameters, id);
            if (hnsw.needsRebuild((try storage.header()).?)) try rebuild(graph, arena, definition);
        },
        .vector => |vector| {
            if (was_live) {
                if (std.mem.eql(f32, try vectorOfRecord(arena, stored.?), vector)) return;
                try storage.putEntity(id, stored.?[0], true, vector);
                return Hnsw.update(&storage, arena, parameters, id);
            }
            const was_tombstone = stored != null;
            try storage.putEntity(id, hnsw.levelOf(id, parameters), true, vector);
            try Hnsw.insert(&storage, arena, parameters, id, was_tombstone);
        },
    }
}

fn vectorOfRecord(arena: Allocator, record: []const u8) Allocator.Error![]f32 {
    const bytes = record[entity_prefix_length..];
    const vector = try arena.alloc(f32, bytes.len / 4);
    for (vector, 0..) |*element, i| element.* = @bitCast(std.mem.readInt(u32, bytes[4 * i ..][0..4], .little));
    return vector;
}

/// Builds the index anew from its live entities, dropping its tombstones.
fn rebuild(graph: *Graph, arena: Allocator, definition: fulltext.Definition) StorageError!void {
    var storage = try IndexStorage.init(graph, arena, definition);
    const Live = struct { id: u64, vector: []const f32 };
    var live = std.ArrayList(Live).empty;
    {
        const entities = storage.prefix(entity_tag);
        var keys = try graph.store.scanPrefix(&entities);
        defer keys.deinit();
        while (try keys.next()) |entry| {
            if (entry.value[1] != 1) continue;
            const id = std.mem.readInt(u64, entry.key[6..14], .big);
            try live.append(arena, .{ .id = id, .vector = try vectorOfRecord(arena, entry.value) });
        }
    }
    try clear(graph, definition.index_id);
    for (live.items) |entity| {
        try storage.putEntity(entity.id, hnsw.levelOf(entity.id, parameters), true, entity.vector);
        try Hnsw.insert(&storage, arena, parameters, entity.id, false);
    }
}

/// Indexes what the graph already holds for a new index, failing with
/// `error.ConstraintViolation` on the first entity whose property is not a
/// vector the index takes (the caller aborts the transaction).
pub fn populate(graph: *Graph, definition: fulltext.Definition) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const property = definition.properties[0];
    // Collect first: indexing writes, and no scan may be open across writes.
    const Entry = struct { id: u64, value: Value };
    var entries = std.ArrayList(Entry).empty;
    switch (definition.entity) {
        .nodes => {
            var nodes = try graph.nodesWithLabel(definition.labels_or_types[0]);
            defer nodes.deinit();
            while (try nodes.next()) |id| {
                const record = NodeRecord{ .bytes = try graph.recordCopy(id, arena) };
                const value = try decodedProperty(arena, record, property) orelse continue;
                try entries.append(arena, .{ .id = id, .value = value });
            }
        },
        .relationships => {
            // Relationship properties are keys `f | relationship_id | name`.
            var keys = try graph.store.scanPrefix(&.{@import("key_encoding.zig").edge_property_marker});
            defer keys.deinit();
            while (try keys.next()) |entry| {
                if (!std.mem.eql(u8, entry.key[9..], property)) continue;
                const id = std.mem.readInt(u64, entry.key[1..9], .big);
                try entries.append(arena, .{ .id = id, .value = try value_encoding.decodeValue(entry.value, arena) });
            }
        },
    }
    const what = if (definition.entity == .nodes) "node" else "relationship";
    for (entries.items) |entry| {
        if (definition.entity == .relationships) {
            const stored = try graph.relationship(entry.id, arena) orelse continue;
            if (!std.mem.eql(u8, stored.edge_type, definition.labels_or_types[0])) continue;
        }
        const checked = try check(arena, definition, entry.value);
        if (checked == .invalid) {
            graph.setViolation("cannot create vector index '{s}': it takes {s} as a list of {d} numbers, and that of {s} {d} {s}", .{ definition.name, property, definition.dimensions, what, entry.id, checked.invalid });
            return error.ConstraintViolation;
        }
        try place(graph, arena, definition, entry.id, entry.value);
    }
}

/// Removes every key of index `index_id` (its definition is removed by the caller).
pub fn clear(graph: *Graph, index_id: u32) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var prefix: [5]u8 = undefined;
    prefix[0] = marker;
    std.mem.writeInt(u32, prefix[1..5], index_id, .big);
    var stale = std.ArrayList([]const u8).empty;
    {
        var keys = try graph.store.scanPrefix(&prefix);
        defer keys.deinit();
        while (try keys.next()) |entry| try stale.append(arena, try arena.dupe(u8, entry.key));
    }
    for (stale.items) |key| try graph.store.del(key);
}

// --- Searching ----------------------------------------------------------------

pub const Hit = struct { id: u64, score: f64 };

/// How many entities a search looks at for each one it returns, at least
/// (the HNSW's ef is the larger of this and k).
pub const min_search_breadth = 100;

/// The `k` entities of index `definition` closest to `query` (checked by
/// the caller with `check`), best score first, ties by id. In `arena`.
pub fn search(graph: *Graph, arena: Allocator, definition: fulltext.Definition, query: []const f32, k: usize) StorageError![]const Hit {
    var storage = try IndexStorage.init(graph, arena, definition);
    const found = try Hnsw.search(&storage, arena, query, k, @max(k, min_search_breadth));
    const hits = try arena.alloc(Hit, found.len);
    for (hits, found) |*hit, entity| hit.* = .{ .id = entity.id, .score = similarity_functions.score(definition.similarity, entity.distance) };
    return hits;
}
