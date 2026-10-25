//! The layout of stored bytes, checked: what the encoders guarantee
//! (node_record.zig, value_encoding.zig, key_encoding.zig), as functions
//! that say why some bytes break it.
//!
//! Two users. The integrity checker reports every problem it finds. The
//! storage boundary asserts the same guarantees in pairs: the writer checks
//! the bytes it is about to store, the reader checks the bytes it is about to
//! trust, so a bug on either side stops at the boundary instead of spreading
//! (TigerBeetle's pair assertions). The assertions run in Debug and
//! ReleaseSafe builds (`checked`); ReleaseFast and ReleaseSmall skip them.

const std = @import("std");

const value_encoding = @import("value_encoding.zig");
const Tag = value_encoding.Tag;

/// True in builds with runtime safety, where the boundary asserts layouts.
pub const checked = std.debug.runtime_safety;

/// Panics if `bytes` is not a well-formed node record (in checked builds).
pub fn assertRecord(bytes: []const u8) void {
    if (!checked) return;
    if (recordProblem(bytes)) |problem| std.debug.panic("zypherdb: malformed node record: {s}", .{problem});
}

/// Panics if `encoded` is not a well-formed stored value (in checked builds).
pub fn assertValue(encoded: []const u8) void {
    if (!checked) return;
    if (valueProblem(encoded)) |problem| std.debug.panic("zypherdb: malformed stored value: {s}", .{problem});
}

/// Panics if `bytes` is not a well-formed relationship record (in checked builds).
pub fn assertRelationshipRecord(bytes: []const u8) void {
    if (!checked) return;
    if (relationshipRecordProblem(bytes)) |problem| std.debug.panic("zypherdb: malformed relationship record: {s}", .{problem});
}

/// Panics if `name` is not a storable label, type or property name (in
/// checked builds); callers refuse such names with an error first.
pub fn assertName(name: []const u8) void {
    if (!checked) return;
    if (!isStorableName(name)) std.debug.panic("zypherdb: unstorable name of {d} bytes", .{name.len});
}

/// Reads big-endian integers and byte runs, failing (null) past the end.
pub const Reader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn int(self: *Reader, comptime T: type) ?T {
        const bytes = self.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
    }

    pub fn take(self: *Reader, length: usize) ?[]const u8 {
        if (self.bytes.len - self.position < length) return null;
        defer self.position += length;
        return self.bytes[self.position..][0..length];
    }
};

/// Why `bytes` is not a well-formed node record (node_record.zig), or null:
/// labels and property names non-empty and in strictly ascending order,
/// each value well formed, nothing after the last property.
pub fn recordProblem(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0) return null;
    var reader = Reader{ .bytes = bytes };
    const label_count = reader.int(u16) orelse return "truncated label count";
    var previous: ?[]const u8 = null;
    for (0..label_count) |_| {
        const length = reader.int(u16) orelse return "truncated label";
        const label = reader.take(length) orelse return "truncated label";
        if (label.len == 0) return "empty label";
        if (previous) |before| if (std.mem.order(u8, before, label) != .lt) return "labels out of order";
        previous = label;
    }
    const property_count = reader.int(u32) orelse return "truncated property count";
    previous = null;
    for (0..property_count) |_| {
        const name_length = reader.int(u16) orelse return "truncated property name";
        const name = reader.take(name_length) orelse return "truncated property name";
        if (name.len == 0) return "empty property name";
        if (previous) |before| if (std.mem.order(u8, before, name) != .lt) return "properties out of order";
        previous = name;
        const value_length = reader.int(u32) orelse return "truncated property value";
        const value = reader.take(value_length) orelse return "truncated property value";
        if (valueProblem(value)) |problem| return problem;
    }
    if (reader.position != bytes.len) return "bytes after the last property";
    return null;
}

/// Where a value sits, which decides what it may be: a property holds any
/// storable value; an element of a property list holds no list; a value
/// inside a map (a document) may also be null or a list of anything.
const Place = enum { property, list_element, document };

/// Why `encoded` is not a stored value (value_encoding.zig), or null: a tag
/// allowed where it sits, the payload size its type has, temporal fields in
/// their ranges, and for lists and maps every element in turn (lists of one
/// kind outside documents, map keys strings in strictly ascending order).
pub fn valueProblem(encoded: []const u8) ?[]const u8 {
    return problemAt(encoded, .property);
}

