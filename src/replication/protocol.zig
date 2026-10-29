//! The replication protocol: what a master and its replicas say to each
//! other over a byte stream (a TCP connection; anything with a
//! `std.Io.Reader` and a `std.Io.Writer`).
//!
//! A replica opens the conversation with `hello`: who it is (protocol
//! version, storage format and engine, the id of the master it copies, the
//! last change set it applied) and the token the master expects. The master
//! answers with `refused` and closes, or with one of:
//!
//!     stream          the replica can resume: change sets follow, from
//!                     the one after the replica's last
//!     snapshot_part*  the replica cannot (it is empty, or the master no
//!     snapshot_end    longer holds the change sets it misses): a copy of
//!                     the master's database (KeyValueStore.copyDatabase),
//!                     in parts; the replica makes it its database and
//!                     `ack`s the copy's last LSN, and change sets from
//!                     the one after follow
//!
//! Then the master sends each change set as it commits (`change_set_part`,
//! a change set cut into parts of at most `part_bytes`, the last one marked
//! final) and, when it has none to send, a `heartbeat` with its last LSN,
//! so a replica knows how far behind it is and that the master is alive.
//! The replica answers with `ack`s of the last LSN it applied.
//!
//! Every message is one frame, integers big-endian:
//!
//!     kind (u8) | payload length (u32) | CRC-32 of kind and payload (u32) | payload
//!
//! A frame's payload is at most `max_payload_bytes`, so a reader whose
//! buffer holds `max_frame_bytes` reads any frame without allocating.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Crc32 = std.hash.Crc32;

/// Bumped on every change to the messages: a master and a replica of
/// different versions do not talk.
pub const version: u16 = 1;

/// The first bytes of a `hello`, so a master that is sent something else
/// (another protocol, a stray connection) refuses it at once.
pub const magic = "ZYPR".*;

/// The largest part of a snapshot or a change set in one frame.
pub const part_bytes: usize = 1 << 20;

/// The largest token a replica may send.
pub const max_token_bytes: usize = 1024;

/// The largest name of a storage engine.
pub const max_engine_name_bytes: usize = 32;

const part_header_bytes = 9;
const hello_fixed_bytes = magic.len + 2 + 4 + 1 + 16 + 8 + 2;

pub const max_payload_bytes: usize = @max(part_bytes + part_header_bytes, hello_fixed_bytes + max_engine_name_bytes + max_token_bytes);

const header_bytes = 9;

/// The buffer a `std.Io.Reader` needs to read any frame.
pub const max_frame_bytes: usize = header_bytes + max_payload_bytes;

pub const DatabaseId = [16]u8;

pub const Kind = enum(u8) {
    hello = 1,
    refused = 2,
    stream = 3,
    snapshot_part = 4,
    snapshot_end = 5,
    change_set_part = 6,
    heartbeat = 7,
    ack = 8,
};

/// A replica introduces itself.
pub const Hello = struct {
    protocol_version: u16 = version,
    /// `Graph.format_version` of the replica's build.
    storage_format: u32,
    /// The replica build's storage engine (`zypherdb.storage_engine`): a
    /// snapshot is an engine's file.
    storage_engine: []const u8,
    /// The master the replica's database is a copy of; null if it has none.
    database_id: ?DatabaseId,
    /// The last change set the replica applied (0 if none).
    applied_lsn: u64,
    token: []const u8,
};

/// Why a master turns a replica away.
pub const Refusal = enum(u8) {
    protocol_version = 1,
    storage_format = 2,
    storage_engine = 3,
    /// The replica copies another master.
    database_id = 4,
    token = 5,
    /// The replica has change sets the master never made (it was promoted,
    /// or the master restored from an older copy).
    ahead = 6,
    /// The database is no master: its change log is not started, or it is
    /// a replica itself.
    not_master = 7,
    _,
};

pub const ChangeSetPart = struct {
    lsn: u64,
    /// The change set's last part.
    final: bool,
    bytes: []const u8,
};

pub const Message = union(Kind) {
    hello: Hello,
    refused: Refusal,
    /// The LSN of the first change set to come.
    stream: u64,
    snapshot_part: []const u8,
    /// The size of the copy, in bytes.
    snapshot_end: u64,
    change_set_part: ChangeSetPart,
    /// The master's last LSN.
    heartbeat: u64,
    /// The replica's last applied LSN.
    ack: u64,
};

pub const ReadError = Reader.Error || error{ MalformedFrame, ChecksumMismatch };

/// Writes `message` as one frame (not flushed). Asserts its parts fit
/// (`part_bytes`, `max_token_bytes`, `max_engine_name_bytes`).
pub fn write(writer: *Writer, message: Message) Writer.Error!void {
    var checksum: ChecksumSink = .{};
    checksum.crc.update(&.{@backingInt(message)});
    encodePayload(&checksum, message) catch unreachable;
    try writer.writeByte(@backingInt(message));
    try writer.writeInt(u32, @intCast(checksum.length), .big);
    try writer.writeInt(u32, checksum.crc.final(), .big);
    try encodePayload(writer, message);
}

/// Reads one frame. The message's slices are views into `reader`'s buffer,
/// valid until its next read. A reader of a stream needs a buffer of
/// `max_frame_bytes`.
pub fn read(reader: *Reader) ReadError!Message {
    const kind_byte = try reader.takeByte();
    const length = try reader.takeInt(u32, .big);
    const expected_crc = try reader.takeInt(u32, .big);
    if (length > max_payload_bytes) return error.MalformedFrame;
    const payload = try reader.take(length);
    var crc = Crc32.init();
    crc.update(&.{kind_byte});
    crc.update(payload);
    if (crc.final() != expected_crc) return error.ChecksumMismatch;
    const kind = std.enums.fromInt(Kind, kind_byte) orelse return error.MalformedFrame;
    return decodePayload(kind, payload) orelse error.MalformedFrame;
}

