//! A replica's conversation with its master over the connection for
//! forwarded writes (protocol.zig), as a state machine with no I/O of its
//! own, the other side of writer_session.zig. The conversation opens with
//! the `writer_hello` waiting in the outbox; once the master is `ready`,
//! `request` hands over a request's bytes, `pump` sends them in parts and
//! `next` joins the answer's. One write at a time.
//!
//! The master sends a `heartbeat` each interval while it sends no answer;
//! the replica acks each one. A master that says nothing for `timeout_ns`,
//! or reads nothing sent, is given up on.
//!
//! Whether a request may be sent again on a new connection is `delivered`:
//! the master runs a request only once its final part is in, so until the
//! last byte of that part is sent it has not run it.

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
    /// The answer to the request (forwarding.zig), whole; its bytes are
    /// the caller's to free.
    answer: []u8,
};

pub const Error = protocol.DecodeError || forwarding.Assembly.Error || error{UnexpectedMessage};

pub const ForwardingSession = struct {
    inbox: protocol.Inbox,
    outbox: protocol.Outbox,
    state: State = .introducing,
    timeout_ns: u64,
    /// When the master was last heard from.
    last_heard: Instant,
    /// When bytes of the outbox were last sent, or it was last empty.
    last_sent: Instant,
    /// An ack is owed (sent once the outbox has room).
    ack_due: bool = false,
    /// The request being sent or answered: its id, its bytes (the
    /// caller's, kept until its answer or the end of the conversation) and
    /// how much of them went into the outbox.
    request_id: u64 = 0,
    request_bytes: []const u8 = &.{},
    request_offset: usize = 0,
    /// Bytes of the outbox to send before the request's final part is out
    /// whole; null before that part is in the outbox.
    final_unsent: ?usize = null,
    /// The parts of the answer coming.
    assembly: forwarding.Assembly = .{ .limit = forwarding.max_answer_bytes },

    pub const State = enum {
        /// Waiting for `writer_ready`.
        introducing,
        /// No request: `request` may hand one over.
        ready,
        /// Its parts are sent.
        requesting,
        /// It is sent whole: its answer comes next.
        waiting,
        /// The master turned the replica away.
        refused,
    };

    /// A conversation opened with `hello`, which waits in the outbox. A
    /// master silent for `timeout_ns` (longer than its heartbeat) ends it.
    pub fn init(inbox_buffer: []u8, outbox_buffer: []u8, hello: protocol.WriterHello, timeout_ns: u64, now: Instant) ForwardingSession {
        var self: ForwardingSession = .{
            .inbox = .init(inbox_buffer),
            .outbox = .init(outbox_buffer),
            .timeout_ns = timeout_ns,
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
        if (count > 0) self.last_sent = now;
        const unsent = self.final_unsent orelse return;
        self.final_unsent = unsent -| count;
        if (self.final_unsent == 0) self.state = .waiting;
    }

    /// Hands over the request `bytes` (forwarding.zig), under `id`; they
    /// stay the caller's, untouched until its answer or the end of the
    /// conversation. `pump` sends them.
    pub fn request(self: *ForwardingSession, id: u64, bytes: []const u8) void {
        std.debug.assert(self.state == .ready);
        self.state = .requesting;
        self.request_id = id;
        self.request_bytes = bytes;
        self.request_offset = 0;
        self.final_unsent = null;
    }

    /// Whether the master may have run the request handed over: its final
    /// part was sent whole. Until then it may be sent again on a new
    /// connection.
    pub fn delivered(self: *const ForwardingSession) bool {
        return switch (self.state) {
            .waiting => true,
            .introducing, .ready, .requesting, .refused => false,
        };
    }

    /// What the replica must know of the messages received, or null until
    /// more come. A message the master would not send now fails with
    /// `UnexpectedMessage`; the connection is then of no further use.
    pub fn next(self: *ForwardingSession, allocator: Allocator) Error!?Event {
        while (try self.inbox.next()) |message| {
            switch (self.state) {
                .introducing => switch (message) {
                    .writer_ready => {
                        self.state = .ready;
                        return .ready;
                    },
                    .refused => |reason| {
                        self.state = .refused;
                        return .{ .refused = reason };
                    },
                    else => return error.UnexpectedMessage,
                },
                .ready, .requesting, .waiting => switch (message) {
                    // Acked by the next `pump`.
                    .heartbeat => self.ack_due = true,
                    .answer_part => |part| {
                        // The master answers once the request is in whole.
                        if (self.state != .waiting or part.id != self.request_id) return error.UnexpectedMessage;
                        if (try self.assembly.add(allocator, part.id, part.final, part.bytes) == null) continue;
                        self.state = .ready;
                        self.request_bytes = &.{};
                        self.final_unsent = null;
                        return .{ .answer = try self.assembly.bytes.toOwnedSlice(allocator) };
                    },
                    else => return error.UnexpectedMessage,
                },
                .refused => return error.UnexpectedMessage,
            }
        }
        return null;
    }

    /// Fills the outbox with what is to be sent at `now`: an owed ack, then
    /// the request's parts while they fit. Call after `next` and `request`,
    /// and again once some of the outbox is sent.
    pub fn pump(self: *ForwardingSession, now: Instant) void {
        if (self.outbox.isEmpty()) self.last_sent = now;
        if (self.ack_due) {
            // The master asks only that the replica is alive.
            const ack: protocol.Message = .{ .ack = 0 };
            if (!self.outbox.fits(ack)) return;
            self.outbox.put(ack);
            self.ack_due = false;
        }
        while (self.state == .requesting and self.final_unsent == null) {
            const length = @min(self.request_bytes.len - self.request_offset, protocol.part_bytes);
            const final = self.request_offset + length == self.request_bytes.len;
            const message: protocol.Message = .{ .request_part = .{ .id = self.request_id, .final = final, .bytes = self.request_bytes[self.request_offset..][0..length] } };
            if (!self.outbox.fits(message)) return;
            self.outbox.put(message);
            self.request_offset += length;
            if (final) self.final_unsent = self.outbox.unsent().len;
        }
    }

    /// When the master is given up on, if nothing comes before: it read
    /// nothing sent, or said nothing, for `timeout_ns`.
    pub fn deadline(self: *const ForwardingSession) Instant {
        const read_expiry = self.last_heard + self.timeout_ns;
        if (self.outbox.isEmpty()) return read_expiry;
        return @min(read_expiry, self.last_sent + self.timeout_ns);
    }
};
