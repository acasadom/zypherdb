//! Forwarded writes: what a replica asks its master to run, and what the
//! master answers. The bytes of a request (or of an answer) travel in the
//! `request_part`s (or `answer_part`s) of protocol.zig, joined in order;
//! values in them are written as values.zig writes them. Integers are
//! big-endian.
//!
//! A request is the statement and its parameters:
//!
//!     text length (u32) | text | parameters (a map value)
//!
//! An answer is one of:
//!
//!     0x00 | lsn (u64) | column count (u32) | per column its name length (u32) and name
//!          | row count (u32) | per row its values, one per column
//!          | node count (u32) | per node its id (u64), label count (u32), per
//!            label its length (u32) and name, then its properties
//!          | relationship count (u32) | per relationship its value (values.zig),
//!            then its properties
//!     0x01 | error code (u32) | position (u32) | message length (u32) | message
//!
//! The first: the statement ran and, if it changed anything, committed;
//! `lsn` is the master's last LSN once it is done, so a replica that has
//! applied it reads what the statement wrote (or read). The second: it
//! failed, with the `Diagnostic` the master's run left (nothing committed).
//! The nodes and relationships after the rows are those the rows refer to,
//! as the statement left them (execution/entities.zig): a replica shows
//! them whole even before it has applied the write. Properties are a count
//! (u32), then per property its name length (u32), name and value.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_module = @import("../value.zig");
const Value = value_module.Value;
const MapEntry = value_module.MapEntry;
const values = @import("values.zig");
const entities_module = @import("../execution/entities.zig");
const EntitySnapshot = entities_module.EntitySnapshot;
const Property = entities_module.Property;

/// The largest request a master takes (statement text and parameters).
pub const max_request_bytes: usize = 16 << 20;

/// The largest answer a master sends: a statement whose rows take more
/// fails instead.
pub const max_answer_bytes: usize = 64 << 20;

pub const Request = struct {
    text: []const u8,
    /// Sorted by name, names unique (`Value.map`'s entries).
    parameters: []const MapEntry,
};

pub const Answer = union(enum) {
    done: Done,
    failed: Failure,
};

pub const Done = struct {
    lsn: u64,
    columns: []const []const u8,
    /// Each as long as `columns`; none without columns.
    rows: []const []const Value,
    /// The labels and properties of every node and relationship the rows
    /// refer to.
    entities: EntitySnapshot = .{},
};

pub const Failure = struct {
    /// A `diagnostics.ErrorCode`, as a number: a code this version does not
    /// know still reaches the application.
    code: u32,
    /// The byte in the statement text the error is at (0 when none).
    position: u32,
    message: []const u8,
};

pub const EncodeError = values.EncodeError || error{TooLarge};

/// Appends the bytes of `request`; `error.TooLarge` past `max_request_bytes`.
pub fn encodeRequest(list: *std.ArrayList(u8), allocator: Allocator, request: Request) EncodeError!void {
    const start = list.items.len;
    try appendBytes(list, allocator, request.text);
    try values.encode(list, allocator, .{ .map = request.parameters });
    if (list.items.len - start > max_request_bytes) return error.TooLarge;
}

