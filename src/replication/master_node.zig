//! The master's side of replication on one thread, with no thread of its
//! own: it accepts replicas and holds each one's conversation
//! (master_session.zig) over connections that never block, and asks a
//! `Copier` for the copies replicas need. Whoever runs it waits on what
//! `watch` tells until `deadline`, hands back what was `ready`, then calls
//! `step`: server.zig on a thread of its own, or a simulation that decides
//! when time passes and when copies are made.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const copies = @import("copies.zig");
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

/// A replica served, as the node last saw it.
pub const ReplicaState = struct {
    phase: Phase,
    /// The last change set it applied, as it last acked (0 until it
    /// streams): its lag is the master's last LSN minus this.
    acked_lsn: u64,
    /// When it connected, on the node's clock.
    connected_at: Instant,
    name_buffer: [protocol.max_name_bytes]u8,
    name_length: u8,
    address_buffer: [network.max_address_bytes]u8,
    address_length: u8,

    /// What it calls itself ("" until its hello came).
    pub fn name(self: *const ReplicaState) []const u8 {
        return self.name_buffer[0..self.name_length];
    }

    /// Where it connected from, "host:port".
    pub fn address(self: *const ReplicaState) []const u8 {
        return self.address_buffer[0..self.address_length];
    }

    pub const Phase = enum {
        /// Connected, its hello not answered yet.
        introducing,
        /// A copy is made for it, sent, or loaded.
        copying,
        streaming,
    };
};

/// Makes the copies of the master's database replicas ask for
/// (`makeCopy`), and raises the node's wakeup when some are made.
pub const Copier = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Made = struct { number: u64, failed: bool };

    pub const VTable = struct {
        ask: *const fn (context: *anyopaque, number: u64) Allocator.Error!void,
        take: *const fn (context: *anyopaque) std.ArrayList(Made),
    };

    pub fn ask(self: Copier, number: u64) Allocator.Error!void {
        return self.vtable.ask(self.context, number);
    }

    /// The copies made since the last take, allocated with the node's
    /// allocator: the caller's to free.
    pub fn take(self: Copier) std.ArrayList(Made) {
        return self.vtable.take(self.context);
    }
};

/// Makes copy `number` of `store`'s database in `copies_directory`.
pub fn makeCopy(io: Io, store: *KeyValueStore, copies_directory: []const u8, number: u64) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try copies.directory(&path_buffer, copies_directory, number);
    const cwd = Io.Dir.cwd();
    cwd.deleteTree(io, directory) catch {};
    try cwd.createDirPath(io, directory);
    errdefer cwd.deleteTree(io, directory) catch {};
    try store.copyDatabase(directory);
}

/// A copier with no thread: copies are made when its owner calls
/// `makeNext`, on the owner's thread. For a simulation.
pub const InlineCopier = struct {
    allocator: Allocator,
    io: Io,
    store: KeyValueStore,
    wakeup: Wakeup,
    copies_directory: []const u8,
    asked: std.ArrayList(u64) = .empty,
    made: std.ArrayList(Copier.Made) = .empty,

    pub fn copier(self: *InlineCopier) Copier {
        return .{ .context = self, .vtable = &.{ .ask = ask, .take = take } };
    }

    /// Deletes the copies made and not taken.
    pub fn deinit(self: *InlineCopier) void {
        for (self.made.items) |made| copies.delete(self.io, self.copies_directory, made.number);
        self.made.deinit(self.allocator);
        self.asked.deinit(self.allocator);
        self.store.deinit();
    }

    pub fn waiting(self: *const InlineCopier) usize {
        return self.asked.items.len;
    }

    /// Makes the oldest copy asked for, if any, and raises the wakeup.
    pub fn makeNext(self: *InlineCopier) Allocator.Error!void {
        if (self.asked.items.len == 0) return;
        try self.made.ensureUnusedCapacity(self.allocator, 1);
        const number = self.asked.orderedRemove(0);
        const failed = if (makeCopy(self.io, &self.store, self.copies_directory, number)) false else |err| blk: {
            log.warn("making copy {d} failed: {t}", .{ number, err });
            break :blk true;
        };
        self.made.appendAssumeCapacity(.{ .number = number, .failed = failed });
        self.wakeup.raise();
    }

    fn ask(context: *anyopaque, number: u64) Allocator.Error!void {
        const self: *InlineCopier = @ptrCast(@alignCast(context));
        try self.asked.append(self.allocator, number);
    }

    fn take(context: *anyopaque) std.ArrayList(Copier.Made) {
        const self: *InlineCopier = @ptrCast(@alignCast(context));
        const made = self.made;
        self.made = .empty;
        return made;
    }
};

