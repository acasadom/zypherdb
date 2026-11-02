//! Values on the wire (replication/values.zig): every kind of value reads
//! back as written, and damaged bytes are refused or read as some other
//! well-formed value, never misread into a broken one or a crash.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");

const values = zypherdb.replication_values;
const Value = zypherdb.Value;
const MapEntry = zypherdb.value.MapEntry;
const Relationship = zypherdb.value.Relationship;

fn encoded(arena: Allocator, value: Value) ![]u8 {
    var bytes = std.ArrayList(u8).empty;
    try values.encode(&bytes, arena, value);
    return bytes.items;
}

/// `value` reads back whole, and writes again into the same bytes (so
/// nothing `Value.eql` ignores, as a relationship's type, is lost).
fn expectRoundTrip(arena: Allocator, value: Value) !void {
    const bytes = try encoded(arena, value);
    const decoded = try values.decodeWhole(bytes, arena);
    try testing.expect(Value.eql(value, decoded));
    try testing.expectEqualSlices(u8, bytes, try encoded(arena, decoded));
}

const knows: Relationship = .{ .id = 9, .src = 1, .dst = 2, .edge_type = "KNOWS" };
const back: Relationship = .{ .id = 10, .src = 3, .dst = 2, .edge_type = "MAY_ENTER" };

const every_kind = [_]Value{
    .null,
    .{ .int = std.math.minInt(i64) },
    .{ .int = std.math.maxInt(i64) },
    .{ .float = -0.0 },
    .{ .float = std.math.inf(f64) },
    .{ .float = 2.5 },
    .{ .string = "" },
    .{ .string = "año" },
    .{ .boolean = true },
    .{ .boolean = false },
    .{ .list = &.{} },
    .{ .list = &.{ .{ .int = 1 }, .{ .string = "a" }, .null, .{ .list = &.{.{ .node = 3 }} } } },
    .{ .map = &.{} },
    .{ .map = &.{ .{ .key = "a", .value = .null }, .{ .key = "b", .value = .{ .map = &.{.{ .key = "", .value = .{ .relationship = knows } }} } } } },
    .{ .node = 0 },
    .{ .node = std.math.maxInt(u64) },
    .{ .relationship = knows },
    .{ .path = .{ .nodes = &.{7}, .relationships = &.{} } },
    .{ .path = .{ .nodes = &.{ 1, 2, 3 }, .relationships = &.{ knows, back } } },
    .{ .date = .{ .days = -719_162 } },
    .{ .local_time = .{ .nanoseconds = 86_399_999_999_999 } },
    .{ .time = .{ .nanoseconds = 0, .offset = -64_800 } },
    .{ .local_date_time = .{ .seconds = -1, .nanoseconds = 999_999_999 } },
    .{ .date_time = .{ .seconds = 1_700_000_000, .nanoseconds = 1, .offset = 3600, .zone = "Europe/Madrid" } },
    .{ .date_time = .{ .seconds = 0, .nanoseconds = 0, .offset = 0, .zone = "" } },
    .{ .duration = .{ .months = -14, .days = 1, .seconds = -5, .nanoseconds = 999_999_999 } },
};

test "every kind of value round-trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    for (every_kind) |value| try expectRoundTrip(arena.allocator(), value);
}

test "NaN keeps its bits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bytes = try encoded(arena.allocator(), .{ .float = std.math.nan(f64) });
    const decoded = try values.decodeWhole(bytes, arena.allocator());
    try testing.expect(std.math.isNan(decoded.float));
    try testing.expectEqualSlices(u8, bytes, try encoded(arena.allocator(), decoded));
}

test "values follow one another, each telling where it ends" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes = std.ArrayList(u8).empty;
    for (every_kind) |value| try values.encode(&bytes, a, value);
    var position: usize = 0;
    for (every_kind) |value| {
        const decoded = try values.decode(bytes.items[position..], a);
        try testing.expect(Value.eql(value, decoded.value));
        position += decoded.length;
    }
    try testing.expectEqual(bytes.items.len, position);
}

fn nested(arena: Allocator, depth: usize) !Value {
    var value: Value = .{ .int = 1 };
    for (0..depth) |i| {
        const holder = try arena.alloc(Value, 1);
        holder[0] = value;
        value = if (i % 2 == 0) .{ .list = holder } else .{ .map = try arena.dupe(MapEntry, &.{.{ .key = "k", .value = holder[0] }}) };
    }
    return value;
}

