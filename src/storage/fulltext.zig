//! Schema definitions: full-text indexes (whose postings live in the same
//! keys' space, fulltext_postings.zig), property indexes
//! (property_indexes.zig), and uniqueness constraints (constraints.zig),
//! each of which owns a property index. One namespace for their names, as
//! in Neo4j.
//!
//! A definition is stored under `i | name`:
//!
//!     kind: u8                   0 full-text, 1 range (declared), 2 unique
//!     entity: u8                 0 nodes, 1 relationships
//!     analyzer: u16 length, bytes (empty but for full-text)
//!     labels or types: u16 count, each u16 length, bytes
//!     properties: u16 count, each u16 length, bytes
//!     index id: u32              the property index's keys (0 for full-text)
//!
//! The key `!schema` counts the changes to the definitions, so a process that
//! keeps them in memory knows when to read them again.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("graph.zig").Graph;
const StorageError = @import("key_value_store.zig").StorageError;

pub const definition_marker: u8 = 'i';
pub const schema_version_key: []const u8 = "!schema";
/// The last property index id handed out (u32; ids start at 1).
pub const index_id_key: []const u8 = "!index_id";

pub const Entity = enum(u8) { nodes = 0, relationships = 1 };

pub const Kind = enum(u8) { fulltext = 0, range = 1, unique = 2 };

pub const Definition = struct {
    name: []const u8,
    kind: Kind = .fulltext,
    entity: Entity,
    analyzer: []const u8,
    labels_or_types: []const []const u8,
    properties: []const []const u8,
    /// The property index's id in its keys (range and unique; 0 for
    /// full-text), given by `create`.
    index_id: u32 = 0,

    /// True if the definition owns a property index (property_indexes.zig).
    pub fn hasPropertyIndex(self: Definition) bool {
        return self.kind != .fulltext;
    }

    fn encode(self: Definition, allocator: Allocator) Allocator.Error![]u8 {
        var bytes = std.ArrayList(u8).empty;
        try bytes.append(allocator, @backingInt(self.kind));
        try bytes.append(allocator, @backingInt(self.entity));
        try appendString(&bytes, allocator, self.analyzer);
        for ([_][]const []const u8{ self.labels_or_types, self.properties }) |list| {
            try appendCount(&bytes, allocator, list.len);
            for (list) |item| try appendString(&bytes, allocator, item);
        }
        var id: [4]u8 = undefined;
        std.mem.writeInt(u32, &id, self.index_id, .big);
        try bytes.appendSlice(allocator, &id);
        return bytes.items;
    }

    /// The definition `name` stored as `bytes`, its strings copied with `allocator`.
    fn decode(name: []const u8, bytes: []const u8, allocator: Allocator) Allocator.Error!Definition {
        var reader = Reader{ .bytes = bytes };
        const kind: Kind = @fromBackingInt(@intCast(reader.byte()));
        const entity: Entity = @fromBackingInt(@intCast(reader.byte()));
        const analyzer = try allocator.dupe(u8, reader.string());
        var lists: [2][]const []const u8 = undefined;
        for (&lists) |*list| {
            const items = try allocator.alloc([]const u8, reader.count());
            for (items) |*item| item.* = try allocator.dupe(u8, reader.string());
            list.* = items;
        }
        const index_id = std.mem.readInt(u32, bytes[reader.position..][0..4], .big);
        return .{ .name = try allocator.dupe(u8, name), .kind = kind, .entity = entity, .analyzer = analyzer, .labels_or_types = lists[0], .properties = lists[1], .index_id = index_id };
    }
};

/// The definition of index `name`, if there is one (copied with `allocator`).
pub fn find(graph: *Graph, name: []const u8, allocator: Allocator) StorageError!?Definition {
    var key = std.ArrayList(u8).empty;
    defer key.deinit(graph.allocator);
    try appendDefinitionKey(&key, graph.allocator, name);
    const raw = (try graph.store.get(key.items)) orelse return null;
    defer graph.store.allocator.free(raw);
    return try Definition.decode(name, raw, allocator);
}

/// Every definition, in name order (copied with `allocator`).
pub fn all(graph: *Graph, allocator: Allocator) StorageError![]const Definition {
    var definitions = std.ArrayList(Definition).empty;
    var keys = try graph.store.scanPrefix(&.{definition_marker});
    defer keys.deinit();
    while (try keys.next()) |entry| try definitions.append(allocator, try Definition.decode(entry.key[1..], entry.value, allocator));
    return definitions.items;
}