/// Appends the bytes of `answer`; `error.TooLarge` past `max_answer_bytes`
/// (the master then answers a failure instead).
pub fn encodeAnswer(list: *std.ArrayList(u8), allocator: Allocator, answer: Answer) EncodeError!void {
    const start = list.items.len;
    switch (answer) {
        .done => |done| {
            std.debug.assert(done.columns.len != 0 or done.rows.len == 0);
            try list.append(allocator, 0x00);
            try appendInt(list, allocator, u64, done.lsn);
            try appendInt(list, allocator, u32, @intCast(done.columns.len));
            for (done.columns) |column| try appendBytes(list, allocator, column);
            try appendInt(list, allocator, u32, @intCast(done.rows.len));
            for (done.rows) |row| {
                std.debug.assert(row.len == done.columns.len);
                for (row) |value| {
                    try values.encode(list, allocator, value);
                    if (list.items.len - start > max_answer_bytes) return error.TooLarge;
                }
            }
            try appendInt(list, allocator, u32, done.entities.nodes.count());
            var nodes = done.entities.nodes.iterator();
            while (nodes.next()) |node| {
                try appendInt(list, allocator, u64, node.key_ptr.*);
                try appendInt(list, allocator, u32, @intCast(node.value_ptr.labels.len));
                for (node.value_ptr.labels) |label| try appendBytes(list, allocator, label);
                try appendProperties(list, allocator, node.value_ptr.properties);
                if (list.items.len - start > max_answer_bytes) return error.TooLarge;
            }
            try appendInt(list, allocator, u32, done.entities.relationships.count());
            var relationships = done.entities.relationships.iterator();
            while (relationships.next()) |relationship| {
                try values.encode(list, allocator, .{ .relationship = relationship.key_ptr.* });
                try appendProperties(list, allocator, relationship.value_ptr.*);
                if (list.items.len - start > max_answer_bytes) return error.TooLarge;
            }
        },
        .failed => |failure| {
            try list.append(allocator, 0x01);
            try appendInt(list, allocator, u32, failure.code);
            try appendInt(list, allocator, u32, failure.position);
            try appendBytes(list, allocator, failure.message);
        },
    }
    if (list.items.len - start > max_answer_bytes) return error.TooLarge;
}