/// Whether the token a replica sent is the one expected, in a time that
/// does not tell how much of it matched.
pub fn tokensMatch(sent: []const u8, expected: []const u8) bool {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var sent_digest: [Sha256.digest_length]u8 = undefined;
    var expected_digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(sent, &sent_digest, .{});
    Sha256.hash(expected, &expected_digest, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, sent_digest, expected_digest);
}

/// Counts and checksums what is written to it.
const ChecksumSink = struct {
    crc: Crc32 = .init(),
    length: usize = 0,

    fn writeAll(self: *ChecksumSink, bytes: []const u8) error{}!void {
        self.crc.update(bytes);
        self.length += bytes.len;
    }

    fn writeByte(self: *ChecksumSink, byte: u8) error{}!void {
        return self.writeAll(&.{byte});
    }

    fn writeInt(self: *ChecksumSink, comptime T: type, value: T, comptime endian: std.builtin.Endian) error{}!void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, endian);
        return self.writeAll(&bytes);
    }
};

/// Writes `message`'s payload to `sink`, a `*Writer` or a `*ChecksumSink`.
fn encodePayload(sink: anytype, message: Message) !void {
    switch (message) {
        .hello => |hello| {
            std.debug.assert(hello.storage_engine.len <= max_engine_name_bytes);
            std.debug.assert(hello.token.len <= max_token_bytes);
            try sink.writeAll(&magic);
            try sink.writeInt(u16, hello.protocol_version, .big);
            try sink.writeInt(u32, hello.storage_format, .big);
            try sink.writeByte(@intCast(hello.storage_engine.len));
            try sink.writeAll(hello.storage_engine);
            try sink.writeByte(@intFromBool(hello.database_id != null));
            try sink.writeAll(&(hello.database_id orelse @as(DatabaseId, @splat(0))));
            try sink.writeInt(u64, hello.applied_lsn, .big);
            try sink.writeInt(u16, @intCast(hello.token.len), .big);
            try sink.writeAll(hello.token);
        },
        .refused => |reason| try sink.writeByte(@backingInt(reason)),
        .stream, .snapshot_end, .heartbeat, .ack => |lsn_or_size| try sink.writeInt(u64, lsn_or_size, .big),
        .snapshot_part => |bytes| {
            std.debug.assert(bytes.len <= part_bytes);
            try sink.writeAll(bytes);
        },
        .change_set_part => |part| {
            std.debug.assert(part.bytes.len <= part_bytes);
            try sink.writeInt(u64, part.lsn, .big);
            try sink.writeByte(@intFromBool(part.final));
            try sink.writeAll(part.bytes);
        },
    }
}

fn decodePayload(kind: Kind, payload: []const u8) ?Message {
    var cursor = Cursor{ .bytes = payload };
    const message: Message = switch (kind) {
        .hello => hello: {
            if (!std.mem.eql(u8, cursor.take(magic.len) orelse return null, &magic)) return null;
            const protocol_version = cursor.int(u16) orelse return null;
            const storage_format = cursor.int(u32) orelse return null;
            const storage_engine = cursor.take(cursor.int(u8) orelse return null) orelse return null;
            const has_database_id = cursor.int(u8) orelse return null;
            const database_id = (cursor.take(16) orelse return null)[0..16].*;
            const applied_lsn = cursor.int(u64) orelse return null;
            const token = cursor.take(cursor.int(u16) orelse return null) orelse return null;
            if (has_database_id > 1 or storage_engine.len > max_engine_name_bytes or token.len > max_token_bytes) return null;
            break :hello .{ .hello = .{
                .protocol_version = protocol_version,
                .storage_format = storage_format,
                .storage_engine = storage_engine,
                .database_id = if (has_database_id == 1) database_id else null,
                .applied_lsn = applied_lsn,
                .token = token,
            } };
        },
        .refused => .{ .refused = @fromBackingInt(@intCast(cursor.int(u8) orelse return null)) },
        .stream => .{ .stream = cursor.int(u64) orelse return null },
        .snapshot_end => .{ .snapshot_end = cursor.int(u64) orelse return null },
        .heartbeat => .{ .heartbeat = cursor.int(u64) orelse return null },
        .ack => .{ .ack = cursor.int(u64) orelse return null },
        .snapshot_part => .{ .snapshot_part = cursor.rest() },
        .change_set_part => part: {
            const lsn = cursor.int(u64) orelse return null;
            const final = cursor.int(u8) orelse return null;
            if (final > 1) return null;
            break :part .{ .change_set_part = .{ .lsn = lsn, .final = final == 1, .bytes = cursor.rest() } };
        },
    };
    if (cursor.bytes.len != 0) return null;
    if (switch (message) {
        .snapshot_part => |bytes| bytes.len > part_bytes,
        .change_set_part => |part| part.bytes.len > part_bytes,
        else => false,
    }) return null;
    return message;
}

/// Reads a payload from the front.
const Cursor = struct {
    bytes: []const u8,

    fn take(self: *Cursor, length: usize) ?[]const u8 {
        if (self.bytes.len < length) return null;
        defer self.bytes = self.bytes[length..];
        return self.bytes[0..length];
    }

    fn int(self: *Cursor, comptime T: type) ?T {
        const bytes = self.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
    }

    fn rest(self: *Cursor) []const u8 {
        defer self.bytes = self.bytes[self.bytes.len..];
        return self.bytes;
    }
};
