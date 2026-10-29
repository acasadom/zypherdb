//! The master's replication threads: one accepts replicas, and each
//! replica gets a thread of its own that holds the conversation of
//! master.zig with it. That thread sends the change sets each commit makes
//! (woken by `commitListener`), and a heartbeat when none came for a while.
//! It does not read while streaming: a replica only acks a copy.
//!
//! TEMPORARY, to be replaced: a thread per replica with blocking I/O. A
//! replica that stops reading blocks its thread in a write (no write
//! deadline), and the master never learns a replica's lag. The direction:
//! one event-driven I/O thread, write deadlines, a bounded backlog per
//! replica, acks read while streaming.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const master = @import("master.zig");
const Clock = @import("clock.zig").Clock;
const Signal = @import("clock.zig").Signal;
const Network = @import("network.zig").Network;
const Connection = @import("network.zig").Connection;
const Listener = @import("network.zig").Listener;
const SpinLock = @import("spin_lock.zig").SpinLock;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;

const log = std.log.scoped(.replication);

pub const Options = struct {
    /// Where to listen, "host:port".
    address: []const u8,
    /// What a replica must send to be served.
    token: []const u8,
    /// A directory for the copies sent to replicas, each in a directory of
    /// its own, deleted once sent.
    copies_directory: []const u8,
    heartbeat_ns: u64 = std.time.ns_per_s,
    max_replicas: usize = 16,
};

