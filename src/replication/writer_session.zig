//! The master's conversation with a replica's connection for forwarded
//! writes (protocol.zig), as a state machine with no I/O of its own, like
//! master_session.zig. The connection opens as any other: once
//! `MasterSession.next` tells it is a writer's, its inbox and outbox move
//! here and `introduced` answers the `writer_hello`. Then `next` joins each
//! request's parts and hands the request over to be run, `answered` takes
//! its answer and `pump` sends it in parts. One write at a time.
//!
//! While no answer is sent the master sends a `heartbeat` each
//! `heartbeat_ns`, a write running or not, and the replica acks each one:
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
    /// The id of the request running or answered.
    request_id: u64 = 0,
    /// The answer being sent and how much of it is.
    answer: ?[]u8 = null,
    answer_offset: usize = 0,

    pub const State = enum {
        /// Waiting for a request, or for the rest of one.
        ready,
        /// A request is run: `answered` comes next.
        running,
        /// Its answer is sent.
        answering,
        /// The replica was refused: close once the refusal is sent.
        refused,
    };

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
        if (self.answer) |bytes| self.allocator.free(bytes);
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
        self.outbox.put(.writer_ready);
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

    /// Handles the messages received; returns a request once it is whole,
    /// its bytes the caller's to free: run it, then `answered`. Null until
    /// one is. A message the replica would not send now (a request while
    /// one runs) fails with `UnexpectedMessage`; the connection is then of
    /// no further use.
    pub fn next(self: *WriterSession) Error!?[]u8 {
        while (try self.inbox.next()) |message| {
            if (self.state == .refused) return error.UnexpectedMessage;
            switch (message) {
                // Of a heartbeat: the replica is alive.
                .ack => {},
                .request_part => |part| {
                    if (self.state != .ready) return error.UnexpectedMessage;
                    _ = try self.assembly.add(self.allocator, part.id, part.final, part.bytes) orelse continue;
                    self.request_id = part.id;
                    self.state = .running;
                    return try self.assembly.bytes.toOwnedSlice(self.allocator);
                },
                else => return error.UnexpectedMessage,
            }
        }
        return null;
    }

    /// The request `next` returned ran: `answer` (forwarding.zig), allocated
    /// with the session's allocator, is the session's to send and free.
    pub fn answered(self: *WriterSession, answer: []u8) void {
        std.debug.assert(self.state == .running);
        self.state = .answering;
        self.answer = answer;
        self.answer_offset = 0;
    }

    /// Fills the outbox with what is to be sent at `now`: the answer, or a
    /// heartbeat when one is due.
    pub fn pump(self: *WriterSession, store: *KeyValueStore, now: Instant) Error!void {
        if (self.outbox.isEmpty()) self.last_sent = now;
        if (self.state == .answering) self.pumpAnswer(now);
        switch (self.state) {
            .ready, .running => if (now >= self.heartbeat_due) {
                const state = try store.changeLogState() orelse return error.NotMaster;
                const heartbeat: protocol.Message = .{ .heartbeat = state.next_lsn - 1 };
                if (!self.outbox.fits(heartbeat)) return;
                self.outbox.put(heartbeat);
                self.heartbeat_due = now + self.settings.heartbeat_ns;
            },
            .answering, .refused => {},
        }
    }

    /// When the caller must call `pump` again, or check `expired`, if
    /// nothing comes before.
    pub fn deadline(self: *const WriterSession) Instant {
        var at = self.expiry() orelse std.math.maxInt(Instant);
        if (self.state == .ready or self.state == .running) at = @min(at, self.heartbeat_due);
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
        const read_expiry: ?Instant = switch (self.state) {
            .ready, .running => self.last_heard + self.settings.timeout_ns,
            // The replica reads, silent.
            .answering, .refused => null,
        };
        if (write_expiry) |write| return if (read_expiry) |read| @min(write, read) else write;
        return read_expiry;
    }

    fn pumpAnswer(self: *WriterSession, now: Instant) void {
        const bytes = self.answer.?;
        while (true) {
            const length = @min(bytes.len - self.answer_offset, protocol.part_bytes);
            const final = self.answer_offset + length == bytes.len;
            const message: protocol.Message = .{ .answer_part = .{ .id = self.request_id, .final = final, .bytes = bytes[self.answer_offset..][0..length] } };
            if (!self.outbox.fits(message)) return;
            self.outbox.put(message);
            self.heartbeat_due = now + self.settings.heartbeat_ns;
            self.answer_offset += length;
            if (!final) continue;
            self.allocator.free(bytes);
            self.answer = null;
            self.state = .ready;
            // Silent while it received the answer.
            self.last_heard = now;
            return;
        }
    }
};
