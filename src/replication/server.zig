//! The master's replication threads: a loop that accepts replicas and
//! holds each one's conversation (master_session.zig) over connections
//! that never block, and a worker that makes the copies replicas ask for
//! (it may take minutes; the loop goes on meanwhile). A commit wakes the
//! loop (`commitListener`) to send its change set; a replica that reads
//! nothing sent, or says nothing awaited, for `timeout_ns` is let go: the
//! session's deadlines, checked by the loop on the clock. Each replica
//! acks how far it applied; `replicaStates` tells it, and so its lag.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const Clock = @import("clock.zig").Clock;
const Instant = @import("clock.zig").Instant;
const network = @import("network.zig");
const Network = network.Network;
const Connection = network.Connection;
const Listener = network.Listener;
const Wakeup = network.Wakeup;
const Watched = network.Watched;
const Readiness = network.Readiness;
const MasterSession = @import("master_session.zig").MasterSession;
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
    /// A replica that reads nothing sent, or sends nothing awaited, for
    /// this long is let go (longer than `heartbeat_ns`).
    timeout_ns: u64 = 5 * std.time.ns_per_s,
    /// What a replica loading its copy may take.
    copy_timeout_ns: u64 = 10 * std.time.ns_per_min,
    /// At most `network.max_watched` - 2 (the listener and the wakeup).
    max_replicas: usize = 16,
};

/// A replica served, as the loop last saw it.
pub const ReplicaState = struct {
    phase: Phase,
    /// The last change set it applied, as it last acked (0 until it
    /// streams): its lag is the master's last LSN minus this.
    acked_lsn: u64,

    pub const Phase = enum {
        /// Connected, its hello not answered yet.
        introducing,
        /// A copy is made for it, sent, or loaded.
        copying,
        streaming,
    };
};

