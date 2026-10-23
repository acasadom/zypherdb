//! The statements `query` calls prepared, by their text: a query run again
//! is not parsed, checked or planned again. Holds at most `capacity`; when
//! full, the one used least recently goes (expected O(1) lookup, O(capacity)
//! eviction).
//!
//! The cache owns its statements. What a statement's checks depend on
//! besides the text (the procedures defined) must `clear` it when it changes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Statement = @import("Statement.zig");

const Cache = @This();

pub const default_capacity = 64;

allocator: Allocator,
capacity: usize = default_capacity,
/// By text (the statement's own copy), each with when it was last used.
entries: std.StringHashMapUnmanaged(Entry) = .empty,
clock: u64 = 0,

const Entry = struct { statement: *Statement, last_used: u64 };

pub fn init(allocator: Allocator) Cache {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Cache) void {
    self.clear();
    self.entries.deinit(self.allocator);
}

/// The statement prepared for `text`, if the cache has it.
pub fn get(self: *Cache, text: []const u8) ?*Statement {
    const entry = self.entries.getPtr(text) orelse return null;
    self.clock += 1;
    entry.last_used = self.clock;
    return entry.statement;
}

/// Keeps `statement` (the cache owns it from now on), making room first.
/// With no room to keep it (capacity 0, out of memory), it is destroyed.
pub fn put(self: *Cache, statement: *Statement) void {
    if (self.capacity == 0) return statement.destroy();
    if (self.entries.count() >= self.capacity) self.evictLeastRecent();
    self.clock += 1;
    self.entries.put(self.allocator, statement.text, .{ .statement = statement, .last_used = self.clock }) catch statement.destroy();
}

/// Drops every statement.
pub fn clear(self: *Cache) void {
    var iterator = self.entries.valueIterator();
    while (iterator.next()) |entry| entry.statement.destroy();
    self.entries.clearRetainingCapacity();
}

fn evictLeastRecent(self: *Cache) void {
    var oldest: ?[]const u8 = null;
    var oldest_use: u64 = std.math.maxInt(u64);
    var iterator = self.entries.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.last_used < oldest_use) {
            oldest_use = entry.value_ptr.last_used;
            oldest = entry.key_ptr.*;
        }
    }
    const key = oldest orelse return;
    const removed = self.entries.fetchRemove(key).?;
    removed.value.statement.destroy();
}
