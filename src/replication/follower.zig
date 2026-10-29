//! A replica's replication threads: a loop that connects to the master and
//! holds the conversation (replica_session.zig) over a connection that
//! never blocks, and an applier that applies the change sets and loads the
//! copy the loop receives (it may take long; the loop goes on meanwhile,
//! acking heartbeats). When the conversation ends for any reason the loop
//! connects again after a while. A master silent for too long
//! (`timeout_ns`, a few heartbeats) ends it too: the session's deadline,
//! checked by the loop on the clock.
//!
//! TEMPORARY, to be replaced: every refusal is retried, the permanent ones
//! (token, versions, another master) too, and the timeout is not tied to
//! the master's heartbeat.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const replica = @import("replica.zig");
const Clock = @import("clock.zig").Clock;
const Instant = @import("clock.zig").Instant;
const Signal = @import("clock.zig").Signal;
const network = @import("network.zig");
const Network = network.Network;
const Connection = network.Connection;
const Wakeup = network.Wakeup;
const Watched = network.Watched;
const ReplicaSession = @import("replica_session.zig").ReplicaSession;
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
    /// the loop stops reading until the applier catches up.
    max_unapplied_bytes: usize = 64 << 20,
};

pub const Follower = struct {
    allocator: Allocator,
    /// For the copies' files and the applier's lock.
    io: Io,
    clock: Clock,
    network: Network,
    options: Options,
    /// The replica's last applied LSN, raised by each change set applied.
    applied: Signal = .{},
    /// The master's last LSN, as its last heartbeat told.
    master_lsn: std.atomic.Value(u64) = .init(0),
    /// Why the master last turned this replica away, if it did.
    refusal: std.atomic.Value(u8) = .init(0),
    /// The loop's store, for its hellos; the applier's shares it.
    store: KeyValueStore,
    /// Raised by the applier when it is done with something, and by `stop`.
    wakeup: Wakeup,
    stopping: std.atomic.Value(bool) = .init(false),
    loop_thread: ?std.Thread = null,
    applier: Applier,
    copies_made: u64 = 0,

    /// Starts following the master for the database of `store`, which must
    /// not be a master. It becomes a replica of it with its first copy.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, net: Network, store: *KeyValueStore, options: Options) !*Follower {
        if (try store.changeLogState() != null) return error.MasterDatabase;
        const self = try allocator.create(Follower);
        errdefer allocator.destroy(self);
        var shared = try store.share();
        errdefer shared.deinit();
        var applier_store = try store.share();
        errdefer applier_store.deinit();
        const wakeup = try net.wakeup();
        errdefer wakeup.close();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .network = net,
            .options = options,
            .applied = .{ .value = try shared.appliedLsn() orelse 0 },
            .store = shared,
            .wakeup = wakeup,
            .applier = .{ .allocator = allocator, .io = io, .store = applier_store, .wakeup = wakeup, .follower = self },
        };
        try self.applier.start();
        errdefer self.applier.stop();
        self.loop_thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops the threads, closes the connection and frees the follower.
    pub fn stop(self: *Follower) void {
        self.stopping.store(true, .release);
        self.clock.stop(&self.applied);
        self.wakeup.raise();
        if (self.loop_thread) |thread| thread.join();
        self.applier.stop();
        self.applier.deinit();
        self.wakeup.close();
        self.store.deinit();
        self.allocator.destroy(self);
    }

    /// Waits until change set `lsn` is applied or `deadline` comes; returns
    /// the last applied then, or null once stopped.
    pub fn waitApplied(self: *Follower, lsn: u64, deadline: u64) ?u64 {
        if (lsn == 0) return self.applied.value;
        return self.clock.wait(&self.applied, lsn - 1, deadline);
    }

    /// Why the master last turned this replica away, if it did since it
    /// last followed it.
    pub fn lastRefusal(self: *Follower) ?protocol.Refusal {
        const reason = self.refusal.load(.acquire);
        return if (reason == 0) null else @fromBackingInt(@intCast(reason));
    }

    fn stopped(self: *Follower) bool {
        return self.stopping.load(.acquire);
    }

    fn run(self: *Follower) void {
        var retry = self.options.first_retry_ns;
        while (!self.stopped()) {
            var conversation: Conversation = .{ .follower = self };
            conversation.follow() catch |err| switch (err) {
                error.Stopped => {},
                else => log.info("following the master ended: {t}", .{err}),
            };
            conversation.deinit();
            // The next hello tells what the replica applied: nothing may be
            // left half done.
            self.applier.drop();
            retry = if (conversation.streamed) self.options.first_retry_ns else @min(retry * 2, self.options.longest_retry_ns);
            self.sleep(self.clock.now() + retry);
        }
    }

    /// Waits until `deadline` or a stop.
    fn sleep(self: *Follower, deadline: Instant) void {
        while (!self.stopped()) {
            const now = self.clock.now();
            if (now >= deadline) return;
            var watched = [_]Watched{.{ .source = .{ .wakeup = self.wakeup }, .wanted = .{ .readable = true } }};
            self.network.wait(&watched, deadline - now) catch return;
            if (watched[0].ready.readable) self.wakeup.clear();
        }
    }
};

