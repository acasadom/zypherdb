//! Generic algorithms over sequences, written once for any element type.
//!
//! The element types used here are *regular*: they provide
//!
//!   fn eql(a: T, b: T) bool                     an equivalence relation
//!   fn hash(self: T, hasher: *std.hash.Wyhash)   consistent with it
//!                                                (`eql(a, b)` implies equal hashes)
//!
//! `ElementContext(T)` and `SequenceContext(T)` adapt such a type to the
//! std.HashMap context protocol (`hash(context, K) u64`, `eql(context, K, K) bool`),
//! which is the concept `removeDuplicates` and grouping require.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Wyhash = std.hash.Wyhash;

/// Hash-map context for a single regular `T`.
pub fn ElementContext(comptime T: type) type {
    return struct {
        pub fn hash(_: @This(), item: T) u64 {
            var hasher = Wyhash.init(0);
            item.hash(&hasher);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: T, b: T) bool {
            return a.eql(b);
        }
    };
}

/// Hash-map context for a sequence `[]const T` of a regular `T`: equal when
/// element-wise equal.
pub fn SequenceContext(comptime T: type) type {
    return struct {
        pub fn hash(_: @This(), items: []const T) u64 {
            var hasher = Wyhash.init(0);
            hashSequence(T, items, &hasher);
            return hasher.final();
        }

        pub fn eql(_: @This(), a: []const T, b: []const T) bool {
            return eqlSequence(T, a, b);
        }
    };
}

/// Element-wise equality of two sequences of a regular `T`. O(n).
pub fn eqlSequence(comptime T: type, a: []const T, b: []const T) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// Feeds a sequence (its length, then each element) into `hasher`. O(n).
pub fn hashSequence(comptime T: type, items: []const T, hasher: *Wyhash) void {
    hasher.update(std.mem.asBytes(&items.len));
    for (items) |item| item.hash(hasher);
}

/// Removes every element equal (under `context`) to an earlier one, keeping
/// the first occurrences in their original order. Expected O(n) time, O(n)
/// extra space. `context` is a std.HashMap context for `T`.
pub fn removeDuplicates(comptime T: type, allocator: Allocator, items: *std.ArrayList(T), context: anytype) Allocator.Error!void {
    const Context = @TypeOf(context);
    var seen: std.HashMapUnmanaged(T, void, Context, std.hash_map.default_max_load_percentage) = .empty;
    defer seen.deinit(allocator);

    var kept: usize = 0;
    for (items.items) |item| {
        const entry = try seen.getOrPutContext(allocator, item, context);
        if (entry.found_existing) continue;
        items.items[kept] = item;
        kept += 1;
    }
    items.shrinkRetainingCapacity(kept);
}

/// Removes the first `count` elements (all of them if fewer), keeping the rest
/// in order. O(n).
pub fn dropFirst(comptime T: type, items: *std.ArrayList(T), count: usize) void {
    const dropped = @min(count, items.items.len);
    const kept = items.items.len - dropped;
    std.mem.copyForwards(T, items.items[0..kept], items.items[dropped..]);
    items.shrinkRetainingCapacity(kept);
}

/// Keeps at most the first `count` elements. O(1).
pub fn truncate(comptime T: type, items: *std.ArrayList(T), count: usize) void {
    if (count < items.items.len) items.shrinkRetainingCapacity(count);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A minimal regular type: equality and hashing by `key` only, so that equal
/// elements can still be told apart by `tag` (to check which one is kept).
const Tagged = struct {
    key: u8,
    tag: u8,

    fn eql(a: Tagged, b: Tagged) bool {
        return a.key == b.key;
    }

    fn hash(self: Tagged, hasher: *Wyhash) void {
        hasher.update(&.{self.key});
    }
};

test "removeDuplicates keeps first occurrences in order" {
    var items = std.ArrayList(Tagged).empty;
    defer items.deinit(testing.allocator);
    for ([_]Tagged{ .{ .key = 3, .tag = 0 }, .{ .key = 1, .tag = 1 }, .{ .key = 3, .tag = 2 }, .{ .key = 2, .tag = 3 }, .{ .key = 1, .tag = 4 } }) |item| {
        try items.append(testing.allocator, item);
    }

    try removeDuplicates(Tagged, testing.allocator, &items, ElementContext(Tagged){});

    try testing.expectEqual(@as(usize, 3), items.items.len);
    for (items.items, [_]u8{ 0, 1, 3 }) |item, tag| try testing.expectEqual(tag, item.tag);
}

test "dropFirst and truncate clamp to the length" {
    var items = std.ArrayList(u8).empty;
    defer items.deinit(testing.allocator);
    try items.appendSlice(testing.allocator, &.{ 1, 2, 3, 4, 5 });

    dropFirst(u8, &items, 2);
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5 }, items.items);
    truncate(u8, &items, 2);
    try testing.expectEqualSlices(u8, &.{ 3, 4 }, items.items);
    truncate(u8, &items, 10);
    try testing.expectEqualSlices(u8, &.{ 3, 4 }, items.items);
    dropFirst(u8, &items, 10);
    try testing.expectEqual(@as(usize, 0), items.items.len);
}

test "SequenceContext: equal sequences hash equally" {
    const a = [_]Tagged{ .{ .key = 1, .tag = 0 }, .{ .key = 2, .tag = 0 } };
    const b = [_]Tagged{ .{ .key = 1, .tag = 9 }, .{ .key = 2, .tag = 9 } };
    const context = SequenceContext(Tagged){};
    try testing.expect(context.eql(&a, &b));
    try testing.expectEqual(context.hash(&a), context.hash(&b));
    try testing.expect(!context.eql(&a, a[0..1]));
}