/// The definitions of one kind, in name order.
pub fn allOfKind(graph: *Graph, allocator: Allocator, kind: Kind) StorageError![]const Definition {
    var definitions = std.ArrayList(Definition).empty;
    for (try all(graph, allocator)) |definition| {
        if (definition.kind == kind) try definitions.append(allocator, definition);
    }
    return definitions.items;
}

/// Stores `definition` (a new index; the caller checked the name is free),
/// with a fresh index id if it owns a property index, and returns it as
/// stored.
pub fn create(graph: *Graph, definition: Definition) StorageError!Definition {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    var stored = definition;
    if (definition.hasPropertyIndex()) stored.index_id = try nextIndexId(graph);
    var key = std.ArrayList(u8).empty;
    try appendDefinitionKey(&key, scratch.allocator(), definition.name);
    try graph.store.put(key.items, try stored.encode(scratch.allocator()));
    try bumpSchemaVersion(graph);
    return stored;
}

/// Hands out a property index id never used before (a counter, so the keys
/// of a dropped index are never read as another's).
fn nextIndexId(graph: *Graph) StorageError!u32 {
    const last: u32 = if (try graph.store.get(index_id_key)) |raw| last: {
        defer graph.store.allocator.free(raw);
        break :last if (raw.len == 4) std.mem.readInt(u32, raw[0..4], .big) else 0;
    } else 0;
    if (last == std.math.maxInt(u32)) return error.WriteFailed; // 4 billion indexes created
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &buffer, last + 1, .big);
    try graph.store.put(index_id_key, &buffer);
    return last + 1;
}

/// Removes index `name`'s definition. False if there was none.
pub fn drop(graph: *Graph, name: []const u8) StorageError!bool {
    var key = std.ArrayList(u8).empty;
    defer key.deinit(graph.allocator);
    try appendDefinitionKey(&key, graph.allocator, name);
    if (!try graph.store.exists(key.items)) return false;
    try graph.store.del(key.items);
    try bumpSchemaVersion(graph);
    return true;
}

/// How many times the definitions changed (0 before the first index).
/// Every mutation asks (to know whether there are indexes to keep current),
/// so inside a write transaction the answer is read once: only the
/// transaction itself could change it, and then it updates the memo too.
pub fn schemaVersion(graph: *Graph) StorageError!u64 {
    const in_write = graph.store.active_write_transaction != null;
    if (in_write) if (graph.store.write_transaction_memo.schema_version) |version| return version;
    const version: u64 = if (try graph.store.get(schema_version_key)) |raw| version: {
        defer graph.store.allocator.free(raw);
        break :version if (raw.len == 8) std.mem.readInt(u64, raw[0..8], .big) else 0;
    } else 0;
    if (in_write) graph.store.write_transaction_memo.schema_version = version;
    return version;
}

fn bumpSchemaVersion(graph: *Graph) StorageError!void {
    const version = try schemaVersion(graph) + 1;
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, version, .big);
    try graph.store.put(schema_version_key, &buffer);
    if (graph.store.active_write_transaction != null) graph.store.write_transaction_memo.schema_version = version;
}

fn appendDefinitionKey(key: *std.ArrayList(u8), allocator: Allocator, name: []const u8) Allocator.Error!void {
    try key.append(allocator, definition_marker);
    try key.appendSlice(allocator, name);
}

fn appendString(bytes: *std.ArrayList(u8), allocator: Allocator, string: []const u8) Allocator.Error!void {
    try appendCount(bytes, allocator, string.len);
    try bytes.appendSlice(allocator, string);
}

fn appendCount(bytes: *std.ArrayList(u8), allocator: Allocator, count: usize) Allocator.Error!void {
    var buffer: [2]u8 = undefined;
    std.mem.writeInt(u16, &buffer, @intCast(count), .big);
    try bytes.appendSlice(allocator, &buffer);
}

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    fn byte(self: *Reader) u8 {
        defer self.position += 1;
        return self.bytes[self.position];
    }

    fn count(self: *Reader) usize {
        defer self.position += 2;
        return std.mem.readInt(u16, self.bytes[self.position..][0..2], .big);
    }

    fn string(self: *Reader) []const u8 {
        const length = self.count();
        defer self.position += length;
        return self.bytes[self.position..][0..length];
    }
};
