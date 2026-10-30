//! A replica's conversation with its master as a state machine with no
//! I/O of its own: the bytes its connection receives go into `inbox`,
//! `next` turns them into what the replica must do (write a part of the
//! copy, load the copy, apply a change set), and the frames to send wait
//! in `outbox`. Reading the socket, writing the copy's file, applying and
//! keeping time are the caller's (follower.zig, or a simulation).
//!
//! The replica acks each heartbeat with the last change set it applied, so
//! the master learns its lag and that it is alive.

const std = @import("std");
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const Instant = @import("clock.zig").Instant;

pub const Event = union(enum) {
    /// The master turned the replica away: close the connection.
    refused: protocol.Refusal,
    /// The next bytes of the master's copy: append them to the copy's
    /// file. A view into the inbox, valid until its `unfilled`.
    copy_part: []const u8,
    /// The copy is whole: load it, then `copyLoaded`.
    copy_received,
    /// The change set after the last one given: apply it, then `applied`.
    /// Its bytes are the caller's to free.
    change_set: ChangeSet,
    /// The master's last LSN.
    heartbeat: u64,
};

pub const ChangeSet = struct {
    lsn: u64,
    bytes: []u8,
};

pub const Error = protocol.DecodeError || Allocator.Error || error{ UnexpectedMessage, SnapshotSizeMismatch };

pub const ReplicaSession = struct {
    inbox: protocol.Inbox,
    outbox: protocol.Outbox,
    state: State = .awaiting_answer,
    timeout_ns: u64,
    /// When the master was last heard from.
    last_heard: Instant,
    /// The last change set applied, as `copyLoaded` and `applied` told.
    applied_lsn: u64,
    /// The LSN of the next change set to come.
    next_lsn: u64,
    /// The copy's bytes received so far.
    copy_size: u64 = 0,
    /// The parts of change set `next_lsn` received so far.
    gathered: std.ArrayList(u8) = .empty,
    /// An ack is owed (sent once the outbox has room).
    ack_due: bool = false,

    pub const State = enum { awaiting_answer, receiving_copy, loading_copy, streaming };

    /// A conversation opened with `hello`, which waits in the outbox. A
    /// master silent for `timeout_ns` (longer than its heartbeat) ends it.
    pub fn init(inbox_buffer: []u8, outbox_buffer: []u8, hello: protocol.Hello, timeout_ns: u64, now: Instant) ReplicaSession {
        var self: ReplicaSession = .{
            .inbox = .init(inbox_buffer),
            .outbox = .init(outbox_buffer),
            .timeout_ns = timeout_ns,
            .last_heard = now,
            .applied_lsn = hello.applied_lsn,
            .next_lsn = hello.applied_lsn + 1,
        };
        self.outbox.put(.{ .hello = hello });
        return self;
    }

    pub fn deinit(self: *ReplicaSession, allocator: Allocator) void {
        self.gathered.deinit(allocator);
    }

    /// `count` bytes from the master went into `inbox.unfilled()`.
    pub fn received(self: *ReplicaSession, count: usize, now: Instant) void {
        self.inbox.filled(count);
        if (count > 0) self.last_heard = now;
    }

    /// What the replica must do next for the messages received, or null
    /// until more come. A message the master would not send now fails with
    /// `UnexpectedMessage`; the connection is then of no further use.
    pub fn next(self: *ReplicaSession, allocator: Allocator) Error!?Event {
        while (try self.inbox.next()) |message| {
            switch (self.state) {
                .awaiting_answer => switch (message) {
                    .refused => |reason| return .{ .refused = reason },
                    .stream => |first| {
                        if (first != self.next_lsn) return error.UnexpectedMessage;
                        self.state = .streaming;
                    },
                    .snapshot_part => |bytes| {
                        self.state = .receiving_copy;
                        self.copy_size = bytes.len;
                        return .{ .copy_part = bytes };
                    },
                    // The master is making the copy.
                    .heartbeat => |last| return .{ .heartbeat = last },
                    else => return error.UnexpectedMessage,
                },
                .receiving_copy => switch (message) {
                    .snapshot_part => |bytes| {
                        self.copy_size += bytes.len;
                        return .{ .copy_part = bytes };
                    },
                    .snapshot_end => |size| {
                        if (size != self.copy_size) return error.SnapshotSizeMismatch;
                        self.state = .loading_copy;
                        return .copy_received;
                    },
                    else => return error.UnexpectedMessage,
                },
                // The master waits for the copy's ack.
                .loading_copy => return error.UnexpectedMessage,
                .streaming => switch (message) {
                    .change_set_part => |part| {
                        if (part.lsn != self.next_lsn) return error.UnexpectedMessage;
                        try self.gathered.appendSlice(allocator, part.bytes);
                        if (!part.final) continue;
                        self.next_lsn += 1;
                        return .{ .change_set = .{ .lsn = part.lsn, .bytes = try self.gathered.toOwnedSlice(allocator) } };
                    },
                    .heartbeat => |last| {
                        self.ack_due = true;
                        self.pump();
                        return .{ .heartbeat = last };
                    },
                    else => return error.UnexpectedMessage,
                },
            }
        }
        return null;
    }

    /// The copy is loaded; it holds the change sets up to `lsn`. Acks it.
    pub fn copyLoaded(self: *ReplicaSession, lsn: u64, now: Instant) void {
        std.debug.assert(self.state == .loading_copy);
        self.state = .streaming;
        self.applied_lsn = lsn;
        self.next_lsn = lsn + 1;
        // The master waited for the ack, silent.
        self.last_heard = now;
        self.ack_due = true;
        self.pump();
    }

    /// Change set `lsn` is applied (the next ack tells the master).
    pub fn applied(self: *ReplicaSession, lsn: u64) void {
        std.debug.assert(lsn > self.applied_lsn and lsn < self.next_lsn);
        self.applied_lsn = lsn;
    }

    /// Puts an owed ack in the outbox, if it has room; call once some of
    /// it is sent.
    pub fn pump(self: *ReplicaSession) void {
        if (!self.ack_due) return;
        const ack: protocol.Message = .{ .ack = self.applied_lsn };
        if (!self.outbox.fits(ack)) return;
        self.outbox.put(ack);
        self.ack_due = false;
    }

    /// When a silent master is given up on; null while the replica loads a
    /// copy (the master waits for it, silent).
    pub fn deadline(self: *const ReplicaSession) ?Instant {
        if (self.state == .loading_copy) return null;
        return self.last_heard + self.timeout_ns;
    }
};
