//! Vector indexes: an HNSW graph (src/vector/hnsw.zig) per index, kept in
//! the key-value store and written in the transaction of the change that
//! moves it, so readers see it as of their snapshot. The change log does
//! not carry its keys: a replica keeps its own (replica_vector_indexes.zig).
//!
//! A vector index is on one label (or relationship type) and one
//! property, which holds a list of `dimensions` numbers. A write that
//! would give an indexed entity anything else there (another value, a
//! wrong length, NaN or infinity, all zeros under cosine) fails with
//! `error.ConstraintViolation` before anything is written: a silent skip
//! would hide an embedding model change as missing results. The property
//! keeps the numbers; the index a copy as f32 (normalized under cosine).
//!
//! A new index is populated from the data already there in the background
//! (vector_population.zig); writes keep it current meanwhile. One whose
//! data holds something that is not a vector fails: it is no longer kept
//! or checked, and queries on it are refused until it is dropped.
//!
//! An entity that leaves the index stays in its graph as a tombstone, which
//! routes searches. Once tombstones outnumber the live entities, the index
//! is rebuilt without them in the background (vector_rebuild.zig), into
//! the next generation of its graph: searches read the current one until
//! the rebuild is done. Keys no generation needs any more, and those of a
//! dropped or failed index, are cleared in the background too.
//!
//! Keys, after the marker `h` and the index id (u32, big-endian); the
//! values' integers and floats are little-endian:
//!
//!     (none)                  state: 0 populating (generation 0), next id
//!                             (u64), entities examined (u64); 1 online,
//!                             generation (u8), and while rebuilding the
//!                             next id (u64); 2 failed, entity (u64),
//!                             reason (the rest)
//!     generation(u8) H        header: entry (u64), top level (u8),
//!                             live (u64), tombstones (u64)
//!     generation E entity     level (u8), live (u8), the vector (f32 each)
//!     generation N entity level(u8)   neighbours on that level (u64 each)

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
pub const entity_tag: u8 = 'E';
const neighbours_tag: u8 = 'N';

/// Bytes of an entity record before its vector.
const entity_prefix_length = 2;

const Hnsw = hnsw.Hnsw(IndexStorage);

