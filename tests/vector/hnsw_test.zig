//! The HNSW algorithm over an in-memory storage: recall against an exact
//! search, on random and on clustered vectors, through inserts, removals
//! and updates.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const hnsw = zypherdb.vector.hnsw;
const similarity = zypherdb.vector.similarity;
const Similarity = similarity.Similarity;

/// Vectors, levels, lists and the header in hash maps.
const MemoryStorage = struct {
    allocator: std.mem.Allocator,
    measure: Similarity,
    vectors: std.AutoHashMapUnmanaged(u64, []f32) = .empty,
    levels: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    live: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    lists: std.AutoHashMapUnmanaged(struct { u64, u8 }, []u64) = .empty,
    stored_header: ?hnsw.Header = null,

    pub const Error = std.mem.Allocator.Error;

    fn deinit(self: *MemoryStorage) void {
        var vectors = self.vectors.valueIterator();
        while (vectors.next()) |vector| self.allocator.free(vector.*);
        var lists = self.lists.valueIterator();
        while (lists.next()) |list| self.allocator.free(list.*);
        self.vectors.deinit(self.allocator);
        self.levels.deinit(self.allocator);
        self.live.deinit(self.allocator);
        self.lists.deinit(self.allocator);
    }

    fn put(self: *MemoryStorage, id: u64, numbers: []const f64, live: bool) !void {
        const vector = try self.allocator.alloc(f32, numbers.len);
        try testing.expect(similarity.prepare(self.measure, numbers, vector) == null);
        if (try self.vectors.fetchPut(self.allocator, id, vector)) |old| self.allocator.free(old.value);
        if (!self.levels.contains(id)) try self.levels.put(self.allocator, id, hnsw.levelOf(id, .{}));
        try self.live.put(self.allocator, id, live);
    }

    pub fn vectorOf(self: *MemoryStorage, id: u64) Error![]const f32 {
        return self.vectors.get(id).?;
    }

    pub fn distance(self: *MemoryStorage, a: []const f32, b: []const f32) f32 {
        return similarity.distance(self.measure, a, b);
    }

    pub fn isLive(self: *MemoryStorage, id: u64) Error!bool {
        return self.live.get(id).?;
    }

    pub fn level(self: *MemoryStorage, id: u64) Error!u8 {
        return self.levels.get(id).?;
    }

    pub fn neighbours(self: *MemoryStorage, arena: std.mem.Allocator, id: u64, at: u8) Error![]u64 {
        return arena.dupe(u64, self.lists.get(.{ id, at }).?);
    }

    pub fn setNeighbours(self: *MemoryStorage, id: u64, at: u8, ids: []const u64) Error!void {
        const copy = try self.allocator.dupe(u64, ids);
        if (try self.lists.fetchPut(self.allocator, .{ id, at }, copy)) |old| self.allocator.free(old.value);
    }

    pub fn header(self: *MemoryStorage) Error!?hnsw.Header {
        return self.stored_header;
    }

    pub fn setHeader(self: *MemoryStorage, value: ?hnsw.Header) Error!void {
        self.stored_header = value;
    }
};

const Graph = hnsw.Hnsw(MemoryStorage);

/// The fraction of the exact k nearest live entities a search finds.
fn recall(storage: *MemoryStorage, queries: []const []const f64, k: usize, ef: usize) !f64 {
    var found_total: usize = 0;
    var wanted_total: usize = 0;
    for (queries) |numbers| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const query = try arena.allocator().alloc(f32, numbers.len);
        try testing.expect(similarity.prepare(storage.measure, numbers, query) == null);
        // Exact: every live entity, by distance.
        var exact = std.ArrayList(hnsw.Hit).empty;
        var entities = storage.vectors.iterator();
        while (entities.next()) |entity| {
            if (!storage.live.get(entity.key_ptr.*).?) continue;
            try exact.append(arena.allocator(), .{ .id = entity.key_ptr.*, .distance = similarity.distance(storage.measure, query, entity.value_ptr.*) });
        }
        std.mem.sort(hnsw.Hit, exact.items, {}, struct {
            fn lessThan(_: void, a: hnsw.Hit, b: hnsw.Hit) bool {
                return a.order(b) == .lt;
            }
        }.lessThan);
        const wanted = exact.items[0..@min(k, exact.items.len)];
        const found = try Graph.search(storage, arena.allocator(), query, k, ef);
        try testing.expectEqual(wanted.len, found.len);
        for (found, 0..) |hit, i| {
            try testing.expect(storage.live.get(hit.id).?);
            if (i > 0) try testing.expect(found[i - 1].order(hit) == .lt);
        }
        for (wanted) |want| {
            for (found) |hit| if (hit.id == want.id) {
                found_total += 1;
                break;
            };
        }
        wanted_total += wanted.len;
    }
    return @as(f64, @floatFromInt(found_total)) / @as(f64, @floatFromInt(wanted_total));
}

