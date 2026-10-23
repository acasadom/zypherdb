//! Generic algorithms over sequences, written once for any element type.
//!
//! The element types used here are *regular*: they provide
//!
//!   fn eql(a: T, b: T) bool                     an equivalence relation
//!   fn hash(self: T) u64                        consistent with it
//!                                                (`eql(a, b)` implies equal hashes)
//!
//! A composite's hash folds its parts' with `combineHashes`; a scalar's is
//! `hashWord` of its bits, a byte string's `hashBytes`.
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
            return item.hash();
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
            return hashSequence(T, items);
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

/// The hash of a sequence: its length, then each element's, folded. O(n).
pub fn hashSequence(comptime T: type, items: []const T) u64 {
    var result = hashWord(items.len);
    for (items) |item| result = combineHashes(result, item.hash());
    return result;
}

/// The hash of a 64-bit word: every input bit affects every output bit.
pub fn hashWord(word: u64) u64 {
    return std.hash.int(word);
}

/// The hash of a byte string, seeded so strings of different kinds differ.
pub fn hashBytes(seed: u64, bytes: []const u8) u64 {
    return Wyhash.hash(seed, bytes);
}

/// Folds the hash of the next part into the hash so far. Order matters:
/// (a, b) and (b, a) hash differently.
pub fn combineHashes(so_far: u64, next: u64) u64 {
    return hashWord(so_far *% 0x9e3779b97f4a7c15 ^ next);
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

    fn hash(self: Tagged) u64 {
        return hashWord(self.key);
    }
};

/// Rearranges `items` so its first `min(count, len)` elements are the
/// smallest under `lessThan`, in stable sorted order (as a stable sort would
/// put them; the rest are left in an unspecified order). For `ORDER BY ...
/// LIMIT k`: O(n log k) instead of sorting all n. `lessThan` is a strict weak
/// order (`fn (context, T, T) bool`); ties are broken by position.
pub fn partialSortStable(
    comptime T: type,
    allocator: Allocator,
    items: []T,
    count: usize,
    context: anytype,
    comptime lessThan: fn (@TypeOf(context), T, T) bool,
) Allocator.Error!void {
    const k = @min(count, items.len);
    if (k == 0) return;
    // A max-heap of the positions of the k smallest seen so far, ordered by
    // (value, position): its top is the one to evict.
    const Order = struct {
        items: []const T,
        context: @TypeOf(context),
        fn before(self: @This(), a: usize, b: usize) bool {
            if (lessThan(self.context, self.items[a], self.items[b])) return true;
            if (lessThan(self.context, self.items[b], self.items[a])) return false;
            return a < b;
        }
    };
    const order = Order{ .items = items, .context = context };
    const heap = try allocator.alloc(usize, k);
    defer allocator.free(heap);
    for (heap, 0..) |*slot, i| slot.* = i;
    var i = k / 2;
    while (i > 0) {
        i -= 1;
        siftDown(heap, i, order);
    }
    for (k..items.len) |position| {
        if (order.before(position, heap[0])) {
            heap[0] = position;
            siftDown(heap, 0, order);
        }
    }
    std.sort.pdq(usize, heap, order, Order.before);
    const chosen = try allocator.alloc(T, k);
    defer allocator.free(chosen);
    for (chosen, heap) |*element, position| element.* = items[position];
    // Put the chosen first; the displaced elements go where the chosen were.
    var displaced = std.ArrayList(T).empty;
    defer displaced.deinit(allocator);
    const taken = try allocator.alloc(bool, items.len);
    defer allocator.free(taken);
    @memset(taken, false);
    for (heap) |position| taken[position] = true;
    for (items[0..k], 0..) |element, position| {
        if (!taken[position]) try displaced.append(allocator, element);
    }
    var next: usize = 0;
    for (heap) |position| {
        if (position >= k) {
            items[position] = displaced.items[next];
            next += 1;
        }
    }
    @memcpy(items[0..k], chosen);
}

fn siftDown(heap: []usize, start: usize, order: anytype) void {
    var parent = start;
    while (true) {
        var largest = parent;
        const left = 2 * parent + 1;
        const right = left + 1;
        if (left < heap.len and order.before(heap[largest], heap[left])) largest = left;
        if (right < heap.len and order.before(heap[largest], heap[right])) largest = right;
        if (largest == parent) return;
        std.mem.swap(usize, &heap[parent], &heap[largest]);
        parent = largest;
    }
}

test "partialSortStable gives the k smallest in stable order" {
    const Pair = struct { key: u8, tag: u8 };
    const less = struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.key < b.key;
        }
    }.lessThan;
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    for (0..200) |_| {
        var items: [40]Pair = undefined;
        for (&items, 0..) |*item, i| item.* = .{ .key = random.uintLessThan(u8, 6), .tag = @intCast(i) };
        var expected = items;
        std.sort.block(Pair, &expected, {}, less);
        const k = random.uintLessThan(usize, 45);
        try partialSortStable(Pair, std.testing.allocator, &items, k, {}, less);
        try std.testing.expectEqualSlices(Pair, expected[0..@min(k, 40)], items[0..@min(k, 40)]);
        // The rest is a permutation of what is left.
        var tags: [40]bool = @splat(false);
        for (items) |item| tags[item.tag] = true;
        try std.testing.expect(std.mem.allEqual(bool, &tags, true));
    }
}

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