pub const Server = struct {
    allocator: Allocator,
    /// For the copies' files and the worker's lock.
    io: Io,
    clock: Clock,
    network: Network,
    options: Options,
    /// The loop's store, which the worker's shares.
    store: KeyValueStore,
    listener: Listener,
    /// Raised by each commit, each copy made, and `stop`.
    wakeup: Wakeup,
    stopping: std.atomic.Value(bool) = .init(false),
    loop_thread: ?std.Thread = null,
    copier: Copier,
    /// Each replica served, the loop's alone.
    replicas: []?*Replica,
    /// The copies asked for so far: each one's directory is numbered.
    copies_asked: u64 = 0,
    /// What `replicaStates` tells: the first `states_count`, published by
    /// the loop under `states_mutex`.
    states: []ReplicaState,
    states_count: usize = 0,
    states_mutex: Io.Mutex = .init,

    const Replica = struct {
        connection: Connection,
        session: MasterSession,
        /// The session's inbox and outbox.
        buffers: []u8,
        /// What the connection was ready for at the last wait.
        ready: Readiness = .{},
        /// The copy asked for, or sent, for this replica.
        copy_number: ?u64 = null,
        copy_file: ?Io.File = null,
        copy_reader: Io.File.Reader = undefined,
        copy_buffer: [64 << 10]u8 = undefined,
    };

    /// Listens for replicas of the master `store` and starts accepting
    /// them. Set `commitListener` on the store that writes to the master.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, net: Network, store: *KeyValueStore, options: Options) !*Server {
        std.debug.assert(options.max_replicas + 2 <= network.max_watched);
        if (try store.changeLogState() == null) return error.NotMaster;
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        const replicas = try allocator.alloc(?*Replica, options.max_replicas);
        errdefer allocator.free(replicas);
        @memset(replicas, null);
        const states = try allocator.alloc(ReplicaState, options.max_replicas);
        errdefer allocator.free(states);
        var shared = try store.share();
        errdefer shared.deinit();
        var copier_store = try store.share();
        errdefer copier_store.deinit();
        const listener = try net.listen(options.address);
        errdefer listener.close();
        const wakeup = try net.wakeup();
        errdefer wakeup.close();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .network = net,
            .options = options,
            .store = shared,
            .listener = listener,
            .wakeup = wakeup,
            .copier = .{ .allocator = allocator, .io = io, .store = copier_store, .wakeup = wakeup, .copies_directory = options.copies_directory },
            .replicas = replicas,
            .states = states,
        };
        try self.copier.start();
        errdefer self.copier.stop();
        self.loop_thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops every thread, closes every connection and frees the server.
    /// Unset the `commitListener` first: it points to the server.
    pub fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        self.wakeup.raise();
        if (self.loop_thread) |thread| thread.join();
        self.copier.stop();
        self.copier.deinit();
        self.listener.close();
        self.wakeup.close();
        self.store.deinit();
        self.allocator.free(self.replicas);
        self.allocator.free(self.states);
        self.allocator.destroy(self);
    }

    /// Where the server listens (the port chosen, if asked to choose).
    pub fn address(self: *Server, buffer: *[network.max_address_bytes]u8) []const u8 {
        return self.listener.address(buffer);
    }

    /// The replicas served now, at most `buffer.len` of them, as the loop
    /// last saw them (it looks at least each heartbeat).
    pub fn replicaStates(self: *Server, buffer: []ReplicaState) []ReplicaState {
        self.states_mutex.lockUncancelable(self.io);
        defer self.states_mutex.unlock(self.io);
        const count = @min(buffer.len, self.states_count);
        @memcpy(buffer[0..count], self.states[0..count]);
        return buffer[0..count];
    }

    /// For the master's writing store (`KeyValueStore.commit_listener`).
    pub fn commitListener(self: *Server) KeyValueStore.CommitListener {
        return .{ .context = self, .committed = committed };
    }

    fn committed(context: *anyopaque, lsn: u64) void {
        _ = lsn;
        const self: *Server = @ptrCast(@alignCast(context));
        self.wakeup.raise();
    }

    fn run(self: *Server) void {
        defer {
            for (self.replicas) |*slot| if (slot.*) |replica| self.release(slot, replica);
            self.publishStates();
        }
        var watched: [network.max_watched]Watched = undefined;
        // The replica each watched connection is of, from `watched[2]` on.
        var watched_slots: [network.max_watched]usize = undefined;
        while (!self.stopping.load(.acquire)) {
            const now = self.clock.now();
            var deadline: Instant = std.math.maxInt(Instant);
            watched[0] = .{ .source = .{ .listener = self.listener }, .wanted = .{ .readable = true } };
            watched[1] = .{ .source = .{ .wakeup = self.wakeup }, .wanted = .{ .readable = true } };
            var count: usize = 2;
            for (self.replicas, 0..) |*slot, index| {
                const replica = slot.* orelse continue;
                self.serve(replica, now) catch |err| {
                    log.info("a replica's conversation ended: {t}", .{err});
                    self.release(slot, replica);
                    continue;
                };
                if (replica.session.finished()) {
                    self.release(slot, replica);
                    continue;
                }
                if (replica.session.expired(now)) {
                    log.info("a replica was let go: silent for too long", .{});
                    self.release(slot, replica);
                    continue;
                }
                deadline = @min(deadline, replica.session.deadline());
                watched[count] = .{ .source = .{ .connection = replica.connection }, .wanted = .{
                    .readable = replica.session.inbox.unfilled().len > 0,
                    .writable = replica.session.outbox.unsent().len > 0,
                } };
                watched_slots[count] = index;
                count += 1;
            }
            self.publishStates();
            const timeout: ?u64 = if (deadline == std.math.maxInt(Instant)) null else deadline -| now;
            self.network.wait(watched[0..count], timeout) catch |err| {
                log.warn("waiting on the network failed: {t}", .{err});
                continue;
            };
            for (watched[2..count], watched_slots[2..count]) |one, index| self.replicas[index].?.ready = one.ready;
            if (watched[1].ready.readable) {
                self.wakeup.clear();
                self.takeCopies();
            }
            if (watched[0].ready.readable) self.acceptReplicas();
        }
    }

    fn publishStates(self: *Server) void {
        self.states_mutex.lockUncancelable(self.io);
        defer self.states_mutex.unlock(self.io);
        self.states_count = 0;
        for (self.replicas) |slot| {
            const session = &(slot orelse continue).session;
            const phase: ReplicaState.Phase = switch (session.state) {
                .awaiting_hello => .introducing,
                .making_copy, .sending_copy, .awaiting_copy_ack => .copying,
                .streaming => .streaming,
                // Not served: let go once told.
                .refused => continue,
            };
            self.states[self.states_count] = .{ .phase = phase, .acked_lsn = session.acked_lsn };
            self.states_count += 1;
        }
    }

    /// Moves `replica`'s conversation on at `now`: what it received, what
    /// to send.
    fn serve(self: *Server, replica: *Replica, now: Instant) !void {
        const session = &replica.session;
        if (replica.ready.readable) {
            while (session.inbox.unfilled().len > 0) {
                const count = replica.connection.receive(session.inbox.unfilled()) catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.Closed => return error.ConnectionClosed,
                };
                session.received(count, now);
                while (try session.next(&self.store)) |event| switch (event) {
                    .make_copy => try self.askCopy(replica),
                };
            }
        }
        replica.ready = .{};
        while (true) {
            try session.pump(&self.store, now);
            if (session.state != .sending_copy) self.closeCopy(replica);
            const unsent = session.outbox.unsent();
            if (unsent.len == 0) return;
            const count = replica.connection.send(unsent) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Closed => return error.ConnectionClosed,
            };
            session.sent(count, now);
        }
    }

    fn acceptReplicas(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch |err| {
                log.warn("accepting a replica failed: {t}", .{err});
                return;
            } orelse return;
            const slot = for (self.replicas) |*slot| {
                if (slot.* == null) break slot;
            } else {
                log.warn("a replica was turned away: {d} are served already", .{self.replicas.len});
                connection.close();
                continue;
            };
            slot.* = self.newReplica(connection) catch {
                connection.close();
                continue;
            };
        }
    }

    fn newReplica(self: *Server, connection: Connection) !*Replica {
        const replica = try self.allocator.create(Replica);
        errdefer self.allocator.destroy(replica);
        const buffers = try self.allocator.alloc(u8, 2 * protocol.max_frame_bytes);
        replica.* = .{
            .connection = connection,
            .session = .init(buffers[0..protocol.max_frame_bytes], buffers[protocol.max_frame_bytes..], .{
                .token = self.options.token,
                .heartbeat_ns = self.options.heartbeat_ns,
                .timeout_ns = self.options.timeout_ns,
                .copy_timeout_ns = self.options.copy_timeout_ns,
            }, self.clock.now()),
            .buffers = buffers,
        };
        return replica;
    }

    /// Closes `replica`'s connection and frees it and its copy.
    fn release(self: *Server, slot: *?*Replica, replica: *Replica) void {
        self.closeCopy(replica);
        replica.connection.close();
        replica.session.deinit(self.store.allocator);
        self.allocator.free(replica.buffers);
        self.allocator.destroy(replica);
        slot.* = null;
    }

    fn askCopy(self: *Server, replica: *Replica) !void {
        replica.copy_number = self.copies_asked;
        self.copies_asked += 1;
        try self.copier.ask(replica.copy_number.?);
    }

    /// Hands each copy the worker made to the replica that asked for it.
    fn takeCopies(self: *Server) void {
        var made = self.copier.take();
        defer made.deinit(self.allocator);
        for (made.items) |copy| {
            const replica = for (self.replicas) |slot| {
                const replica = slot orelse continue;
                if (replica.copy_number == copy.number) break replica;
            } else {
                // Its replica is gone.
                self.copier.deleteCopy(copy.number);
                continue;
            };
            if (copy.failed) {
                log.warn("making a copy for a replica failed", .{});
                self.release(self.slotOf(replica), replica);
                continue;
            }
            self.openCopy(replica) catch |err| {
                log.warn("opening a copy for a replica failed: {t}", .{err});
                self.release(self.slotOf(replica), replica);
                continue;
            };
        }
    }

    fn slotOf(self: *Server, replica: *Replica) *?*Replica {
        for (self.replicas) |*slot| if (slot.* == replica) return slot;
        unreachable;
    }

    fn openCopy(self: *Server, replica: *Replica) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}/{s}", .{ self.options.copies_directory, replica.copy_number.?, KeyValueStore.data_file_name });
        const file = try Io.Dir.cwd().openFile(self.io, path, .{});
        replica.copy_file = file;
        replica.copy_reader = file.reader(self.io, &replica.copy_buffer);
        replica.session.copyMade(&replica.copy_reader.interface);
    }

    /// Closes and deletes `replica`'s copy once sent, or once the replica
    /// is gone. A copy still being made is deleted when the worker is done.
    fn closeCopy(self: *Server, replica: *Replica) void {
        const file = replica.copy_file orelse return;
        file.close(self.io);
        replica.copy_file = null;
        self.copier.deleteCopy(replica.copy_number.?);
        replica.copy_number = null;
    }
};