/// The HNSW storage context over one index's keys (see hnsw.zig).
/// An entity's record is read and decoded once per context: an insert
/// measures thousands of distances among a few hundred entities.
pub const IndexStorage = struct {
    graph: *Graph,
    arena: Allocator,
    index_id: u32,
    generation: u8,
    similarity: Similarity,
    dimensions: usize,
    /// The records read or written through this context, by entity id.
    entities: std.AutoHashMapUnmanaged(u64, Entity) = .empty,

    pub const Error = StorageError;

    /// The context over `generation` of index `definition`'s graph.
    pub fn init(graph: *Graph, arena: Allocator, definition: fulltext.Definition, generation: u8) Allocator.Error!IndexStorage {
        return .{
            .graph = graph,
            .arena = arena,
            .index_id = definition.index_id,
            .generation = generation,
            .similarity = definition.similarity,
            .dimensions = definition.dimensions,
        };
    }

    /// An entity record, decoded.
    const Entity = struct {
        level: u8,
        live: bool,
        vector: []const f32,
    };

    pub fn prefix(self: *const IndexStorage, tag: u8) [7]u8 {
        var key: [7]u8 = undefined;
        key[0..6].* = generationPrefix(self.index_id, self.generation);
        key[6] = tag;
        return key;
    }

    pub fn entityKey(self: *const IndexStorage, id: u64) [15]u8 {
        var key: [15]u8 = undefined;
        key[0..7].* = self.prefix(entity_tag);
        std.mem.writeInt(u64, key[7..15], id, .big);
        return key;
    }

    fn neighboursKey(self: *const IndexStorage, id: u64, at: u8) [16]u8 {
        var key: [16]u8 = undefined;
        key[0..7].* = self.prefix(neighbours_tag);
        std.mem.writeInt(u64, key[7..15], id, .big);
        key[15] = at;
        return key;
    }

    /// The value of `key`: a view inside a transaction, else a copy.
    fn read(self: *IndexStorage, key: []const u8) StorageError!?[]const u8 {
        return readIn(self.graph, self.arena, key);
    }

    /// Entity `id`'s record, which must be there.
    fn entity(self: *IndexStorage, id: u64) StorageError!Entity {
        const slot = try self.entities.getOrPut(self.arena, id);
        if (slot.found_existing) return slot.value_ptr.*;
        errdefer _ = self.entities.remove(id);
        const key = self.entityKey(id);
        const record = try self.read(&key) orelse return error.ReadFailed;
        if (record.len != entity_prefix_length + 4 * self.dimensions) return error.ReadFailed;
        slot.value_ptr.* = .{ .level = record[0], .live = record[1] == 1, .vector = try vectorOfRecord(self.arena, record) };
        return slot.value_ptr.*;
    }

    /// The entity's record if it has one (live or a tombstone).
    pub fn entityRecord(self: *IndexStorage, id: u64) StorageError!?[]const u8 {
        const key = self.entityKey(id);
        return self.read(&key);
    }

    pub fn vectorOf(self: *IndexStorage, id: u64) StorageError![]const f32 {
        return (try self.entity(id)).vector;
    }

    pub fn distance(self: *IndexStorage, a: []const f32, b: []const f32) f32 {
        return similarity_functions.distance(self.similarity, a, b);
    }

    pub fn isLive(self: *IndexStorage, id: u64) StorageError!bool {
        return (try self.entity(id)).live;
    }

    pub fn level(self: *IndexStorage, id: u64) StorageError!u8 {
        return (try self.entity(id)).level;
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
        // On the stack when it fits: the arena lives as long as the context.
        var buffer: [8 * parameters.maxNeighbours(0)]u8 = undefined;
        const bytes = if (8 * ids.len <= buffer.len) buffer[0 .. 8 * ids.len] else try self.arena.alloc(u8, 8 * ids.len);
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
        try self.entities.put(self.arena, id, .{ .level = entity_level, .live = live, .vector = try self.arena.dupe(f32, vector) });
    }
};

/// The prefix of every key of index `index_id`, and its state's key.
pub fn indexPrefix(index_id: u32) [5]u8 {
    var key: [5]u8 = undefined;
    key[0] = marker;
    std.mem.writeInt(u32, key[1..5], index_id, .big);
    return key;
}

/// The prefix of the keys of `generation` of index `index_id`'s graph.
pub fn generationPrefix(index_id: u32, generation: u8) [6]u8 {
    var key: [6]u8 = undefined;
    key[0..5].* = indexPrefix(index_id);
    key[5] = generation;
    return key;
}

// --- State ----------------------------------------------------------------------

/// Where an index is in its life. Kept per database, not in the change
/// log: a replica populates and rebuilds its own indexes.
pub const State = union(enum) {
    populating: Progress,
    online: Online,
    failed: Failure,

    /// The generations of the graph writes keep: none for a failed index.
    pub fn kept(self: State) ?Generations {
        return switch (self) {
            .populating => .{ .current = 0 },
            .online => |online| .{
                .current = online.generation,
                .shadow = if (online.rebuild) |next| .{ .generation = online.generation +% 1, .below = next } else null,
            },
            .failed => null,
        };
    }
};

pub const Progress = struct {
    /// The entities with a smaller id are in the index.
    next: u64 = 0,
    /// How many entities of its label or type the population looked at.
    examined: u64 = 0,
};

pub const Online = struct {
    /// The generation of the graph searches read.
    generation: u8 = 0,
    /// While the index is rebuilt into the next generation: the entities
    /// with a smaller id are in it.
    rebuild: ?u64 = null,
};

pub const Failure = struct {
    entity: u64,
    /// What is wrong with the entity's value, a phrase whose subject is
    /// the value ("has 2 elements").
    reason: []const u8,
};

