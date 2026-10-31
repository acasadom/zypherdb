//! Values on the wire: how a forwarded write's parameters and its result
//! rows travel between a replica and its master. Unlike the storage
//! encoding (storage/value_encoding.zig), it holds every `Value`, nodes,
//! relationships and paths among them, and reading checks every byte: what
//! comes from the network is never trusted to be well formed.
//!
//! A value is `tag | payload`, integers big-endian:
//!
//! | Tag    | Value           | Payload                                          |
//! | ------ | --------------- | ------------------------------------------------ |
//! | `0x00` | null            | nothing                                          |
//! | `0x01` | integer         | i64                                              |
//! | `0x02` | float           | the IEEE 754 bits, u64                           |
//! | `0x03` | string          | length, u32; the bytes                           |
//! | `0x04` | boolean         | one byte, 0 or 1                                 |
//! | `0x05` | list            | count, u32; each element                         |
//! | `0x06` | map             | count, u32; per entry its key (as a string payload) and its value; keys strictly increasing |
//! | `0x07` | node            | id, u64                                          |
//! | `0x08` | relationship    | id, start, end, u64; type (as a string payload)  |
//! | `0x09` | path            | node count, u32 (at least 1); the node ids, u64; then one relationship payload per step, joining the nodes on either side |
//! | `0x0a` | date            | days, i64                                        |
//! | `0x0b` | local time      | nanoseconds of the day, i64                      |
//! | `0x0c` | time            | nanoseconds of the day, i64; offset, i32         |
//! | `0x0d` | local date-time | seconds, i64; nanoseconds, u32                   |
//! | `0x0e` | date-time       | seconds, i64; nanoseconds, u32; offset, i32; zone (as a string payload) |
//! | `0x0f` | duration        | months, days, seconds, i64; nanoseconds, u32     |
//!
//! Lists and maps nest at most `max_depth` deep, on both sides: a value
//! nested deeper is refused when written, so a reader's recursion is bounded.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_module = @import("../value.zig");
const Value = value_module.Value;
const MapEntry = value_module.MapEntry;
const Relationship = value_module.Relationship;

/// How deep lists and maps nest (a list in a list is depth 2).
pub const max_depth: usize = 64;

const nanoseconds_per_second: u64 = std.time.ns_per_s;
const nanoseconds_per_day: i64 = std.time.ns_per_day;

const Tag = enum(u8) {
    null = 0x00,
    int = 0x01,
    float = 0x02,
    string = 0x03,
    boolean = 0x04,
    list = 0x05,
    map = 0x06,
    node = 0x07,
    relationship = 0x08,
    path = 0x09,
    date = 0x0a,
    local_time = 0x0b,
    time = 0x0c,
    local_date_time = 0x0d,
    date_time = 0x0e,
    duration = 0x0f,
};

pub const EncodeError = Allocator.Error || error{ValueTooDeep};

/// Appends the wire encoding of `value`.
pub fn encode(list: *std.ArrayList(u8), allocator: Allocator, value: Value) EncodeError!void {
    try encodeNested(list, allocator, value, 0);
}

