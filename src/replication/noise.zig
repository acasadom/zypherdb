//! The Noise protocol's `NNpsk0` pattern (noiseprotocol.org, revision 34)
//! with X25519, ChaCha20-Poly1305 and SHA-256, on bytes in memory:
//!
//!     -> psk, e
//!     <- e, ee
//!
//! Both sides hold a pre-shared key and make a fresh key pair for each
//! connection. No key travels; only a side holding the same pre-shared key
//! gets through a handshake, and what a connection sent stays secret even
//! if the pre-shared key is learned later. tests/replication/noise_test.zig
//! checks it against a published test vector.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const X25519 = std.crypto.dh.X25519;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const protocol_name = "Noise_NNpsk0_25519_ChaChaPoly_SHA256";

pub const key_bytes = 32;
pub const public_key_bytes = X25519.public_length;
pub const tag_bytes = Aead.tag_length;
pub const hash_bytes = Sha256.digest_length;

/// The largest message Noise allows.
pub const max_message_bytes: usize = 65535;

/// A handshake message with an empty payload.
pub const handshake_message_bytes = public_key_bytes + tag_bytes;

pub const Error = error{AuthenticationFailed};

/// One direction of a conversation: each message under the next nonce, so a
/// message lost, repeated or moved fails to decrypt.
pub const Cipher = struct {
    key: [key_bytes]u8,
    nonce: u64 = 0,

    /// Writes `plain` encrypted to `out`, `tag_bytes` longer. They may be
    /// the same bytes.
    pub fn encrypt(self: *Cipher, out: []u8, plain: []const u8, associated: []const u8) void {
        std.debug.assert(out.len == plain.len + tag_bytes);
        Aead.encrypt(out[0..plain.len], out[plain.len..][0..tag_bytes], plain, associated, self.nextNonce(), self.key);
    }

    /// Writes `message` decrypted to `out`, `tag_bytes` shorter. They may be
    /// the same bytes.
    pub fn decrypt(self: *Cipher, out: []u8, message: []const u8, associated: []const u8) Error!void {
        if (message.len < tag_bytes or out.len != message.len - tag_bytes) return error.AuthenticationFailed;
        const tag = message[out.len..][0..tag_bytes].*;
        Aead.decrypt(out, message[0..out.len], tag, associated, self.nextNonce(), self.key) catch return error.AuthenticationFailed;
    }

    /// Forgets the key.
    pub fn wipe(self: *Cipher) void {
        std.crypto.secureZero(u8, &self.key);
    }

    fn nextNonce(self: *Cipher) [Aead.nonce_length]u8 {
        // 2^64 - 1 is reserved; no connection sends that many.
        std.debug.assert(self.nonce != std.math.maxInt(u64));
        var bytes: [Aead.nonce_length]u8 = @splat(0);
        std.mem.writeInt(u64, bytes[4..12], self.nonce, .little);
        self.nonce += 1;
        return bytes;
    }
};

/// What a finished handshake leaves.
pub const Keys = struct {
    sending: Cipher,
    receiving: Cipher,
    /// Names this conversation: the same on both sides.
    handshake_hash: [hash_bytes]u8,
};

