//! The master's side of replication on one thread, with no thread of its
//! own: it accepts replicas and holds each one's conversation
//! (master_session.zig) over connections that never block, and asks a
//! `Copier` for the copies replicas need. A replica's connection for
//! forwarded writes (writer_session.zig) is held here too, and a `Runner`
//! runs the writes, one at a time. Whoever runs it waits on what
//! `watch` tells until `deadline`, hands back what was `ready`, then calls
//! `step`: server.zig on a thread of its own, or a simulation that decides
//! when time passes, when copies are made and when writes run.

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
const WriterSession = @import("writer_session.zig").WriterSession;
const forwarded_writes = @import("forwarded_writes.zig");
const Graph = @import("../storage/graph.zig").Graph;
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
    /// At most (`network.max_watched` - 2) / 2: besides the listener and
    /// the wakeup, each replica may hold a second connection, for its
    /// forwarded writes.
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

/// Runs the writes replicas forward (`run`), one at a time and in order,
/// and raises the node's wakeup when some are answered.
pub const Runner = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Asked = struct {
        number: u64,
        /// The request's bytes, allocated with the node's allocator.
        request: []u8,
    };

    pub const Ran = struct {
        number: u64,
        /// The answer's bytes, allocated with the node's allocator; null
        /// if not even an answer could be made: the replica is let go.
        answer: ?[]u8,
    };

    pub const VTable = struct {
        run: *const fn (context: *anyopaque, asked: Asked) Allocator.Error!void,
        take: *const fn (context: *anyopaque) std.ArrayList(Ran),
    };

    /// Takes the request's bytes, also on failure.
    pub fn run(self: Runner, asked: Asked) Allocator.Error!void {
        return self.vtable.run(self.context, asked);
    }

    /// The writes run since the last take, allocated with the node's
    /// allocator: the caller's to free.
    pub fn take(self: Runner) std.ArrayList(Ran) {
        return self.vtable.take(self.context);
    }
};

/// Runs `asked` on the master `store`, freeing its request.
pub fn runWrite(allocator: Allocator, store: *KeyValueStore, asked: Runner.Asked) Runner.Ran {
    defer allocator.free(asked.request);
    var graph: Graph = .init(store, allocator);
    const answer = forwarded_writes.run(&graph, allocator, asked.request) catch |err| blk: {
        log.warn("running a forwarded write failed: {t}", .{err});
        break :blk null;
    };
    return .{ .number = asked.number, .answer = answer };
}