fn problemAt(encoded: []const u8, place: Place) ?[]const u8 {
    if (encoded.len == 0) return "empty value";
    const tag = std.enums.fromInt(Tag, encoded[0]) orelse return "not a stored value's tag";
    var payload = Reader{ .bytes = encoded[1..] };
    const size = payload.bytes.len;
    switch (tag) {
        .int, .float, .date => if (size != 8) return "wrong size for its type",
        .string => {},
        .boolean => if (size != 1 or payload.bytes[0] > 1) return "wrong size for its type",
        .local_time => {
            const nanoseconds = payload.int(i64) orelse return "wrong size for its type";
            if (size != 8) return "wrong size for its type";
            if (!isTimeOfDay(nanoseconds)) return "time of day out of range";
        },
        .time => {
            const nanoseconds = payload.int(i64) orelse return "wrong size for its type";
            if (size != 12) return "wrong size for its type";
            if (!isTimeOfDay(nanoseconds)) return "time of day out of range";
        },
        .local_date_time, .date_time, .duration => {
            const before_nanoseconds: usize = if (tag == .duration) 24 else 8;
            _ = payload.take(before_nanoseconds) orelse return "wrong size for its type";
            const nanoseconds = payload.int(u32) orelse return "wrong size for its type";
            const exact = switch (tag) {
                .local_date_time => size == 12,
                .date_time => size >= 16,
                else => size == 28,
            };
            if (!exact) return "wrong size for its type";
            if (nanoseconds >= std.time.ns_per_s) return "nanoseconds out of range";
        },
        .list => {
            if (place == .list_element) return "a list inside a list property";
            const count = payload.int(u32) orelse return "wrong size for its type";
            const element_place: Place = if (place == .document) .document else .list_element;
            var first_tag: ?u8 = null;
            for (0..count) |_| {
                const element = takeElement(&payload) orelse return "truncated list element";
                if (problemAt(element, element_place)) |problem| return problem;
                if (element_place == .list_element) {
                    const kind = numberAsOne(element[0]);
                    if (first_tag) |first| if (first != kind) return "a list property of mixed types";
                    first_tag = kind;
                }
            }
            if (payload.position != size) return "bytes after the last list element";
        },
        .map => {
            const count = payload.int(u32) orelse return "wrong size for its type";
            var previous: ?[]const u8 = null;
            for (0..count) |_| {
                const key = takeElement(&payload) orelse return "truncated map key";
                if (key.len == 0 or key[0] != @backingInt(Tag.string)) return "a map key that is not a string";
                if (previous) |before| if (std.mem.order(u8, before, key[1..]) != .lt) return "map keys out of order";
                previous = key[1..];
                const value = takeElement(&payload) orelse return "truncated map value";
                if (problemAt(value, .document)) |problem| return problem;
            }
            if (payload.position != size) return "bytes after the last map entry";
        },
        .null => {
            if (place != .document) return "not a stored value's tag";
            if (size != 0) return "wrong size for its type";
        },
        .never_stored => return "not a stored value's tag",
    }
    return null;
}

/// A list element or map entry: its length, u32, then its encoding.
fn takeElement(reader: *Reader) ?[]const u8 {
    const length = reader.int(u32) orelse return null;
    return reader.take(length);
}

fn isTimeOfDay(nanoseconds: i64) bool {
    return nanoseconds >= 0 and nanoseconds < std.time.ns_per_day;
}

/// The tag, with integers and floats as one kind (numbers).
fn numberAsOne(tag: u8) u8 {
    return if (tag == @backingInt(Tag.float)) @backingInt(Tag.int) else tag;
}

/// True if `name` can be stored as a label, relationship type or property
/// name: not empty (records hold no empty names) and without 0x00, which ends
/// names inside index and edge keys (a label "A\x00B" would be found as "A").
pub fn isStorableName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfScalar(u8, name, 0) == null;
}

