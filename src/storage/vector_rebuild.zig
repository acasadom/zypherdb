//! Rebuilding a vector index without its tombstones, and clearing the keys
//! no index needs any more, in the background (the builder of
//! vector_population.zig does both, a batch at a time).
//!
//! A removal that leaves an online index with more tombstones than live
//! entities (vector_index.startRebuildIfDue) only marks it for a rebuild:
//! a rebuild is O(n) and must not hold up a user's write. Each batch then
//! takes the next live entities by id from the current generation of the
//! graph and links them into the next one, storing how far it got in the
//! index's state; writes meanwhile keep the current generation and, below
//! where the rebuild got to, the next. Searches read the current one. The
//! last batch makes the next generation current; the old one's keys are
//! then garbage.
//!
//! Garbage is any key under the vector marker that no index needs: those
//! of an index id with no vector definition (dropped), those of a failed
//! index but its state, and those of a generation neither current nor
//! being rebuilt into. Dropping an index, or failing it, leaves its keys
//! to this, so neither is O(n) in its transaction. Garbage goes before any
//! rebuild batch: the generation a rebuild fills (one byte, wrapping) then
//! holds nothing it did not put there.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Graph = @import("graph.zig").Graph;
const KeyValueStore = @import("key_value_store.zig").KeyValueStore;
const StorageError = @import("key_value_store.zig").StorageError;
const fulltext = @import("fulltext.zig");
const vector_index = @import("vector_index.zig");

const Budget = KeyValueStore.PopulationBudget;

// --- Garbage ----------------------------------------------------------------------

/// Which keys of an index id its index needs.
pub const Needed = union(enum) {
    /// No vector index has the id: none.
    nothing,
    /// A failed index: its state.
    state,
    /// Its state, and these generations of its graph.
    generations: vector_index.Generations,

    /// Whether `key`, under the index's prefix, is one of them.
    pub fn has(self: Needed, key: []const u8) bool {
        return switch (self) {
            .nothing => false,
            .state => key.len == 5,
            .generations => |generations| key.len == 5 or generations.has(key[5]),
        };
    }
};

/// The keys index id `index_id` needs, given every index's definition.
pub fn needed(graph: *Graph, arena: Allocator, definitions: []const fulltext.Definition, index_id: u32) StorageError!Needed {
    for (definitions) |definition| {
        if (definition.kind != .vector or definition.index_id != index_id) continue;
        const generations = (try vector_index.state(graph, arena, index_id)).kept() orelse return .state;
        return .{ .generations = generations };
    }
    return .nothing;
}

/// Keys deleted at a time: collected before deleting them, since no scan
/// may stay open across writes.
const garbage_round = 64;

/// Appends to `keys` (copies in `arena`) the first garbage keys in key
/// order, until it holds `max`.
fn collectGarbage(graph: *Graph, arena: Allocator, definitions: []const fulltext.Definition, keys: *std.ArrayList([]const u8), max: usize) StorageError!void {
    const marker = [1]u8{vector_index.marker};
    var index_id: u32 = 0;
    while (keys.items.len < max) {
        // The next index id with keys.
        const first_key = vector_index.indexPrefix(index_id);
        index_id = first: {
            var iterator = try graph.store.scanRange(&marker, &first_key, null);
            defer iterator.deinit();
            const entry = try iterator.next() orelse return;
            if (entry.key.len < 5) return error.ReadFailed;
            break :first std.mem.readInt(u32, entry.key[1..5], .big);
        };
        const index_needs = try needed(graph, arena, definitions, index_id);
        const prefix = vector_index.indexPrefix(index_id);
        var start: [6]u8 = undefined;
        var start_length: usize = 5;
        start[0..5].* = prefix;
        scan: while (keys.items.len < max) {
            var iterator = try graph.store.scanRange(&prefix, start[0..start_length], null);
            defer iterator.deinit();
            while (try iterator.next()) |entry| {
                if (!index_needs.has(entry.key)) {
                    try keys.append(arena, try arena.dupe(u8, entry.key));
                    if (keys.items.len == max) return;
                    continue;
                }
                if (entry.key.len == 5) continue;
                // A generation needed: on from the one after it.
                const generation = entry.key[5];
                if (generation == std.math.maxInt(u8)) break :scan;
                start = vector_index.generationPrefix(index_id, generation + 1);
                start_length = 6;
                continue :scan;
            }
            break;
        }
        if (index_id == std.math.maxInt(u32)) return;
        index_id += 1;
    }
}

/// Whether some key under the vector marker is garbage. In a transaction.
pub fn anyGarbage(graph: *Graph, arena: Allocator) StorageError!bool {
    var keys = std.ArrayList([]const u8).empty;
    try collectGarbage(graph, arena, try fulltext.all(graph, arena), &keys, 1);
    return keys.items.len > 0;
}

