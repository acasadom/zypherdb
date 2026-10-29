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

fn expectRoundTrip(message: Message) !void {
    var buffer: [4096]u8 = undefined;
    const frame = try encode(&buffer, message);
    var reader: std.Io.Reader = .fixed(frame);
    const read = try protocol.read(&reader);
    try testing.expectEqualDeep(message, read);
    try testing.expectError(error.EndOfStream, protocol.read(&reader));
}

test "every message reads back as written" {
    try expectRoundTrip(.{ .hello = .{
        .storage_format = 1,
        .storage_engine = "lmdb",
        .database_id = @splat(0xab),
        .applied_lsn = 42,
        .token = "secret",
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
}

test "messages follow one another in a stream" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try protocol.write(&writer, .{ .stream = 5 });
    try protocol.write(&writer, .{ .change_set_part = .{ .lsn = 5, .final = true, .bytes = "abc" } });
    try protocol.write(&writer, .{ .heartbeat = 5 });
    var reader: std.Io.Reader = .fixed(writer.buffered());
    try testing.expectEqual(@as(u64, 5), (try protocol.read(&reader)).stream);
    try testing.expectEqualStrings("abc", (try protocol.read(&reader)).change_set_part.bytes);
    try testing.expectEqual(@as(u64, 5), (try protocol.read(&reader)).heartbeat);
}

test "a part of the largest size reads back" {
    const part = try testing.allocator.alloc(u8, protocol.part_bytes);
    defer testing.allocator.free(part);
    @memset(part, 0x5a);
    const buffer = try testing.allocator.alloc(u8, protocol.max_frame_bytes);
    defer testing.allocator.free(buffer);
    const frame = try encode(buffer, .{ .change_set_part = .{ .lsn = 1, .final = true, .bytes = part } });
    var reader: std.Io.Reader = .fixed(frame);
    try testing.expectEqualSlices(u8, part, (try protocol.read(&reader)).change_set_part.bytes);
}

test "a flipped bit anywhere in a frame is caught" {
    var buffer: [256]u8 = undefined;
    const frame = try encode(&buffer, .{ .change_set_part = .{ .lsn = 3, .final = true, .bytes = "\x01\x00\x00\x00\x00\x01k\x00\x00\x00\x01v" } });
    var damaged: [256]u8 = undefined;
    for (0..frame.len * 8) |bit| {
        @memcpy(damaged[0..frame.len], frame);
        damaged[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        var reader: std.Io.Reader = .fixed(damaged[0..frame.len]);
        if (protocol.read(&reader)) |message| {
            std.debug.print("bit {d} flipped, read {any}\n", .{ bit, message });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "a truncated frame is an end of stream" {
    var buffer: [256]u8 = undefined;
    const frame = try encode(&buffer, .{ .ack = 7 });
    for (0..frame.len) |length| {
        var reader: std.Io.Reader = .fixed(frame[0..length]);
        try testing.expectError(error.EndOfStream, protocol.read(&reader));
    }
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
    var reader: std.Io.Reader = .fixed(forge(&buffer, kind, payload));
    try testing.expectError(error.MalformedFrame, protocol.read(&reader));
}

test "a frame with a right checksum but a wrong payload is malformed" {
    try expectMalformed(0, "");
    try expectMalformed(9, "");
    try expectMalformed(@backingInt(protocol.Kind.ack), "\x00\x00\x00\x00\x00\x00\x00");
    try expectMalformed(@backingInt(protocol.Kind.ack), "\x00\x00\x00\x00\x00\x00\x00\x07\x00");
    try expectMalformed(@backingInt(protocol.Kind.change_set_part), "\x00\x00\x00\x00\x00\x00\x00\x01\x02");
    try expectMalformed(@backingInt(protocol.Kind.hello), "ZYPQ");
    // A hello whose token length runs past the payload.
    const no_id: [16]u8 = @splat(0);
    const no_lsn: [8]u8 = @splat(0);
    try expectMalformed(@backingInt(protocol.Kind.hello), "ZYPR" ++ "\x00\x01" ++ "\x00\x00\x00\x01" ++ "\x04lmdb" ++ "\x00" ++ no_id ++ no_lsn ++ "\x00\x09abc");
}

test "a frame longer than any message is refused before it is read" {
    var header: [9]u8 = undefined;
    header[0] = @backingInt(protocol.Kind.snapshot_part);
    std.mem.writeInt(u32, header[1..5], @intCast(protocol.max_payload_bytes + 1), .big);
    std.mem.writeInt(u32, header[5..9], 0, .big);
    var reader: std.Io.Reader = .fixed(&header);
    try testing.expectError(error.MalformedFrame, protocol.read(&reader));
}

test "tokens match only when equal" {
    try testing.expect(protocol.tokensMatch("secret", "secret"));
    try testing.expect(protocol.tokensMatch("", ""));
    try testing.expect(!protocol.tokensMatch("secret", "secreT"));
    try testing.expect(!protocol.tokensMatch("secret", "secret "));
    try testing.expect(!protocol.tokensMatch("", "secret"));
}