/// The generations of an index's graph that hold its entities.
pub const Generations = struct {
    current: u8,
    /// The one a rebuild fills, holding the entities below `below`.
    shadow: ?struct { generation: u8, below: u64 } = null,

    pub fn has(self: Generations, generation: u8) bool {
        if (self.shadow) |shadow| if (shadow.generation == generation) return true;
        return self.current == generation;
    }
};

/// Index `index_id`'s state (its strings in `arena`).
pub fn state(graph: *Graph, arena: Allocator, index_id: u32) StorageError!State {
    const key = indexPrefix(index_id);
    const bytes = try readIn(graph, arena, &key) orelse return error.ReadFailed;
    var decoded = try decodeState(bytes);
    if (decoded == .failed) decoded.failed.reason = try arena.dupe(u8, decoded.failed.reason);
    return decoded;
}

/// The state stored as `bytes`; a failure's reason is a view into them.
fn decodeState(bytes: []const u8) StorageError!State {
    if (bytes.len == 0) return error.ReadFailed;
    switch (bytes[0]) {
        0 => {
            if (bytes.len != 17) return error.ReadFailed;
            return .{ .populating = .{ .next = std.mem.readInt(u64, bytes[1..9], .little), .examined = std.mem.readInt(u64, bytes[9..17], .little) } };
        },
        1 => return switch (bytes.len) {
            2 => .{ .online = .{ .generation = bytes[1] } },
            10 => .{ .online = .{ .generation = bytes[1], .rebuild = std.mem.readInt(u64, bytes[2..10], .little) } },
            else => error.ReadFailed,
        },
        2 => {
            if (bytes.len < 9) return error.ReadFailed;
            return .{ .failed = .{ .entity = std.mem.readInt(u64, bytes[1..9], .little), .reason = bytes[9..] } };
        },
        else => return error.ReadFailed,
    }
}

pub fn setState(graph: *Graph, index_id: u32, value: State) StorageError!void {
    var buffer: [17]u8 = undefined;
    const key = indexPrefix(index_id);
    switch (value) {
        .populating => |progress| {
            buffer[0] = 0;
            std.mem.writeInt(u64, buffer[1..9], progress.next, .little);
            std.mem.writeInt(u64, buffer[9..17], progress.examined, .little);
            try graph.store.put(&key, &buffer);
        },
        .online => |online| {
            buffer[0] = 1;
            buffer[1] = online.generation;
            const next = online.rebuild orelse return graph.store.put(&key, buffer[0..2]);
            std.mem.writeInt(u64, buffer[2..10], next, .little);
            try graph.store.put(&key, buffer[0..10]);
        },
        .failed => |failure| {
            var scratch = std.heap.ArenaAllocator.init(graph.allocator);
            defer scratch.deinit();
            const bytes = try scratch.allocator().alloc(u8, 9 + failure.reason.len);
            bytes[0] = 2;
            std.mem.writeInt(u64, bytes[1..9], failure.entity, .little);
            @memcpy(bytes[9..], failure.reason);
            try graph.store.put(&key, bytes);
        },
    }
}

/// The generations writes keep of index `index_id`, null for a failed
/// one. In a transaction.
pub fn keptGenerations(graph: *Graph, index_id: u32) StorageError!?Generations {
    const key = indexPrefix(index_id);
    const bytes = try graph.store.view(&key) orelse return error.ReadFailed;
    return (try decodeState(bytes)).kept();
}

/// Whether writes keep index `index_id` (all but a failed one).
fn isKept(graph: *Graph, index_id: u32) StorageError!bool {
    const key = indexPrefix(index_id);
    const bytes = try graph.store.view(&key) orelse return error.ReadFailed;
    return bytes.len == 0 or bytes[0] != 2;
}

