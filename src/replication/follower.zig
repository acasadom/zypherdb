//! A replica's replication thread: it connects to the master, holds the
//! conversation of replica.zig with it (a copy first if the master says
//! so, then the change sets as they come) and, when the conversation
//! ends for any reason, connects again after a while. Reads that wait too
//! long (the network's read timeout, a few heartbeats) end it too.
//!
//! TEMPORARY, to be replaced: every refusal is retried, the permanent ones
//! (token, versions, another master) too, and the read timeout is not tied
//! to the master's heartbeat.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const replica = @import("replica.zig");
const Clock = @import("clock.zig").Clock;
const Signal = @import("clock.zig").Signal;
const Network = @import("network.zig").Network;
const Connection = @import("network.zig").Connection;
const SpinLock = @import("spin_lock.zig").SpinLock;
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
};

pub const Follower = struct {
    allocator: Allocator,
    /// For the copies' files.
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
    store: KeyValueStore,
    thread: ?std.Thread = null,
    lock: SpinLock = .{},
    /// The connection to the master, while there is one (under `lock`).
    connection: ?Connection = null,
    copies_made: u64 = 0,

    /// Starts following the master for the database of `store`, which must
    /// not be a master. It becomes a replica of it with its first copy.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, network: Network, store: *KeyValueStore, options: Options) !*Follower {
        if (try store.changeLogState() != null) return error.MasterDatabase;
        const self = try allocator.create(Follower);
        errdefer allocator.destroy(self);
        var shared = try store.share();
        errdefer shared.deinit();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .network = network,
            .options = options,
            .applied = .{ .value = try shared.appliedLsn() orelse 0 },
            .store = shared,
        };
        self.thread = try std.Thread.spawn(.{}, follow, .{self});
        return self;
    }

    /// Stops the thread, closes the connection and frees the follower.
    pub fn stop(self: *Follower) void {
        self.clock.stop(&self.applied);
        self.lock.lock();
        if (self.connection) |connection| connection.shutdown();
        self.lock.unlock();
        if (self.thread) |thread| thread.join();
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
        return if (reason == 0) null else @enumFromInt(reason);
    }

    fn stopped(self: *Follower) bool {
        return self.clock.wait(&self.applied, std.math.maxInt(u64), 0) == null;
    }

    fn follow(self: *Follower) void {
        var retry = self.options.first_retry_ns;
        while (!self.stopped()) {
            const followed = self.followOnce() catch |err| blk: {
                log.info("following the master ended: {t}", .{err});
                break :blk false;
            };
            retry = if (followed) self.options.first_retry_ns else @min(retry * 2, self.options.longest_retry_ns);
            _ = self.clock.wait(&self.applied, std.math.maxInt(u64), self.clock.now() + retry) orelse return;
        }
    }

    /// One connection to the master; true if the master streamed to it.
    fn followOnce(self: *Follower) !bool {
        const connection = try self.network.connect(self.options.master_address);
        self.lock.lock();
        self.connection = connection;
        self.lock.unlock();
        defer {
            self.lock.lock();
            self.connection = null;
            self.lock.unlock();
            connection.close();
        }
        // A stop that came before the connection was held.
        if (self.stopped()) return error.Stopped;
        const reader = connection.reader();
        const writer = connection.writer();
        const hello = try replica.hello(&self.store, self.options.token);
        try protocol.write(writer, .{ .hello = hello });
        try writer.flush();
        switch (try replica.receiveAnswer(reader, hello.applied_lsn)) {
            .refused => |reason| {
                log.info("the master turned this replica away: {t}", .{reason});
                self.refusal.store(@intFromEnum(reason), .release);
                return false;
            },
            .stream => {},
            .snapshot => {
                const lsn = try self.loadCopy(reader);
                try replica.sendAck(writer, lsn);
                try writer.flush();
                self.clock.raise(&self.applied, lsn);
            },
        }
        self.refusal.store(0, .release);
        var receiver: replica.ChangeSetReceiver = .{};
        defer receiver.deinit(self.allocator);
        while (true) switch (try receiver.receive(&self.store, try protocol.read(reader))) {
            .part => {},
            .change_set => |lsn| self.clock.raise(&self.applied, lsn),
            .heartbeat => |last| self.master_lsn.store(last, .release),
        };
    }

    /// Receives the master's copy into a file and loads it; returns the
    /// LSN it holds.
    fn loadCopy(self: *Follower, reader: *Io.Reader) !u64 {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}", .{ self.options.copies_directory, self.copies_made });
        self.copies_made += 1;
        const cwd = Io.Dir.cwd();
        cwd.deleteTree(self.io, directory) catch {};
        try cwd.createDirPath(self.io, directory);
        defer cwd.deleteTree(self.io, directory) catch {};
        {
            var file_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const file_path = try std.fmt.bufPrint(&file_path_buffer, "{s}/{s}", .{ directory, KeyValueStore.data_file_name });
            var file = try cwd.createFile(self.io, file_path, .{});
            defer file.close(self.io);
            var buffer: [64 << 10]u8 = undefined;
            var file_writer = file.writer(self.io, &buffer);
            _ = try replica.receiveSnapshot(reader, &file_writer.interface);
            try file_writer.interface.flush();
        }
        return self.store.loadCopy(directory);
    }
};
