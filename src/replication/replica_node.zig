//! A replica's side of replication on one thread, with no thread of its
//! own: it connects to the master and holds the conversation
//! (replica_session.zig) over a connection that never blocks, handing
//! what it receives to an `Applier`. When the conversation ends for any
//! reason it connects again after a while (a deadline, not a sleep). A
//! master silent for too long (`timeout_ns`, a few heartbeats) ends it
//! too. A refusal that asking again cannot help (a wrong token, another
//! version, another master) stops it for good: `halted` tells why.
//! Whoever runs it waits on what `watch` tells until `deadline`, hands
//! back what was `ready`, then calls `step`: follower.zig on a thread of
//! its own, or a simulation that decides when time passes and when change
//! sets are applied.
//!
//! TEMPORARY, to be replaced: the timeout is not tied to the master's
//! heartbeat.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const copies = @import("copies.zig");
const replica = @import("replica.zig");
const Clock = @import("clock.zig").Clock;
const Instant = @import("clock.zig").Instant;
const Signal = @import("clock.zig").Signal;
const network = @import("network.zig");
const Network = network.Network;
const Connection = network.Connection;
const Wakeup = network.Wakeup;
const Watched = network.Watched;
const replica_session = @import("replica_session.zig");
const ReplicaSession = replica_session.ReplicaSession;
const ChangeSet = replica_session.ChangeSet;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;

const log = std.log.scoped(.replication);

pub const Options = struct {
    /// The master's address, "host:port".
    master_address: []const u8,
    token: []const u8,
    /// A directory for the copies received, each in a directory of its
    /// own, deleted once loaded.
    copies_directory: []const u8,
    /// The waits between attempts to connect, doubling from the first to
    /// the longest.
    first_retry_ns: u64 = 100 * std.time.ns_per_ms,
    longest_retry_ns: u64 = 5 * std.time.ns_per_s,
    /// A master that sends nothing for this long is left (longer than its
    /// heartbeat).
    timeout_ns: u64 = 5 * std.time.ns_per_s,
    /// The bytes of change sets received and not yet applied past which
    /// the node stops reading until the applier catches up.
    max_unapplied_bytes: usize = 64 << 20,
    /// What the replica calls itself in its hello, at most
    /// `protocol.max_name_bytes`.
    name: []const u8 = "",
};

/// Where a replica is in following its master.
pub const Phase = enum(u8) {
    /// Connecting, waiting to connect again, or introducing itself.
    connecting,
    /// Receiving or loading a copy of the master's database.
    copying,
    streaming,
    /// Stopped for good by a refusal (`halted`).
    halted,
};

/// What an applier is given, in order.
pub const Work = union(enum) {
    change_set: ChangeSet,
    /// The number of a copy to load, deleted once loaded.
    load_copy: u64,
};

/// What an applier did since the last `take`.
pub const Done = struct {
    /// The last change set applied.
    applied: ?u64 = null,
    /// The LSN of the copy loaded.
    copy_loaded: ?u64 = null,
    failure: ?anyerror = null,
};

/// Applies, in order, what the node receives (`doWork`), raises the
/// node's `applied` signal and wakeup as it does.
pub const Applier = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        give: *const fn (context: *anyopaque, work: Work) Allocator.Error!void,
        take: *const fn (context: *anyopaque) Done,
        drop: *const fn (context: *anyopaque) void,
        unappliedBytes: *const fn (context: *anyopaque) usize,
    };

    /// Takes a change set's bytes.
    pub fn give(self: Applier, work: Work) Allocator.Error!void {
        return self.vtable.give(self.context, work);
    }

    pub fn take(self: Applier) Done {
        return self.vtable.take(self.context);
    }

    /// Drops the work not started, waits for the one in hand, and forgets
    /// what was done: the conversation it was for is over.
    pub fn drop(self: Applier) void {
        self.vtable.drop(self.context);
    }

    /// The bytes of the change sets given and not yet applied.
    pub fn unappliedBytes(self: Applier) usize {
        return self.vtable.unappliedBytes(self.context);
    }
};

