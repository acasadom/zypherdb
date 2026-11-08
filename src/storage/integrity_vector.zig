//! The integrity checker's part for vector indexes (integrity.zig).
//!
//! An HNSW graph depends on the order of the writes that built it, so it
//! cannot be rebuilt and compared key by key. What is checked:
//!
//! - each entity the index must hold has its record, exactly: its level,
//!   live, its property's vector as the index keeps it;
//! - the other records are tombstones;
//! - each record has a neighbour list on each of its levels, of at most
//!   the level's maximum, naming other recorded entities, once each;
//! - the header names a recorded entity on the top level, and counts the
//!   live entities and the tombstones.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Checker = @import("integrity.zig").Checker;
const Bytes = @import("integrity.zig").Bytes;
const StorageError = @import("key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const value_encoding = @import("value_encoding.zig");
const fulltext = @import("fulltext.zig");
const vector_index = @import("vector_index.zig");
const hnsw = @import("../vector/hnsw.zig");

/// Records the keys vector index `definition` must hold, and reports what
/// its stored graph gets wrong.
pub fn expectIndex(checker: *Checker, definition: fulltext.Definition) StorageError!void {
    const arena = checker.arena;
    var storage = try vector_index.IndexStorage.init(checker.graph, arena, definition);
    var live = std.AutoArrayHashMapUnmanaged(u64, void).empty;
    switch (definition.entity) {
        .nodes => for (checker.nodes.keys(), checker.nodes.values()) |id, record| {
            if (!record.hasLabel(definition.labels_or_types[0])) continue;
            const encoded = record.property(definition.properties[0]) orelse continue;
            try expectEntity(checker, &storage, definition, id, try value_encoding.decodeValue(encoded, arena), &live);
        },
        .relationships => for (checker.relationships.keys(), checker.relationships.values()) |id, relationship| {
            if (!std.mem.eql(u8, relationship.edge_type, definition.labels_or_types[0])) continue;
            for (relationship.properties.items) |stored| if (std.mem.eql(u8, stored.name, definition.properties[0])) {
                try expectEntity(checker, &storage, definition, id, try value_encoding.decodeValue(stored.encoded, arena), &live);
            };
        },
    }
    try checkGraph(checker, &storage, definition, &live);
}

fn expectEntity(checker: *Checker, storage: *vector_index.IndexStorage, definition: fulltext.Definition, id: u64, value: Value, live: *std.AutoArrayHashMapUnmanaged(u64, void)) StorageError!void {
    const arena = checker.arena;
    const vector = switch (try vector_index.check(arena, definition, value)) {
        .absent => return,
        .invalid => |reason| return checker.report.add("vector index '{s}': the value of entity {d} {s}", .{ definition.name, id, reason }),
        .vector => |vector| vector,
    };
    try live.put(arena, id, {});
    const bytes = try arena.alloc(u8, 2 + 4 * vector.len);
    bytes[0] = hnsw.levelOf(id, vector_index.parameters);
    bytes[1] = 1;
    for (vector, 0..) |element, i| std.mem.writeInt(u32, bytes[2 + 4 * i ..][0..4], @bitCast(element), .little);
    const key = storage.entityKey(id);
    try checker.expect(try arena.dupe(u8, &key), bytes);
}

/// Scans the index's keys: the tombstones, the neighbour lists and the
/// header are expected with any value once they pass the checks.
fn checkGraph(checker: *Checker, storage: *vector_index.IndexStorage, definition: fulltext.Definition, live: *const std.AutoArrayHashMapUnmanaged(u64, void)) StorageError!void {
    const arena = checker.arena;
    const report = checker.report;
    const name = definition.name;
    // Every record's level, and the lists found.
    var levels = std.AutoArrayHashMapUnmanaged(u64, u8).empty;
    const List = struct { key: []const u8, id: u64, level: u8, neighbours: []const u8 };
    var lists = std.ArrayList(List).empty;
    var header_value: ?[]const u8 = null; // its checks follow the scan
    var tombstones: u64 = 0;
    {
        var prefix: [5]u8 = undefined;
        prefix[0] = vector_index.marker;
        std.mem.writeInt(u32, prefix[1..5], definition.index_id, .big);
        var keys = try checker.graph.store.scanPrefix(&prefix);
        defer keys.deinit();
        while (try keys.next()) |entry| {
            const key = try arena.dupe(u8, entry.key);
            const rest = key[5..];
            if (rest.len == 1 and rest[0] == 'H') {
                header_value = try arena.dupe(u8, entry.value);
                try checker.expect(key, null);
            } else if (rest.len == 9 and rest[0] == 'E' and entry.value.len == 2 + 4 * @as(usize, definition.dimensions)) {
                const id = std.mem.readInt(u64, rest[1..9], .big);
                try levels.put(arena, id, entry.value[0]);
                if (entry.value[1] != 1) {
                    tombstones += 1;
                    try checker.expect(key, null);
                    if (live.contains(id)) try report.add("vector index '{s}': entity {d} is a tombstone, but its property holds a vector", .{ name, id });
                }
            } else if (rest.len == 10 and rest[0] == 'N' and entry.value.len % 8 == 0) {
                try lists.append(arena, .{ .key = key, .id = std.mem.readInt(u64, rest[1..9], .big), .level = rest[9], .neighbours = try arena.dupe(u8, entry.value) });
                try checker.expect(key, null);
            } else {
                try report.add("vector index '{s}': malformed key {f}", .{ name, Bytes{ .bytes = key } });
            }
        }
    }
    var lists_per_entity = std.AutoArrayHashMapUnmanaged(u64, usize).empty;
    for (lists.items) |list| {
        const level = levels.get(list.id) orelse {
            try report.add("vector index '{s}': a neighbour list of entity {d}, which has no record", .{ name, list.id });
            continue;
        };
        if (list.level > level) try report.add("vector index '{s}': entity {d} has a list on level {d}, above its level {d}", .{ name, list.id, list.level, level });
        (try lists_per_entity.getOrPutValue(arena, list.id, 0)).value_ptr.* += 1;
        const count = list.neighbours.len / 8;
        if (count > vector_index.parameters.maxNeighbours(list.level)) try report.add("vector index '{s}': entity {d} has {d} neighbours on level {d}", .{ name, list.id, count, list.level });
        for (0..count) |i| {
            const neighbour = std.mem.readInt(u64, list.neighbours[8 * i ..][0..8], .little);
            if (neighbour == list.id) try report.add("vector index '{s}': entity {d} is its own neighbour", .{ name, list.id });
            if (!levels.contains(neighbour)) try report.add("vector index '{s}': entity {d} links to {d}, which has no record", .{ name, list.id, neighbour });
            for (0..i) |j| if (std.mem.readInt(u64, list.neighbours[8 * j ..][0..8], .little) == neighbour) {
                try report.add("vector index '{s}': entity {d} links to {d} twice", .{ name, list.id, neighbour });
            };
        }
    }
    var top_level: u8 = 0;
    for (levels.keys(), levels.values()) |id, level| {
        top_level = @max(top_level, level);
        const have = lists_per_entity.get(id) orelse 0;
        if (have != @as(usize, level) + 1) try report.add("vector index '{s}': entity {d} has {d} neighbour lists for {d} levels", .{ name, id, have, @as(usize, level) + 1 });
    }
    if (header_value == null) {
        if (levels.count() > 0) try report.add("vector index '{s}': {d} entities and no header", .{ name, levels.count() });
        return;
    }
    const header = storage.header() catch |err| switch (err) {
        error.ReadFailed => return report.add("vector index '{s}': malformed header {f}", .{ name, Bytes{ .bytes = header_value.? } }),
        else => |other| return other,
    } orelse return;
    if (header.live != live.count()) try report.add("vector index '{s}': the header counts {d} live entities, there are {d}", .{ name, header.live, live.count() });
    if (header.tombstones != tombstones) try report.add("vector index '{s}': the header counts {d} tombstones, there are {d}", .{ name, header.tombstones, tombstones });
    const entry_level = levels.get(header.entry) orelse return report.add("vector index '{s}': the entry point {d} has no record", .{ name, header.entry });
    if (entry_level != header.top_level or header.top_level != top_level) {
        try report.add("vector index '{s}': the entry point {d} is on level {d}, the header says {d}, the top level is {d}", .{ name, header.entry, entry_level, header.top_level, top_level });
    }
}
