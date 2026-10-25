//! Value encoding: how a property value is stored, and how it is written in
//! index keys.
//!
//! A stored value is `tag | payload`, integers big-endian:
//!
//! | Tag    | Value           | Payload                                         |
//! | ------ | --------------- | ----------------------------------------------- |
//! | `0x01` | integer         | i64                                             |
//! | `0x02` | string          | the bytes                                       |
//! | `0x03` | boolean         | one byte, 0 or 1                                |
//! | `0x04` | float           | the IEEE 754 bits, u64                          |
//! | `0x05` | date            | days, i64                                       |
//! | `0x06` | local time      | nanoseconds of the day, i64                     |
//! | `0x07` | time            | nanoseconds of the day, i64; offset, i32        |
//! | `0x08` | local date-time | seconds, i64; nanoseconds, u32                  |
//! | `0x09` | date-time       | seconds, i64; nanoseconds, u32; offset, i32; zone bytes |
//! | `0x0a` | duration        | months, days, seconds, i64; nanoseconds, u32    |
//! | `0x0b` | list            | count, u32; per element its length, u32, and its encoding |
//! | `0x0c` | map             | count, u32; per entry its key and its value, each as a list element |
//! | `0x0d` | null            | nothing (only inside a map)                     |
//!
//! A list is stored only when its elements are all of one storable,
//! non-list type (integers and floats count as one: numbers), as openCypher
//! requires. A map (a document, an acmedb extension to openCypher) holds any
//! JSON-like value: nested maps, lists of any elements, and nulls.
//!
//! The index encoding is the same except that variable-length parts end in
//! `0x00` (strings, zone names; so a lookup prefix for "X" cannot also match
//! "XY"), list elements are not length-prefixed, and numbers are canonical:
//! an integral float is written as the integer it equals, so `{x: 1}` finds
//! x = 1.0, as `=` says it should. Integers, floats and dates are written so
//! that their bytes sort in their order (`orderedInteger`, `orderedFloat`):
//! a range of values is a range of keys.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Value = @import("../value.zig").Value;
const exactInteger = @import("../value.zig").exactInteger;
const MapEntry = @import("../value.zig").MapEntry;
const layout = @import("layout.zig");

pub const Tag = enum(u8) {
    int = 0x01,
    string = 0x02,
    boolean = 0x03,
    float = 0x04,
    date = 0x05,
    local_time = 0x06,
    time = 0x07,
    local_date_time = 0x08,
    date_time = 0x09,
    duration = 0x0a,
    list = 0x0b,
    map = 0x0c,
    null = 0x0d,
    /// Index-lookup tag for a value that is never stored (`null`, a node):
    /// no index entry carries it, so a lookup by such a value finds nothing.
    never_stored = 0xff,
};

const separator: u8 = 0x00;

/// True if `value` can be stored as a property. (`null` is never stored:
/// setting a property to null removes it.)
pub fn isStorable(value: Value) bool {
    return switch (value) {
        .list => |items| for (items) |item| {
            if (!isStorableElement(item) or !sameKind(item, items[0])) break false;
        } else true,
        else => isStorableElement(value),
    };
}

fn isStorableElement(value: Value) bool {
    return switch (value) {
        .int, .float, .string, .boolean, .date, .local_time, .time, .local_date_time, .date_time, .duration => true,
        .map => |entries| for (entries) |entry| {
            if (!isDocumentValue(entry.value)) break false;
        } else true,
        .null, .list, .node, .relationship, .path => false,
    };
}

/// A value inside a map property: anything storable, a null, or a list of
/// any of them.
fn isDocumentValue(value: Value) bool {
    return switch (value) {
        .null => true,
        .list => |items| for (items) |item| {
            if (!isDocumentValue(item)) break false;
        } else true,
        else => isStorableElement(value),
    };
}

fn sameKind(a: Value, b: Value) bool {
    const a_number = a == .int or a == .float;
    const b_number = b == .int or b == .float;
    if (a_number or b_number) return a_number and b_number;
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

/// An integer as an unsigned one whose big-endian bytes sort in the
/// integer's order (the sign bit flipped), for index keys.
pub fn orderedInteger(n: i64) u64 {
    return @as(u64, @bitCast(n)) ^ (1 << 63);
}

/// A float's bits arranged so that their big-endian bytes sort in the
/// float's order: negatives (sign set) inverted, positives with the sign set.
/// -0.0 sorts just below 0.0, and NaNs beyond the infinities.
pub fn orderedFloat(x: f64) u64 {
    const bits: u64 = @bitCast(x);
    return if (bits >> 63 == 1) ~bits else bits | (1 << 63);
}

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, n: T) Allocator.Error!void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, n, .big);
    try list.appendSlice(allocator, &buffer);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

const Form = enum { stored, index };

