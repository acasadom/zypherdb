//! The replication protocol (replication/protocol.zig): every message reads
//! back as written, and a damaged or forged frame is refused, never misread.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const protocol = zypherdb.replication_protocol;
const Message = protocol.Message;

fn encode(buffer: []u8, message: Message) ![]u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try protocol.write(&writer, message);
    return writer.buffered();
}

/// The message of the one frame `bytes` holds, whole and nothing after.
fn decodeWhole(bytes: []const u8) !Message {
    const decoded = try protocol.decode(bytes) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(bytes.len, decoded.length);
    return decoded.message;
}

fn expectRoundTrip(message: Message) !void {
    var buffer: [4096]u8 = undefined;
    try testing.expectEqualDeep(message, try decodeWhole(try encode(&buffer, message)));
}

test "every message reads back as written" {
    try expectRoundTrip(.{ .hello = .{
        .storage_format = 1,
        .storage_engine = "lmdb",
        .database_id = @splat(0xab),
        .applied_lsn = 42,
        .token = "secret",
        .name = "replica-eu-1",
    } });
    try expectRoundTrip(.{ .hello = .{
        .protocol_version = 7,
        .storage_format = 3,
        .storage_engine = "mdbx",
        .database_id = null,
        .applied_lsn = 0,
        .token = "",
    } });
    try expectRoundTrip(.{ .refused = .token });
    try expectRoundTrip(.{ .refused = .ahead });
    try expectRoundTrip(.{ .stream = 43 });
    try expectRoundTrip(.{ .snapshot_part = "the bytes of a copy" });
    try expectRoundTrip(.{ .snapshot_part = "" });
    try expectRoundTrip(.{ .snapshot_end = 1 << 40 });
    try expectRoundTrip(.{ .change_set_part = .{ .lsn = 9, .final = false, .bytes = "\x01\x00" } });
    try expectRoundTrip(.{ .change_set_part = .{ .lsn = std.math.maxInt(u64), .final = true, .bytes = "" } });
    try expectRoundTrip(.{ .heartbeat = 100 });
    try expectRoundTrip(.{ .ack = 99 });
    try expectRoundTrip(.{ .writer_hello = .{ .database_id = @splat(0xcd), .token = "secret", .name = "edge-3" } });
    try expectRoundTrip(.{ .writer_hello = .{ .protocol_version = 2, .database_id = @splat(0), .token = "" } });
    try expectRoundTrip(.writer_ready);
    try expectRoundTrip(.{ .request_part = .{ .id = 1, .final = false, .bytes = "CREATE" } });
    try expectRoundTrip(.{ .request_part = .{ .id = std.math.maxInt(u64), .final = true, .bytes = "" } });
    try expectRoundTrip(.{ .answer_part = .{ .id = 7, .final = true, .bytes = "\x00" } });
}

test "messages follow one another in a stream" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try protocol.write(&writer, .{ .stream = 5 });
    try protocol.write(&writer, .{ .change_set_part = .{ .lsn = 5, .final = true, .bytes = "abc" } });
    try protocol.write(&writer, .{ .heartbeat = 5 });
    var rest = writer.buffered();
    const first = (try protocol.decode(rest)).?;
    try testing.expectEqual(@as(u64, 5), first.message.stream);
    rest = rest[first.length..];
    const second = (try protocol.decode(rest)).?;
    try testing.expectEqualStrings("abc", second.message.change_set_part.bytes);
    try testing.expectEqual(@as(u64, 5), (try decodeWhole(rest[second.length..])).heartbeat);
}

test "a part of the largest size reads back" {
    const part = try testing.allocator.alloc(u8, protocol.part_bytes);
    defer testing.allocator.free(part);
    @memset(part, 0x5a);
    const buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(buffer);
    const frame = try encode(buffer, .{ .change_set_part = .{ .lsn = 1, .final = true, .bytes = part } });
    try testing.expectEqualSlices(u8, part, (try decodeWhole(frame)).change_set_part.bytes);
}

test "a truncated frame is not whole yet" {
    var buffer: [256]u8 = undefined;
    const frame = try encode(&buffer, .{ .ack = 7 });
    for (0..frame.len) |length| try testing.expectEqual(@as(?protocol.Decoded, null), try protocol.decode(frame[0..length]));
}

/// A frame of `kind` around `payload`, its checksum right.
fn forge(buffer: []u8, kind: u8, payload: []const u8) []u8 {
    var crc = std.hash.Crc32.init();
    crc.update(&.{kind});
    crc.update(payload);
    buffer[0] = kind;
    std.mem.writeInt(u32, buffer[1..5], @intCast(payload.len), .big);
    std.mem.writeInt(u32, buffer[5..9], crc.final(), .big);
    @memcpy(buffer[9..][0..payload.len], payload);
    return buffer[0 .. 9 + payload.len];
}

fn expectMalformed(kind: u8, payload: []const u8) !void {
    var buffer: [256]u8 = undefined;
    try testing.expectError(error.MalformedFrame, protocol.decode(forge(&buffer, kind, payload)));
}