/// The value of `key`: a view inside a transaction, else a copy in `arena`.
fn readIn(graph: *Graph, arena: Allocator, key: []const u8) StorageError!?[]const u8 {
    if (graph.store.inTransaction()) return graph.store.view(key);
    const owned = try graph.store.get(key) orelse return null;
    defer graph.store.allocator.free(owned);
    return try arena.dupe(u8, owned);
}

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

pub fn decodedProperty(arena: Allocator, record: NodeRecord, property: []const u8) Allocator.Error!?Value {
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
        if (!try isKept(graph, definition.index_id)) continue;
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
        if (!try isKept(graph, definition.index_id)) continue;
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
        if (!try isKept(graph, definition.index_id)) continue;
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
        if (!try isKept(graph, definition.index_id)) continue;
        try place(graph, arena, definition, id, new);
    }
}

/// After property `name` of relationship `id` was removed, takes it out of
/// the vector indexes on that property: those of its type held it, the
/// others did not (a replica applying the removal of a relationship may
/// no longer know its type).
pub fn relationshipPropertyRemoved(graph: *Graph, id: RelationshipId, name: []const u8) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.cachedDefinitions(graph)) |definition| {
        if (definition.kind != .vector or definition.entity != .relationships) continue;
        if (!std.mem.eql(u8, definition.properties[0], name)) continue;
        if (!try isKept(graph, definition.index_id)) continue;
        try place(graph, arena, definition, id, null);
    }
}

/// Whether the database has a vector index.
pub fn exist(graph: *Graph) StorageError!bool {
    if (try fulltext.schemaVersion(graph) == 0) return false;
    for (try fulltext.cachedDefinitions(graph)) |definition| if (definition.kind == .vector) return true;
    return false;
}

/// Puts entity `id` where `value` (checked) puts it in index `definition`:
/// in with its vector, or out (a tombstone). In every generation of its
/// graph that holds it: the current one, and the one a rebuild fills if
/// the rebuild got past `id`. Nothing for a failed index.
pub fn place(graph: *Graph, arena: Allocator, definition: fulltext.Definition, id: u64, value: ?Value) StorageError!void {
    var placer = try Placer.init(graph, arena, definition) orelse return;
    try placer.place(arena, id, value);
}

/// Places entities of index `definition` one after another, as `place`
/// does, in the write transaction open, with one storage context per
/// generation for all of them: what an insert reads stays decoded for the
/// next ones. Every write of the index's keys in the transaction must go
/// through it while it is used.
pub const Placer = struct {
    graph: *Graph,
    definition: fulltext.Definition,
    current: IndexStorage,
    /// The generation a rebuild fills, and the entities it holds.
    shadow: ?IndexStorage,
    shadow_below: u64,

    /// Null for a failed index. The contexts live in `arena`.
    pub fn init(graph: *Graph, arena: Allocator, definition: fulltext.Definition) StorageError!?Placer {
        const generations = try keptGenerations(graph, definition.index_id) orelse return null;
        const shadow = generations.shadow;
        return .{
            .graph = graph,
            .definition = definition,
            .current = try IndexStorage.init(graph, arena, definition, generations.current),
            .shadow = if (shadow) |kept| try IndexStorage.init(graph, arena, definition, kept.generation) else null,
            .shadow_below = if (shadow) |kept| kept.below else 0,
        };
    }

    /// `arena` holds the scratch of this call.
    pub fn place(self: *Placer, arena: Allocator, id: u64, value: ?Value) StorageError!void {
        const checked = try check(arena, self.definition, value);
        if (checked == .invalid) unreachable; // checked before the write
        // A rebuild it starts has placed nothing yet: no shadow to place in.
        if (try placeIn(&self.current, arena, id, checked)) |header| try startRebuildIfDue(self.graph, self.definition, header);
        const shadow = if (self.shadow) |*storage| storage else return;
        if (id >= self.shadow_below) return; // the rebuild places it when it gets there
        _ = try placeIn(shadow, arena, id, checked);
    }
};

