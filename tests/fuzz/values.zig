//! Random property values for the fuzzers: every type a property can hold,
//! values that cannot be stored, and nulls. Most come from small pools, so
//! that equal values meet in the indexes and the uniqueness constraints
//! (1 and 1.0 among them), and texts that the full-text analyzers treat
//! differently.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");
const Value = zypherdb.Value;
const MapEntry = zypherdb.value.MapEntry;

const integers = [_]i64{ -1, 0, 1, 2, 42, std.math.minInt(i64), std.math.maxInt(i64) };
const floats = [_]f64{ 0.0, -0.0, 1.0, 2.0, 2.5, -3.75, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e300, 5e-324 };

/// Texts for the full-text indexes: words that stem alike, case and accents,
/// repeated terms, punctuation only, and a word too long to be indexed.
pub const texts = [_][]const u8{
    "",
    "a",
    "   ",
    "The quick brown fox",
    "running runners ran",
    "fox fox FOX",
    "El niño corría por el árbol",
    "ÑANDÚ ñandú Ñandu",
    "¡¿...?!",
    &@as([300]u8, @splat('x')),
    "door 7, building B",
    "brown",
};

const map_keys = [_][]const u8{ "a", "b", "c" };

/// A value for a property: storable, null (setting it removes the property),
/// or one that cannot be stored (a list of mixed types).
pub fn randomValue(random: std.Random, arena: Allocator) Allocator.Error!Value {
    return switch (random.uintLessThan(u8, 16)) {
        0, 1 => .{ .int = pick(i64, random, &integers) },
        2 => .{ .float = pick(f64, random, &floats) },
        3, 4, 5 => .{ .string = pick([]const u8, random, &texts) },
        6 => .{ .boolean = random.boolean() },
        7 => randomTemporal(random),
        8 => .{ .list = try randomNumbers(random, arena) },
        9 => .{ .list = try randomTexts(random, arena) },
        10 => .{ .map = try randomMap(random, arena, 2) },
        11 => .null,
        12 => try unstorable(random, arena),
        13 => .{ .int = random.int(i64) },
        14 => .{ .string = try randomWords(random, arena) },
        else => .{ .int = random.intRangeAtMost(i64, 0, 3) },
    };
}

/// A value from a handful (a seed's narrow mix): equal values meet often,
/// so uniqueness constraints are broken often.
pub fn narrowValue(random: std.Random) Value {
    const narrow = [_]Value{ .{ .int = 0 }, .{ .int = 1 }, .{ .float = 1.0 }, .{ .string = "ab" }, .null };
    return narrow[random.uintLessThan(usize, narrow.len)];
}

fn pick(comptime T: type, random: std.Random, items: []const T) T {
    return items[random.uintLessThan(usize, items.len)];
}

fn randomTemporal(random: std.Random) Value {
    const zones = [_][]const u8{ "", "Europe/Madrid" };
    return switch (random.uintLessThan(u8, 6)) {
        0 => .{ .date = .{ .days = pick(i64, random, &.{ -1, 0, 19000 }) } },
        1 => .{ .local_time = .{ .nanoseconds = pick(i64, random, &.{ 0, 1, 86_399_999_999_999 }) } },
        2 => .{ .time = .{ .nanoseconds = 3_600_000_000_000, .offset = pick(i32, random, &.{ 0, 3600, -1800 }) } },
        3 => .{ .local_date_time = .{ .seconds = pick(i64, random, &.{ -1, 0, 1_700_000_000 }), .nanoseconds = 5 } },
        4 => .{ .date_time = .{ .seconds = 1_700_000_000, .nanoseconds = pick(u32, random, &.{ 0, 1 }), .offset = 3600, .zone = pick([]const u8, random, &zones) } },
        else => .{ .duration = .{ .months = pick(i64, random, &.{ 0, 14 }), .days = 1, .seconds = -5, .nanoseconds = pick(u32, random, &.{ 0, 999_999_999 }) } },
    };
}

/// Integers and floats mixed (one kind: numbers), possibly none.
fn randomNumbers(random: std.Random, arena: Allocator) Allocator.Error![]const Value {
    const items = try arena.alloc(Value, random.uintLessThan(usize, 4));
    for (items) |*item| item.* = if (random.boolean()) .{ .int = pick(i64, random, &integers) } else .{ .float = pick(f64, random, &floats) };
    return items;
}

fn randomTexts(random: std.Random, arena: Allocator) Allocator.Error![]const Value {
    const items = try arena.alloc(Value, 1 + random.uintLessThan(usize, 3));
    for (items) |*item| item.* = .{ .string = pick([]const u8, random, &texts) };
    return items;
}

/// A document: keys in order (as maps are stored), values of any kind,
/// nulls and lists of mixed elements included.
fn randomMap(random: std.Random, arena: Allocator, depth: u8) Allocator.Error![]const MapEntry {
    var entries = std.ArrayList(MapEntry).empty;
    for (map_keys) |key| {
        if (random.boolean()) continue;
        const value: Value = switch (random.uintLessThan(u8, if (depth > 0) 5 else 4)) {
            0 => .null,
            1 => .{ .int = pick(i64, random, &integers) },
            2 => .{ .string = pick([]const u8, random, &texts) },
            3 => .{ .list = try arena.dupe(Value, &.{ .{ .int = 1 }, .{ .string = "x" }, .null }) },
            else => .{ .map = try randomMap(random, arena, depth - 1) },
        };
        try entries.append(arena, .{ .key = key, .value = value });
    }
    return entries.items;
}

/// A few words of a two-letter alphabet: terms that repeat across entities.
fn randomWords(random: std.Random, arena: Allocator) Allocator.Error![]const u8 {
    const words = [_][]const u8{ "ab", "ba", "aa", "bb", "Ab" };
    var text = std.ArrayList(u8).empty;
    for (0..1 + random.uintLessThan(usize, 4)) |i| {
        if (i > 0) try text.append(arena, ' ');
        try text.appendSlice(arena, pick([]const u8, random, &words));
    }
    return text.items;
}

/// A value no property can hold: a list of mixed types, or of lists.
fn unstorable(random: std.Random, arena: Allocator) Allocator.Error!Value {
    if (random.boolean()) return .{ .list = try arena.dupe(Value, &.{ .{ .int = 1 }, .{ .string = "a" } }) };
    const inner = try arena.dupe(Value, &.{.{ .int = 1 }});
    return .{ .list = try arena.dupe(Value, &.{.{ .list = inner }}) };
}
