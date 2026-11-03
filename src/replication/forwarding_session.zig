//! A replica's conversation with its master over the connection for
//! forwarded writes (protocol.zig), as a state machine with no I/O of its
//! own, the other side of writer_session.zig. The conversation opens with
//! the `writer_hello` waiting in the outbox; once the master is `ready`,
//! `request` hands over a request's bytes, `pump` sends them in parts and
//! `next` joins each answer's. Up to `protocol.max_writes_in_flight`
//! requests wait for their answers at once, sent one after the other.
//!
//! The master sends a `heartbeat` each interval while it sends no answer;
//! the replica acks each one. A master that says nothing, or reads nothing
//! sent, for `protocol.heartbeats_per_timeout` of the intervals its
//! `writer_ready` told is given up on.
//!
//! Whether a request may be sent again on a new connection is `delivered`:
//! the master runs a request only once its final part is in, so until the
//! last byte of that part is sent it has not run it. One none of which is
//! in the outbox yet may be taken back (`withdraw`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const forwarding = @import("forwarding.zig");
const Instant = @import("clock.zig").Instant;

pub const Event = union(enum) {
    /// The master takes requests now.
    ready,
    /// The master turned the replica away: close the connection.
    refused: protocol.Refusal,
    /// The answer to a request, whole.
    answer: Answer,
};

pub const Answer = struct {
    id: u64,
    /// Its bytes (forwarding.zig), the caller's to free.
    bytes: []u8,
};

pub const Error = protocol.DecodeError || forwarding.Assembly.Error || error{UnexpectedMessage};