pub const Server = struct {
    allocator: Allocator,
    /// For the copies' files.
    io: Io,
    clock: Clock,
    network: Network,
    options: Options,
    /// The master's last LSN, raised by each commit.
    signal: Signal = .{},
    /// The accept thread's store, which each replica's store shares.
    store: KeyValueStore,
    listener: Listener,
    accept_thread: ?std.Thread = null,
    lock: SpinLock = .{},
    /// Each replica served or just served, by its thread (under `lock`).
    replicas: []Replica,
    copies_made: std.atomic.Value(u64) = .init(0),

    const Replica = struct {
        thread: ?std.Thread = null,
        connection: ?Connection = null,
        done: std.atomic.Value(bool) = .init(true),
    };

    /// Listens for replicas of the master `store` and starts accepting
    /// them. Set `commitListener` on the store that writes to the master.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, network: Network, store: *KeyValueStore, options: Options) !*Server {
        const state = try store.changeLogState() orelse return error.NotMaster;
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const replicas = try allocator.alloc(Replica, options.max_replicas);
        errdefer allocator.free(replicas);
        @memset(replicas, .{});
        var shared = try store.share();
        errdefer shared.deinit();
        const listener = try network.listen(options.address);
        errdefer listener.close();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .network = network,
            .options = options,
            .signal = .{ .value = state.next_lsn - 1 },
            .store = shared,
            .listener = listener,
            .replicas = replicas,
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptReplicas, .{self});
        return self;
    }

    /// Stops every thread, closes every connection and frees the server.
    /// Unset the `commitListener` first: it points to the server.
    pub fn stop(self: *Server) void {
        self.clock.stop(&self.signal);
        self.listener.shutdown();
        if (self.accept_thread) |thread| thread.join();
        self.lock.lock();
        for (self.replicas) |replica| if (replica.connection) |connection| connection.shutdown();
        self.lock.unlock();
        for (self.replicas) |replica| if (replica.thread) |thread| thread.join();
        self.listener.close();
        self.store.deinit();
        self.allocator.free(self.replicas);
        self.allocator.destroy(self);
    }

    /// Where the server listens (the port chosen, if asked to choose).
    pub fn address(self: *Server, buffer: *[@import("network.zig").max_address_bytes]u8) []const u8 {
        return self.listener.address(buffer);
    }

    /// For the master's writing store (`KeyValueStore.commit_listener`).
    pub fn commitListener(self: *Server) KeyValueStore.CommitListener {
        return .{ .context = self, .committed = committed };
    }

    fn committed(context: *anyopaque, lsn: u64) void {
        const self: *Server = @ptrCast(@alignCast(context));
        self.clock.raise(&self.signal, lsn);
    }

    fn acceptReplicas(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch |err| switch (err) {
                error.ListenerShutDown => return,
                else => {
                    log.warn("accepting a replica failed: {t}", .{err});
                    continue;
                },
            };
            const slot = self.freeSlot() orelse {
                log.warn("a replica was turned away: {d} are served already", .{self.replicas.len});
                connection.close();
                continue;
            };
            const replica = &self.replicas[slot];
            var store = self.store.share() catch {
                connection.close();
                continue;
            };
            self.lock.lock();
            replica.connection = connection;
            replica.done.store(false, .release);
            self.lock.unlock();
            replica.thread = std.Thread.spawn(.{}, serveReplica, .{ self, replica, store }) catch {
                self.release(replica);
                store.deinit();
                continue;
            };
        }
    }

    /// A slot whose thread is done, joined.
    fn freeSlot(self: *Server) ?usize {
        for (self.replicas, 0..) |*replica, slot| {
            if (!replica.done.load(.acquire)) continue;
            if (replica.thread) |thread| thread.join();
            replica.thread = null;
            return slot;
        }
        return null;
    }

    /// Takes `replica`'s connection from those `stop` shuts down, and
    /// closes it.
    fn release(self: *Server, replica: *Replica) void {
        self.lock.lock();
        const connection = replica.connection.?;
        replica.connection = null;
        self.lock.unlock();
        connection.close();
        replica.done.store(true, .release);
    }

    fn serveReplica(self: *Server, replica: *Replica, store_shared: KeyValueStore) void {
        var store = store_shared;
        defer store.deinit();
        defer self.release(replica);
        self.converse(&store, replica.connection.?) catch |err| switch (err) {
            error.Stopped => {},
            else => log.info("a replica's conversation ended: {t}", .{err}),
        };
    }

    fn converse(self: *Server, store: *KeyValueStore, connection: Connection) !void {
        const reader = connection.reader();
        const writer = connection.writer();
        const hello = switch (try protocol.read(reader)) {
            .hello => |hello| hello,
            else => return error.UnexpectedMessage,
        };
        var answer = try master.answer(store, hello, self.options.token);
        if (answer == .snapshot) {
            try self.sendCopy(store, writer);
            const acked = switch (try protocol.read(reader)) {
                .ack => |lsn| lsn,
                else => return error.UnexpectedMessage,
            };
            answer = try master.resumeFrom(store, acked);
            // Its log moved past the copy meanwhile: the replica comes
            // back for another.
            if (answer != .stream) return error.CopyOutdated;
        } else {
            switch (answer) {
                .refused => |reason| try protocol.write(writer, .{ .refused = reason }),
                .stream => |first| try protocol.write(writer, .{ .stream = first }),
                .snapshot => unreachable,
            }
            try writer.flush();
        }
        var next = switch (answer) {
            .stream => |first| first,
            else => return,
        };
        try self.stream(store, writer, &next);
    }

    fn sendCopy(self: *Server, store: *KeyValueStore, writer: *Io.Writer) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}", .{ self.options.copies_directory, self.copies_made.fetchAdd(1, .monotonic) });
        const cwd = Io.Dir.cwd();
        cwd.deleteTree(self.io, directory) catch {};
        try cwd.createDirPath(self.io, directory);
        defer cwd.deleteTree(self.io, directory) catch {};
        try store.copyDatabase(directory);
        var file_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&file_path_buffer, "{s}/{s}", .{ directory, KeyValueStore.data_file_name });
        var file = try cwd.openFile(self.io, file_path, .{});
        defer file.close(self.io);
        var buffer: [64 << 10]u8 = undefined;
        var file_reader = file.reader(self.io, &buffer);
        try master.sendSnapshot(writer, &file_reader.interface);
        try writer.flush();
    }

    /// Sends the change sets from `next.*` as they are committed, and a
    /// heartbeat each `heartbeat_ns` with none, until stopped.
    fn stream(self: *Server, store: *KeyValueStore, writer: *Io.Writer, next: *u64) !void {
        var deadline = self.clock.now();
        while (true) {
            if (try master.sendChangeSets(store, writer, next) > 0) {
                try writer.flush();
                deadline = self.clock.now() + self.options.heartbeat_ns;
            }
            if (self.clock.now() >= deadline) {
                try master.sendHeartbeat(store, writer);
                try writer.flush();
                deadline = self.clock.now() + self.options.heartbeat_ns;
            }
            _ = self.clock.wait(&self.signal, next.* - 1, deadline) orelse return error.Stopped;
        }
    }
};