/// One connection to the master, on the loop's thread.
const Conversation = struct {
    follower: *Follower,
    connection: ?Connection = null,
    buffers: ?[]u8 = null,
    session: ?ReplicaSession = null,
    /// The copy being received, open while it is.
    copy_number: ?u64 = null,
    copy_file: ?Io.File = null,
    copy_writer: Io.File.Writer = undefined,
    copy_buffer: [64 << 10]u8 = undefined,
    /// Whether the master streamed change sets or a copy to it.
    streamed: bool = false,

    fn deinit(self: *Conversation) void {
        const follower = self.follower;
        // A copy received whole is the applier's, which deletes it.
        if (self.copy_file) |file| {
            file.close(follower.io);
            follower.applier.deleteCopy(self.copy_number.?);
        }
        if (self.session) |*session| session.deinit(follower.allocator);
        if (self.buffers) |buffers| follower.allocator.free(buffers);
        if (self.connection) |connection| connection.close();
    }

    fn follow(self: *Conversation) !void {
        const follower = self.follower;
        const connection = try follower.network.connect(follower.options.master_address);
        self.connection = connection;
        const hello = try replica.hello(&follower.store, follower.options.token);
        const buffers = try follower.allocator.alloc(u8, 2 * protocol.max_frame_bytes);
        self.buffers = buffers;
        self.session = .init(buffers[0..protocol.max_frame_bytes], buffers[protocol.max_frame_bytes..], hello, follower.options.timeout_ns, follower.clock.now());
        const session = &self.session.?;
        var readable = false;
        while (!follower.stopped()) {
            const now = follower.clock.now();
            const reading = follower.applier.unappliedBytes() < follower.options.max_unapplied_bytes;
            if (readable and reading) {
                while (session.inbox.unfilled().len > 0 and follower.applier.unappliedBytes() < follower.options.max_unapplied_bytes) {
                    const count = connection.receive(session.inbox.unfilled()) catch |err| switch (err) {
                        error.WouldBlock => break,
                        error.Closed => return error.ConnectionClosed,
                    };
                    session.received(count, now);
                    while (try session.next(follower.allocator)) |event| switch (event) {
                        .refused => |reason| {
                            log.info("the master turned this replica away: {t}", .{reason});
                            follower.refusal.store(@backingInt(reason), .release);
                            return;
                        },
                        .copy_part => |bytes| try self.writeCopyPart(bytes),
                        .copy_received => try self.copyReceived(),
                        .change_set => |change_set| follower.applier.apply(change_set) catch |err| {
                            follower.allocator.free(change_set.bytes);
                            return err;
                        },
                        .heartbeat => |last| follower.master_lsn.store(last, .release),
                    };
                    if (session.state != .awaiting_answer) {
                        self.streamed = true;
                        follower.refusal.store(0, .release);
                    }
                }
            }
            const done = follower.applier.take();
            if (done.failure) |err| return err;
            if (done.copy_loaded) |lsn| session.copyLoaded(lsn, now);
            if (done.applied) |lsn| session.applied(lsn);
            session.pump();
            while (session.outbox.unsent().len > 0) {
                const count = connection.send(session.outbox.unsent()) catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.Closed => return error.ConnectionClosed,
                };
                session.outbox.sent(count);
                session.pump();
            }
            const deadline = session.deadline();
            if (deadline) |at| if (now >= at) return error.MasterSilent;
            var watched = [_]Watched{
                .{ .source = .{ .connection = connection }, .wanted = .{
                    .readable = follower.applier.unappliedBytes() < follower.options.max_unapplied_bytes,
                    .writable = session.outbox.unsent().len > 0,
                } },
                .{ .source = .{ .wakeup = follower.wakeup }, .wanted = .{ .readable = true } },
            };
            try follower.network.wait(&watched, if (deadline) |at| at -| now else null);
            readable = watched[0].ready.readable;
            if (watched[1].ready.readable) follower.wakeup.clear();
        }
        return error.Stopped;
    }

    fn writeCopyPart(self: *Conversation, bytes: []const u8) !void {
        const follower = self.follower;
        if (self.copy_file == null) {
            const number = follower.copies_made;
            follower.copies_made += 1;
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const directory = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}", .{ follower.options.copies_directory, number });
            const cwd = Io.Dir.cwd();
            cwd.deleteTree(follower.io, directory) catch {};
            try cwd.createDirPath(follower.io, directory);
            var file_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const file_path = try std.fmt.bufPrint(&file_path_buffer, "{s}/{s}", .{ directory, KeyValueStore.data_file_name });
            const file = try cwd.createFile(follower.io, file_path, .{});
            self.copy_number = number;
            self.copy_file = file;
            self.copy_writer = file.writer(follower.io, &self.copy_buffer);
        }
        try self.copy_writer.interface.writeAll(bytes);
    }

    /// Hands the whole copy to the applier to load.
    fn copyReceived(self: *Conversation) !void {
        const follower = self.follower;
        const file = self.copy_file orelse return error.EmptyCopy;
        defer {
            file.close(follower.io);
            self.copy_file = null;
        }
        errdefer follower.applier.deleteCopy(self.copy_number.?);
        try self.copy_writer.interface.flush();
        try follower.applier.load(self.copy_number.?);
    }
};