pub const ForwardingSession = struct {
    inbox: protocol.Inbox,
    outbox: protocol.Outbox,
    state: State = .introducing,
    /// Until `writer_ready`, how long the master may take to answer; then
    /// derived from its heartbeat.
    timeout_ns: u64,
    /// When the master was last heard from.
    last_heard: Instant,
    /// When bytes of the outbox were last sent, or it was last empty.
    last_sent: Instant,
    /// An ack is owed (sent once the outbox has room).
    ack_due: bool = false,
    /// The requests handed over and not answered, the first `count`, in
    /// the order they are sent.
    requests: [protocol.max_writes_in_flight]Request = undefined,
    count: usize = 0,
    /// The requests before this one are in the outbox whole.
    putting: usize = 0,
    /// The bytes of the outbox sent so far.
    sent_total: u64 = 0,
    /// The parts of the answer coming.
    assembly: forwarding.Assembly = .{ .limit = forwarding.max_answer_bytes },

    const Request = struct {
        id: u64,
        /// The caller's, kept until its answer or the end of the
        /// conversation.
        bytes: []const u8,
        /// How much of them went into the outbox.
        offset: usize = 0,
        /// What `sent_total` reaches once its final part is out whole;
        /// null before that part is in the outbox.
        delivered_at: ?u64 = null,
    };

    pub const State = enum {
        /// Waiting for `writer_ready`.
        introducing,
        /// `request` may hand requests over.
        ready,
        /// The master turned the replica away.
        refused,
    };

    /// A conversation opened with `hello`, which waits in the outbox. A
    /// master that does not answer within `answer_timeout_ns` ends it.
    pub fn init(inbox_buffer: []u8, outbox_buffer: []u8, hello: protocol.WriterHello, answer_timeout_ns: u64, now: Instant) ForwardingSession {
        var self: ForwardingSession = .{
            .inbox = .init(inbox_buffer),
            .outbox = .init(outbox_buffer),
            .timeout_ns = answer_timeout_ns,
            .last_heard = now,
            .last_sent = now,
        };
        self.outbox.put(.{ .writer_hello = hello });
        return self;
    }

    pub fn deinit(self: *ForwardingSession, allocator: Allocator) void {
        self.assembly.deinit(allocator);
    }

    /// `count` bytes from the master went into `inbox.unfilled()`.
    pub fn received(self: *ForwardingSession, count: usize, now: Instant) void {
        self.inbox.filled(count);
        if (count > 0) self.last_heard = now;
    }

    /// The first `count` bytes of `outbox.unsent()` were sent.
    pub fn sent(self: *ForwardingSession, count: usize, now: Instant) void {
        self.outbox.sent(count);
        self.sent_total += count;
        if (count > 0) self.last_sent = now;
    }

    /// Whether `max_writes_in_flight` requests wait for their answers.
    pub fn full(self: *const ForwardingSession) bool {
        return self.count == self.requests.len;
    }

    /// Hands over the request `bytes` (forwarding.zig), under `id`, once
    /// the master is ready and the session is not `full`; they stay the
    /// caller's, untouched until its answer or the end of the
    /// conversation. `pump` sends them, after the ones handed before.
    pub fn request(self: *ForwardingSession, id: u64, bytes: []const u8) void {
        std.debug.assert(self.state == .ready and !self.full());
        self.requests[self.count] = .{ .id = id, .bytes = bytes };
        self.count += 1;
    }

    /// Takes back request `id` if none of it went into the outbox yet:
    /// the master will not run it. Returns whether it did.
    pub fn withdraw(self: *ForwardingSession, id: u64) bool {
        const index = self.indexOf(id) orelse return false;
        if (index < self.putting or self.requests[index].offset > 0) return false;
        self.remove(index);
        return true;
    }

    /// Whether the master may have run request `id`: its final part was
    /// sent whole. Until then it may be sent again on a new connection.
    pub fn delivered(self: *const ForwardingSession, id: u64) bool {
        const index = self.indexOf(id) orelse return false;
        return self.isDelivered(self.requests[index]);
    }

    /// What the replica must know of the messages received, or null until
    /// more come. A message the master would not send now fails with
    /// `UnexpectedMessage`; the connection is then of no further use.
    pub fn next(self: *ForwardingSession, allocator: Allocator) Error!?Event {
        while (try self.inbox.next()) |message| {
            switch (self.state) {
                .introducing => switch (message) {
                    .writer_ready => |heartbeat_ns| {
                        if (heartbeat_ns == 0) return error.UnexpectedMessage;
                        self.timeout_ns = protocol.timeoutFor(heartbeat_ns);
                        self.state = .ready;
                        return .ready;
                    },
                    .refused => |reason| {
                        self.state = .refused;
                        return .{ .refused = reason };
                    },
                    else => return error.UnexpectedMessage,
                },
                .ready => switch (message) {
                    // Acked by the next `pump`.
                    .heartbeat => self.ack_due = true,
                    .answer_part => |part| {
                        // The master answers a request once it is in whole.
                        const index = self.indexOf(part.id) orelse return error.UnexpectedMessage;
                        if (!self.isDelivered(self.requests[index])) return error.UnexpectedMessage;
                        if (try self.assembly.add(allocator, part.id, part.final, part.bytes) == null) continue;
                        const bytes = try self.assembly.bytes.toOwnedSlice(allocator);
                        self.remove(index);
                        return .{ .answer = .{ .id = part.id, .bytes = bytes } };
                    },
                    else => return error.UnexpectedMessage,
                },
                .refused => return error.UnexpectedMessage,
            }
        }
        return null;
    }

    /// Fills the outbox with what is to be sent at `now`: an owed ack, then
    /// the requests' parts, in order, while they fit. Call after `next` and
    /// `request`, and again once some of the outbox is sent.
    pub fn pump(self: *ForwardingSession, now: Instant) void {
        if (self.outbox.isEmpty()) self.last_sent = now;
        if (self.ack_due) {
            // The master asks only that the replica is alive.
            const ack: protocol.Message = .{ .ack = 0 };
            if (!self.outbox.fits(ack)) return;
            self.outbox.put(ack);
            self.ack_due = false;
        }
        while (self.putting < self.count) {
            const request_in_hand = &self.requests[self.putting];
            const length = @min(request_in_hand.bytes.len - request_in_hand.offset, protocol.part_bytes);
            const final = request_in_hand.offset + length == request_in_hand.bytes.len;
            const message: protocol.Message = .{ .request_part = .{ .id = request_in_hand.id, .final = final, .bytes = request_in_hand.bytes[request_in_hand.offset..][0..length] } };
            if (!self.outbox.fits(message)) return;
            self.outbox.put(message);
            request_in_hand.offset += length;
            if (!final) continue;
            request_in_hand.delivered_at = self.sent_total + self.outbox.unsent().len;
            self.putting += 1;
        }
    }

    /// When the master is given up on, if nothing comes before: it read
    /// nothing sent, or said nothing, for too long.
    pub fn deadline(self: *const ForwardingSession) Instant {
        const read_expiry = self.last_heard + self.timeout_ns;
        if (self.outbox.isEmpty()) return read_expiry;
        return @min(read_expiry, self.last_sent + self.timeout_ns);
    }

    fn indexOf(self: *const ForwardingSession, id: u64) ?usize {
        for (self.requests[0..self.count], 0..) |request_in_hand, index| {
            if (request_in_hand.id == id) return index;
        }
        return null;
    }

    fn isDelivered(self: *const ForwardingSession, request_in_hand: Request) bool {
        const at = request_in_hand.delivered_at orelse return false;
        return self.sent_total >= at;
    }

    fn remove(self: *ForwardingSession, index: usize) void {
        std.mem.copyForwards(Request, self.requests[index .. self.count - 1], self.requests[index + 1 .. self.count]);
        self.count -= 1;
        if (index < self.putting) self.putting -= 1;
    }
};