fn encodeNested(list: *std.ArrayList(u8), allocator: Allocator, value: Value, depth: usize) EncodeError!void {
    const tag: Tag = switch (value) {
        inline else => |_, kind| @field(Tag, @tagName(kind)),
    };
    try list.append(allocator, @backingInt(tag));
    switch (value) {
        .null => {},
        .int => |n| try appendInt(list, allocator, i64, n),
        .float => |x| try appendInt(list, allocator, u64, @bitCast(x)),
        .string => |s| try appendBytes(list, allocator, s),
        .boolean => |b| try list.append(allocator, @intFromBool(b)),
        .list => |items| {
            if (depth == max_depth) return error.ValueTooDeep;
            try appendInt(list, allocator, u32, @intCast(items.len));
            for (items) |item| try encodeNested(list, allocator, item, depth + 1);
        },
        .map => |entries| {
            if (depth == max_depth) return error.ValueTooDeep;
            try appendInt(list, allocator, u32, @intCast(entries.len));
            for (entries) |entry| {
                try appendBytes(list, allocator, entry.key);
                try encodeNested(list, allocator, entry.value, depth + 1);
            }
        },
        .node => |id| try appendInt(list, allocator, u64, id),
        .relationship => |relationship| try appendRelationship(list, allocator, relationship),
        .path => |path| {
            try appendInt(list, allocator, u32, @intCast(path.nodes.len));
            for (path.nodes) |id| try appendInt(list, allocator, u64, id);
            for (path.relationships) |relationship| try appendRelationship(list, allocator, relationship);
        },
        .date => |d| try appendInt(list, allocator, i64, d.days),
        .local_time => |t| try appendInt(list, allocator, i64, t.nanoseconds),
        .time => |t| {
            try appendInt(list, allocator, i64, t.nanoseconds);
            try appendInt(list, allocator, i32, t.offset);
        },
        .local_date_time => |t| {
            try appendInt(list, allocator, i64, t.seconds);
            try appendInt(list, allocator, u32, t.nanoseconds);
        },
        .date_time => |t| {
            try appendInt(list, allocator, i64, t.seconds);
            try appendInt(list, allocator, u32, t.nanoseconds);
            try appendInt(list, allocator, i32, t.offset);
            try appendBytes(list, allocator, t.zone);
        },
        .duration => |d| {
            try appendInt(list, allocator, i64, d.months);
            try appendInt(list, allocator, i64, d.days);
            try appendInt(list, allocator, i64, d.seconds);
            try appendInt(list, allocator, u32, d.nanoseconds);
        },
    }
}

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, n: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, n, .big);
    try list.appendSlice(allocator, &bytes);
}

fn appendBytes(list: *std.ArrayList(u8), allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    try appendInt(list, allocator, u32, @intCast(bytes.len));
    try list.appendSlice(allocator, bytes);
}

fn appendRelationship(list: *std.ArrayList(u8), allocator: Allocator, relationship: Relationship) Allocator.Error!void {
    try appendInt(list, allocator, u64, relationship.id);
    try appendInt(list, allocator, u64, relationship.src);
    try appendInt(list, allocator, u64, relationship.dst);
    try appendBytes(list, allocator, relationship.edge_type);
}

pub const DecodeError = Allocator.Error || error{MalformedValue};

/// The value at the start of `bytes`, and where it ends. Strings, lists,
/// maps and paths are allocated with `allocator` (an arena suits: nothing
/// is freed on an error). Any byte out of place is `error.MalformedValue`.
pub fn decode(bytes: []const u8, allocator: Allocator) DecodeError!Decoded {
    var reader: Reader = .{ .bytes = bytes, .allocator = allocator };
    const value = try reader.value(0);
    return .{ .value = value, .length = reader.position };
}

pub const Decoded = struct { value: Value, length: usize };

/// The value `bytes` holds, whole and nothing after.
pub fn decodeWhole(bytes: []const u8, allocator: Allocator) DecodeError!Value {
    const decoded = try decode(bytes, allocator);
    if (decoded.length != bytes.len) return error.MalformedValue;
    return decoded.value;
}

