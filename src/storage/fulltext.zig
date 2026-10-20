//! Full-text indexes: their definitions (this file), and, in the same keys'
//! space, their postings.
//!
//! A definition is stored under `i | name`:
//!
//!     entity: u8                 0 nodes, 1 relationships
//!     analyzer: u16 length, bytes
//!     labels or types: u16 count, each u16 length, bytes
//!     properties: u16 count, each u16 length, bytes
//!
//! The key `!schema` counts the changes to the definitions, so a process that
//! keeps them in memory knows when to read them again.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("graph.zig").Graph;
const StorageError = @import("key_value_store.zig").StorageError;

pub const definition_marker: u8 = 'i';
pub const schema_version_key: []const u8 = "!schema";

pub const Entity = enum(u8) { nodes = 0, relationships = 1 };

pub const Definition = struct {
    name: []const u8,
    entity: Entity,
    analyzer: []const u8,
    labels_or_types: []const []const u8,
    properties: []const []const u8,

    fn encode(self: Definition, allocator: Allocator) Allocator.Error![]u8 {
        var bytes = std.ArrayList(u8).empty;
        try bytes.append(allocator, @intFromEnum(self.entity));
        try appendString(&bytes, allocator, self.analyzer);
        for ([_][]const []const u8{ self.labels_or_types, self.properties }) |list| {
            try appendCount(&bytes, allocator, list.len);
            for (list) |item| try appendString(&bytes, allocator, item);
        }
        return bytes.items;
    }

    /// The definition `name` stored as `bytes`, its strings copied with `allocator`.
    fn decode(name: []const u8, bytes: []const u8, allocator: Allocator) Allocator.Error!Definition {
        var reader = Reader{ .bytes = bytes };
        const entity: Entity = @enumFromInt(reader.byte());
        const analyzer = try allocator.dupe(u8, reader.string());
        var lists: [2][]const []const u8 = undefined;
        for (&lists) |*list| {
            const items = try allocator.alloc([]const u8, reader.count());
            for (items) |*item| item.* = try allocator.dupe(u8, reader.string());
            list.* = items;
        }
        return .{ .name = try allocator.dupe(u8, name), .entity = entity, .analyzer = analyzer, .labels_or_types = lists[0], .properties = lists[1] };
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

/// Every index's definition, in name order (copied with `allocator`).
pub fn all(graph: *Graph, allocator: Allocator) StorageError![]const Definition {
    var definitions = std.ArrayList(Definition).empty;
    var keys = try graph.store.scanPrefix(&.{definition_marker});
    defer keys.deinit();
    while (try keys.next()) |entry| try definitions.append(allocator, try Definition.decode(entry.key[1..], entry.value, allocator));
    return definitions.items;
}

/// Stores `definition` (a new index; the caller checked the name is free).
pub fn create(graph: *Graph, definition: Definition) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    var key = std.ArrayList(u8).empty;
    try appendDefinitionKey(&key, scratch.allocator(), definition.name);
    try graph.store.put(key.items, try definition.encode(scratch.allocator()));
    try bumpSchemaVersion(graph);
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
    if (in_write) if (graph.store.write_transaction_memo) |version| return version;
    const version: u64 = if (try graph.store.get(schema_version_key)) |raw| version: {
        defer graph.store.allocator.free(raw);
        break :version if (raw.len == 8) std.mem.readInt(u64, raw[0..8], .big) else 0;
    } else 0;
    if (in_write) graph.store.write_transaction_memo = version;
    return version;
}

fn bumpSchemaVersion(graph: *Graph) StorageError!void {
    const version = try schemaVersion(graph) + 1;
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, version, .big);
    try graph.store.put(schema_version_key, &buffer);
    if (graph.store.active_write_transaction != null) graph.store.write_transaction_memo = version;
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