fn randomVector(random: std.Random, allocator: std.mem.Allocator, dimensions: usize, center: ?[]const f64) ![]f64 {
    const numbers = try allocator.alloc(f64, dimensions);
    for (numbers, 0..) |*number, i| {
        const noise = random.floatNorm(f64);
        number.* = if (center) |c| c[i] + 0.05 * noise else noise;
    }
    return numbers;
}

fn insertAll(storage: *MemoryStorage, vectors: []const []const f64) !void {
    for (vectors, 0..) |numbers, i| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try storage.put(i, numbers, true);
        try Graph.insert(storage, arena.allocator(), .{}, i, false);
    }
}

test "recall on random vectors, both similarities" {
    var data = std.heap.ArenaAllocator.init(testing.allocator);
    defer data.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    const vectors = try data.allocator().alloc([]const f64, 2000);
    for (vectors) |*vector| vector.* = try randomVector(random, data.allocator(), 24, null);
    const queries = try data.allocator().alloc([]const f64, 50);
    for (queries) |*query| query.* = try randomVector(random, data.allocator(), 24, null);

    for ([_]Similarity{ .cosine, .euclidean }) |measure| {
        var storage = MemoryStorage{ .allocator = testing.allocator, .measure = measure };
        defer storage.deinit();
        try insertAll(&storage, vectors);
        const measured = try recall(&storage, queries, 10, 100);
        if (measured < 0.95) std.debug.print("{t}: recall {d:.3}\n", .{ measure, measured });
        try testing.expect(measured >= 0.95);
    }
}

test "recall on clustered vectors" {
    var data = std.heap.ArenaAllocator.init(testing.allocator);
    defer data.deinit();
    var prng = std.Random.DefaultPrng.init(2);
    const random = prng.random();
    const centers = try data.allocator().alloc([]const f64, 20);
    for (centers) |*center| center.* = try randomVector(random, data.allocator(), 32, null);
    const vectors = try data.allocator().alloc([]const f64, 2000);
    for (vectors) |*vector| vector.* = try randomVector(random, data.allocator(), 32, centers[random.uintLessThan(usize, centers.len)]);
    const queries = try data.allocator().alloc([]const f64, 50);
    for (queries) |*query| query.* = try randomVector(random, data.allocator(), 32, centers[random.uintLessThan(usize, centers.len)]);

    var storage = MemoryStorage{ .allocator = testing.allocator, .measure = .cosine };
    defer storage.deinit();
    try insertAll(&storage, vectors);
    const measured = try recall(&storage, queries, 10, 100);
    if (measured < 0.95) std.debug.print("clustered: recall {d:.3}\n", .{measured});
    try testing.expect(measured >= 0.95);
}

test "removed entities are never returned, and recall holds" {
    var data = std.heap.ArenaAllocator.init(testing.allocator);
    defer data.deinit();
    var prng = std.Random.DefaultPrng.init(3);
    const random = prng.random();
    const vectors = try data.allocator().alloc([]const f64, 1500);
    for (vectors) |*vector| vector.* = try randomVector(random, data.allocator(), 16, null);
    const queries = try data.allocator().alloc([]const f64, 50);
    for (queries) |*query| query.* = try randomVector(random, data.allocator(), 16, null);

    var storage = MemoryStorage{ .allocator = testing.allocator, .measure = .euclidean };
    defer storage.deinit();
    try insertAll(&storage, vectors);
    // Remove two of every five, the entry point among them.
    const entry = (try storage.header()).?.entry;
    for (vectors, 0..) |_, i| {
        if (i % 5 >= 2 and i != entry) continue;
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try storage.live.put(testing.allocator, i, false);
        try Graph.remove(&storage, arena.allocator(), .{}, i);
    }
    const header = (try storage.header()).?;
    try testing.expectEqual(@as(u64, 900) - @intFromBool(entry % 5 >= 2), header.live);
    try testing.expectEqual(vectors.len - header.live, header.tombstones);
    const measured = try recall(&storage, queries, 10, 100);
    if (measured < 0.95) std.debug.print("after removals: recall {d:.3}\n", .{measured});
    try testing.expect(measured >= 0.95);

    // A tombstone comes back.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try storage.put(entry, vectors[entry], true);
    try Graph.insert(&storage, arena.allocator(), .{}, entry, true);
    try testing.expectEqual(header.live + 1, (try storage.header()).?.live);
    try testing.expectEqual(header.tombstones - 1, (try storage.header()).?.tombstones);
}