/// Appends the storage encoding of `value` (callers check `isStorable`).
pub fn encodeValue(list: *std.ArrayList(u8), allocator: Allocator, value: Value) Allocator.Error!void {
    const start = list.items.len;
    try encode(list, allocator, value, .stored);
    layout.assertValue(list.items[start..]); // paired with `decodeValue`
}

/// Appends the index encoding of `value`.
pub fn encodeIndexValue(list: *std.ArrayList(u8), allocator: Allocator, value: Value) Allocator.Error!void {
    if (!isStorable(value)) return list.append(allocator, @backingInt(Tag.never_stored));
    try encode(list, allocator, value, .index);
}

/// A list element or map entry: stored with its length before it (so it can
/// be skipped while decoding), indexed as is.
fn encodeElement(list: *std.ArrayList(u8), allocator: Allocator, value: Value, form: Form) Allocator.Error!void {
    switch (form) {
        .index => try encode(list, allocator, value, .index),
        .stored => {
            const length_at = list.items.len;
            try appendInt(list, allocator, u32, 0);
            try encode(list, allocator, value, .stored);
            std.mem.writeInt(u32, list.items[length_at..][0..4], @intCast(list.items.len - length_at - 4), .big);
        },
    }
}

fn encode(list: *std.ArrayList(u8), allocator: Allocator, value: Value, form: Form) Allocator.Error!void {
    switch (value) {
        .int => |n| {
            try list.append(allocator, @backingInt(Tag.int));
            if (form == .index) try appendInt(list, allocator, u64, orderedInteger(n)) else try appendInt(list, allocator, i64, n);
        },
        .float => |x| {
            if (form == .index) if (exactInteger(x)) |n| return encode(list, allocator, .{ .int = n }, form);
            try list.append(allocator, @backingInt(Tag.float));
            try appendInt(list, allocator, u64, if (form == .index) orderedFloat(x) else @bitCast(x));
        },
        .string => |s| {
            try list.append(allocator, @backingInt(Tag.string));
            try list.appendSlice(allocator, s);
            if (form == .index) try list.append(allocator, separator);
        },
        .boolean => |b| try list.appendSlice(allocator, &.{ @backingInt(Tag.boolean), @intFromBool(b) }),
        .date => |d| {
            try list.append(allocator, @backingInt(Tag.date));
            if (form == .index) try appendInt(list, allocator, u64, orderedInteger(d.days)) else try appendInt(list, allocator, i64, d.days);
        },
        .local_time => |t| {
            try list.append(allocator, @backingInt(Tag.local_time));
            try appendInt(list, allocator, i64, t.nanoseconds);
        },
        .time => |t| {
            try list.append(allocator, @backingInt(Tag.time));
            try appendInt(list, allocator, i64, t.nanoseconds);
            try appendInt(list, allocator, i32, t.offset);
        },
        .local_date_time => |t| {
            try list.append(allocator, @backingInt(Tag.local_date_time));
            try appendInt(list, allocator, i64, t.seconds);
            try appendInt(list, allocator, u32, t.nanoseconds);
        },
        .date_time => |t| {
            try list.append(allocator, @backingInt(Tag.date_time));
            try appendInt(list, allocator, i64, t.seconds);
            try appendInt(list, allocator, u32, t.nanoseconds);
            try appendInt(list, allocator, i32, t.offset);
            try list.appendSlice(allocator, t.zone);
            if (form == .index) try list.append(allocator, separator);
        },
        .duration => |d| {
            try list.append(allocator, @backingInt(Tag.duration));
            try appendInt(list, allocator, i64, d.months);
            try appendInt(list, allocator, i64, d.days);
            try appendInt(list, allocator, i64, d.seconds);
            try appendInt(list, allocator, u32, d.nanoseconds);
        },
        .list => |items| {
            try list.append(allocator, @backingInt(Tag.list));
            try appendInt(list, allocator, u32, @intCast(items.len));
            for (items) |item| try encodeElement(list, allocator, item, form);
        },
        // Entries are sorted by key (see `mapOf`), so equal maps encode alike.
        .map => |entries| {
            try list.append(allocator, @backingInt(Tag.map));
            try appendInt(list, allocator, u32, @intCast(entries.len));
            for (entries) |entry| {
                try encodeElement(list, allocator, .{ .string = entry.key }, form);
                try encodeElement(list, allocator, entry.value, form);
            }
        },
        .null => try list.append(allocator, @backingInt(Tag.null)), // only inside a map
        .node, .relationship, .path => unreachable, // callers check `isStorable` first
    }
}

fn decodeElement(payload: []const u8, position: *usize, allocator: Allocator) Allocator.Error!Value {
    const length = readInt(u32, payload[position.*..]);
    const start = position.* + 4;
    position.* = start + length;
    return decodeChecked(payload[start..position.*], allocator);
}