/// Applies `work` to `store` and raises `applied`; returns the LSN applied,
/// or the copy's. Frees nothing.
pub fn doWork(clock: Clock, applied: *Signal, store: *KeyValueStore, copies_directory: []const u8, work: Work) !u64 {
    switch (work) {
        .change_set => |change_set| {
            _ = try store.applyChangeSet(change_set.lsn, change_set.bytes);
            clock.raise(applied, change_set.lsn);
            return change_set.lsn;
        },
        .load_copy => |number| {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const lsn = try store.loadCopy(try copies.directory(&path_buffer, copies_directory, number));
            clock.raise(applied, lsn);
            return lsn;
        },
    }
}

/// Frees `work`'s bytes, or deletes its copy.
pub fn dropWork(allocator: Allocator, io: Io, copies_directory: []const u8, work: Work) void {
    switch (work) {
        .change_set => |change_set| allocator.free(change_set.bytes),
        .load_copy => |number| copies.delete(io, copies_directory, number),
    }
}

/// An applier with no thread: work is done when its owner calls
/// `applyNext`, on the owner's thread. For a simulation.
pub const InlineApplier = struct {
    allocator: Allocator,
    io: Io,
    clock: Clock,
    applied: *Signal,
    store: KeyValueStore,
    wakeup: Wakeup,
    copies_directory: []const u8,
    work: std.ArrayList(Work) = .empty,
    unapplied_bytes: usize = 0,
    done: Done = .{},

    pub fn applier(self: *InlineApplier) Applier {
        return .{ .context = self, .vtable = &.{ .give = give, .take = take, .drop = drop, .unappliedBytes = unappliedBytes } };
    }

    pub fn deinit(self: *InlineApplier) void {
        self.dropAll();
        self.work.deinit(self.allocator);
        self.store.deinit();
    }

    pub fn waiting(self: *const InlineApplier) usize {
        return self.work.items.len;
    }

    /// Does the oldest work given, if any, and raises the wakeup.
    pub fn applyNext(self: *InlineApplier) void {
        if (self.work.items.len == 0) return;
        const work = self.work.orderedRemove(0);
        defer dropWork(self.allocator, self.io, self.copies_directory, work);
        if (work == .change_set) self.unapplied_bytes -= work.change_set.bytes.len;
        if (doWork(self.clock, self.applied, &self.store, self.copies_directory, work)) |lsn| switch (work) {
            .change_set => self.done.applied = lsn,
            .load_copy => self.done.copy_loaded = lsn,
        } else |err| {
            log.info("applying what the master sent failed: {t}", .{err});
            self.done.failure = err;
            // What follows depends on what failed.
            self.dropAll();
        }
        self.wakeup.raise();
    }

    fn dropAll(self: *InlineApplier) void {
        for (self.work.items) |work| dropWork(self.allocator, self.io, self.copies_directory, work);
        self.work.clearRetainingCapacity();
        self.unapplied_bytes = 0;
    }

    fn give(context: *anyopaque, work: Work) Allocator.Error!void {
        const self: *InlineApplier = @ptrCast(@alignCast(context));
        try self.work.append(self.allocator, work);
        if (work == .change_set) self.unapplied_bytes += work.change_set.bytes.len;
    }

    fn take(context: *anyopaque) Done {
        const self: *InlineApplier = @ptrCast(@alignCast(context));
        const done = self.done;
        self.done = .{};
        return done;
    }

    fn drop(context: *anyopaque) void {
        const self: *InlineApplier = @ptrCast(@alignCast(context));
        self.dropAll();
        self.done = .{};
    }

    fn unappliedBytes(context: *anyopaque) usize {
        const self: *InlineApplier = @ptrCast(@alignCast(context));
        return self.unapplied_bytes;
    }
};