test "an updated entity is found where its new vector is" {
    var data = std.heap.ArenaAllocator.init(testing.allocator);
    defer data.deinit();
    var prng = std.Random.DefaultPrng.init(4);
    const random = prng.random();
    const vectors = try data.allocator().alloc([]const f64, 1000);
    for (vectors) |*vector| vector.* = try randomVector(random, data.allocator(), 16, null);

    var storage = MemoryStorage{ .allocator = testing.allocator, .measure = .cosine };
    defer storage.deinit();
    try insertAll(&storage, vectors);
    // Move every tenth entity somewhere else.
    for (vectors, 0..) |*vector, i| {
        if (i % 10 != 0) continue;
        vector.* = try randomVector(random, data.allocator(), 16, null);
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        try storage.put(i, vector.*, true);
        try Graph.update(&storage, arena.allocator(), .{}, i);
    }
    try testing.expectEqual(@as(u64, vectors.len), (try storage.header()).?.live);
    // Each moved entity is the first hit of a query on its new vector.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (vectors, 0..) |vector, i| {
        if (i % 10 != 0) continue;
        const query = try arena.allocator().alloc(f32, vector.len);
        _ = similarity.prepare(.cosine, vector, query);
        const found = try Graph.search(&storage, arena.allocator(), query, 1, 50);
        try testing.expectEqual(@as(u64, i), found[0].id);
    }
}

test "an empty graph, and k beyond its size" {
    var storage = MemoryStorage{ .allocator = testing.allocator, .measure = .euclidean };
    defer storage.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const query = [_]f32{ 1, 2 };
    try testing.expectEqual(@as(usize, 0), (try Graph.search(&storage, arena.allocator(), &query, 5, 10)).len);
    try storage.put(7, &.{ 1, 1 }, true);
    try Graph.insert(&storage, arena.allocator(), .{}, 7, false);
    try storage.put(8, &.{ 3, 3 }, true);
    try Graph.insert(&storage, arena.allocator(), .{}, 8, false);
    const found = try Graph.search(&storage, arena.allocator(), &query, 5, 10);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(@as(u64, 7), found[0].id);
}

test "levels are geometric: about one in M above level 0" {
    var above: usize = 0;
    for (0..100_000) |id| {
        if (hnsw.levelOf(id, .{}) > 0) above += 1;
    }
    // 1/16 of 100000 is 6250.
    try testing.expect(above > 5800 and above < 6700);
}

test "similarity scores as Neo4j scores" {
    try testing.expectEqual(@as(?f64, 1), similarity.scoreOfNumbers(.cosine, &.{ 1, 0 }, &.{ 2, 0 }));
    try testing.expectEqual(@as(?f64, 0.5), similarity.scoreOfNumbers(.cosine, &.{ 1, 0 }, &.{ 0, 1 }));
    try testing.expectEqual(@as(?f64, 0), similarity.scoreOfNumbers(.cosine, &.{ 1, 0 }, &.{ -1, 0 }));
    try testing.expectEqual(@as(?f64, null), similarity.scoreOfNumbers(.cosine, &.{ 0, 0 }, &.{ 1, 0 }));
    try testing.expectEqual(@as(?f64, 0.2), similarity.scoreOfNumbers(.euclidean, &.{ 0, 0 }, &.{ 0, 2 }));
    // The SIMD loops agree with the plain sum past a whole number of lanes.
    var a: [37]f32 = undefined;
    var b: [37]f32 = undefined;
    var plain: f32 = 0;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i);
        y.* = @floatFromInt(37 - i);
        plain += (x.* - y.*) * (x.* - y.*);
    }
    try testing.expectEqual(plain, similarity.squaredDistance(&a, &b));
}