/// Decodes a stored value. Strings, zone names and lists are allocated
/// with `allocator` (free them with it, or use an arena).
pub fn decodeValue(raw: []const u8, allocator: Allocator) Allocator.Error!Value {
    layout.assertValue(raw); // paired with `encodeValue`; covers the elements too
    return decodeChecked(raw, allocator);
}

/// Decodes a value whose layout was checked (as part of the whole value).
fn decodeChecked(raw: []const u8, allocator: Allocator) Allocator.Error!Value {
    const payload = raw[1..];
    return switch (@as(Tag, @fromBackingInt(@intCast(raw[0])))) {
        .int => .{ .int = readInt(i64, payload) },
        .string => .{ .string = try allocator.dupe(u8, payload) },
        .boolean => .{ .boolean = payload[0] != 0 },
        .float => .{ .float = @bitCast(readInt(u64, payload)) },
        .date => .{ .date = .{ .days = readInt(i64, payload) } },
        .local_time => .{ .local_time = .{ .nanoseconds = readInt(i64, payload) } },
        .time => .{ .time = .{ .nanoseconds = readInt(i64, payload), .offset = readInt(i32, payload[8..]) } },
        .local_date_time => .{ .local_date_time = .{ .seconds = readInt(i64, payload), .nanoseconds = readInt(u32, payload[8..]) } },
        .date_time => .{ .date_time = .{
            .seconds = readInt(i64, payload),
            .nanoseconds = readInt(u32, payload[8..]),
            .offset = readInt(i32, payload[12..]),
            .zone = try allocator.dupe(u8, payload[16..]),
        } },
        .duration => .{ .duration = .{
            .months = readInt(i64, payload),
            .days = readInt(i64, payload[8..]),
            .seconds = readInt(i64, payload[16..]),
            .nanoseconds = readInt(u32, payload[24..]),
        } },
        .list => blk: {
            const items = try allocator.alloc(Value, readInt(u32, payload));
            var position: usize = 4;
            for (items) |*item| item.* = try decodeElement(payload, &position, allocator);
            break :blk .{ .list = items };
        },
        .map => blk: {
            const entries = try allocator.alloc(MapEntry, readInt(u32, payload));
            var position: usize = 4;
            for (entries) |*entry| {
                const key = try decodeElement(payload, &position, allocator);
                entry.* = .{ .key = key.string, .value = try decodeElement(payload, &position, allocator) };
            }
            break :blk .{ .map = entries };
        },
        .null => .{ .null = {} },
        .never_stored => unreachable, // index-only
    };
}

test "every storable value round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]Value{
        .{ .int = -7 },
        .{ .float = 2.5 },
        .{ .string = "año" },
        .{ .boolean = true },
        .{ .date = .{ .days = -3 } },
        .{ .time = .{ .nanoseconds = 5, .offset = -3600 } },
        .{ .date_time = .{ .seconds = 9, .nanoseconds = 1, .offset = 3600, .zone = "Europe/Stockholm" } },
        .{ .duration = .{ .months = 1, .days = -2, .seconds = 3, .nanoseconds = 4 } },
        .{ .list = &.{ .{ .string = "a" }, .{ .string = "" } } },
        .{ .list = &.{ .{ .int = 1 }, .{ .float = 1.5 } } },
        .{ .list = &.{} },
        .{ .map = &.{ .{ .key = "address", .value = .{ .map = &.{.{ .key = "city", .value = .{ .string = "Madrid" } }} } }, .{ .key = "tags", .value = .{ .list = &.{ .{ .int = 1 }, .{ .string = "a" }, .{ .null = {} } } } } } },
    };
    for (values) |value| {
        try std.testing.expect(isStorable(value));
        var bytes = std.ArrayList(u8).empty;
        try encodeValue(&bytes, a, value);
        try std.testing.expect(Value.eql(value, try decodeValue(bytes.items, a)));
    }
    try std.testing.expect(!isStorable(.{ .list = &.{ .{ .int = 1 }, .{ .string = "a" } } }));
    try std.testing.expect(!isStorable(.{ .list = &.{.{ .null = {} }} }));
    try std.testing.expect(!isStorable(.{ .map = &.{.{ .key = "n", .value = .{ .node = 1 } }} }));
}

test "index keys are canonical for numbers and never prefixes of each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var one = std.ArrayList(u8).empty;
    var one_float = std.ArrayList(u8).empty;
    try encodeIndexValue(&one, a, .{ .list = &.{.{ .int = 1 }} });
    try encodeIndexValue(&one_float, a, .{ .list = &.{.{ .float = 1.0 }} });
    try std.testing.expectEqualSlices(u8, one.items, one_float.items);
    var longer = std.ArrayList(u8).empty;
    try encodeIndexValue(&longer, a, .{ .list = &.{ .{ .int = 1 }, .{ .int = 2 } } });
    try std.testing.expect(!std.mem.startsWith(u8, longer.items, one.items));
}