test "a frame with a right checksum but a wrong payload is malformed" {
    try expectMalformed(0, "");
    try expectMalformed(13, "");
    try expectMalformed(@backingInt(protocol.Kind.writer_ready), "\x00");
    try expectMalformed(@backingInt(protocol.Kind.request_part), "\x00\x00\x00\x00\x00\x00\x00\x01\x02");
    try expectMalformed(@backingInt(protocol.Kind.answer_part), "\x00\x00\x00\x00\x00\x00\x00\x01");
    try expectMalformed(@backingInt(protocol.Kind.writer_hello), "ZYPQ");
    // A writer hello whose name runs past the payload.
    const any_id: [16]u8 = @splat(0);
    try expectMalformed(@backingInt(protocol.Kind.writer_hello), "ZYPR" ++ "\x00\x01" ++ any_id ++ "\x00\x01a" ++ "\x05abc");
    try expectMalformed(@backingInt(protocol.Kind.ack), "\x00\x00\x00\x00\x00\x00\x00");
    try expectMalformed(@backingInt(protocol.Kind.ack), "\x00\x00\x00\x00\x00\x00\x00\x07\x00");
    try expectMalformed(@backingInt(protocol.Kind.change_set_part), "\x00\x00\x00\x00\x00\x00\x00\x01\x02");
    try expectMalformed(@backingInt(protocol.Kind.hello), "ZYPQ");
    // A hello whose token length runs past the payload.
    const no_id: [16]u8 = @splat(0);
    const no_lsn: [8]u8 = @splat(0);
    try expectMalformed(@backingInt(protocol.Kind.hello), "ZYPR" ++ "\x00\x01" ++ "\x00\x00\x00\x01" ++ "\x04lmdb" ++ "\x00" ++ no_id ++ no_lsn ++ "\x00\x09abc");
    // One whose name is missing, or runs past it.
    try expectMalformed(@backingInt(protocol.Kind.hello), "ZYPR" ++ "\x00\x01" ++ "\x00\x00\x00\x01" ++ "\x04lmdb" ++ "\x00" ++ no_id ++ no_lsn ++ "\x00\x03abc");
    try expectMalformed(@backingInt(protocol.Kind.hello), "ZYPR" ++ "\x00\x01" ++ "\x00\x00\x00\x01" ++ "\x04lmdb" ++ "\x00" ++ no_id ++ no_lsn ++ "\x00\x03abc" ++ "\x05host");
}

test "tokens match only when equal" {
    try testing.expect(protocol.tokensMatch("secret", "secret"));
    try testing.expect(protocol.tokensMatch("", ""));
    try testing.expect(!protocol.tokensMatch("secret", "secreT"));
    try testing.expect(!protocol.tokensMatch("secret", "secret "));
    try testing.expect(!protocol.tokensMatch("", "secret"));
}

/// Frames of every kind, one after another, as `write` writes them.
fn encodeSequence(buffer: []u8) ![]u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (sequence) |message| try protocol.write(&writer, message);
    return writer.buffered();
}

const sequence = [_]Message{
    .{ .hello = .{ .storage_format = 1, .storage_engine = "lmdb", .database_id = @splat(0xab), .applied_lsn = 42, .token = "secret", .name = "host" } },
    .{ .refused = .ahead },
    .{ .stream = 43 },
    .{ .snapshot_part = "the bytes of a copy" },
    .{ .snapshot_end = 1 << 40 },
    .{ .change_set_part = .{ .lsn = 9, .final = false, .bytes = "\x01\x00" } },
    .{ .change_set_part = .{ .lsn = 9, .final = true, .bytes = "" } },
    .{ .heartbeat = 100 },
    .{ .ack = 99 },
    .{ .writer_hello = .{ .database_id = @splat(0xcd), .token = "secret", .name = "edge-3" } },
    .writer_ready,
    .{ .request_part = .{ .id = 3, .final = false, .bytes = "MERGE" } },
    .{ .request_part = .{ .id = 3, .final = true, .bytes = "" } },
    .{ .answer_part = .{ .id = 3, .final = true, .bytes = "\x01" } },
};

/// Feeds `frames` to an inbox in pieces of `piece` bytes (the last one
/// shorter) and expects `sequence` out, in order, each message as soon as
/// its last byte is in.
fn expectSequenceInPieces(frames: []const u8, piece: usize) !void {
    const buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(buffer);
    var inbox: protocol.Inbox = .init(buffer);
    var taken: usize = 0;
    var fed: usize = 0;
    var frame_end: usize = 0;
    while (fed < frames.len) {
        const count = @min(piece, frames.len - fed);
        @memcpy(inbox.unfilled()[0..count], frames[fed..][0..count]);
        inbox.filled(count);
        fed += count;
        while (try inbox.next()) |message| {
            try testing.expectEqualDeep(sequence[taken], message);
            frame_end += protocol.frameLength(sequence[taken]);
            try testing.expect(frame_end <= fed and frame_end > fed - count);
            taken += 1;
        }
    }
    try testing.expectEqual(sequence.len, taken);
}

