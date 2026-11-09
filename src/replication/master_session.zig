//! The master's conversation with one replica as a state machine with no
//! I/O of its own: the bytes its connection receives go into `inbox`,
//! `next` answers them (and asks for a copy of the database when the
//! replica needs one), and `pump` fills `outbox` with what to send: the
//! copy, the change sets the replica has not applied, heartbeats. Reading
//! and writing the socket, making the copy and keeping time are the
//! caller's (server.zig, or a simulation).
//!
//! `outbox` holds a frame or two, so a replica that reads slowly is sent
//! slowly: the change sets wait in the master's log, not in memory, and
//! are read a chunk at a time, each one part. One
//! that reads nothing, or says nothing, for `timeout_ns` is let go.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const protocol = @import("protocol.zig");
const master = @import("master.zig");
const Instant = @import("clock.zig").Instant;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;
const change_log = @import("../storage/change_log.zig");
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Graph = @import("../storage/graph.zig").Graph;

pub const Settings = struct {
    /// What a replica must send to be served; empty in an encrypted
    /// conversation, whose handshake proved the token.
    token: []const u8,
    heartbeat_ns: u64,
    /// A replica that reads nothing sent, or sends nothing awaited, for
    /// this long is let go (longer than `heartbeat_ns`).
    timeout_ns: u64,
    /// What a replica reading and loading its copy may take to read more,
    /// or to ack it.
    copy_timeout_ns: u64,
};

pub const Event = union(enum) {
    /// Make a copy of the database for this replica, then `copyMade`.
    make_copy,
    /// The connection is a replica's for forwarded writes: its
    /// conversation goes on in a `WriterSession` (writer_session.zig),
    /// with this session's inbox and outbox. The hello's slices are views
    /// into the inbox, valid until its `unfilled`.
    writer: protocol.WriterHello,
};

comptime {
    std.debug.assert(change_log.chunk_bytes == protocol.part_bytes);
}

pub const Error = protocol.DecodeError || StorageError || error{ UnexpectedMessage, NotMaster, ChangeSetDropped, CopyOutdated, ReadFailed, FormatRaised };