/// A handshake in progress: the initiator calls `writeFirst`, then
/// `readSecond`; the responder `readFirst`, then `writeSecond`.
pub const Handshake = struct {
    chaining_key: [hash_bytes]u8,
    hash: [hash_bytes]u8,
    cipher: Cipher,
    ephemeral: X25519.KeyPair,
    remote_ephemeral: [public_key_bytes]u8 = undefined,

    /// `ephemeral_seed` is 32 random bytes, of this handshake only.
    pub fn init(prologue: []const u8, pre_shared_key: *const [key_bytes]u8, ephemeral_seed: [X25519.seed_length]u8) Handshake {
        var hash: [hash_bytes]u8 = undefined;
        Sha256.hash(protocol_name, &hash, .{});
        var self: Handshake = .{
            .chaining_key = hash,
            .hash = hash,
            .cipher = .{ .key = undefined },
            .ephemeral = X25519.KeyPair.generateDeterministic(ephemeral_seed),
        };
        self.mixHash(prologue);
        self.mixKeyAndHash(pre_shared_key);
        return self;
    }

    /// Writes `-> psk, e` with `payload` to `out`; returns its bytes.
    pub fn writeFirst(self: *Handshake, payload: []const u8, out: []u8) []u8 {
        return self.writeEphemeralAndPayload(payload, out, false) catch unreachable;
    }

    /// Reads `-> psk, e`, its payload to `payload_out` (the message's bytes
    /// less `handshake_message_bytes`). Fails if the pre-shared keys differ.
    pub fn readFirst(self: *Handshake, message: []const u8, payload_out: []u8) Error!void {
        return self.readEphemeralAndPayload(message, payload_out, false);
    }

    /// Writes `<- e, ee` with `payload` to `out`; returns its bytes.
    /// `result` is the conversation's keys.
    pub fn writeSecond(self: *Handshake, payload: []const u8, out: []u8, result: *Keys) Error![]u8 {
        const written = try self.writeEphemeralAndPayload(payload, out, true);
        result.* = self.split(.responder);
        return written;
    }

    /// Reads `<- e, ee`, its payload to `payload_out`; returns the
    /// conversation's keys.
    pub fn readSecond(self: *Handshake, message: []const u8, payload_out: []u8) Error!Keys {
        try self.readEphemeralAndPayload(message, payload_out, true);
        return self.split(.initiator);
    }

    /// Forgets its secrets.
    pub fn wipe(self: *Handshake) void {
        std.crypto.secureZero(u8, &self.chaining_key);
        std.crypto.secureZero(u8, &self.ephemeral.secret_key);
        self.cipher.wipe();
    }

    fn writeEphemeralAndPayload(self: *Handshake, payload: []const u8, out: []u8, mix_shared_secret: bool) Error![]u8 {
        const length = handshake_message_bytes + payload.len;
        std.debug.assert(out.len >= length);
        out[0..public_key_bytes].* = self.ephemeral.public_key;
        self.mixEphemeral(&self.ephemeral.public_key);
        if (mix_shared_secret) try self.mixSharedSecret();
        const encrypted = out[public_key_bytes..length];
        self.cipher.encrypt(encrypted, payload, &self.hash);
        self.mixHash(encrypted);
        return out[0..length];
    }

    fn readEphemeralAndPayload(self: *Handshake, message: []const u8, payload_out: []u8, mix_shared_secret: bool) Error!void {
        if (message.len < handshake_message_bytes) return error.AuthenticationFailed;
        self.remote_ephemeral = message[0..public_key_bytes].*;
        self.mixEphemeral(&self.remote_ephemeral);
        if (mix_shared_secret) try self.mixSharedSecret();
        const encrypted = message[public_key_bytes..];
        try self.cipher.decrypt(payload_out, encrypted, &self.hash);
        self.mixHash(encrypted);
    }

    /// An `e` token in a pattern with a pre-shared key mixes it as a key too.
    fn mixEphemeral(self: *Handshake, public_key: *const [public_key_bytes]u8) void {
        self.mixHash(public_key);
        self.mixKey(public_key);
    }

    /// The `ee` token.
    fn mixSharedSecret(self: *Handshake) Error!void {
        var shared = X25519.scalarmult(self.ephemeral.secret_key, self.remote_ephemeral) catch return error.AuthenticationFailed;
        defer std.crypto.secureZero(u8, &shared);
        self.mixKey(&shared);
    }

    fn mixHash(self: *Handshake, data: []const u8) void {
        var hasher = Sha256.init(.{});
        hasher.update(&self.hash);
        hasher.update(data);
        hasher.final(&self.hash);
    }

    fn mixKey(self: *Handshake, material: []const u8) void {
        const outputs = hkdf(&self.chaining_key, material);
        self.chaining_key = outputs[0];
        self.cipher = .{ .key = outputs[1] };
    }

    fn mixKeyAndHash(self: *Handshake, material: []const u8) void {
        const outputs = hkdf(&self.chaining_key, material);
        self.chaining_key = outputs[0];
        self.mixHash(&outputs[1]);
        self.cipher = .{ .key = outputs[2] };
    }

    fn split(self: *Handshake, side: enum { initiator, responder }) Keys {
        const outputs = hkdf(&self.chaining_key, "");
        const from_initiator: Cipher = .{ .key = outputs[0] };
        const from_responder: Cipher = .{ .key = outputs[1] };
        return .{
            .sending = if (side == .initiator) from_initiator else from_responder,
            .receiving = if (side == .initiator) from_responder else from_initiator,
            .handshake_hash = self.hash,
        };
    }
};

/// Noise's HKDF, with its three outputs (a caller uses those it asks for).
fn hkdf(chaining_key: *const [hash_bytes]u8, material: []const u8) [3][hash_bytes]u8 {
    var temporary: [hash_bytes]u8 = undefined;
    HmacSha256.create(&temporary, material, chaining_key);
    defer std.crypto.secureZero(u8, &temporary);
    var outputs: [3][hash_bytes]u8 = undefined;
    HmacSha256.create(&outputs[0], &.{1}, &temporary);
    var input: [hash_bytes + 1]u8 = undefined;
    for (1..outputs.len) |index| {
        input[0..hash_bytes].* = outputs[index - 1];
        input[hash_bytes] = @intCast(index + 1);
        HmacSha256.create(&outputs[index], &input, &temporary);
    }
    return outputs;
}