/// The thread that applies what the loop receives, in order: change sets,
/// and copies to load (each in directory `copy-N` of the copies
/// directory, deleted once loaded). It raises `Follower.applied` and tells
/// the loop (`take`) through the wakeup.
const Applier = struct {
    allocator: Allocator,
    io: Io,
    store: KeyValueStore,
    wakeup: Wakeup,
    follower: *Follower,
    thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Under `mutex`.
    work: std.ArrayList(Work) = .empty,
    /// The bytes of the change sets in `work` and in hand.
    unapplied_bytes: usize = 0,
    busy: bool = false,
    done: Done = .{},
    stopping: bool = false,

    const Work = union(enum) {
        change_set: @import("replica_session.zig").ChangeSet,
        load_copy: u64,
    };

    /// What was done since the last `take`.
    const Done = struct {
        /// The last change set applied.
        applied: ?u64 = null,
        /// The LSN of the copy loaded.
        copy_loaded: ?u64 = null,
        failure: ?anyerror = null,
    };

    fn start(self: *Applier) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Waits for what is in hand, if anything is.
    fn stop(self: *Applier) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Once stopped.
    fn deinit(self: *Applier) void {
        self.dropWork();
        self.work.deinit(self.allocator);
        self.store.deinit();
    }

    /// Takes `change_set`'s bytes.
    fn apply(self: *Applier, change_set: @import("replica_session.zig").ChangeSet) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.work.append(self.allocator, .{ .change_set = change_set });
        self.unapplied_bytes += change_set.bytes.len;
        self.condition.broadcast(self.io);
    }

    fn load(self: *Applier, copy_number: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.work.append(self.allocator, .{ .load_copy = copy_number });
        self.condition.broadcast(self.io);
    }

    fn unappliedBytes(self: *Applier) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.unapplied_bytes;
    }

    fn take(self: *Applier) Done {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const done = self.done;
        self.done = .{};
        return done;
    }

    /// Drops the work not started, waits for the one in hand, and forgets
    /// what was done: the conversation it was for is over.
    fn drop(self: *Applier) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dropWork();
        while (self.busy) self.condition.waitUncancelable(self.io, &self.mutex);
        self.done = .{};
    }

    fn dropWork(self: *Applier) void {
        for (self.work.items) |work| switch (work) {
            .change_set => |change_set| {
                self.unapplied_bytes -= change_set.bytes.len;
                self.allocator.free(change_set.bytes);
            },
            .load_copy => |number| self.deleteCopy(number),
        };
        self.work.clearRetainingCapacity();
    }

    fn run(self: *Applier) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (!self.stopping and self.work.items.len == 0) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) return;
            const work = self.work.orderedRemove(0);
            self.busy = true;
            self.mutex.unlock(self.io);
            const result = self.do(work);
            self.mutex.lockUncancelable(self.io);
            self.busy = false;
            if (work == .change_set) self.unapplied_bytes -= work.change_set.bytes.len;
            if (result) |lsn| switch (work) {
                .change_set => self.done.applied = lsn,
                .load_copy => self.done.copy_loaded = lsn,
            } else |err| {
                log.info("applying what the master sent failed: {t}", .{err});
                self.done.failure = err;
                // What follows depends on what failed.
                self.dropWork();
            }
            if (work == .change_set) self.allocator.free(work.change_set.bytes);
            self.condition.broadcast(self.io);
            self.wakeup.raise();
        }
    }

    /// Returns the LSN applied, or the copy's.
    fn do(self: *Applier, work: Work) !u64 {
        switch (work) {
            .change_set => |change_set| {
                _ = try self.store.applyChangeSet(change_set.lsn, change_set.bytes);
                self.follower.clock.raise(&self.follower.applied, change_set.lsn);
                return change_set.lsn;
            },
            .load_copy => |number| {
                defer self.deleteCopy(number);
                var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const directory = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}", .{ self.follower.options.copies_directory, number });
                const lsn = try self.store.loadCopy(directory);
                self.follower.clock.raise(&self.follower.applied, lsn);
                return lsn;
            },
        }
    }

    fn deleteCopy(self: *Applier, number: u64) void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}", .{ self.follower.options.copies_directory, number }) catch return;
        Io.Dir.cwd().deleteTree(self.io, directory) catch {};
    }
};
