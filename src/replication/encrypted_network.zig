//! A network whose connections are encrypted and authenticated, over any
//! other (`Tcp`, a simulation's): what network.zig promises, on top of a
//! Noise handshake (noise.zig) keyed by the token. The token never travels:
//! a side that does not hold it gets no further than the handshake. Those
//! above send and receive plain bytes, and nothing but the two sides can
//! read them or change them unnoticed.
//!
//! The handshake's two messages are `protocol.Kind.handshake` frames, so a
//! side that does not encrypt can tell what it was sent and refuse it. After
//! them each direction is a run of records, each a Noise message of at most
//! `max_record_payload_bytes` and its tag:
//!
//!     length of what follows (u16, big-endian) | encrypted bytes | tag
//!
//! A master that turns a connection away before there are keys says why in
//! a `refused` frame in clear (there is nothing to encrypt it with), given
//! to the replica as received, so it reads like any other refusal. Anyone
//! who can write to the connection can forge that frame, as they can cut the
//! connection: so only the reasons `Refusal.beforeKeys` are believed, and a
//! replica asks again after them. Everything after the handshake is
//! authenticated, and a record that fails to decrypt ends the connection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const X25519 = std.crypto.dh.X25519;

const noise = @import("noise.zig");
const protocol = @import("protocol.zig");
const network_module = @import("network.zig");
const Error = network_module.Error;
const Connection = network_module.Connection;
const Listener = network_module.Listener;
const Wakeup = network_module.Wakeup;
const Readiness = network_module.Readiness;
const Watched = network_module.Watched;
const Network = network_module.Network;

/// Bound into the handshake: it fails with anything but this protocol.
const prologue = "ZypherDB replication";

const length_bytes = 2;

/// The most plain bytes a record holds. Nothing of a record can be told until
/// all of it is in, and the one above only knows the other end is alive once
/// something is: a long record would look like silence on a slow link.
const max_record_payload_bytes = 16 << 10;

const max_record_bytes = length_bytes + max_record_payload_bytes + noise.tag_bytes;

comptime {
    std.debug.assert(max_record_payload_bytes + noise.tag_bytes <= noise.max_message_bytes);
}

/// What a connection holds each way: some records, so a socket with little
/// room does not cut the rate to one record a wait.
const buffer_bytes = 4 * max_record_bytes;

pub const EncryptedNetwork = struct {
    inner: Network,
    allocator: Allocator,
    /// Where the keys of each handshake come from.
    random: std.Random,
    pre_shared_key: [noise.key_bytes]u8,

    /// A network over `inner`. Any side with the same `token` gets through
    /// a handshake. Noise wants a key of a fixed size, and a token is any
    /// string: its hash is the key, so a token must be hard to guess (an
    /// eavesdropper can try guesses against a recorded handshake).
    pub fn init(inner: Network, allocator: Allocator, random: std.Random, token: []const u8) EncryptedNetwork {
        var pre_shared_key: [noise.key_bytes]u8 = undefined;
        Sha256.hash(token, &pre_shared_key, .{});
        return .{ .inner = inner, .allocator = allocator, .random = random, .pre_shared_key = pre_shared_key };
    }

    pub fn network(self: *EncryptedNetwork) Network {
        return .{ .context = self, .vtable = &.{ .listen = listen, .connect = connect, .wakeup = wakeup, .wait = wait } };
    }

    fn listen(context: *anyopaque, address: []const u8) Error!Listener {
        const self: *EncryptedNetwork = @ptrCast(@alignCast(context));
        const inner = try self.inner.listen(address);
        errdefer inner.close();
        const listener = self.allocator.create(EncryptedListener) catch return error.OutOfMemory;
        listener.* = .{ .owner = self, .inner = inner };
        return listener.listener();
    }

    fn connect(context: *anyopaque, address: []const u8) Error!Connection {
        const self: *EncryptedNetwork = @ptrCast(@alignCast(context));
        const inner = try self.inner.connect(address);
        errdefer inner.close();
        const connection = try EncryptedConnection.create(self, inner, .awaiting_answer);
        connection.queueHandshake();
        return connection.connection();
    }

    fn wakeup(context: *anyopaque) Error!Wakeup {
        const self: *EncryptedNetwork = @ptrCast(@alignCast(context));
        return self.inner.wakeup();
    }

    fn wait(context: *anyopaque, watched: []Watched, timeout_ns: ?u64) Error!void {
        const self: *EncryptedNetwork = @ptrCast(@alignCast(context));
        var inner: [network_module.max_watched]Watched = undefined;
        var timeout = timeout_ns;
        for (watched, inner[0..watched.len]) |one, *below| switch (one.source) {
            .connection => |connection| {
                const encrypted = EncryptedConnection.of(connection);
                encrypted.advance();
                if (encrypted.readiness(one.wanted).any()) timeout = 0;
                below.* = .{ .source = .{ .connection = encrypted.inner }, .wanted = encrypted.wantedBelow(one.wanted) };
            },
            .listener => |listener| below.* = .{ .source = .{ .listener = EncryptedListener.of(listener).inner }, .wanted = one.wanted },
            .wakeup => below.* = one,
        };
        try self.inner.wait(inner[0..watched.len], timeout);
        for (watched, inner[0..watched.len]) |*one, below| switch (one.source) {
            .connection => |connection| {
                const encrypted = EncryptedConnection.of(connection);
                if (below.ready.writable) encrypted.flush();
                if (below.ready.readable) encrypted.pull();
                encrypted.advance();
                one.ready = encrypted.readiness(one.wanted);
            },
            .listener, .wakeup => one.ready = below.ready,
        };
    }
};