pub const MasterNode = struct {
    allocator: Allocator,
    /// For the copies' files and the states' lock.
    io: Io,
    options: Options,
    /// The node's own store, a share of the master's.
    store: KeyValueStore,
    listener: Listener,
    /// The owner's: raised by each commit, each copy made, and a stop.
    wakeup: Wakeup,
    copier: Copier,
    /// Each replica served.
    replicas: []?*Replica,
    /// What the listener and the wakeup were ready for at the last wait.
    listener_ready: bool = false,
    wakeup_ready: bool = false,
    /// The copies asked for so far: each one's directory is numbered.
    copies_asked: u64 = 0,
    /// What `replicaStates` tells: the first `states_count`, published by
    /// each step under `states_mutex` (other threads read them).
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
        connected_at: Instant,
        /// Where it connected from: the first `address_length` bytes.
        address_buffer: [network.max_address_bytes]u8 = undefined,
        address_length: u8 = 0,
        /// The copy asked for, or sent, for this replica.
        copy_number: ?u64 = null,
        copy_file: ?Io.File = null,
        copy_reader: Io.File.Reader = undefined,
        copy_buffer: [64 << 10]u8 = undefined,
    };

    /// Listens for replicas of the master `store`. Set the owner's
    /// `commitListener` on the store that writes to the master.
    pub fn init(allocator: Allocator, io: Io, net: Network, store: *KeyValueStore, wakeup: Wakeup, copier: Copier, options: Options) !MasterNode {
        std.debug.assert(options.max_replicas + 2 <= network.max_watched);
        if (try store.changeLogState() == null) return error.NotMaster;
        const replicas = try allocator.alloc(?*Replica, options.max_replicas);
        errdefer allocator.free(replicas);
        @memset(replicas, null);
        const states = try allocator.alloc(ReplicaState, options.max_replicas);
        errdefer allocator.free(states);
        var shared = try store.share();
        errdefer shared.deinit();
        const listener = try net.listen(options.address);
        return .{
            .allocator = allocator,
            .io = io,
            .options = options,
            .store = shared,
            .listener = listener,
            .wakeup = wakeup,
            .copier = copier,
            .replicas = replicas,
            .states = states,
        };
    }

    /// Lets every replica go and stops listening; the wakeup and the
    /// copier stay the owner's.
    pub fn deinit(self: *MasterNode) void {
        for (self.replicas) |*slot| if (slot.*) |replica| self.release(slot, replica);
        self.publishStates();
        self.listener.close();
        self.store.deinit();
        self.allocator.free(self.replicas);
        self.allocator.free(self.states);
    }

    /// Where the node listens (the port chosen, if asked to choose).
    pub fn address(self: *MasterNode, buffer: *[network.max_address_bytes]u8) []const u8 {
        return self.listener.address(buffer);
    }

    /// The replicas served, at most `buffer.len` of them, as the last step
    /// saw them. Any thread.
    pub fn replicaStates(self: *MasterNode, buffer: []ReplicaState) []ReplicaState {
        self.states_mutex.lockUncancelable(self.io);
        defer self.states_mutex.unlock(self.io);
        const count = @min(buffer.len, self.states_count);
        @memcpy(buffer[0..count], self.states[0..count]);
        return buffer[0..count];
    }

    /// Moves every conversation on at `now`, with what was `ready`: takes
    /// the copies made, accepts replicas, receives and sends, and lets go
    /// of the replicas finished or silent for too long.
    pub fn step(self: *MasterNode, now: Instant) void {
        if (self.wakeup_ready) {
            self.wakeup_ready = false;
            self.wakeup.clear();
            self.takeCopies();
        }
        if (self.listener_ready) {
            self.listener_ready = false;
            self.acceptReplicas(now);
        }
        for (self.replicas) |*slot| {
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
        }
        self.publishStates();
    }

    /// What to wait on before the next step: the listener, the wakeup,
    /// then each replica's connection.
    pub fn watch(self: *MasterNode, watched: *[network.max_watched]Watched) []Watched {
        watched[0] = .{ .source = .{ .listener = self.listener }, .wanted = .{ .readable = true } };
        watched[1] = .{ .source = .{ .wakeup = self.wakeup }, .wanted = .{ .readable = true } };
        var count: usize = 2;
        for (self.replicas) |slot| {
            const replica = slot orelse continue;
            watched[count] = .{ .source = .{ .connection = replica.connection }, .wanted = .{
                .readable = replica.session.inbox.unfilled().len > 0,
                .writable = replica.session.outbox.unsent().len > 0,
            } };
            count += 1;
        }
        return watched[0..count];
    }

    /// When to step though nothing is ready, or null for never.
    pub fn deadline(self: *const MasterNode) ?Instant {
        var earliest: ?Instant = null;
        for (self.replicas) |slot| {
            const replica = slot orelse continue;
            const one = replica.session.deadline();
            earliest = if (earliest) |known| @min(known, one) else one;
        }
        return earliest;
    }

    /// What each of `watched` (from `watch`, nothing stepped since) was
    /// ready for.
    pub fn ready(self: *MasterNode, watched: []const Watched) void {
        self.listener_ready = watched[0].ready.readable;
        self.wakeup_ready = watched[1].ready.readable;
        var index: usize = 2;
        for (self.replicas) |slot| {
            const replica = slot orelse continue;
            replica.ready = watched[index].ready;
            index += 1;
        }
    }

    fn publishStates(self: *MasterNode) void {
        self.states_mutex.lockUncancelable(self.io);
        defer self.states_mutex.unlock(self.io);
        self.states_count = 0;
        for (self.replicas) |slot| {
            const replica = slot orelse continue;
            const session = &replica.session;
            const phase: ReplicaState.Phase = switch (session.state) {
                .awaiting_hello => .introducing,
                .making_copy, .sending_copy, .awaiting_copy_ack => .copying,
                .streaming => .streaming,
                // Not served: let go once told.
                .refused => continue,
            };
            const state = &self.states[self.states_count];
            state.* = .{
                .phase = phase,
                .acked_lsn = session.acked_lsn,
                .connected_at = replica.connected_at,
                .name_buffer = undefined,
                .name_length = session.name_length,
                .address_buffer = undefined,
                .address_length = replica.address_length,
            };
            @memcpy(state.name_buffer[0..state.name_length], session.name());
            @memcpy(state.address_buffer[0..state.address_length], replica.address_buffer[0..replica.address_length]);
            self.states_count += 1;
        }
    }

    /// Moves `replica`'s conversation on at `now`: what it received, what
    /// to send.
    fn serve(self: *MasterNode, replica: *Replica, now: Instant) !void {
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

    fn acceptReplicas(self: *MasterNode, now: Instant) void {
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
            slot.* = self.newReplica(connection, now) catch {
                connection.close();
                continue;
            };
        }
    }

    fn newReplica(self: *MasterNode, connection: Connection, now: Instant) !*Replica {
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
            }, now),
            .buffers = buffers,
            .connected_at = now,
        };
        replica.address_length = @intCast(connection.peer(&replica.address_buffer).len);
        return replica;
    }

    /// Closes `replica`'s connection and frees it and its copy.
    fn release(self: *MasterNode, slot: *?*Replica, replica: *Replica) void {
        self.closeCopy(replica);
        replica.connection.close();
        replica.session.deinit(self.store.allocator);
        self.allocator.free(replica.buffers);
        self.allocator.destroy(replica);
        slot.* = null;
    }

    fn askCopy(self: *MasterNode, replica: *Replica) !void {
        replica.copy_number = self.copies_asked;
        self.copies_asked += 1;
        try self.copier.ask(replica.copy_number.?);
    }

    /// Hands each copy made to the replica that asked for it.
    fn takeCopies(self: *MasterNode) void {
        var made = self.copier.take();
        defer made.deinit(self.allocator);
        for (made.items) |copy| {
            const replica = for (self.replicas) |slot| {
                const replica = slot orelse continue;
                if (replica.copy_number == copy.number) break replica;
            } else {
                // Its replica is gone.
                copies.delete(self.io, self.options.copies_directory, copy.number);
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

    fn slotOf(self: *MasterNode, replica: *Replica) *?*Replica {
        for (self.replicas) |*slot| if (slot.* == replica) return slot;
        unreachable;
    }

    fn openCopy(self: *MasterNode, replica: *Replica) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}/{s}", .{ self.options.copies_directory, replica.copy_number.?, KeyValueStore.data_file_name });
        const file = try Io.Dir.cwd().openFile(self.io, path, .{});
        replica.copy_file = file;
        replica.copy_reader = file.reader(self.io, &replica.copy_buffer);
        replica.session.copyMade(&replica.copy_reader.interface);
    }

    /// Closes and deletes `replica`'s copy once sent, or once the replica
    /// is gone. A copy still being made is deleted when it is taken.
    fn closeCopy(self: *MasterNode, replica: *Replica) void {
        const file = replica.copy_file orelse return;
        file.close(self.io);
        replica.copy_file = null;
        copies.delete(self.io, self.options.copies_directory, replica.copy_number.?);
        replica.copy_number = null;
    }
};