/// Why `bytes` is not a relationship record (`src | dst | edge_type`,
/// key_encoding.zig), or null: both ids, and a type that is not empty and
/// has no 0x00 (the separator of edge keys).
pub fn relationshipRecordProblem(bytes: []const u8) ?[]const u8 {
    if (bytes.len <= 16) return "no relationship type";
    if (std.mem.indexOfScalar(u8, bytes[16..], 0) != null) return "a relationship type with a 0x00 byte";
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Value = @import("../value.zig").Value;

test "a record's layout is checked" {
    try testing.expectEqual(@as(?[]const u8, null), recordProblem(""));
    // One label "A", no properties.
    try testing.expectEqual(@as(?[]const u8, null), recordProblem("\x00\x01\x00\x01A\x00\x00\x00\x00"));
    try testing.expectEqualStrings("labels out of order", (recordProblem("\x00\x02\x00\x01B\x00\x01A\x00\x00\x00\x00")).?);
    try testing.expectEqualStrings("truncated label", (recordProblem("\x00\x01\x00\x05A")).?);
    try testing.expectEqualStrings("bytes after the last property", (recordProblem("\x00\x00\x00\x00\x00\x00!")).?);
}

test "a value's tag and size are checked" {
    try testing.expectEqual(@as(?[]const u8, null), valueProblem("\x01\x00\x00\x00\x00\x00\x00\x00\x2a"));
    try testing.expectEqualStrings("wrong size for its type", valueProblem("\x01\x2a").?);
    try testing.expectEqualStrings("not a stored value's tag", valueProblem("\x0d").?);
    try testing.expectEqualStrings("wrong size for its type", valueProblem("\x03\x02").?);
    // A local time of 86400 s.
    try testing.expectEqualStrings("time of day out of range", valueProblem("\x06\x00\x00\x4e\x94\x91\x4f\x00\x00").?);
}

test "every value the encoder writes passes, and broken lists and maps fail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]Value{
        .{ .list = &.{ .{ .int = 1 }, .{ .float = 1.5 } } },
        .{ .list = &.{} },
        .{ .date_time = .{ .seconds = 9, .nanoseconds = 999_999_999, .offset = 3600, .zone = "Europe/Madrid" } },
        .{ .map = &.{ .{ .key = "a", .value = .{ .null = {} } }, .{ .key = "b", .value = .{ .list = &.{ .{ .int = 1 }, .{ .list = &.{} } } } } } },
    };
    for (values) |value| {
        var bytes = std.ArrayList(u8).empty;
        try value_encoding.encodeValue(&bytes, a, value);
        try testing.expectEqual(@as(?[]const u8, null), valueProblem(bytes.items));
    }
    // ["a", 1]: one string element, one integer element.
    try testing.expectEqualStrings("a list property of mixed types", valueProblem("\x0b\x00\x00\x00\x02\x00\x00\x00\x02\x02a\x00\x00\x00\x09\x01\x00\x00\x00\x00\x00\x00\x00\x01").?);
    // [[]] as a property.
    try testing.expectEqualStrings("a list inside a list property", valueProblem("\x0b\x00\x00\x00\x01\x00\x00\x00\x05\x0b\x00\x00\x00\x00").?);
    // A list that says two elements and has one.
    try testing.expectEqualStrings("truncated list element", valueProblem("\x0b\x00\x00\x00\x02\x00\x00\x00\x02\x02a").?);
    // {b: null, a: null}.
    try testing.expectEqualStrings("map keys out of order", valueProblem("\x0c\x00\x00\x00\x02\x00\x00\x00\x02\x02b\x00\x00\x00\x01\x0d\x00\x00\x00\x02\x02a\x00\x00\x00\x01\x0d").?);
}

test "a storable name is not empty and has no 0x00" {
    try testing.expect(isStorableName("Person"));
    try testing.expect(!isStorableName(""));
    try testing.expect(!isStorableName("A\x00B"));
}

test "a relationship record has a type without 0x00" {
    try testing.expectEqual(@as(?[]const u8, null), relationshipRecordProblem("0123456789abcdefKNOWS"));
    try testing.expectEqualStrings("no relationship type", relationshipRecordProblem("0123456789abcdef").?);
    try testing.expectEqualStrings("a relationship type with a 0x00 byte", relationshipRecordProblem("0123456789abcdefA\x00B").?);
}