test "lists and maps nest up to max_depth, and no deeper on either side" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectRoundTrip(a, try nested(a, values.max_depth));
    var bytes = std.ArrayList(u8).empty;
    try testing.expectError(error.ValueTooDeep, values.encode(&bytes, a, try nested(a, values.max_depth + 1)));
    // Bytes a writer would refuse to make: 65 lists, one in the other.
    var deep = std.ArrayList(u8).empty;
    for (0..values.max_depth + 1) |_| try deep.appendSlice(a, &.{ 0x05, 0, 0, 0, 1 });
    try deep.append(a, 0x00);
    try testing.expectError(error.MalformedValue, values.decodeWhole(deep.items, a));
}

test "malformed bytes are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const malformed = [_][]const u8{
        "", // nothing
        &.{0x10}, // unknown tag
        &.{ 0x04, 2 }, // a boolean neither 0 nor 1
        &.{ 0x03, 0, 0, 0, 5, 'a' }, // a string shorter than its length
        &.{ 0x05, 0xff, 0xff, 0xff, 0xff }, // a count the bytes cannot hold (nothing allocated)
        &.{ 0x06, 0, 0, 0, 2, 0, 0, 0, 1, 'b', 0x00, 0, 0, 0, 1, 'a', 0x00 }, // map keys out of order
        &.{ 0x06, 0, 0, 0, 2, 0, 0, 0, 1, 'a', 0x00, 0, 0, 0, 1, 'a', 0x00 }, // a key twice
        &.{ 0x09, 0, 0, 0, 0 }, // a path without nodes
        &.{ 0x0b, 0, 0, 0x4e, 0x94, 0x91, 0x4f, 0x00, 0x00 }, // a local time of 86400 s
        &.{ 0x0b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, // a negative local time
        &.{ 0x0d, 0, 0, 0, 0, 0, 0, 0, 0, 0x3b, 0x9a, 0xca, 0x00 }, // 1e9 nanoseconds of a second
    };
    for (malformed) |bytes| try testing.expectError(error.MalformedValue, values.decodeWhole(bytes, a));
    // A path whose relationship does not join its nodes.
    const stray: Relationship = .{ .id = 1, .src = 5, .dst = 6, .edge_type = "T" };
    const bytes = try encoded(a, .{ .path = .{ .nodes = &.{ 1, 2 }, .relationships = &.{stray} } });
    try testing.expectError(error.MalformedValue, values.decodeWhole(bytes, a));
    // Something after a whole value.
    var trailing = std.ArrayList(u8).empty;
    try trailing.appendSlice(a, try encoded(a, .{ .int = 1 }));
    try trailing.append(a, 0);
    try testing.expectError(error.MalformedValue, values.decodeWhole(trailing.items, a));
}

test "every value cut short is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (every_kind) |value| {
        const bytes = try encoded(a, value);
        for (0..bytes.len) |length| try testing.expectError(error.MalformedValue, values.decodeWhole(bytes[0..length], a));
    }
}

fn randomValue(random: std.Random, arena: Allocator, depth: usize) Allocator.Error!Value {
    switch (random.uintLessThan(u8, 3)) {
        0 => return every_kind[random.uintLessThan(usize, every_kind.len)],
        1 => return .{ .int = random.int(i64) },
        else => {
            if (depth == 0) return .{ .string = "leaf" };
            const items = try arena.alloc(Value, random.uintLessThan(usize, 4));
            for (items) |*item| item.* = try randomValue(random, arena, depth - 1);
            if (random.boolean()) return .{ .list = items };
            const keys = [_][]const u8{ "a", "b", "c", "d" };
            const entries = try arena.alloc(MapEntry, items.len);
            for (entries, items, 0..) |*entry, item, i| entry.* = .{ .key = keys[i], .value = item };
            return .{ .map = entries };
        },
    }
}

test "damaged bytes are refused or read as a well-formed value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x7a7a);
    const random = prng.random();
    for (0..2000) |_| {
        const value = try randomValue(random, a, 3);
        try expectRoundTrip(a, value);
        const bytes = try a.dupe(u8, try encoded(a, value));
        bytes[random.uintLessThan(usize, bytes.len)] ^= @as(u8, 1) << random.int(u3);
        // What reads back is a value of its own: it writes into the same bytes.
        const decoded = values.decodeWhole(bytes, a) catch continue;
        try testing.expectEqualSlices(u8, bytes, try encoded(a, decoded));
    }
}
