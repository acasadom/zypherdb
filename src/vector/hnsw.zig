//! HNSW (Malkov and Yashunin, "Efficient and robust approximate nearest
//! neighbor search using Hierarchical Navigable Small World graphs"),
//! written once over a storage context, as `std.HashMap` is over its
//! hash context. It knows nothing of where vectors and neighbour lists
//! live: src/storage/vector_index.zig keeps them in the key-value store,
//! tests keep them in memory.
//!
//! `Storage` provides (`Storage.Error` is its error set):
//!
//!     fn distanceTo(*Storage, query: []const f32, id: u64) Error!f32
//!     fn distanceBetween(*Storage, a: u64, b: u64) Error!f32
//!     fn isLive(*Storage, id: u64) Error!bool        false for a tombstone
//!     fn level(*Storage, id: u64) Error!u8           the top level of id
//!     fn neighbours(*Storage, arena, id: u64, level: u8) Error![]u64   a copy
//!     fn setNeighbours(*Storage, id: u64, level: u8, ids: []const u64) Error!void
//!     fn header(*Storage) Error!?Header
//!     fn setHeader(*Storage, ?Header) Error!void
//!
//! An entity's vector and level are stored by the caller before `insert`,
//! and its tombstone mark before `remove`. A tombstone still routes
//! searches (other lists keep pointing at it) and is never returned.
//!
//! Costs (n entities, M neighbours per level, ef the search breadth):
//! `insert` and `search` visit O(ef · M · log n) entities, each a distance
//! computation; `remove` repairs O(M²) lists. Every list an operation
//! writes is O(M) ids.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Where searches start, and how many entities the graph holds.
pub const Header = struct {
    entry: u64,
    top_level: u8,
    live: u64,
    tombstones: u64,
};

pub const Parameters = struct {
    /// Neighbours per entity on levels above 0 (twice as many on level 0).
    m: u16 = 16,
    /// The search breadth when inserting.
    ef_construction: u16 = 100,

    pub fn maxNeighbours(self: Parameters, at_level: u8) usize {
        return if (at_level == 0) 2 * @as(usize, self.m) else self.m;
    }
};

/// The highest level an entity gets (levels above it are vanishingly rare).
pub const max_level: u8 = 15;

/// An entity found, and its distance to the query.
pub const Hit = struct {
    id: u64,
    distance: f32,

    /// Closer first, then by id: a total order, so results are deterministic.
    pub fn order(a: Hit, b: Hit) std.math.Order {
        const by_distance = std.math.order(a.distance, b.distance);
        return if (by_distance != .eq) by_distance else std.math.order(a.id, b.id);
    }

    fn lessThan(_: void, a: Hit, b: Hit) bool {
        return a.order(b) == .lt;
    }
};

/// The level entity `id` gets: drawn from a geometric distribution with
/// ratio 1/M, from a hash of the id, so that rebuilding gives the same graph.
pub fn levelOf(id: u64, parameters: Parameters) u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, id, .little);
    const hash = std.hash.Wyhash.hash(0x6873_6e77, &bytes);
    // Uniform in (0, 1].
    const uniform = (@as(f64, @floatFromInt(hash >> 11)) + 1) / @as(f64, 1 << 53);
    const scale = 1 / @log(@as(f64, @floatFromInt(parameters.m)));
    return @intFromFloat(@min(@floor(-@log(uniform) * scale), max_level));
}

/// True when tombstones outnumber live entities (and there are enough to be
/// worth a rebuild): searches then route through more dead ends than not.
pub fn needsRebuild(header: Header) bool {
    return header.tombstones > 1024 and header.tombstones > header.live;
}