pub const ReplicaNode = struct {
    allocator: Allocator,
    /// For the copies' files.
    io: Io,
    clock: Clock,
    network: Network,
    options: Options,
    /// The owner's: the replica's last applied LSN, raised by the applier;
    /// stopped once halted.
    applied: *Signal,
    /// The master's last LSN, as its last heartbeat told. Any thread.
    master_lsn: std.atomic.Value(u64) = .init(0),
    /// Why the master last turned this replica away, if it did. Any thread.
    refusal: std.atomic.Value(u8) = .init(0),
    /// The permanent refusal that stopped the node, if one did. Any thread.
    halt: std.atomic.Value(u8) = .init(0),
    /// `Phase`, as the last step left it. Any thread.
    phase_value: std.atomic.Value(u8) = .init(@backingInt(Phase.connecting)),
    /// When the master was last heard from (`never_heard` if it was not).
    /// Any thread.
    last_heard: std.atomic.Value(Instant) = .init(never_heard),
    /// The node's own store, for its hellos.
    store: KeyValueStore,
    /// The owner's: raised by the applier when it is done with something.
    wakeup: Wakeup,
    wakeup_ready: bool = false,
    applier: Applier,
    /// The conversation with the master, if one is held.
    conversation: ?*Conversation = null,
    /// When to connect again, with no conversation.
    retry_at: Instant = 0,
    retry_ns: u64,
    copies_made: u64 = 0,

    /// Follows the master for the database of `store`, which must not be
    /// a master. It becomes a replica of it with its first copy.
    pub fn init(allocator: Allocator, io: Io, clock: Clock, net: Network, store: *KeyValueStore, applied: *Signal, wakeup: Wakeup, applier: Applier, options: Options) !ReplicaNode {
        if (try store.changeLogState() != null) return error.MasterDatabase;
        var shared = try store.share();
        errdefer shared.deinit();
        applied.value = try shared.appliedLsn() orelse 0;
        return .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .network = net,
            .options = options,
            .applied = applied,
            .store = shared,
            .wakeup = wakeup,
            .applier = applier,
            .retry_ns = options.first_retry_ns,
        };
    }

    /// Ends the conversation, if one is held; the wakeup and the applier
    /// stay the owner's.
    pub fn deinit(self: *ReplicaNode) void {
        if (self.conversation) |conversation| self.forget(conversation);
        self.store.deinit();
    }

    /// Why the master last turned this replica away, if it did since it
    /// last followed it.
    pub fn lastRefusal(self: *const ReplicaNode) ?protocol.Refusal {
        const reason = self.refusal.load(.acquire);
        return if (reason == 0) null else @fromBackingInt(@intCast(reason));
    }

    /// The refusal that made the replica stop following its master for
    /// good (`Refusal.permanent`), or null while it follows.
    pub fn halted(self: *const ReplicaNode) ?protocol.Refusal {
        const reason = self.halt.load(.acquire);
        return if (reason == 0) null else @fromBackingInt(@intCast(reason));
    }

    const never_heard = std.math.maxInt(Instant);

    /// Where the replica is in following its master. Any thread.
    pub fn phase(self: *const ReplicaNode) Phase {
        // Halted before the step that halted it ends.
        if (self.halted() != null) return .halted;
        return @fromBackingInt(@intCast(self.phase_value.load(.acquire)));
    }

    /// When the master was last heard from, on the node's clock; null if
    /// never. Any thread.
    pub fn lastHeard(self: *const ReplicaNode) ?Instant {
        const at = self.last_heard.load(.acquire);
        return if (at == never_heard) null else at;
    }

    /// Moves the conversation on at `now`, with what was `ready`: connects
    /// when it is time, receives, hands what came to the applier, takes
    /// what it did, sends; ends the conversation on any failure.
    pub fn step(self: *ReplicaNode, now: Instant) void {
        self.advance(now);
        const phase_now: Phase = if (self.halted() != null) .halted else if (self.conversation) |conversation| switch (conversation.session.state) {
            .awaiting_answer => .connecting,
            .receiving_copy, .loading_copy => .copying,
            .streaming => .streaming,
        } else .connecting;
        self.phase_value.store(@backingInt(phase_now), .release);
    }

    fn advance(self: *ReplicaNode, now: Instant) void {
        self.clearWakeup();
        if (self.halted() != null) return;
        if (self.conversation == null) {
            if (now < self.retry_at) return;
            self.conversation = self.connect(now) catch |err| {
                log.info("following the master ended: {t}", .{err});
                self.retry(now, false);
                return;
            };
        }
        const conversation = self.conversation.?;
        const going = conversation.step(self, now) catch |err| blk: {
            log.info("following the master ended: {t}", .{err});
            break :blk false;
        };
        if (going) return;
        const streamed = conversation.streamed;
        self.forget(conversation);
        if (self.halted() != null) {
            // Its waiters would wait for nothing.
            self.clock.stop(self.applied);
            return;
        }
        self.retry(now, streamed);
    }

    /// Clears the wakeup if it was ready: before the owner looks at what
    /// raised it, or a raise meanwhile is lost. `step` does it too.
    pub fn clearWakeup(self: *ReplicaNode) void {
        if (!self.wakeup_ready) return;
        self.wakeup_ready = false;
        self.wakeup.clear();
    }

    /// What to wait on before the next step: the wakeup, then the
    /// connection to the master if there is one.
    pub fn watch(self: *ReplicaNode, watched: *[2]Watched) []Watched {
        watched[0] = .{ .source = .{ .wakeup = self.wakeup }, .wanted = .{ .readable = true } };
        const conversation = self.conversation orelse return watched[0..1];
        watched[1] = .{ .source = .{ .connection = conversation.connection }, .wanted = .{
            .readable = self.applier.unappliedBytes() < self.options.max_unapplied_bytes,
            .writable = conversation.session.outbox.unsent().len > 0,
        } };
        return watched[0..2];
    }

    /// When to step though nothing is ready, or null for never.
    pub fn deadline(self: *const ReplicaNode) ?Instant {
        if (self.halted() != null) return null;
        const conversation = self.conversation orelse return self.retry_at;
        return conversation.session.deadline();
    }

    /// What each of `watched` (from `watch`, nothing stepped since) was
    /// ready for.
    pub fn ready(self: *ReplicaNode, watched: []const Watched) void {
        self.wakeup_ready = watched[0].ready.readable;
        if (watched.len > 1) self.conversation.?.readable = watched[1].ready.readable;
    }

    fn connect(self: *ReplicaNode, now: Instant) !*Conversation {
        const conversation = try self.allocator.create(Conversation);
        errdefer self.allocator.destroy(conversation);
        const buffers = try self.allocator.alloc(u8, 2 * protocol.max_frame_bytes);
        errdefer self.allocator.free(buffers);
        var hello = try replica.hello(&self.store, self.options.token);
        hello.name = self.options.name;
        const connection = try self.network.connect(self.options.master_address);
        conversation.* = .{
            .connection = connection,
            .buffers = buffers,
            .session = .init(buffers[0..protocol.max_frame_bytes], buffers[protocol.max_frame_bytes..], hello, self.options.timeout_ns, now),
        };
        return conversation;
    }

    /// Ends `conversation`. The next hello tells what the replica applied:
    /// nothing may be left half done.
    fn forget(self: *ReplicaNode, conversation: *Conversation) void {
        conversation.deinit(self);
        self.allocator.destroy(conversation);
        self.conversation = null;
        self.applier.drop();
    }

    fn retry(self: *ReplicaNode, now: Instant, streamed: bool) void {
        self.retry_ns = if (streamed) self.options.first_retry_ns else @min(self.retry_ns * 2, self.options.longest_retry_ns);
        self.retry_at = now + self.retry_ns;
    }
};