/// Deletes garbage, at most a batch of `budget` (a round of up to
/// `garbage_round` keys counts as one entity), in the write transaction
/// open. False if there was none.
pub fn clearGarbage(graph: *Graph, budget: Budget) StorageError!bool {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const definitions = try fulltext.all(graph, scratch.allocator());
    var round_scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer round_scratch.deinit();
    const started = now();
    var rounds: u64 = 0;
    while (true) {
        defer _ = round_scratch.reset(.retain_capacity);
        var keys = std.ArrayList([]const u8).empty;
        try collectGarbage(graph, round_scratch.allocator(), definitions, &keys, garbage_round);
        if (keys.items.len == 0) return rounds > 0;
        for (keys.items) |key| try graph.store.del(key);
        rounds += 1;
        if (rounds >= budget.entities or now() - started >= budget.nanoseconds) return true;
    }
}

// --- Rebuilding ---------------------------------------------------------------------

/// Takes the rebuild of index `definition`, if it is being rebuilt, one
/// batch of at most `budget` further, in the write transaction open. False
/// if it was not being rebuilt.
pub fn advance(graph: *Graph, definition: fulltext.Definition, budget: Budget) StorageError!bool {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const online = switch (try vector_index.state(graph, scratch.allocator(), definition.index_id)) {
        .online => |online| online,
        else => return false,
    };
    var next = online.rebuild orelse return false;
    const shadow = online.generation +% 1;
    const started = now();
    var placed: u64 = 0;
    // The scratch of one look, and of one entity, each dropped after it:
    // kept for all of them, they would grow with the batch.
    var look_scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer look_scratch.deinit();
    var entity_scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer entity_scratch.deinit();
    // One for the batch, so that what an insert reads stays decoded.
    var storage = try vector_index.IndexStorage.init(graph, scratch.allocator(), definition, shadow);
    while (true) {
        defer _ = look_scratch.reset(.retain_capacity);
        const found = try nextLive(graph, look_scratch.allocator(), definition, online.generation, next);
        for (found.entities[0..found.count]) |entity| {
            defer _ = entity_scratch.reset(.retain_capacity);
            try vector_index.insertWith(&storage, entity_scratch.allocator(), entity.id, entity.vector);
            next = entity.id + 1;
            placed += 1;
            if (placed >= budget.entities or now() - started >= budget.nanoseconds) {
                try vector_index.setState(graph, definition.index_id, .{ .online = .{ .generation = online.generation, .rebuild = next } });
                return true;
            }
        }
        if (found.last) break;
        next = found.next;
    }
    try vector_index.setState(graph, definition.index_id, .{ .online = .{ .generation = shadow } });
    // Writes may have left the new generation tombstones of its own.
    if (try storage.header()) |header| try vector_index.startRebuildIfDue(graph, definition, header);
    return true;
}

/// One batch of the rebuild of the first index being rebuilt, in the
/// write transaction open. False if none is.
pub fn advanceAny(graph: *Graph, arena: Allocator, budget: Budget) StorageError!bool {
    const definition = try firstRebuilding(graph, arena) orelse return false;
    return advance(graph, definition, budget);
}

/// Whether some index is being rebuilt. In a transaction.
pub fn anyRebuilding(graph: *Graph, arena: Allocator) StorageError!bool {
    return try firstRebuilding(graph, arena) != null;
}

fn firstRebuilding(graph: *Graph, arena: Allocator) StorageError!?fulltext.Definition {
    for (try fulltext.all(graph, arena)) |definition| {
        if (definition.kind != .vector) continue;
        switch (try vector_index.state(graph, arena, definition.index_id)) {
            .online => |online| if (online.rebuild != null) return definition,
            else => {},
        }
    }
    return null;
}

/// The live entities after `first`, in id order, that the next batch links.
const Found = struct {
    entities: [batch_length]struct { id: u64, vector: []const f32 } = undefined,
    count: usize = 0,
    /// Where the next look goes on from.
    next: u64,
    /// Nothing is left after these.
    last: bool,
};

/// Entities looked for at a time.
const batch_length = 64;
/// Tombstones read at most per look: they outnumber the live entities.
const max_skipped = 4096;

fn nextLive(graph: *Graph, arena: Allocator, definition: fulltext.Definition, generation: u8, first: u64) StorageError!Found {
    var found = Found{ .next = first, .last = false };
    var storage = try vector_index.IndexStorage.init(graph, arena, definition, generation);
    const prefix = storage.prefix(vector_index.entity_tag);
    const start = storage.entityKey(first);
    var records = try graph.store.scanRange(&prefix, &start, null);
    defer records.deinit();
    var skipped: usize = 0;
    while (found.count < batch_length and skipped < max_skipped) {
        const entry = try records.next() orelse {
            found.last = true;
            break;
        };
        if (entry.key.len != prefix.len + 8) return error.ReadFailed;
        const id = std.mem.readInt(u64, entry.key[prefix.len..][0..8], .big);
        found.next = id + 1;
        if (!vector_index.isLiveRecord(entry.value)) {
            skipped += 1;
            continue;
        }
        found.entities[found.count] = .{ .id = id, .vector = try vector_index.vectorOfRecord(arena, entry.value) };
        found.count += 1;
    }
    return found;
}

fn now() u64 {
    return @intCast(Io.Clock.awake.now(Io.Threaded.global_single_threaded.io()).nanoseconds);
}