/// A runner with no thread: writes run when its owner calls `runNext`, on
/// the owner's thread. For a simulation.
pub const InlineRunner = struct {
    allocator: Allocator,
    store: KeyValueStore,
    wakeup: Wakeup,
    asked: std.ArrayList(Runner.Asked) = .empty,
    ran: std.ArrayList(Runner.Ran) = .empty,

    pub fn runner(self: *InlineRunner) Runner {
        return .{ .context = self, .vtable = &.{ .run = run, .take = take } };
    }

    /// Frees the requests not run and the answers not taken.
    pub fn deinit(self: *InlineRunner) void {
        for (self.asked.items) |asked| self.allocator.free(asked.request);
        self.asked.deinit(self.allocator);
        for (self.ran.items) |ran| if (ran.answer) |answer| self.allocator.free(answer);
        self.ran.deinit(self.allocator);
        self.store.deinit();
    }

    pub fn waiting(self: *const InlineRunner) usize {
        return self.asked.items.len;
    }

    /// Runs the oldest write asked for, if any, and raises the wakeup.
    pub fn runNext(self: *InlineRunner) Allocator.Error!void {
        if (self.asked.items.len == 0) return;
        try self.ran.ensureUnusedCapacity(self.allocator, 1);
        self.ran.appendAssumeCapacity(runWrite(self.allocator, &self.store, self.asked.orderedRemove(0)));
        self.wakeup.raise();
    }

    fn run(context: *anyopaque, asked: Runner.Asked) Allocator.Error!void {
        const self: *InlineRunner = @ptrCast(@alignCast(context));
        self.asked.append(self.allocator, asked) catch |err| {
            self.allocator.free(asked.request);
            return err;
        };
    }

    fn take(context: *anyopaque) std.ArrayList(Runner.Ran) {
        const self: *InlineRunner = @ptrCast(@alignCast(context));
        const ran = self.ran;
        self.ran = .empty;
        return ran;
    }
};

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
    /// The owner's: raised by each commit, each copy made, each write
    /// run, and a stop.
    wakeup: Wakeup,
    copier: Copier,
    runner: Runner,
    /// Each connection held: twice `max_replicas`.
    peers: []?*Peer,
    /// What the listener and the wakeup were ready for at the last wait.
    listener_ready: bool = false,
    wakeup_ready: bool = false,
    /// The wakeup was cleared since the last step: copies made or writes
    /// run may wait.
    woken: bool = false,
    /// The copies asked for so far: each one's directory is numbered.
    copies_asked: u64 = 0,
    /// The writes run so far: each is numbered.
    writes_asked: u64 = 0,
    /// What `replicaStates` tells: the first `states_count`, published by
    /// each step under `states_mutex` (other threads read them).
    states: []ReplicaState,
    states_count: usize = 0,
    states_mutex: Io.Mutex = .init,

    /// A connection: a replica's, or, once it said so, a replica's for its
    /// forwarded writes.
    const Peer = struct {
        connection: Connection,
        conversation: union(enum) {
            replica: MasterSession,
            writer: WriterSession,
        },
        /// The sessions' inbox and outbox.
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
        /// The write run for this writer, until it is answered.
        write_number: ?u64 = null,
    };

    /// Listens for replicas of the master `store`. Set the owner's
    /// `commitListener` on the store that writes to the master.
    pub fn init(allocator: Allocator, io: Io, net: Network, store: *KeyValueStore, wakeup: Wakeup, copier: Copier, runner: Runner, options: Options) !MasterNode {
        std.debug.assert(2 * options.max_replicas + 2 <= network.max_watched);
        if (try store.changeLogState() == null) return error.NotMaster;
        const peers = try allocator.alloc(?*Peer, 2 * options.max_replicas);
        errdefer allocator.free(peers);
        @memset(peers, null);
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
            .runner = runner,
            .peers = peers,
            .states = states,
        };
    }

    /// Lets every replica go and stops listening; the wakeup, the copier
    /// and the runner stay the owner's.
    pub fn deinit(self: *MasterNode) void {
        for (self.peers) |*slot| if (slot.*) |peer| self.release(slot, peer);
        self.publishStates();
        self.listener.close();
        self.store.deinit();
        self.allocator.free(self.peers);
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
    /// the copies made and the writes run, accepts replicas, receives and
    /// sends, and lets go of the replicas finished or silent for too long.
    pub fn step(self: *MasterNode, now: Instant) void {
        self.clearWakeup();
        if (self.woken) {
            self.woken = false;
            self.takeCopies();
            self.takeWrites();
        }
        if (self.listener_ready) {
            self.listener_ready = false;
            self.acceptPeers(now);
        }
        for (self.peers) |*slot| {
            const peer = slot.* orelse continue;
            self.serve(peer, now) catch |err| {
                log.info("a replica's conversation ended: {t}", .{err});
                self.release(slot, peer);
                continue;
            };
            switch (peer.conversation) {
                inline else => |*session| {
                    if (session.finished()) {
                        self.release(slot, peer);
                        continue;
                    }
                    if (session.expired(now)) {
                        log.info("a replica was let go: silent for too long", .{});
                        self.release(slot, peer);
                        continue;
                    }
                },
            }
        }
        self.publishStates();
    }

    /// Clears the wakeup if it was ready: before the owner looks at what
    /// raised it, or a raise meanwhile is lost. `step` does it too.
    pub fn clearWakeup(self: *MasterNode) void {
        if (!self.wakeup_ready) return;
        self.wakeup_ready = false;
        self.wakeup.clear();
        self.woken = true;
    }

    /// What to wait on before the next step: the listener, the wakeup,
    /// then each connection.
    pub fn watch(self: *MasterNode, watched: *[network.max_watched]Watched) []Watched {
        watched[0] = .{ .source = .{ .listener = self.listener }, .wanted = .{ .readable = true } };
        watched[1] = .{ .source = .{ .wakeup = self.wakeup }, .wanted = .{ .readable = true } };
        var count: usize = 2;
        for (self.peers) |slot| {
            const peer = slot orelse continue;
            switch (peer.conversation) {
                inline else => |*session| watched[count] = .{ .source = .{ .connection = peer.connection }, .wanted = .{
                    .readable = session.inbox.unfilled().len > 0,
                    .writable = session.outbox.unsent().len > 0,
                } },
            }
            count += 1;
        }
        return watched[0..count];
    }

    /// When to step though nothing is ready, or null for never.
    pub fn deadline(self: *const MasterNode) ?Instant {
        var earliest: ?Instant = null;
        for (self.peers) |slot| {
            const peer = slot orelse continue;
            const one = switch (peer.conversation) {
                inline else => |*session| session.deadline(),
            };
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
        for (self.peers) |slot| {
            const peer = slot orelse continue;
            peer.ready = watched[index].ready;
            index += 1;
        }
    }

    fn publishStates(self: *MasterNode) void {
        self.states_mutex.lockUncancelable(self.io);
        defer self.states_mutex.unlock(self.io);
        self.states_count = 0;
        for (self.peers) |slot| {
            const peer = slot orelse continue;
            // A writer is told by its replica's state.
            const session = switch (peer.conversation) {
                .replica => |*session| session,
                .writer => continue,
            };
            const phase: ReplicaState.Phase = switch (session.state) {
                .awaiting_hello => .introducing,
                .making_copy, .sending_copy, .awaiting_copy_ack => .copying,
                .streaming => .streaming,
                // Not served: let go once told.
                .refused => continue,
            };
            // Connections not introduced yet may be writers: at most
            // `max_replicas` are told.
            if (self.states_count == self.states.len) break;
            const state = &self.states[self.states_count];
            state.* = .{
                .phase = phase,
                .acked_lsn = session.acked_lsn,
                .connected_at = peer.connected_at,
                .name_buffer = undefined,
                .name_length = session.name_length,
                .address_buffer = undefined,
                .address_length = peer.address_length,
            };
            @memcpy(state.name_buffer[0..state.name_length], session.name());
            @memcpy(state.address_buffer[0..state.address_length], peer.address_buffer[0..peer.address_length]);
            self.states_count += 1;
        }
    }

    /// Moves `peer`'s conversation on at `now`: what it received, what to
    /// send.
    fn serve(self: *MasterNode, peer: *Peer, now: Instant) !void {
        if (peer.ready.readable) {
            while (true) {
                const unfilled = switch (peer.conversation) {
                    inline else => |*session| session.inbox.unfilled(),
                };
                if (unfilled.len == 0) break;
                const count = peer.connection.receive(unfilled) catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.Closed => return error.ConnectionClosed,
                };
                switch (peer.conversation) {
                    inline else => |*session| session.received(count, now),
                }
                try self.handle(peer, now);
            }
        }
        peer.ready = .{};
        while (true) {
            const outbox = switch (peer.conversation) {
                .replica => |*session| outbox: {
                    try session.pump(&self.store, now);
                    if (session.state != .sending_copy) self.closeCopy(peer);
                    break :outbox &session.outbox;
                },
                .writer => |*session| outbox: {
                    try session.pump(&self.store, now);
                    break :outbox &session.outbox;
                },
            };
            const unsent = outbox.unsent();
            if (unsent.len == 0) return;
            const count = peer.connection.send(unsent) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Closed => return error.ConnectionClosed,
            };
            switch (peer.conversation) {
                inline else => |*session| session.sent(count, now),
            }
        }
    }

    /// Handles the messages `peer` received.
    fn handle(self: *MasterNode, peer: *Peer, now: Instant) !void {
        while (true) switch (peer.conversation) {
            .replica => |*session| {
                const introducing = session.state == .awaiting_hello;
                const next = try session.next(&self.store);
                if (introducing and session.state != .awaiting_hello and session.state != .refused) {
                    if (self.replicasServed() > self.options.max_replicas) return error.TooManyReplicas;
                }
                const event = next orelse return;
                switch (event) {
                    .make_copy => try self.askCopy(peer),
                    .writer => |hello| try self.becomeWriter(peer, hello, now),
                }
            },
            .writer => |*session| {
                const request = try session.next() orelse return;
                const number = self.writes_asked;
                self.writes_asked += 1;
                peer.write_number = number;
                try self.runner.run(.{ .number = number, .request = request });
            },
        };
    }

    /// `peer` turned out a replica's connection for forwarded writes.
    fn becomeWriter(self: *MasterNode, peer: *Peer, hello: protocol.WriterHello, now: Instant) !void {
        if (self.writers() == self.options.max_replicas) return error.TooManyWriters;
        const replica = &peer.conversation.replica;
        var writer: WriterSession = .init(self.allocator, replica.inbox, replica.outbox, .{
            .token = self.options.token,
            .heartbeat_ns = self.options.heartbeat_ns,
            .timeout_ns = self.options.timeout_ns,
        }, now);
        errdefer writer.deinit();
        // Before anything else reads the inbox the hello is in.
        try writer.introduced(&self.store, hello);
        replica.deinit(self.store.allocator);
        peer.conversation = .{ .writer = writer };
    }

    /// The replicas served: introduced, not refused.
    fn replicasServed(self: *const MasterNode) usize {
        var total: usize = 0;
        for (self.peers) |slot| {
            const peer = slot orelse continue;
            switch (peer.conversation) {
                .replica => |*session| if (session.state != .awaiting_hello and session.state != .refused) {
                    total += 1;
                },
                .writer => {},
            }
        }
        return total;
    }

    /// The replicas' connections for forwarded writes, refused ones among
    /// them.
    fn writers(self: *const MasterNode) usize {
        var total: usize = 0;
        for (self.peers) |slot| {
            const peer = slot orelse continue;
            if (peer.conversation == .writer) total += 1;
        }
        return total;
    }

    fn acceptPeers(self: *MasterNode, now: Instant) void {
        while (true) {
            const connection = self.listener.accept() catch |err| {
                log.warn("accepting a replica failed: {t}", .{err});
                return;
            } orelse return;
            const slot = for (self.peers) |*slot| {
                if (slot.* == null) break slot;
            } else {
                log.warn("a replica was turned away: {d} connections are held already", .{self.peers.len});
                connection.close();
                continue;
            };
            slot.* = self.newPeer(connection, now) catch {
                connection.close();
                continue;
            };
        }
    }

    fn newPeer(self: *MasterNode, connection: Connection, now: Instant) !*Peer {
        const peer = try self.allocator.create(Peer);
        errdefer self.allocator.destroy(peer);
        const buffers = try self.allocator.alloc(u8, 2 * protocol.max_frame_bytes);
        peer.* = .{
            .connection = connection,
            .conversation = .{ .replica = .init(buffers[0..protocol.max_frame_bytes], buffers[protocol.max_frame_bytes..], .{
                .token = self.options.token,
                .heartbeat_ns = self.options.heartbeat_ns,
                .timeout_ns = self.options.timeout_ns,
                .copy_timeout_ns = self.options.copy_timeout_ns,
            }, now) },
            .buffers = buffers,
            .connected_at = now,
        };
        peer.address_length = @intCast(connection.peer(&peer.address_buffer).len);
        return peer;
    }

    /// Closes `peer`'s connection and frees it and its copy. A write
    /// running for it is answered to no one.
    fn release(self: *MasterNode, slot: *?*Peer, peer: *Peer) void {
        self.closeCopy(peer);
        peer.connection.close();
        switch (peer.conversation) {
            .replica => |*session| session.deinit(self.store.allocator),
            .writer => |*session| session.deinit(),
        }
        self.allocator.free(peer.buffers);
        self.allocator.destroy(peer);
        slot.* = null;
    }

    fn askCopy(self: *MasterNode, peer: *Peer) !void {
        peer.copy_number = self.copies_asked;
        self.copies_asked += 1;
        try self.copier.ask(peer.copy_number.?);
    }

    /// Hands each copy made to the replica that asked for it.
    fn takeCopies(self: *MasterNode) void {
        var made = self.copier.take();
        defer made.deinit(self.allocator);
        for (made.items) |copy| {
            const peer = for (self.peers) |slot| {
                const peer = slot orelse continue;
                if (peer.copy_number == copy.number) break peer;
            } else {
                // Its replica is gone.
                copies.delete(self.io, self.options.copies_directory, copy.number);
                continue;
            };
            if (copy.failed) {
                log.warn("making a copy for a replica failed", .{});
                self.release(self.slotOf(peer), peer);
                continue;
            }
            self.openCopy(peer) catch |err| {
                log.warn("opening a copy for a replica failed: {t}", .{err});
                self.release(self.slotOf(peer), peer);
                continue;
            };
        }
    }

    /// Hands each write run to the writer that asked for it.
    fn takeWrites(self: *MasterNode) void {
        var ran = self.runner.take();
        defer ran.deinit(self.allocator);
        for (ran.items) |write| {
            const peer = for (self.peers) |slot| {
                const peer = slot orelse continue;
                if (peer.write_number == write.number) break peer;
            } else {
                // Its writer is gone.
                if (write.answer) |answer| self.allocator.free(answer);
                continue;
            };
            peer.write_number = null;
            const answer = write.answer orelse {
                log.warn("a forwarded write could not be answered", .{});
                self.release(self.slotOf(peer), peer);
                continue;
            };
            peer.conversation.writer.answered(answer);
        }
    }

    fn slotOf(self: *MasterNode, peer: *Peer) *?*Peer {
        for (self.peers) |*slot| if (slot.* == peer) return slot;
        unreachable;
    }

    fn openCopy(self: *MasterNode, peer: *Peer) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/copy-{d}/{s}", .{ self.options.copies_directory, peer.copy_number.?, KeyValueStore.data_file_name });
        const file = try Io.Dir.cwd().openFile(self.io, path, .{});
        peer.copy_file = file;
        peer.copy_reader = file.reader(self.io, &peer.copy_buffer);
        peer.conversation.replica.copyMade(&peer.copy_reader.interface);
    }

    /// Closes and deletes `peer`'s copy once sent, or once the replica is
    /// gone. A copy still being made is deleted when it is taken.
    fn closeCopy(self: *MasterNode, peer: *Peer) void {
        const file = peer.copy_file orelse return;
        file.close(self.io);
        peer.copy_file = null;
        copies.delete(self.io, self.options.copies_directory, peer.copy_number.?);
        peer.copy_number = null;
    }
};