/// One connection to the master.
const Conversation = struct {
    connection: Connection,
    buffers: []u8,
    session: ReplicaSession,
    /// What the connection was ready to read at the last wait.
    readable: bool = false,
    /// The copy being received, open while it is.
    copy_number: ?u64 = null,
    copy_file: ?Io.File = null,
    copy_writer: Io.File.Writer = undefined,
    copy_buffer: [64 << 10]u8 = undefined,
    /// Whether the master streamed change sets or a copy to it.
    streamed: bool = false,

    fn deinit(self: *Conversation, node: *ReplicaNode) void {
        // A copy received whole is the applier's, which deletes it.
        if (self.copy_file) |file| {
            file.close(node.io);
            copies.delete(node.io, node.options.copies_directory, self.copy_number.?);
        }
        self.session.deinit(node.allocator);
        node.allocator.free(self.buffers);
        self.connection.close();
    }

    /// Returns whether the conversation goes on.
    fn step(self: *Conversation, node: *ReplicaNode, now: Instant) !bool {
        const session = &self.session;
        const applier = node.applier;
        if (self.readable and applier.unappliedBytes() < node.options.max_unapplied_bytes) {
            while (session.inbox.unfilled().len > 0 and applier.unappliedBytes() < node.options.max_unapplied_bytes) {
                const count = self.connection.receive(session.inbox.unfilled()) catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.Closed => return error.ConnectionClosed,
                };
                session.received(count, now);
                node.last_heard.store(now, .release);
                while (try session.next(node.allocator)) |event| switch (event) {
                    .refused => |reason| {
                        log.info("the master turned this replica away: {t}", .{reason});
                        node.refusal.store(@backingInt(reason), .release);
                        if (reason.permanent()) node.halt.store(@backingInt(reason), .release);
                        return false;
                    },
                    .copy_part => |bytes| try self.writeCopyPart(node, bytes),
                    .copy_received => try self.copyReceived(node),
                    .change_set => |change_set| applier.give(.{ .change_set = change_set }) catch |err| {
                        node.allocator.free(change_set.bytes);
                        return err;
                    },
                    .heartbeat => |last| node.master_lsn.store(last, .release),
                };
                if (session.state != .awaiting_answer) {
                    self.streamed = true;
                    node.refusal.store(0, .release);
                }
            }
        }
        self.readable = false;
        const done = applier.take();
        if (done.failure) |err| return err;
        if (done.copy_loaded) |lsn| session.copyLoaded(lsn, now);
        if (done.applied) |lsn| session.applied(lsn);
        session.pump();
        while (session.outbox.unsent().len > 0) {
            const count = self.connection.send(session.outbox.unsent()) catch |err| switch (err) {
                error.WouldBlock => break,
                error.Closed => return error.ConnectionClosed,
            };
            session.outbox.sent(count);
            session.pump();
        }
        if (session.deadline()) |at| if (now >= at) return error.MasterSilent;
        return true;
    }

    fn writeCopyPart(self: *Conversation, node: *ReplicaNode, bytes: []const u8) !void {
        if (self.copy_file == null) {
            const number = node.copies_made;
            node.copies_made += 1;
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const directory = try copies.directory(&path_buffer, node.options.copies_directory, number);
            const cwd = Io.Dir.cwd();
            cwd.deleteTree(node.io, directory) catch {};
            try cwd.createDirPath(node.io, directory);
            var file_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const file_path = try std.fmt.bufPrint(&file_path_buffer, "{s}/{s}", .{ directory, KeyValueStore.data_file_name });
            const file = try cwd.createFile(node.io, file_path, .{});
            self.copy_number = number;
            self.copy_file = file;
            self.copy_writer = file.writer(node.io, &self.copy_buffer);
        }
        try self.copy_writer.interface.writeAll(bytes);
    }

    /// Hands the whole copy to the applier to load.
    fn copyReceived(self: *Conversation, node: *ReplicaNode) !void {
        const file = self.copy_file orelse return error.EmptyCopy;
        defer {
            file.close(node.io);
            self.copy_file = null;
        }
        errdefer copies.delete(node.io, node.options.copies_directory, self.copy_number.?);
        try self.copy_writer.interface.flush();
        try node.applier.give(.{ .load_copy = self.copy_number.? });
    }
};
