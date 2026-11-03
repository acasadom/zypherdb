//! The master's conversation with a replica's connection for forwarded
//! writes (protocol.zig), as a state machine with no I/O of its own, like
//! master_session.zig. The connection opens as any other: once
//! `MasterSession.next` tells it is a writer's, its inbox and outbox move
//! here and `introduced` answers the `writer_hello`. Then `next` joins each
//! request's parts and hands the request over to be run, `answered` takes
//! its answer and `pump` sends the answers in parts, each whole before the
//! next. Up to `protocol.max_writes_in_flight` requests wait for their
//! answers at once; a replica that sends more is let go.
//!
//! While no answer is sent the master sends a `heartbeat` each
//! `heartbeat_ns`, writes running or not, and the replica acks each one:
//! a replica that says nothing for `timeout_ns`, or reads nothing sent, is
//! let go. Heartbeats tell a waiting replica its master is alive.

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const master = @import("master.zig");
const forwarding = @import("forwarding.zig");
const Instant = @import("clock.zig").Instant;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;
const StorageError = @import("../storage/key_value_store.zig").StorageError;

pub const Settings = struct {
    /// What a replica must send to be served.
    token: []const u8,
    heartbeat_ns: u64,
    /// A replica that reads nothing sent, or says nothing, for this long is
    /// let go (longer than `heartbeat_ns`).
    timeout_ns: u64,
};

pub const Error = protocol.DecodeError || StorageError || forwarding.Assembly.Error || error{ UnexpectedMessage, NotMaster };