/// Sets the LSN of a `done` answer `encodeAnswer` wrote at the front of
/// `bytes`: the master writes its rows before it commits, so a result too
/// large to send fails the statement instead of answering for a commit.
pub fn setAnswerLsn(bytes: []u8, lsn: u64) void {
    std.debug.assert(bytes[0] == 0x00);
    std.mem.writeInt(u64, bytes[1..9], lsn, .big);
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

fn appendProperties(list: *std.ArrayList(u8), allocator: Allocator, properties: []const Property) values.EncodeError!void {
    try appendInt(list, allocator, u32, @intCast(properties.len));
    for (properties) |property| {
        try appendBytes(list, allocator, property.name);
        try values.encode(list, allocator, property.value);
    }
}

pub const DecodeError = values.DecodeError || error{MalformedMessage};

/// The request `bytes` holds, whole. Its text is a view into `bytes`; the
/// parameters are allocated with `allocator` (an arena suits).
pub fn decodeRequest(bytes: []const u8, allocator: Allocator) DecodeError!Request {
    if (bytes.len > max_request_bytes) return error.MalformedMessage;
    var cursor: Cursor = .{ .bytes = bytes };
    const text = try cursor.take(try cursor.int(u32));
    const parameters = values.decodeWhole(cursor.bytes, allocator) catch |err| return switch (err) {
        error.MalformedValue => error.MalformedMessage,
        else => |other| other,
    };
    if (parameters != .map) return error.MalformedMessage;
    return .{ .text = text, .parameters = parameters.map };
}

/// The answer `bytes` holds, whole. Its names, labels and message are views
/// into `bytes`; rows, values and entities are allocated with `allocator`
/// (an arena suits). An entity given twice is refused.
pub fn decodeAnswer(bytes: []const u8, allocator: Allocator) DecodeError!Answer {
    if (bytes.len > max_answer_bytes) return error.MalformedMessage;
    var cursor: Cursor = .{ .bytes = bytes };
    const answer: Answer = switch ((try cursor.take(1))[0]) {
        0x00 => done: {
            const lsn = try cursor.int(u64);
            const columns = try allocator.alloc([]const u8, try cursor.count(4));
            for (columns) |*column| column.* = try cursor.take(try cursor.int(u32));
            // Each value takes a byte at least; without columns, no rows.
            const row_count = try cursor.int(u32);
            if (if (columns.len == 0) row_count != 0 else row_count > cursor.bytes.len / columns.len) return error.MalformedMessage;
            const rows = try allocator.alloc([]const Value, row_count);
            for (rows) |*row| {
                const row_values = try allocator.alloc(Value, columns.len);
                for (row_values) |*value| value.* = try cursor.value(allocator);
                row.* = row_values;
            }
            var entities: EntitySnapshot = .{};
            // An id, a label count and a property count at least.
            for (0..try cursor.count(16)) |_| {
                const id = try cursor.int(u64);
                const labels = try allocator.alloc([]const u8, try cursor.count(4));
                for (labels) |*label| label.* = try cursor.take(try cursor.int(u32));
                const entry = try entities.nodes.getOrPut(allocator, id);
                if (entry.found_existing) return error.MalformedMessage;
                entry.value_ptr.* = .{ .labels = labels, .properties = try cursor.properties(allocator) };
            }
            // A relationship's tag, ids, type length and property count.
            for (0..try cursor.count(33)) |_| {
                const relationship = try cursor.value(allocator);
                if (relationship != .relationship) return error.MalformedMessage;
                const entry = try entities.relationships.getOrPutContext(allocator, relationship.relationship, .{});
                if (entry.found_existing) return error.MalformedMessage;
                entry.value_ptr.* = try cursor.properties(allocator);
            }
            break :done .{ .done = .{ .lsn = lsn, .columns = columns, .rows = rows, .entities = entities } };
        },
        0x01 => .{ .failed = .{
            .code = try cursor.int(u32),
            .position = try cursor.int(u32),
            .message = try cursor.take(try cursor.int(u32)),
        } },
        else => return error.MalformedMessage,
    };
    if (cursor.bytes.len != 0) return error.MalformedMessage;
    return answer;
}

/// Reads from the front of a request's or an answer's bytes.
const Cursor = struct {
    bytes: []const u8,

    fn take(self: *Cursor, length: usize) error{MalformedMessage}![]const u8 {
        if (self.bytes.len < length) return error.MalformedMessage;
        defer self.bytes = self.bytes[length..];
        return self.bytes[0..length];
    }

    fn int(self: *Cursor, comptime T: type) error{MalformedMessage}!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn value(self: *Cursor, allocator: Allocator) DecodeError!Value {
        const decoded = values.decode(self.bytes, allocator) catch |err| return switch (err) {
            error.MalformedValue => error.MalformedMessage,
            else => |other| other,
        };
        self.bytes = self.bytes[decoded.length..];
        return decoded.value;
    }

    fn properties(self: *Cursor, allocator: Allocator) DecodeError![]const Property {
        // A name length and a value's tag at least.
        const list = try allocator.alloc(Property, try self.count(5));
        for (list) |*property| property.* = .{
            .name = try self.take(try self.int(u32)),
            .value = try self.value(allocator),
        };
        return list;
    }

    /// A count of things that take at least `least_bytes` each, refused if
    /// the rest of the bytes cannot hold them.
    fn count(self: *Cursor, least_bytes: usize) error{MalformedMessage}!usize {
        const n = try self.int(u32);
        if (n > self.bytes.len / least_bytes) return error.MalformedMessage;
        return n;
    }
};

/// Joins the parts of one request or answer as they come, refusing one that
/// grows past `limit` or whose parts carry different ids.
pub const Assembly = struct {
    bytes: std.ArrayList(u8) = .empty,
    id: ?u64 = null,
    limit: usize,

    pub const Error = Allocator.Error || error{ TooLarge, MixedParts };

    /// Adds a part; returns the whole bytes on the final one (valid until
    /// the next `add` or `deinit`), null before.
    pub fn add(self: *Assembly, allocator: Allocator, id: u64, final: bool, part: []const u8) Error!?[]const u8 {
        if (self.id) |current| {
            if (current != id) return error.MixedParts;
        } else {
            self.bytes.clearRetainingCapacity();
            self.id = id;
        }
        if (part.len > self.limit - self.bytes.items.len) return error.TooLarge;
        try self.bytes.appendSlice(allocator, part);
        if (!final) return null;
        self.id = null;
        return self.bytes.items;
    }

    pub fn deinit(self: *Assembly, allocator: Allocator) void {
        self.bytes.deinit(allocator);
    }
};