/// Places entity `id` in the generation `storage` is over. The header
/// after a removal, else null.
fn placeIn(storage: *IndexStorage, arena: Allocator, id: u64, checked: Checked) StorageError!?hnsw.Header {
    const stored = try storage.entityRecord(id);
    const was_live = if (stored) |record| record[1] == 1 else false;
    switch (checked) {
        .invalid => unreachable,
        .absent => {
            if (!was_live) return null;
            const record = try arena.dupe(u8, stored.?);
            try storage.putEntity(id, record[0], false, try vectorOfRecord(arena, record));
            try Hnsw.remove(storage, arena, parameters, id);
            return (try storage.header()).?;
        },
        .vector => |vector| {
            if (was_live) {
                if (std.mem.eql(f32, try vectorOfRecord(arena, stored.?), vector)) return null;
                try storage.putEntity(id, stored.?[0], true, vector);
                try Hnsw.update(storage, arena, parameters, id);
                return null;
            }
            const was_tombstone = stored != null;
            try storage.putEntity(id, hnsw.levelOf(id, parameters), true, vector);
            try Hnsw.insert(storage, arena, parameters, id, was_tombstone);
            return null;
        },
    }
}

/// Starts rebuilding index `definition` into the next generation, if it
/// is online, not being rebuilt, and the tombstones of `header` (its
/// current generation's) call for it. The builder does the work.
pub fn startRebuildIfDue(graph: *Graph, definition: fulltext.Definition, header: hnsw.Header) StorageError!void {
    if (!hnsw.needsRebuild(header, graph.store.vector_rebuild_tombstones)) return;
    const key = indexPrefix(definition.index_id);
    const current = try decodeState(try graph.store.view(&key) orelse return error.ReadFailed);
    if (current != .online or current.online.rebuild != null) return;
    try setState(graph, definition.index_id, .{ .online = .{ .generation = current.online.generation, .rebuild = 0 } });
    graph.store.wakePopulation();
}

/// Links entity `id`, which the generation `storage` is over does not
/// hold, into it with `vector` (as the index keeps it). `storage` may have
/// placed entities before; `arena` holds the scratch of this call.
pub fn insertWith(storage: *IndexStorage, arena: Allocator, id: u64, vector: []const f32) StorageError!void {
    try storage.putEntity(id, hnsw.levelOf(id, parameters), true, vector);
    try Hnsw.insert(storage, arena, parameters, id, false);
}

/// Whether an entity record is live (not a tombstone).
pub fn isLiveRecord(record: []const u8) bool {
    return record.len >= entity_prefix_length and record[1] == 1;
}

/// The vector of an entity record, in `arena`.
pub fn vectorOfRecord(arena: Allocator, record: []const u8) Allocator.Error![]f32 {
    const bytes = record[entity_prefix_length..];
    const vector = try arena.alloc(f32, bytes.len / 4);
    for (vector, 0..) |*element, i| element.* = @bitCast(std.mem.readInt(u32, bytes[4 * i ..][0..4], .little));
    return vector;
}

// --- Searching ----------------------------------------------------------------

pub const Hit = struct { id: u64, score: f64 };

/// How many entities a search looks at for each one it returns, at least
/// (the HNSW's ef is the larger of this and k).
pub const min_search_breadth = 100;

/// The `k` entities of index `definition` closest to `query` (checked by
/// the caller with `check`), best score first, ties by id. In `arena`.
pub fn search(graph: *Graph, arena: Allocator, definition: fulltext.Definition, query: []const f32, k: usize) StorageError![]const Hit {
    const generations = (try state(graph, arena, definition.index_id)).kept() orelse return error.ReadFailed;
    var storage = try IndexStorage.init(graph, arena, definition, generations.current);
    const found = try Hnsw.search(&storage, arena, query, k, @max(k, min_search_breadth));
    const hits = try arena.alloc(Hit, found.len);
    for (hits, found) |*hit, entity| hit.* = .{ .id = entity.id, .score = similarity_functions.score(definition.similarity, entity.distance) };
    return hits;
}