test "an inbox returns each message once its last byte is in, whatever the pieces" {
    var buffer: [1024]u8 = undefined;
    const frames = try encodeSequence(&buffer);
    for (1..frames.len + 1) |piece| try expectSequenceInPieces(frames, piece);
}

test "frameLength is what write writes" {
    var buffer: [1024]u8 = undefined;
    for (sequence) |message| try testing.expectEqual((try encode(&buffer, message)).len, protocol.frameLength(message));
}

test "an inbox takes a frame of the largest size" {
    const part = try testing.allocator.alloc(u8, protocol.part_bytes);
    defer testing.allocator.free(part);
    @memset(part, 0x5a);
    const frame_buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(frame_buffer);
    const buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(buffer);
    var inbox: protocol.Inbox = .init(buffer);
    // A small frame first, so the large one starts past the front.
    const small = try encode(frame_buffer, .{ .ack = 1 });
    @memcpy(inbox.unfilled()[0..small.len], small);
    inbox.filled(small.len);
    try testing.expectEqual(@as(u64, 1), (try inbox.next()).?.ack);
    const frame = try encode(frame_buffer, .{ .snapshot_part = part[0 .. protocol.part_bytes - 1] });
    try testing.expectEqual(@as(?Message, null), try inbox.next());
    const unfilled = inbox.unfilled();
    try testing.expect(unfilled.len >= frame.len);
    @memcpy(unfilled[0..frame.len], frame);
    inbox.filled(frame.len);
    try testing.expectEqualSlices(u8, part[0 .. protocol.part_bytes - 1], (try inbox.next()).?.snapshot_part);
    try testing.expectEqual(@as(?Message, null), try inbox.next());
}

test "decode refuses a frame longer than any message as soon as its header is in" {
    var header: [9]u8 = undefined;
    header[0] = @backingInt(protocol.Kind.snapshot_part);
    std.mem.writeInt(u32, header[1..5], @intCast(protocol.max_payload_bytes + 1), .big);
    std.mem.writeInt(u32, header[5..9], 0, .big);
    for (0..header.len) |length| try testing.expectEqual(@as(?protocol.Decoded, null), try protocol.decode(header[0..length]));
    try testing.expectError(error.MalformedFrame, protocol.decode(&header));
}

test "decode catches a flipped bit anywhere in a frame" {
    var buffer: [256]u8 = undefined;
    const frame = try encode(&buffer, .{ .change_set_part = .{ .lsn = 3, .final = true, .bytes = "\x01\x00\x00\x00\x00\x01k\x00\x00\x00\x01v" } });
    var damaged: [256]u8 = undefined;
    for (0..frame.len * 8) |bit| {
        @memcpy(damaged[0..frame.len], frame);
        damaged[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        // A flip in the length may make the frame look longer: not whole yet.
        if (protocol.decode(damaged[0..frame.len])) |decoded| {
            if (decoded != null) {
                std.debug.print("bit {d} flipped, decoded {any}\n", .{ bit, decoded });
                return error.TestUnexpectedResult;
            }
        } else |_| {}
    }
}

test "an outbox sends whole frames, in order, whatever the pieces taken" {
    const buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(buffer);
    var outbox: protocol.Outbox = .init(buffer);
    var expected_buffer: [1024]u8 = undefined;
    const expected = try encodeSequence(&expected_buffer);
    var taken: [1024]u8 = undefined;
    var taken_length: usize = 0;
    // Three bytes at a time, putting each message once the previous one
    // is half sent.
    for (sequence) |message| {
        try testing.expect(outbox.fits(message));
        outbox.put(message);
        while (outbox.unsent().len > protocol.frameLength(message) / 2) {
            const count = @min(3, outbox.unsent().len);
            @memcpy(taken[taken_length..][0..count], outbox.unsent()[0..count]);
            taken_length += count;
            outbox.sent(count);
        }
    }
    const rest = outbox.unsent();
    @memcpy(taken[taken_length..][0..rest.len], rest);
    taken_length += rest.len;
    outbox.sent(rest.len);
    try testing.expect(outbox.isEmpty());
    try testing.expectEqualSlices(u8, expected, taken[0..taken_length]);
}

test "an outbox refuses a frame that does not fit until enough is sent" {
    const part = try testing.allocator.alloc(u8, protocol.part_bytes);
    defer testing.allocator.free(part);
    @memset(part, 0x5a);
    const buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(buffer);
    var outbox: protocol.Outbox = .init(buffer);
    outbox.put(.{ .ack = 1 });
    const large: Message = .{ .snapshot_part = part };
    try testing.expect(!outbox.fits(large));
    outbox.sent(1);
    try testing.expect(!outbox.fits(large));
    outbox.sent(outbox.unsent().len);
    try testing.expect(outbox.fits(large));
    outbox.put(large);
    try testing.expectEqualSlices(u8, part, (try decodeWhole(outbox.unsent())).snapshot_part);
}
