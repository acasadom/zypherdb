//! Vector index entries decoded once and kept across transactions, one
//! cache per store (vector_index.zig reads through it). An insert or a
//! search visits thousands of entities; without it each transaction would
//! read and decode them all again.
//!
//! What a generation of an index's graph holds is a function of its
//! version: the id of the write transaction that last wrote it, stored
//! with it (vector_index.zig). A context compares the version its
//! snapshot sees with the cache's and drops the cache's entries of that
//! generation when they differ, so a write by another store (or process)
//! is never read stale. The store drops everything when a write
//! transaction aborts.
//!
//! The cache holds at most `limit` bytes between transactions. A
//! transaction may go above it: what it reads stays valid until it ends,
//! so entries are evicted when the next one begins, by the clock
//! algorithm (an entry read since the hand last passed it gets another
//! round).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const VectorCache = struct {
    allocator: Allocator,
    limit: usize = 64 << 20,
    /// The bytes the entries take, roughly (their data and their slots).
    bytes: usize = 0,
    generations: std.AutoArrayHashMapUnmanaged(GenerationKey, *Generation) = .empty,
    /// The generation the next eviction step looks at.
    hand: usize = 0,

    pub const GenerationKey = struct { index_id: u32, generation: u8 };

    pub const Entity = struct {
        level: u8,
        live: bool,
        referenced: bool = true,
        vector: []f32,
    };

    pub const NeighboursKey = struct { id: u64, at: u8 };
    const Neighbours = struct { referenced: bool = true, ids: []u64 };

    pub const Generation = struct {
        version: u64,
        /// The write transaction that last wrote this generation, so it
        /// stores the version once per transaction.
        written_by: ?u64 = null,
        entities: std.AutoArrayHashMapUnmanaged(u64, Entity) = .empty,
        neighbours: std.AutoArrayHashMapUnmanaged(NeighboursKey, Neighbours) = .empty,
        entity_hand: usize = 0,
        neighbours_hand: usize = 0,
    };

    const entity_slot = @sizeOf(u64) + @sizeOf(Entity) + @sizeOf(u32);
    const neighbours_slot = @sizeOf(NeighboursKey) + @sizeOf(Neighbours) + @sizeOf(u32);

    pub fn init(allocator: Allocator) VectorCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VectorCache) void {
        self.clear();
        self.generations.deinit(self.allocator);
    }

    /// Drops every entry.
    pub fn clear(self: *VectorCache) void {
        for (self.generations.values()) |kept| self.destroy(kept);
        self.generations.clearRetainingCapacity();
        self.hand = 0;
        std.debug.assert(self.bytes == 0);
    }

    /// The entries of generation `key` at `version`: those kept, if they
    /// are of that version, else none.
    pub fn generation(self: *VectorCache, key: GenerationKey, version: u64) Allocator.Error!*Generation {
        const slot = try self.generations.getOrPut(self.allocator, key);
        if (slot.found_existing) {
            if (slot.value_ptr.*.version == version) return slot.value_ptr.*;
            self.empty(slot.value_ptr.*);
            slot.value_ptr.*.version = version;
            slot.value_ptr.*.written_by = null;
            return slot.value_ptr.*;
        }
        errdefer self.generations.swapRemoveAt(slot.index);
        const created = try self.allocator.create(Generation);
        created.* = .{ .version = version };
        slot.value_ptr.* = created;
        return created;
    }

    pub fn findEntity(_: *VectorCache, kept: *Generation, id: u64) ?Entity {
        const entity = kept.entities.getPtr(id) orelse return null;
        entity.referenced = true;
        return entity.*;
    }

    /// Keeps entity `id` as given (its vector copied), and returns it as kept.
    pub fn keepEntity(self: *VectorCache, kept: *Generation, id: u64, level: u8, live: bool, vector: []const f32) Allocator.Error!Entity {
        const slot = try kept.entities.getOrPut(self.allocator, id);
        if (slot.found_existing and slot.value_ptr.vector.len == vector.len) {
            // In place: a vector handed out earlier in the transaction stays valid.
            @memcpy(slot.value_ptr.vector, vector);
            slot.value_ptr.level = level;
            slot.value_ptr.live = live;
            slot.value_ptr.referenced = true;
            return slot.value_ptr.*;
        }
        if (slot.found_existing) {
            self.bytes -= @sizeOf(f32) * slot.value_ptr.vector.len;
            self.allocator.free(slot.value_ptr.vector);
        } else self.bytes += entity_slot;
        const copy = self.allocator.dupe(f32, vector) catch |err| {
            kept.entities.swapRemoveAt(slot.index);
            self.bytes -= entity_slot;
            return err;
        };
        self.bytes += @sizeOf(f32) * copy.len;
        slot.value_ptr.* = .{ .level = level, .live = live, .vector = copy };
        return slot.value_ptr.*;
    }

    pub fn findNeighbours(_: *VectorCache, kept: *Generation, id: u64, at: u8) ?[]const u64 {
        const neighbours = kept.neighbours.getPtr(.{ .id = id, .at = at }) orelse return null;
        neighbours.referenced = true;
        return neighbours.ids;
    }

    /// Keeps the neighbours of `id` on level `at` (copied). The list kept
    /// before is freed: callers get copies.
    pub fn keepNeighbours(self: *VectorCache, kept: *Generation, id: u64, at: u8, ids: []const u64) Allocator.Error!void {
        const copy = try self.allocator.dupe(u64, ids);
        errdefer self.allocator.free(copy);
        const slot = try kept.neighbours.getOrPut(self.allocator, .{ .id = id, .at = at });
        if (slot.found_existing) {
            self.bytes -= @sizeOf(u64) * slot.value_ptr.ids.len;
            self.allocator.free(slot.value_ptr.ids);
        } else self.bytes += neighbours_slot;
        self.bytes += @sizeOf(u64) * copy.len;
        slot.value_ptr.* = .{ .ids = copy };
    }

    /// Evicts entries until the cache is within its limit. Only between
    /// transactions: it frees vectors handed out.
    pub fn evict(self: *VectorCache) void {
        while (self.bytes > self.limit) {
            if (self.hand >= self.generations.count()) self.hand = 0;
            const kept = self.generations.values()[self.hand];
            if (kept.entities.count() == 0 and kept.neighbours.count() == 0) {
                self.destroy(kept);
                self.generations.swapRemoveAt(self.hand);
                continue;
            }
            self.evictStep(kept);
            self.hand += 1;
        }
    }

    /// One step of the clock over each of a generation's two kinds of entry.
    fn evictStep(self: *VectorCache, kept: *Generation) void {
        if (kept.entities.count() > 0) {
            if (kept.entity_hand >= kept.entities.count()) kept.entity_hand = 0;
            const entity = &kept.entities.values()[kept.entity_hand];
            if (entity.referenced) {
                entity.referenced = false;
                kept.entity_hand += 1;
            } else {
                self.bytes -= entity_slot + @sizeOf(f32) * entity.vector.len;
                self.allocator.free(entity.vector);
                kept.entities.swapRemoveAt(kept.entity_hand);
            }
        }
        if (kept.neighbours.count() > 0) {
            if (kept.neighbours_hand >= kept.neighbours.count()) kept.neighbours_hand = 0;
            const neighbours = &kept.neighbours.values()[kept.neighbours_hand];
            if (neighbours.referenced) {
                neighbours.referenced = false;
                kept.neighbours_hand += 1;
            } else {
                self.bytes -= neighbours_slot + @sizeOf(u64) * neighbours.ids.len;
                self.allocator.free(neighbours.ids);
                kept.neighbours.swapRemoveAt(kept.neighbours_hand);
            }
        }
    }

    /// Frees a generation's entries, keeping its maps' memory.
    fn empty(self: *VectorCache, kept: *Generation) void {
        for (kept.entities.values()) |entity| {
            self.bytes -= entity_slot + @sizeOf(f32) * entity.vector.len;
            self.allocator.free(entity.vector);
        }
        for (kept.neighbours.values()) |neighbours| {
            self.bytes -= neighbours_slot + @sizeOf(u64) * neighbours.ids.len;
            self.allocator.free(neighbours.ids);
        }
        kept.entities.clearRetainingCapacity();
        kept.neighbours.clearRetainingCapacity();
        kept.entity_hand = 0;
        kept.neighbours_hand = 0;
    }

    fn destroy(self: *VectorCache, kept: *Generation) void {
        self.empty(kept);
        kept.entities.deinit(self.allocator);
        kept.neighbours.deinit(self.allocator);
        self.allocator.destroy(kept);
    }
};