pub const MasterSession = struct {
    inbox: protocol.Inbox,
    outbox: protocol.Outbox,
    settings: Settings,
    state: State = .awaiting_hello,
    /// When the replica was last heard from.
    last_heard: Instant,
    /// When bytes of the outbox were last sent, or it was last empty.
    last_sent: Instant,
    /// When a heartbeat is due, if nothing else is sent before.
    heartbeat_due: Instant,
    /// The last change set the replica acked: its lag is the master's last
    /// LSN minus this.
    acked_lsn: u64 = 0,
    /// The LSN of the next change set to send.
    next_lsn: u64 = 0,
    /// The chunk of change set `next_lsn` to send next.
    chunk: u32 = 0,
    /// That chunk once read and until sent, and whether it is the last.
    part: std.ArrayList(u8) = .empty,
    part_final: ?bool = null,
    /// The copy being sent and its bytes sent so far.
    copy: ?*Reader = null,
    copy_size: u64 = 0,
    /// The newest storage format the replica reads, once its hello came.
    replica_format: u32 = 0,
    /// What the replica calls itself, once its hello came.
    name_buffer: [protocol.max_name_bytes]u8 = undefined,
    name_length: u8 = 0,

    pub const State = enum {
        awaiting_hello,
        making_copy,
        sending_copy,
        awaiting_copy_ack,
        streaming,
        /// The replica was refused: close once the refusal is sent.
        refused,
    };

    pub fn init(inbox_buffer: []u8, outbox_buffer: []u8, settings: Settings, now: Instant) MasterSession {
        return .{
            .inbox = .init(inbox_buffer),
            .outbox = .init(outbox_buffer),
            .settings = settings,
            .last_heard = now,
            .last_sent = now,
            .heartbeat_due = now + settings.heartbeat_ns,
        };
    }

    /// `allocator` is the master store's.
    pub fn deinit(self: *MasterSession, allocator: Allocator) void {
        self.part.deinit(allocator);
    }

    /// What the replica calls itself ("" until its hello came).
    pub fn name(self: *const MasterSession) []const u8 {
        return self.name_buffer[0..self.name_length];
    }

    /// Keeps the replica's name: `hello` is in the inbox, read over next.
    fn introduced(self: *MasterSession, store: *KeyValueStore, hello: protocol.Hello) StorageError!master.Answer {
        @memcpy(self.name_buffer[0..hello.name.len], hello.name);
        self.name_length = @intCast(hello.name.len);
        self.replica_format = hello.storage_format;
        return master.answer(store, hello, self.settings.token);
    }

    /// `count` bytes from the replica went into `inbox.unfilled()`.
    pub fn received(self: *MasterSession, count: usize, now: Instant) void {
        self.inbox.filled(count);
        if (count > 0) self.last_heard = now;
    }

    /// The first `count` bytes of `outbox.unsent()` were sent.
    pub fn sent(self: *MasterSession, count: usize, now: Instant) void {
        self.outbox.sent(count);
        if (count > 0) self.last_sent = now;
    }

    /// Handles the messages received for the master `store`; returns what
    /// the caller must do, or null until more come. A message the replica
    /// would not send now fails with `UnexpectedMessage`; the connection is
    /// then of no further use.
    pub fn next(self: *MasterSession, store: *KeyValueStore) Error!?Event {
        while (try self.inbox.next()) |message| {
            switch (self.state) {
                .awaiting_hello => switch (message) {
                    .hello => |hello| switch (try self.introduced(store, hello)) {
                        .refused => |reason| self.refuse(reason),
                        .stream => |first| {
                            self.outbox.put(.{ .welcome = self.settings.heartbeat_ns });
                            self.outbox.put(.{ .stream = first });
                            self.startStreaming(first);
                        },
                        .snapshot => {
                            self.outbox.put(.{ .welcome = self.settings.heartbeat_ns });
                            self.state = .making_copy;
                            return .make_copy;
                        },
                    },
                    .writer_hello => |hello| return .{ .writer = hello },
                    // It encrypts; this master does not.
                    .handshake => self.refuse(.encryption),
                    else => return error.UnexpectedMessage,
                },
                .awaiting_copy_ack => switch (message) {
                    .ack => |lsn| switch (try master.resumeFrom(store, lsn)) {
                        // The change sets follow the ack, with no `stream`.
                        .stream => |first| self.startStreaming(first),
                        // Its log moved past the copy meanwhile: the
                        // replica comes back for another.
                        else => return error.CopyOutdated,
                    },
                    else => return error.UnexpectedMessage,
                },
                .streaming => switch (message) {
                    .ack => |lsn| {
                        if (lsn < self.acked_lsn or lsn >= self.next_lsn) return error.UnexpectedMessage;
                        self.acked_lsn = lsn;
                    },
                    else => return error.UnexpectedMessage,
                },
                .making_copy, .sending_copy, .refused => return error.UnexpectedMessage,
            }
        }
        return null;
    }

    /// The copy asked for (`make_copy`) is made: `copy` reads it from its
    /// start, as `KeyValueStore.writeCopy` wrote it. It must stay open until
    /// the session is past `sending_copy`.
    pub fn copyMade(self: *MasterSession, copy: *Reader) void {
        std.debug.assert(self.state == .making_copy);
        self.state = .sending_copy;
        self.copy = copy;
    }

    /// Fills the outbox with what is to be sent at `now`: the copy, the
    /// change sets committed and not sent, a heartbeat when one is due.
    pub fn pump(self: *MasterSession, store: *KeyValueStore, now: Instant) Error!void {
        if (self.outbox.isEmpty()) self.last_sent = now;
        switch (self.state) {
            .sending_copy => {
                // The copy's format is at most the database's now.
                if (self.copy_size == 0) try self.checkFormat(store);
                try self.pumpCopy();
            },
            .streaming => try self.pumpChangeSets(store, now),
            else => {},
        }
        switch (self.state) {
            .making_copy, .streaming => if (now >= self.heartbeat_due) {
                const state = try store.changeLogState() orelse return error.NotMaster;
                const heartbeat: protocol.Message = .{ .heartbeat = state.next_lsn - 1 };
                if (!self.outbox.fits(heartbeat)) return;
                self.outbox.put(heartbeat);
                self.heartbeat_due = now + self.settings.heartbeat_ns;
            },
            else => {},
        }
    }

    /// When the caller must call `pump` again, or check `expired`, if
    /// nothing comes before.
    pub fn deadline(self: *const MasterSession) Instant {
        var at = self.expiry() orelse std.math.maxInt(Instant);
        if (self.state == .making_copy or self.state == .streaming) at = @min(at, self.heartbeat_due);
        return at;
    }

    /// Whether the replica is let go at `now`: it read nothing sent, or
    /// sent nothing awaited, for too long.
    pub fn expired(self: *const MasterSession, now: Instant) bool {
        return now >= self.expiry() orelse return false;
    }

    /// Whether the conversation is over: close the connection.
    pub fn finished(self: *const MasterSession) bool {
        return self.state == .refused and self.outbox.isEmpty();
    }

    fn expiry(self: *const MasterSession) ?Instant {
        // A replica stops reading a copy while it empties its database and
        // loads what it read: for long, on a large one.
        const write_timeout_ns = switch (self.state) {
            .sending_copy, .awaiting_copy_ack => self.settings.copy_timeout_ns,
            else => self.settings.timeout_ns,
        };
        const write_expiry: ?Instant = if (self.outbox.isEmpty()) null else self.last_sent + write_timeout_ns;
        const read_expiry: ?Instant = switch (self.state) {
            .awaiting_hello, .streaming => self.last_heard + self.settings.timeout_ns,
            .awaiting_copy_ack => @max(self.last_heard, self.last_sent) + self.settings.copy_timeout_ns,
            // The replica waits, silent.
            .making_copy, .sending_copy, .refused => null,
        };
        if (write_expiry) |write| return if (read_expiry) |read| @min(write, read) else write;
        return read_expiry;
    }

    fn refuse(self: *MasterSession, reason: protocol.Refusal) void {
        self.state = .refused;
        self.outbox.put(.{ .refused = reason });
    }

    fn startStreaming(self: *MasterSession, first: u64) void {
        self.state = .streaming;
        self.next_lsn = first;
        // The replica applied up to the one before.
        self.acked_lsn = first - 1;
    }

    fn pumpCopy(self: *MasterSession) Error!void {
        const copy = self.copy.?;
        while (true) {
            const buffered = copy.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            const message: protocol.Message = .{ .snapshot_part = buffered[0..@min(buffered.len, protocol.part_bytes)] };
            if (!self.outbox.fits(message)) return;
            self.outbox.put(message);
            copy.toss(message.snapshot_part.len);
            self.copy_size += message.snapshot_part.len;
        }
        const end: protocol.Message = .{ .snapshot_end = self.copy_size };
        if (!self.outbox.fits(end)) return;
        self.outbox.put(end);
        self.copy = null;
        self.state = .awaiting_copy_ack;
    }

    /// Fails with `FormatRaised` once the database is in a format the
    /// replica does not read: it asks again, and its hello is refused.
    fn checkFormat(self: *MasterSession, store: *KeyValueStore) Error!void {
        if (self.replica_format >= Graph.newest_format) return;
        if (!try master.readsFormat(store, self.replica_format)) return error.FormatRaised;
    }

    /// Fails with `ChangeSetDropped` if the log no longer holds the next
    /// change set, or the rest of the one being sent (the replica starts
    /// again from a copy).
    fn pumpChangeSets(self: *MasterSession, store: *KeyValueStore, now: Instant) Error!void {
        while (true) {
            if (self.part_final == null) {
                if (self.chunk == 0) {
                    const state = try store.changeLogState() orelse return error.NotMaster;
                    if (self.next_lsn >= state.next_lsn) return;
                    // Read after the log's state, the format is at least the
                    // one any change set below `state.next_lsn` stamped.
                    try self.checkFormat(store);
                }
                self.part_final = try store.changeSetChunk(self.next_lsn, self.chunk, &self.part) orelse return error.ChangeSetDropped;
            }
            const final = self.part_final.?;
            const message: protocol.Message = .{ .change_set_part = .{ .lsn = self.next_lsn, .final = final, .bytes = self.part.items } };
            if (!self.outbox.fits(message)) return;
            self.outbox.put(message);
            self.heartbeat_due = now + self.settings.heartbeat_ns;
            self.part_final = null;
            if (final) {
                self.chunk = 0;
                self.next_lsn += 1;
            } else self.chunk += 1;
        }
    }
};
