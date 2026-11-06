//! Noise's NNpsk0 (replication/noise.zig) against a published test vector,
//! from the Cacophony vectors (see THIRD_PARTY_NOTICES.md): the handshake
//! and the transport messages after it, byte for byte, from both sides.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const noise = zypherdb.replication_noise;

fn bytesOf(comptime hex: []const u8) [hex.len / 2]u8 {
    var bytes: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;
    return bytes;
}

const prologue = bytesOf("4a6f686e2047616c74");
const pre_shared_key = bytesOf("54686973206973206d7920417573747269616e20706572737065637469766521");
const initiator_ephemeral = bytesOf("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a");
const responder_ephemeral = bytesOf("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b");
const handshake_hash = bytesOf("f4d03dc34495c95729ea6de9e1b59004b59733102488b3e24bc441e0be208eaf");

const first_payload = bytesOf("4c756477696720766f6e204d69736573");
const first_message = bytesOf("ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c794479b962b8aff8485742ac32f905ba45369e2465fb59e138a93d67a0d1266b6a54");
const second_payload = bytesOf("4d757272617920526f746862617264");
const second_message = bytesOf("95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843d6062704d5a9c422a8e834423f8c1feada7e8d0d910a1a2cd030fb584221e3");

const Transport = struct { payload: []const u8, message: []const u8 };

/// In turn: initiator, responder, initiator, responder.
const transports = [_]Transport{
    .{ .payload = &bytesOf("462e20412e20486179656b"), .message = &bytesOf("e632c3763d7669067383433197a3baddf146e9e70ad4b4e9e59e0f") },
    .{ .payload = &bytesOf("4361726c204d656e676572"), .message = &bytesOf("64c6bee32ea91c8474bb4c21d7a700109ad45af77b29764ba5eb1e") },
    .{ .payload = &bytesOf("4a65616e2d426170746973746520536179"), .message = &bytesOf("e2fa0bed0603b62d3ccac2ecabbf3fe33f3e86514909b323361626266cb2471cc8") },
    .{ .payload = &bytesOf("457567656e2042f6686d20766f6e2042617765726b"), .message = &bytesOf("0c01dc9cec1fe4ddd692e8dd32188aa351088dc91183639a53b57aa4692b5ebdef8b8ca111") },
};

fn handshakeOf(seed: [32]u8) noise.Handshake {
    return noise.Handshake.init(&prologue, &pre_shared_key, seed);
}

test "the handshake and the transport messages are the vector's, byte for byte" {
    var initiator = handshakeOf(initiator_ephemeral);
    var responder = handshakeOf(responder_ephemeral);
    var buffer: [256]u8 = undefined;
    var payload: [256]u8 = undefined;

    try testing.expectEqualSlices(u8, &first_message, initiator.writeFirst(&first_payload, &buffer));
    try responder.readFirst(&first_message, payload[0..first_payload.len]);
    try testing.expectEqualSlices(u8, &first_payload, payload[0..first_payload.len]);

    var responder_keys: noise.Keys = undefined;
    try testing.expectEqualSlices(u8, &second_message, try responder.writeSecond(&second_payload, &buffer, &responder_keys));
    var initiator_keys = try initiator.readSecond(&second_message, payload[0..second_payload.len]);
    try testing.expectEqualSlices(u8, &second_payload, payload[0..second_payload.len]);

    try testing.expectEqualSlices(u8, &handshake_hash, &initiator_keys.handshake_hash);
    try testing.expectEqualSlices(u8, &handshake_hash, &responder_keys.handshake_hash);

    for (transports, 0..) |transport, index| {
        const writer = if (index % 2 == 0) &initiator_keys else &responder_keys;
        const reader = if (index % 2 == 0) &responder_keys else &initiator_keys;
        writer.sending.encrypt(buffer[0..transport.message.len], transport.payload, "");
        try testing.expectEqualSlices(u8, transport.message, buffer[0..transport.message.len]);
        try reader.receiving.decrypt(payload[0..transport.payload.len], transport.message, "");
        try testing.expectEqualSlices(u8, transport.payload, payload[0..transport.payload.len]);
    }
}

test "a responder with another key, or another prologue, fails on the first message" {
    var initiator = handshakeOf(initiator_ephemeral);
    var buffer: [noise.handshake_message_bytes]u8 = undefined;
    const message = initiator.writeFirst("", &buffer);
    var empty: [0]u8 = .{};

    var other_key: [noise.key_bytes]u8 = pre_shared_key;
    other_key[0] ^= 1;
    var with_other_key = noise.Handshake.init(&prologue, &other_key, responder_ephemeral);
    try testing.expectError(error.AuthenticationFailed, with_other_key.readFirst(message, &empty));

    var with_other_prologue = noise.Handshake.init("another", &pre_shared_key, responder_ephemeral);
    try testing.expectError(error.AuthenticationFailed, with_other_prologue.readFirst(message, &empty));
}

test "a changed bit in a handshake message, or a message that is too short, fails" {
    var initiator = handshakeOf(initiator_ephemeral);
    var responder = handshakeOf(responder_ephemeral);
    var buffer: [noise.handshake_message_bytes]u8 = undefined;
    const first = initiator.writeFirst("", &buffer);
    var empty: [0]u8 = .{};
    try testing.expectError(error.AuthenticationFailed, responder.readFirst(first[0 .. first.len - 1], &empty));
    for ([_]usize{ 0, first.len - 1 }) |position| {
        var changed = handshakeOf(responder_ephemeral);
        var bad = buffer;
        bad[position] ^= 1;
        try testing.expectError(error.AuthenticationFailed, changed.readFirst(&bad, &empty));
    }
}

test "a transport message read twice, or out of its turn, fails" {
    var cipher: noise.Cipher = .{ .key = pre_shared_key };
    var reader: noise.Cipher = .{ .key = pre_shared_key };
    var first: [16 + 3]u8 = undefined;
    var second: [16 + 3]u8 = undefined;
    cipher.encrypt(&first, "one", "");
    cipher.encrypt(&second, "two", "");
    var plain: [3]u8 = undefined;
    try reader.decrypt(&plain, &first, "");
    try testing.expectError(error.AuthenticationFailed, reader.decrypt(&plain, &first, ""));
    var out_of_turn: noise.Cipher = .{ .key = pre_shared_key };
    try testing.expectError(error.AuthenticationFailed, out_of_turn.decrypt(&plain, &second, ""));
}