const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    allocator: Allocator,

    fn take(self: *Reader, length: usize) DecodeError![]const u8 {
        if (self.bytes.len - self.position < length) return error.MalformedValue;
        defer self.position += length;
        return self.bytes[self.position..][0..length];
    }

    fn int(self: *Reader, comptime T: type) DecodeError!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    /// A count of things that take at least `least_bytes` each: one the
    /// rest of the bytes cannot hold is refused before anything is allocated.
    fn count(self: *Reader, least_bytes: usize) DecodeError!usize {
        const n = try self.int(u32);
        if (n > (self.bytes.len - self.position) / least_bytes) return error.MalformedValue;
        return n;
    }

    fn string(self: *Reader) DecodeError![]const u8 {
        return self.allocator.dupe(u8, try self.take(try self.int(u32)));
    }

    fn nanosecondsOfSecond(self: *Reader) DecodeError!u32 {
        const n = try self.int(u32);
        if (n >= nanoseconds_per_second) return error.MalformedValue;
        return n;
    }

    fn nanosecondsOfDay(self: *Reader) DecodeError!i64 {
        const n = try self.int(i64);
        if (n < 0 or n >= nanoseconds_per_day) return error.MalformedValue;
        return n;
    }

    fn relationship(self: *Reader) DecodeError!Relationship {
        return .{ .id = try self.int(u64), .src = try self.int(u64), .dst = try self.int(u64), .edge_type = try self.string() };
    }

    fn value(self: *Reader, depth: usize) DecodeError!Value {
        const tag = std.enums.fromInt(Tag, (try self.take(1))[0]) orelse return error.MalformedValue;
        return switch (tag) {
            .null => .null,
            .int => .{ .int = try self.int(i64) },
            .float => .{ .float = @bitCast(try self.int(u64)) },
            .string => .{ .string = try self.string() },
            .boolean => switch ((try self.take(1))[0]) {
                0 => .{ .boolean = false },
                1 => .{ .boolean = true },
                else => error.MalformedValue,
            },
            .list => blk: {
                if (depth == max_depth) return error.MalformedValue;
                const items = try self.allocator.alloc(Value, try self.count(1));
                for (items) |*item| item.* = try self.value(depth + 1);
                break :blk .{ .list = items };
            },
            .map => blk: {
                if (depth == max_depth) return error.MalformedValue;
                const entries = try self.allocator.alloc(MapEntry, try self.count(4 + 1));
                for (entries, 0..) |*entry, i| {
                    const key = try self.string();
                    // Sorted and unique, as `Value.map` requires.
                    if (i > 0 and std.mem.order(u8, entries[i - 1].key, key) != .lt) return error.MalformedValue;
                    entry.* = .{ .key = key, .value = try self.value(depth + 1) };
                }
                break :blk .{ .map = entries };
            },
            .node => .{ .node = try self.int(u64) },
            .relationship => .{ .relationship = try self.relationship() },
            .path => blk: {
                const nodes = try self.allocator.alloc(u64, try self.count(8));
                if (nodes.len == 0) return error.MalformedValue;
                for (nodes) |*id| id.* = try self.int(u64);
                const relationships = try self.allocator.alloc(Relationship, nodes.len - 1);
                for (relationships, 0..) |*step, i| {
                    step.* = try self.relationship();
                    const joins = (step.src == nodes[i] and step.dst == nodes[i + 1]) or
                        (step.dst == nodes[i] and step.src == nodes[i + 1]);
                    if (!joins) return error.MalformedValue;
                }
                break :blk .{ .path = .{ .nodes = nodes, .relationships = relationships } };
            },
            .date => .{ .date = .{ .days = try self.int(i64) } },
            .local_time => .{ .local_time = .{ .nanoseconds = try self.nanosecondsOfDay() } },
            .time => .{ .time = .{ .nanoseconds = try self.nanosecondsOfDay(), .offset = try self.int(i32) } },
            .local_date_time => .{ .local_date_time = .{ .seconds = try self.int(i64), .nanoseconds = try self.nanosecondsOfSecond() } },
            .date_time => .{ .date_time = .{
                .seconds = try self.int(i64),
                .nanoseconds = try self.nanosecondsOfSecond(),
                .offset = try self.int(i32),
                .zone = try self.string(),
            } },
            .duration => .{ .duration = .{
                .months = try self.int(i64),
                .days = try self.int(i64),
                .seconds = try self.int(i64),
                .nanoseconds = try self.nanosecondsOfSecond(),
            } },
        };
    }
};
