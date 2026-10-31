//! The replication protocol: what a master and its replicas say to each
//! other over a byte stream (a TCP connection, a simulated network), in
//! frames that may arrive in pieces (`Inbox`) and leave in pieces (`Outbox`).
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
//! A replica that forwards writes opens a connection of its own for them,
//! with `writer_hello` (protocol version, the id of the master it copies,
//! the token, its name). The master answers `refused` and closes, or
//! `writer_ready`; then each write is a `request_part`* the master runs and
//! answers with `answer_part`*, under the id the request gave, one write
//! at a time. A request or an answer is cut into parts of at most
//! `part_bytes`, the last one marked final; forwarding.zig tells what their
//! bytes hold. While it sends no answer, a write running or not, the master
//! sends a `heartbeat` each interval and the replica `ack`s each one, so
//! either side knows the other is alive.
//!
//! Every message is one frame, integers big-endian:
//!
//!     kind (u8) | payload length (u32) | CRC-32 of kind and payload (u32) | payload
//!
//! A frame's payload is at most `max_payload_bytes`, so a reader whose
//! buffer holds `max_frame_bytes` reads any frame without allocating.

const std = @import("std");
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

/// The largest name a replica gives itself.
pub const max_name_bytes: usize = 255;

const part_header_bytes = 9;
const hello_fixed_bytes = magic.len + 2 + 4 + 1 + 16 + 8 + 2 + 1;
const writer_hello_fixed_bytes = magic.len + 2 + 16 + 2 + 1;

pub const max_payload_bytes: usize = @max(
    part_bytes + part_header_bytes,
    hello_fixed_bytes + max_engine_name_bytes + max_token_bytes + max_name_bytes,
    writer_hello_fixed_bytes + max_token_bytes + max_name_bytes,
);

const header_bytes = 9;

/// The largest frame: what an `Inbox` or an `Outbox` holds at least.
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
    writer_hello = 9,
    writer_ready = 10,
    request_part = 11,
    answer_part = 12,
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
    /// What the replica calls itself, for its master's status (its host's
    /// name, unless told another).
    name: []const u8 = "",
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

    /// Whether asking again cannot help until someone changes something:
    /// all but `not_master` (the master may be starting). A reason this
    /// version does not know is taken as permanent.
    pub fn permanent(self: Refusal) bool {
        return self != .not_master;
    }
};

/// A replica's connection for forwarded writes introduces itself.
pub const WriterHello = struct {
    protocol_version: u16 = version,
    /// The master the replica's database is a copy of: only a replica
    /// that holds a copy forwards writes.
    database_id: DatabaseId,
    token: []const u8,
    /// The replica's name, as in its `Hello`.
    name: []const u8 = "",
};

/// A part of a forwarded write's request or of its answer.
pub const WritePart = struct {
    /// The request's, chosen by the replica; its answer carries it back.
    id: u64,
    /// The request's or the answer's last part.
    final: bool,
    bytes: []const u8,
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
    writer_hello: WriterHello,
    writer_ready: void,
    request_part: WritePart,
    answer_part: WritePart,
};

pub const DecodeError = error{ MalformedFrame, ChecksumMismatch };

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

/// The bytes `write` writes for `message`.
pub fn frameLength(message: Message) usize {
    // No checksum: a sender asks this each time it looks for room for a
    // part, which may be many times per part.
    var counter: LengthSink = .{};
    encodePayload(&counter, message) catch unreachable;
    return header_bytes + counter.length;
}

/// A frame decoded from the front of a run of bytes.
pub const Decoded = struct {
    message: Message,
    /// The frame's bytes: where the next frame starts.
    length: usize,
};

/// Decodes the frame at the front of `bytes`, or null if `bytes` holds
/// only its beginning. The message's slices are views into `bytes`. A
/// length no frame has is refused as soon as the header is in.
pub fn decode(bytes: []const u8) DecodeError!?Decoded {
    if (bytes.len < header_bytes) return null;
    const length = std.mem.readInt(u32, bytes[1..5], .big);
    if (length > max_payload_bytes) return error.MalformedFrame;
    if (bytes.len < header_bytes + length) return null;
    const expected_crc = std.mem.readInt(u32, bytes[5..9], .big);
    return .{
        .message = try checkedMessage(bytes[0], expected_crc, bytes[header_bytes..][0..length]),
        .length = header_bytes + length,
    };
}

/// Frames that arrive in pieces (from a non-blocking socket, a simulated
/// network): bytes go in at `unfilled` and `filled`, messages come out of
/// `next`. Its buffer of `max_frame_bytes` holds any frame.
pub const Inbox = struct {
    buffer: []u8,
    /// Bytes before `start` are frames already taken.
    start: usize = 0,
    end: usize = 0,

    pub fn init(buffer: []u8) Inbox {
        std.debug.assert(buffer.len >= max_frame_bytes);
        return .{ .buffer = buffer };
    }

    /// Where the next bytes received go; never empty while a frame can
    /// still be completed (`next` refuses one longer than the buffer
    /// first). Moves what is unread to the front, so the messages `next`
    /// returned are no longer valid.
    pub fn unfilled(self: *Inbox) []u8 {
        if (self.start != 0) {
            std.mem.copyForwards(u8, self.buffer, self.buffer[self.start..self.end]);
            self.end -= self.start;
            self.start = 0;
        }
        return self.buffer[self.end..];
    }

    /// `count` bytes were received into `unfilled`.
    pub fn filled(self: *Inbox, count: usize) void {
        std.debug.assert(self.end + count <= self.buffer.len);
        self.end += count;
    }

    /// The next whole message received, or null until more bytes come.
    /// Its slices are views into the buffer, valid until `unfilled`.
    pub fn next(self: *Inbox) DecodeError!?Message {
        const decoded = try decode(self.buffer[self.start..self.end]) orelse return null;
        self.start += decoded.length;
        return decoded.message;
    }
};