pub const WriterSession = struct {
    /// For the requests and the answers.
    allocator: Allocator,
    inbox: protocol.Inbox,
    outbox: protocol.Outbox,
    settings: Settings,
    state: State = .ready,
    /// When the replica was last heard from, or, after an answer, when it
    /// was sent: the replica may stay silent while it receives one.
    last_heard: Instant,
    /// When bytes of the outbox were last sent, or it was last empty.
    last_sent: Instant,
    /// When a heartbeat is due, if nothing else is sent before.
    heartbeat_due: Instant,
    /// The parts of the request coming.
    assembly: forwarding.Assembly = .{ .limit = forwarding.max_request_bytes },
    /// The requests handed over by `next` and not answered yet.
    running: usize = 0,
    /// The answers to send, the first `answers_count`, in order; the
    /// first one's first `answer_offset` bytes are in the outbox.
    answers: [protocol.max_writes_in_flight]Answer = undefined,
    answers_count: usize = 0,
    answer_offset: usize = 0,

    pub const State = enum {
        /// Requests come, and answers go.
        ready,
        /// The replica was refused: close once the refusal is sent.
        refused,
    };

    pub const Request = struct {
        id: u64,
        /// The caller's to free.
        bytes: []u8,
    };

    const Answer = struct { id: u64, bytes: []u8 };

    /// Goes on with the inbox and outbox of the connection's
    /// `MasterSession`, whose `writer_hello` came last.
    pub fn init(allocator: Allocator, inbox: protocol.Inbox, outbox: protocol.Outbox, settings: Settings, now: Instant) WriterSession {
        return .{
            .allocator = allocator,
            .inbox = inbox,
            .outbox = outbox,
            .settings = settings,
            .last_heard = now,
            .last_sent = now,
            .heartbeat_due = now + settings.heartbeat_ns,
        };
    }

    pub fn deinit(self: *WriterSession) void {
        self.assembly.deinit(self.allocator);
        for (self.answers[0..self.answers_count]) |answer| self.allocator.free(answer.bytes);
    }

    /// Answers `hello` (read from the inbox, before anything else) for the
    /// master `store`: `writer_ready`, or a refusal.
    pub fn introduced(self: *WriterSession, store: *KeyValueStore, hello: protocol.WriterHello) StorageError!void {
        std.debug.assert(self.outbox.isEmpty());
        if (try master.answerWriter(store, hello, self.settings.token)) |reason| {
            self.state = .refused;
            self.outbox.put(.{ .refused = reason });
            return;
        }
        self.outbox.put(.{ .writer_ready = self.settings.heartbeat_ns });
    }

    /// `count` bytes from the replica went into `inbox.unfilled()`.
    pub fn received(self: *WriterSession, count: usize, now: Instant) void {
        self.inbox.filled(count);
        if (count > 0) self.last_heard = now;
    }

    /// The first `count` bytes of `outbox.unsent()` were sent.
    pub fn sent(self: *WriterSession, count: usize, now: Instant) void {
        self.outbox.sent(count);
        if (count > 0) self.last_sent = now;
    }

    /// Handles the messages received; returns a request once it is whole:
    /// run it, then `answered`. Null until one is. A message the replica
    /// would not send now (a request past `max_writes_in_flight`) fails
    /// with `UnexpectedMessage`; the connection is then of no further use.
    pub fn next(self: *WriterSession) Error!?Request {
        while (try self.inbox.next()) |message| {
            if (self.state == .refused) return error.UnexpectedMessage;
            switch (message) {
                // Of a heartbeat: the replica is alive.
                .ack => {},
                .request_part => |part| {
                    _ = try self.assembly.add(self.allocator, part.id, part.final, part.bytes) orelse continue;
                    if (self.running + self.answers_count == protocol.max_writes_in_flight) return error.UnexpectedMessage;
                    const bytes = try self.assembly.bytes.toOwnedSlice(self.allocator);
                    self.running += 1;
                    return .{ .id = part.id, .bytes = bytes };
                },
                else => return error.UnexpectedMessage,
            }
        }
        return null;
    }

    /// Request `id`, which `next` returned, ran: `answer` (forwarding.zig),
    /// allocated with the session's allocator, is the session's to send
    /// and free, after the answers before it.
    pub fn answered(self: *WriterSession, id: u64, answer: []u8) void {
        std.debug.assert(self.running > 0);
        self.running -= 1;
        self.answers[self.answers_count] = .{ .id = id, .bytes = answer };
        self.answers_count += 1;
    }

    /// Fills the outbox with what is to be sent at `now`: the answer, or a
    /// heartbeat when one is due.
    pub fn pump(self: *WriterSession, store: *KeyValueStore, now: Instant) Error!void {
        if (self.outbox.isEmpty()) self.last_sent = now;
        if (self.state == .refused) return;
        if (self.answers_count > 0) return self.pumpAnswers(now);
        if (now >= self.heartbeat_due) {
            const state = try store.changeLogState() orelse return error.NotMaster;
            const heartbeat: protocol.Message = .{ .heartbeat = state.next_lsn - 1 };
            if (!self.outbox.fits(heartbeat)) return;
            self.outbox.put(heartbeat);
            self.heartbeat_due = now + self.settings.heartbeat_ns;
        }
    }

    /// When the caller must call `pump` again, or check `expired`, if
    /// nothing comes before.
    pub fn deadline(self: *const WriterSession) Instant {
        var at = self.expiry() orelse std.math.maxInt(Instant);
        if (self.state == .ready and self.answers_count == 0) at = @min(at, self.heartbeat_due);
        return at;
    }

    /// Whether the replica is let go at `now`: it read nothing sent, or
    /// said nothing, for too long.
    pub fn expired(self: *const WriterSession, now: Instant) bool {
        return now >= self.expiry() orelse return false;
    }

    /// Whether the conversation is over: close the connection.
    pub fn finished(self: *const WriterSession) bool {
        return self.state == .refused and self.outbox.isEmpty();
    }

    fn expiry(self: *const WriterSession) ?Instant {
        const write_expiry: ?Instant = if (self.outbox.isEmpty()) null else self.last_sent + self.settings.timeout_ns;
        // The replica reads answers, or a refusal, silent.
        const read_expiry: ?Instant = if (self.state == .ready and self.answers_count == 0) self.last_heard + self.settings.timeout_ns else null;
        if (write_expiry) |write| return if (read_expiry) |read| @min(write, read) else write;
        return read_expiry;
    }

    fn pumpAnswers(self: *WriterSession, now: Instant) void {
        while (self.answers_count > 0) {
            const answer = self.answers[0];
            const length = @min(answer.bytes.len - self.answer_offset, protocol.part_bytes);
            const final = self.answer_offset + length == answer.bytes.len;
            const message: protocol.Message = .{ .answer_part = .{ .id = answer.id, .final = final, .bytes = answer.bytes[self.answer_offset..][0..length] } };
            if (!self.outbox.fits(message)) return;
            self.outbox.put(message);
            self.heartbeat_due = now + self.settings.heartbeat_ns;
            self.answer_offset += length;
            if (!final) continue;
            self.allocator.free(answer.bytes);
            std.mem.copyForwards(Answer, self.answers[0 .. self.answers_count - 1], self.answers[1..self.answers_count]);
            self.answers_count -= 1;
            self.answer_offset = 0;
            // Silent while it received the answers.
            self.last_heard = now;
        }
    }
};
