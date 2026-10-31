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
//!     0x01 | error code (u32) | position (u32) | message length (u32) | message
//!
//! The first: the statement ran and, if it changed anything, committed;
//! `lsn` is the master's last LSN once it is done, so a replica that has
//! applied it reads what the statement wrote (or read). The second: it
//! failed, with the `Diagnostic` the master's run left (nothing committed).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_module = @import("../value.zig");
const Value = value_module.Value;
const MapEntry = value_module.MapEntry;
const values = @import("values.zig");

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

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, n: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, n, .big);
    try list.appendSlice(allocator, &bytes);
}

fn appendBytes(list: *std.ArrayList(u8), allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    try appendInt(list, allocator, u32, @intCast(bytes.len));
    try list.appendSlice(allocator, bytes);
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

/// The answer `bytes` holds, whole. Its names and message are views into
/// `bytes`; rows and values are allocated with `allocator` (an arena suits).
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
                for (row_values) |*value| {
                    const decoded = values.decode(cursor.bytes, allocator) catch |err| return switch (err) {
                        error.MalformedValue => error.MalformedMessage,
                        else => |other| other,
                    };
                    value.* = decoded.value;
                    cursor.bytes = cursor.bytes[decoded.length..];
                }
                row.* = row_values;
            }
            break :done .{ .done = .{ .lsn = lsn, .columns = columns, .rows = rows } };
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