/// Frames waiting to be sent: `put` adds whole frames while they fit, the
/// sender takes bytes from `unsent` and reports them `sent`. Its buffer of
/// `max_frame_bytes` holds any frame.
pub const Outbox = struct {
    buffer: []u8,
    /// Bytes before `start` are sent.
    start: usize = 0,
    end: usize = 0,

    pub fn init(buffer: []u8) Outbox {
        std.debug.assert(buffer.len >= max_frame_bytes);
        return .{ .buffer = buffer };
    }

    /// Whether `message` fits after the frames waiting. Moves what is
    /// unsent to the front if that makes it fit.
    pub fn fits(self: *Outbox, message: Message) bool {
        const length = frameLength(message);
        if (self.buffer.len - self.end >= length) return true;
        if (self.buffer.len - (self.end - self.start) < length) return false;
        std.mem.copyForwards(u8, self.buffer, self.buffer[self.start..self.end]);
        self.end -= self.start;
        self.start = 0;
        return true;
    }

    /// Adds `message`'s frame; asserts it `fits`.
    pub fn put(self: *Outbox, message: Message) void {
        std.debug.assert(self.fits(message));
        var writer: Writer = .fixed(self.buffer[self.end..]);
        write(&writer, message) catch unreachable;
        self.end += writer.end;
    }

    pub fn unsent(self: *const Outbox) []const u8 {
        return self.buffer[self.start..self.end];
    }

    /// The first `count` bytes of `unsent` are sent.
    pub fn sent(self: *Outbox, count: usize) void {
        std.debug.assert(count <= self.end - self.start);
        self.start += count;
        if (self.start == self.end) {
            self.start = 0;
            self.end = 0;
        }
    }

    pub fn isEmpty(self: *const Outbox) bool {
        return self.start == self.end;
    }
};

/// Checks a frame's checksum and decodes its payload.
fn checkedMessage(kind_byte: u8, expected_crc: u32, payload: []const u8) DecodeError!Message {
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

/// Counts what is written to it.
const LengthSink = struct {
    length: usize = 0,

    fn writeAll(self: *LengthSink, bytes: []const u8) error{}!void {
        self.length += bytes.len;
    }

    fn writeByte(self: *LengthSink, byte: u8) error{}!void {
        _ = byte;
        self.length += 1;
    }

    fn writeInt(self: *LengthSink, comptime T: type, value: T, comptime endian: std.builtin.Endian) error{}!void {
        _ = value;
        _ = endian;
        self.length += @sizeOf(T);
    }
};

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

/// Writes `message`'s payload to `sink`, a `*Writer`, a `*ChecksumSink` or
/// a `*LengthSink`.
fn encodePayload(sink: anytype, message: Message) !void {
    switch (message) {
        .hello => |hello| {
            std.debug.assert(hello.storage_engine.len <= max_engine_name_bytes);
            std.debug.assert(hello.token.len <= max_token_bytes);
            std.debug.assert(hello.name.len <= max_name_bytes);
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
            try sink.writeByte(@intCast(hello.name.len));
            try sink.writeAll(hello.name);
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
        .writer_hello => |hello| {
            std.debug.assert(hello.token.len <= max_token_bytes);
            std.debug.assert(hello.name.len <= max_name_bytes);
            try sink.writeAll(&magic);
            try sink.writeInt(u16, hello.protocol_version, .big);
            try sink.writeAll(&hello.database_id);
            try sink.writeInt(u16, @intCast(hello.token.len), .big);
            try sink.writeAll(hello.token);
            try sink.writeByte(@intCast(hello.name.len));
            try sink.writeAll(hello.name);
        },
        .writer_ready => {},
        .request_part, .answer_part => |part| {
            std.debug.assert(part.bytes.len <= part_bytes);
            try sink.writeInt(u64, part.id, .big);
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
            const name = cursor.take(cursor.int(u8) orelse return null) orelse return null;
            if (has_database_id > 1 or storage_engine.len > max_engine_name_bytes or token.len > max_token_bytes) return null;
            break :hello .{ .hello = .{
                .protocol_version = protocol_version,
                .storage_format = storage_format,
                .storage_engine = storage_engine,
                .database_id = if (has_database_id == 1) database_id else null,
                .applied_lsn = applied_lsn,
                .token = token,
                .name = name,
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
        .writer_hello => hello: {
            if (!std.mem.eql(u8, cursor.take(magic.len) orelse return null, &magic)) return null;
            const protocol_version = cursor.int(u16) orelse return null;
            const database_id = (cursor.take(16) orelse return null)[0..16].*;
            const token = cursor.take(cursor.int(u16) orelse return null) orelse return null;
            const name = cursor.take(cursor.int(u8) orelse return null) orelse return null;
            if (token.len > max_token_bytes) return null;
            break :hello .{ .writer_hello = .{ .protocol_version = protocol_version, .database_id = database_id, .token = token, .name = name } };
        },
        .writer_ready => .writer_ready,
        .request_part, .answer_part => part: {
            const id = cursor.int(u64) orelse return null;
            const final = cursor.int(u8) orelse return null;
            if (final > 1) return null;
            const write_part: WritePart = .{ .id = id, .final = final == 1, .bytes = cursor.rest() };
            break :part if (kind == .request_part) .{ .request_part = write_part } else .{ .answer_part = write_part };
        },
    };
    if (cursor.bytes.len != 0) return null;
    if (switch (message) {
        .snapshot_part => |bytes| bytes.len > part_bytes,
        .change_set_part => |part| part.bytes.len > part_bytes,
        .request_part, .answer_part => |part| part.bytes.len > part_bytes,
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