pub fn Hnsw(comptime Storage: type) type {
    return struct {
        pub const Error = Storage.Error || Allocator.Error;

        /// Links entity `id` (its vector and level stored, live) into the
        /// graph. `arena` holds the scratch of this call.
        pub fn insert(storage: *Storage, arena: Allocator, parameters: Parameters, id: u64, was_tombstone: bool) Error!void {
            const own_level = try storage.level(id);
            var header = try storage.header() orelse {
                for (0..@as(usize, own_level) + 1) |at| try storage.setNeighbours(id, @intCast(at), &.{});
                return storage.setHeader(.{ .entry = id, .top_level = own_level, .live = 1, .tombstones = 0 });
            };
            var entry = Hit{ .id = header.entry, .distance = try storage.distanceBetween(id, header.entry) };
            var at: u8 = header.top_level;
            while (at > own_level) : (at -= 1) entry = try greedy(storage, arena, .{ .entity = id }, entry, at);
            var entries = try arena.dupe(Hit, &.{entry});
            at = @min(own_level, header.top_level);
            while (true) : (at -= 1) {
                const found = try searchLevel(storage, arena, .{ .entity = id }, entries, parameters.ef_construction, at, false);
                const chosen = try selectNeighbours(storage, arena, withoutId(found, id), parameters.maxNeighbours(at));
                try storage.setNeighbours(id, at, try idsOf(arena, chosen));
                for (chosen) |neighbour| try addLink(storage, arena, parameters, neighbour.id, id, at);
                entries = found;
                if (at == 0) break;
            }
            // Levels above the old top start with no neighbours.
            var above = header.top_level + 1;
            while (above <= own_level) : (above += 1) try storage.setNeighbours(id, above, &.{});
            if (own_level > header.top_level) {
                header.entry = id;
                header.top_level = own_level;
            }
            header.live += 1;
            if (was_tombstone) header.tombstones -= 1;
            try storage.setHeader(header);
        }

        /// Repairs the lists that point at `id`, whose tombstone mark is
        /// stored: each of its neighbours that links back to it chooses
        /// again among its other neighbours and `id`'s.
        pub fn remove(storage: *Storage, arena: Allocator, parameters: Parameters, id: u64) Error!void {
            try unlink(storage, arena, parameters, id);
            var header = (try storage.header()).?;
            header.live -= 1;
            header.tombstones += 1;
            try storage.setHeader(header);
        }

        /// Moves entity `id` (live, its new vector stored) to where its new
        /// vector belongs: unlinked from its old neighbours, then linked anew.
        pub fn update(storage: *Storage, arena: Allocator, parameters: Parameters, id: u64) Error!void {
            try unlink(storage, arena, parameters, id);
            var header = (try storage.header()).?;
            header.live -= 1;
            try storage.setHeader(header);
            if (header.live == 0 and header.tombstones == 0) {
                try storage.setHeader(null);
            }
            return insert(storage, arena, parameters, id, false);
        }

        fn unlink(storage: *Storage, arena: Allocator, parameters: Parameters, id: u64) Error!void {
            const own_level = try storage.level(id);
            for (0..@as(usize, own_level) + 1) |at_index| {
                const at: u8 = @intCast(at_index);
                const own = try storage.neighbours(arena, id, at);
                for (own) |neighbour| {
                    if (neighbour == id) continue;
                    const theirs = try storage.neighbours(arena, neighbour, at);
                    if (std.mem.indexOfScalar(u64, theirs, id) == null) continue;
                    var candidates = std.ArrayList(Hit).empty;
                    for ([_][]const u64{ theirs, own }) |list| for (list) |candidate| {
                        if (candidate == id or candidate == neighbour) continue;
                        if (containsId(candidates.items, candidate)) continue;
                        try candidates.append(arena, .{ .id = candidate, .distance = try storage.distanceBetween(neighbour, candidate) });
                    };
                    std.mem.sort(Hit, candidates.items, {}, Hit.lessThan);
                    const chosen = try selectNeighbours(storage, arena, candidates.items, parameters.maxNeighbours(at));
                    try storage.setNeighbours(neighbour, at, try idsOf(arena, chosen));
                }
            }
        }

        /// The `k` live entities closest to `query` (prepared as the
        /// index keeps vectors), closest first; `ef` (at least k) trades
        /// time for recall.
        pub fn search(storage: *Storage, arena: Allocator, query: []const f32, k: usize, ef: usize) Error![]const Hit {
            const header = try storage.header() orelse return &.{};
            if (k == 0 or header.live == 0) return &.{};
            const target = Target{ .query = query };
            var entry = Hit{ .id = header.entry, .distance = try storage.distanceTo(query, header.entry) };
            var at = header.top_level;
            while (at > 0) : (at -= 1) entry = try greedy(storage, arena, target, entry, at);
            const found = try searchLevel(storage, arena, target, &.{entry}, @max(ef, k), 0, true);
            return found[0..@min(k, found.len)];
        }

        /// What a search measures distances to: a query vector, or a stored
        /// entity (when inserting it).
        const Target = union(enum) {
            query: []const f32,
            entity: u64,

            fn distance(self: Target, storage: *Storage, id: u64) Storage.Error!f32 {
                return switch (self) {
                    .query => |query| storage.distanceTo(query, id),
                    .entity => |entity| storage.distanceBetween(entity, id),
                };
            }
        };

        /// The closest entity to `target` reachable from `entry` on level
        /// `at`, moving to a closer neighbour while there is one.
        fn greedy(storage: *Storage, arena: Allocator, target: Target, entry: Hit, at: u8) Error!Hit {
            var best = entry;
            var moved = true;
            while (moved) {
                moved = false;
                for (try storage.neighbours(arena, best.id, at)) |neighbour| {
                    const candidate = Hit{ .id = neighbour, .distance = try target.distance(storage, neighbour) };
                    if (candidate.order(best) == .lt) {
                        best = candidate;
                        moved = true;
                    }
                }
            }
            return best;
        }

        fn closerFirst(_: void, a: Hit, b: Hit) std.math.Order {
            return a.order(b);
        }

        fn fartherFirst(_: void, a: Hit, b: Hit) std.math.Order {
            return b.order(a);
        }

        /// The (up to) `ef` entities closest to `target` on level `at`,
        /// reached from `entries`, closest first. With `live_only`,
        /// tombstones route the search but are left out of the result.
        fn searchLevel(storage: *Storage, arena: Allocator, target: Target, entries: []const Hit, ef: usize, at: u8, live_only: bool) Error![]Hit {
            var visited = std.AutoHashMapUnmanaged(u64, void).empty;
            var candidates = std.PriorityQueue(Hit, void, closerFirst).empty;
            var results = std.PriorityQueue(Hit, void, fartherFirst).empty;
            for (entries) |entry| {
                if ((try visited.getOrPut(arena, entry.id)).found_existing) continue;
                try candidates.push(arena, entry);
                if (!live_only or try storage.isLive(entry.id)) try results.push(arena, entry);
            }
            while (candidates.pop()) |current| {
                if (results.count() >= ef and current.order(results.peek().?) == .gt) break;
                for (try storage.neighbours(arena, current.id, at)) |neighbour| {
                    if ((try visited.getOrPut(arena, neighbour)).found_existing) continue;
                    const candidate = Hit{ .id = neighbour, .distance = try target.distance(storage, neighbour) };
                    if (results.count() >= ef and candidate.order(results.peek().?) != .lt) continue;
                    try candidates.push(arena, candidate);
                    if (live_only and !try storage.isLive(neighbour)) continue;
                    try results.push(arena, candidate);
                    if (results.count() > ef) _ = results.pop();
                }
            }
            const found = try arena.alloc(Hit, results.count());
            var index = found.len;
            while (results.pop()) |hit| {
                index -= 1;
                found[index] = hit;
            }
            return found;
        }

        /// Up to `limit` of `candidates` (closest first, their distances to
        /// the entity they will be neighbours of): the heuristic of the
        /// paper, which keeps a candidate only if it is closer to the entity
        /// than to any one kept, so that neighbours point different ways;
        /// then the closest of those left out, to fill `limit`.
        fn selectNeighbours(storage: *Storage, arena: Allocator, candidates: []const Hit, limit: usize) Error![]const Hit {
            if (candidates.len <= limit) return candidates;
            var kept = std.ArrayList(Hit).empty;
            var left_out = std.ArrayList(Hit).empty;
            for (candidates) |candidate| {
                if (kept.items.len == limit) break;
                const diverse = for (kept.items) |chosen| {
                    if (try storage.distanceBetween(candidate.id, chosen.id) < candidate.distance) break false;
                } else true;
                try (if (diverse) &kept else &left_out).append(arena, candidate);
            }
            for (left_out.items) |candidate| {
                if (kept.items.len == limit) break;
                try kept.append(arena, candidate);
            }
            return kept.items;
        }

        /// Adds `id` to the neighbours of `owner` on level `at`, choosing
        /// again among them when that is one too many.
        fn addLink(storage: *Storage, arena: Allocator, parameters: Parameters, owner: u64, id: u64, at: u8) Error!void {
            const current = try storage.neighbours(arena, owner, at);
            if (std.mem.indexOfScalar(u64, current, id) != null) return;
            const limit = parameters.maxNeighbours(at);
            if (current.len < limit) {
                const grown = try arena.alloc(u64, current.len + 1);
                @memcpy(grown[0..current.len], current);
                grown[current.len] = id;
                return storage.setNeighbours(owner, at, grown);
            }
            const candidates = try arena.alloc(Hit, current.len + 1);
            for (candidates[0..current.len], current) |*candidate, neighbour| {
                candidate.* = .{ .id = neighbour, .distance = try storage.distanceBetween(owner, neighbour) };
            }
            candidates[current.len] = .{ .id = id, .distance = try storage.distanceBetween(owner, id) };
            std.mem.sort(Hit, candidates, {}, Hit.lessThan);
            try storage.setNeighbours(owner, at, try idsOf(arena, try selectNeighbours(storage, arena, candidates, limit)));
        }

        fn idsOf(arena: Allocator, hits: []const Hit) Allocator.Error![]const u64 {
            const ids = try arena.alloc(u64, hits.len);
            for (ids, hits) |*id, hit| id.* = hit.id;
            return ids;
        }

        fn withoutId(hits: []Hit, id: u64) []const Hit {
            var kept: usize = 0;
            for (hits) |hit| if (hit.id != id) {
                hits[kept] = hit;
                kept += 1;
            };
            return hits[0..kept];
        }

        fn containsId(hits: []const Hit, id: u64) bool {
            for (hits) |hit| if (hit.id == id) return true;
            return false;
        }
    };
}