const EncryptedListener = struct {
    owner: *EncryptedNetwork,
    inner: Listener,

    const vtable: Listener.VTable = .{ .accept = accept, .address = address, .close = close };

    fn listener(self: *EncryptedListener) Listener {
        return .{ .context = self, .vtable = &vtable };
    }

    fn of(one: Listener) *EncryptedListener {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    fn accept(context: *anyopaque) Error!?Connection {
        const self: *EncryptedListener = @ptrCast(@alignCast(context));
        const inner = try self.inner.accept() orelse return null;
        errdefer inner.close();
        const connection = try EncryptedConnection.create(self.owner, inner, .awaiting_first);
        return connection.connection();
    }

    fn address(context: *anyopaque, buffer: *[network_module.max_address_bytes]u8) []const u8 {
        const self: *EncryptedListener = @ptrCast(@alignCast(context));
        return self.inner.address(buffer);
    }

    fn close(context: *anyopaque) void {
        const self: *EncryptedListener = @ptrCast(@alignCast(context));
        self.inner.close();
        self.owner.allocator.destroy(self);
    }
};

const EncryptedConnection = struct {
    owner: *EncryptedNetwork,
    inner: Connection,
    state: State,
    handshake: noise.Handshake,
    keys: noise.Keys,
    /// The other end is gone, or sent what cannot be believed: nothing more
    /// goes out or comes in, once what `plain` holds is taken.
    broken: bool = false,
    /// Bytes received: `input[input_start..input_end]` not looked at yet,
    /// `input[plain_start..plain_end]` (before them) decrypted, not taken.
    input: [buffer_bytes]u8 = undefined,
    input_start: usize = 0,
    input_end: usize = 0,
    plain_start: usize = 0,
    plain_end: usize = 0,
    /// Bytes to send: `output[output_start..output_end]`.
    output: [buffer_bytes]u8 = undefined,
    output_start: usize = 0,
    output_end: usize = 0,

    const State = enum {
        /// A listener's: the initiator's message comes first.
        awaiting_first,
        /// A connecting side's: its message is on its way.
        awaiting_answer,
        established,
        /// The handshake ended it: a refusal goes out (or has come in, to
        /// be taken), then it is closed.
        turned_away,
    };

    const vtable: Connection.VTable = .{ .receive = receive, .send = send, .close = close, .peer = peer };

    fn create(owner: *EncryptedNetwork, inner: Connection, state: State) Error!*EncryptedConnection {
        const self = owner.allocator.create(EncryptedConnection) catch return error.OutOfMemory;
        var seed: [X25519.seed_length]u8 = undefined;
        owner.random.bytes(&seed);
        defer std.crypto.secureZero(u8, &seed);
        self.owner = owner;
        self.inner = inner;
        self.state = state;
        self.handshake = noise.Handshake.init(prologue, &owner.pre_shared_key, seed);
        self.keys = undefined;
        self.broken = false;
        self.input_start = 0;
        self.input_end = 0;
        self.plain_start = 0;
        self.plain_end = 0;
        self.output_start = 0;
        self.output_end = 0;
        return self;
    }

    fn connection(self: *EncryptedConnection) Connection {
        return .{ .context = self, .vtable = &vtable };
    }

    fn of(one: Connection) *EncryptedConnection {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    /// The initiator's message goes out once connected.
    fn queueHandshake(self: *EncryptedConnection) void {
        var message: [noise.handshake_message_bytes]u8 = undefined;
        _ = self.handshake.writeFirst("", &message);
        self.queueFrame(.{ .handshake = &message });
    }

    fn queueFrame(self: *EncryptedConnection, message: protocol.Message) void {
        var writer: std.Io.Writer = .fixed(self.output[self.output_end..]);
        protocol.write(&writer, message) catch unreachable;
        self.output_end += writer.end;
    }

    /// Sends what it can.
    fn flush(self: *EncryptedConnection) void {
        while (!self.broken and self.output_start < self.output_end) {
            const count = self.inner.send(self.output[self.output_start..self.output_end]) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Closed => {
                    self.broken = true;
                    return;
                },
            };
            self.output_start += count;
        }
        if (self.output_start == self.output_end) {
            self.output_start = 0;
            self.output_end = 0;
        }
    }

    /// Takes in what it can hold of what was received.
    fn pull(self: *EncryptedConnection) void {
        if (self.broken) return;
        // What is decrypted and not taken stays where it is.
        if (self.plain_start == self.plain_end) {
            std.mem.copyForwards(u8, &self.input, self.input[self.input_start..self.input_end]);
            self.input_end -= self.input_start;
            self.input_start = 0;
            self.plain_start = 0;
            self.plain_end = 0;
        }
        if (self.input_end == self.input.len) return;
        const count = self.inner.receive(self.input[self.input_end..]) catch |err| switch (err) {
            error.WouldBlock => return,
            error.Closed => {
                self.broken = true;
                return;
            },
        };
        self.input_end += count;
    }

    /// Sends what is waiting, and goes on with the handshake and the next
    /// record as far as what was received allows.
    fn advance(self: *EncryptedConnection) void {
        self.flush();
        self.goOnWithHandshake();
        self.flush();
        self.decryptNext();
    }

    fn goOnWithHandshake(self: *EncryptedConnection) void {
        const received = self.input[self.input_start..self.input_end];
        if (received.len == 0) return;
        switch (self.state) {
            .awaiting_first => {
                if (received[0] != @backingInt(protocol.Kind.handshake)) return self.turnAway(.encryption);
                const decoded = (protocol.decode(received) catch return self.turnAway(.token)) orelse return;
                self.input_start += decoded.length;
                var empty: [0]u8 = .{};
                self.handshake.readFirst(decoded.message.handshake, &empty) catch return self.turnAway(.token);
                var message: [noise.handshake_message_bytes]u8 = undefined;
                _ = self.handshake.writeSecond("", &message, &self.keys) catch return self.turnAway(.token);
                self.queueFrame(.{ .handshake = &message });
                self.handshake.wipe();
                self.state = .established;
            },
            .awaiting_answer => {
                const decoded = (protocol.decode(received) catch {
                    self.broken = true;
                    return;
                }) orelse return;
                switch (decoded.message) {
                    .handshake => |message| {
                        var empty: [0]u8 = .{};
                        self.keys = self.handshake.readSecond(message, &empty) catch {
                            self.broken = true;
                            return;
                        };
                        self.input_start += decoded.length;
                        self.handshake.wipe();
                        self.state = .established;
                    },
                    // Taken as it came, by the session above. It may be
                    // forged, so it stops nothing for good.
                    .refused => |reason| {
                        if (!reason.beforeKeys()) {
                            self.broken = true;
                            return;
                        }
                        self.plain_start = self.input_start;
                        self.plain_end = self.input_start + decoded.length;
                        self.input_start = self.plain_end;
                        self.state = .turned_away;
                    },
                    else => self.broken = true,
                }
            },
            .established, .turned_away => {},
        }
    }

    /// No keys in common: tells why, and then is over.
    fn turnAway(self: *EncryptedConnection, reason: protocol.Refusal) void {
        self.input_start = self.input_end;
        self.state = .turned_away;
        self.queueFrame(.{ .refused = reason });
    }

    /// With nothing decrypted waiting, decrypts the next whole record in
    /// place. One that fails ends the connection: nothing of it is told.
    fn decryptNext(self: *EncryptedConnection) void {
        if (self.state != .established or self.plain_start != self.plain_end or self.broken) return;
        const received = self.input[self.input_start..self.input_end];
        if (received.len < length_bytes) return;
        const length: usize = std.mem.readInt(u16, received[0..length_bytes], .big);
        if (received.len < length_bytes + length) return;
        const message = received[length_bytes..][0..length];
        if (length < noise.tag_bytes) {
            self.broken = true;
            return;
        }
        const plain = message[0 .. length - noise.tag_bytes];
        self.keys.receiving.decrypt(plain, message, "") catch {
            self.broken = true;
            self.input_start = self.input_end;
            return;
        };
        self.plain_start = self.input_start + length_bytes;
        self.plain_end = self.plain_start + plain.len;
        self.input_start += length_bytes + length;
    }

    fn wantedBelow(self: *const EncryptedConnection, wanted: Readiness) Readiness {
        if (self.broken) return .{};
        return .{
            .readable = self.state != .turned_away and self.input_end - self.input_start < buffer_bytes and
                (self.state != .established or wanted.readable),
            .writable = self.output_start < self.output_end,
        };
    }

    /// Over: nothing else will come in or go out.
    fn over(self: *const EncryptedConnection) bool {
        if (self.plain_start != self.plain_end) return false;
        return self.broken or (self.state == .turned_away and self.output_start == self.output_end);
    }

    fn hasRoomForARecord(self: *const EncryptedConnection) bool {
        return self.output_end - self.output_start <= buffer_bytes - max_record_bytes;
    }

    fn readiness(self: *const EncryptedConnection, wanted: Readiness) Readiness {
        const over_now = self.over();
        return .{
            .readable = wanted.readable and (over_now or self.plain_start != self.plain_end),
            .writable = wanted.writable and (over_now or (self.state == .established and self.hasRoomForARecord())),
        };
    }

    fn receive(context: *anyopaque, buffer: []u8) error{ WouldBlock, Closed }!usize {
        const self: *EncryptedConnection = @ptrCast(@alignCast(context));
        var given: usize = 0;
        while (given < buffer.len) {
            if (self.plain_start == self.plain_end) {
                self.advance();
                if (self.plain_start == self.plain_end) self.pull();
                self.advance();
                if (self.plain_start == self.plain_end) break;
            }
            const count = @min(buffer.len - given, self.plain_end - self.plain_start);
            @memcpy(buffer[given..][0..count], self.input[self.plain_start..][0..count]);
            self.plain_start += count;
            given += count;
        }
        if (given > 0) return given;
        return if (self.over()) error.Closed else error.WouldBlock;
    }

    fn send(context: *anyopaque, bytes: []const u8) error{ WouldBlock, Closed }!usize {
        const self: *EncryptedConnection = @ptrCast(@alignCast(context));
        // Nothing can go until the handshake ends: its answer is looked for.
        if (self.state == .awaiting_answer or self.state == .awaiting_first) self.pull();
        self.advance();
        if (self.broken or self.state == .turned_away) return error.Closed;
        if (self.state != .established) return error.WouldBlock;
        var accepted: usize = 0;
        while (accepted < bytes.len and self.makeRoomForARecord()) {
            const payload = bytes[accepted..][0..@min(bytes.len - accepted, max_record_payload_bytes)];
            const length = payload.len + noise.tag_bytes;
            std.mem.writeInt(u16, self.output[self.output_end..][0..length_bytes], @intCast(length), .big);
            self.output_end += length_bytes;
            self.keys.sending.encrypt(self.output[self.output_end..][0..length], payload, "");
            self.output_end += length;
            accepted += payload.len;
        }
        self.flush();
        if (accepted > 0) return accepted;
        return if (self.broken) error.Closed else error.WouldBlock;
    }

    fn makeRoomForARecord(self: *EncryptedConnection) bool {
        if (buffer_bytes - self.output_end >= max_record_bytes) return true;
        if (!self.hasRoomForARecord()) return false;
        std.mem.copyForwards(u8, &self.output, self.output[self.output_start..self.output_end]);
        self.output_end -= self.output_start;
        self.output_start = 0;
        return true;
    }

    fn peer(context: *anyopaque, buffer: *[network_module.max_address_bytes]u8) []const u8 {
        const self: *EncryptedConnection = @ptrCast(@alignCast(context));
        return self.inner.peer(buffer);
    }

    fn close(context: *anyopaque) void {
        const self: *EncryptedConnection = @ptrCast(@alignCast(context));
        self.flush();
        self.inner.close();
        self.handshake.wipe();
        if (self.state == .established) {
            self.keys.sending.wipe();
            self.keys.receiving.wipe();
        }
        self.owner.allocator.destroy(self);
    }
};