/// The worker that makes copies of the master's database, one at a time,
/// each in directory `copy-N` of `copies_directory`; the loop asks for
/// them and takes them when the wakeup tells it some are made.
const Copier = struct {
    allocator: Allocator,
    io: Io,
    store: KeyValueStore,
    wakeup: Wakeup,
    copies_directory: []const u8,
    thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Under `mutex`.
    asked: std.ArrayList(u64) = .empty,
    made: std.ArrayList(Made) = .empty,
    stopping: bool = false,

    const Made = struct { number: u64, failed: bool };

    fn start(self: *Copier) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Waits for the copy being made, if one is.
    fn stop(self: *Copier) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    /// Once stopped: deletes the copies made and not taken.
    fn deinit(self: *Copier) void {
        for (self.made.items) |made| self.deleteCopy(made.number);
        self.made.deinit(self.allocator);
        self.asked.deinit(self.allocator);
        self.store.deinit();
    }

    fn ask(self: *Copier, number: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.asked.append(self.allocator, number);
        self.condition.signal(self.io);
    }

    /// The copies made since the last take: the caller's to free.
    fn take(self: *Copier) std.ArrayList(Made) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const made = self.made;
        self.made = .empty;
        return made;
    }

    fn run(self: *Copier) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            while (!self.stopping and self.asked.items.len == 0) self.condition.waitUncancelable(self.io, &self.mutex);
            if (self.stopping) return;
            const number = self.asked.orderedRemove(0);
            self.mutex.unlock(self.io);
            const failed = if (self.makeCopy(number)) false else |err| blk: {
                log.warn("making copy {d} failed: {t}", .{ number, err });
                break :blk true;
            };
            self.mutex.lockUncancelable(self.io);
            // The loop is gone once stopping: `Server.stop` deletes it.
            self.made.append(self.allocator, .{ .number = number, .failed = failed }) catch {
                self.mutex.unlock(self.io);
                self.deleteCopy(number);
                self.mutex.lockUncancelable(self.io);
                continue;
            };
            self.wakeup.raise();
        }
    }

    fn makeCopy(self: *Copier, number: u64) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}", .{ self.copies_directory, number });
        const cwd = Io.Dir.cwd();
        cwd.deleteTree(self.io, directory) catch {};
        try cwd.createDirPath(self.io, directory);
        errdefer cwd.deleteTree(self.io, directory) catch {};
        try self.store.copyDatabase(directory);
    }

    fn deleteCopy(self: *Copier, number: u64) void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const directory = std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}", .{ self.copies_directory, number }) catch return;
        Io.Dir.cwd().deleteTree(self.io, directory) catch {};
    }
};
