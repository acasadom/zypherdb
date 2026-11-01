//! A replica's forwarded writes, sent to its master over a connection of
//! their own (forwarding_session.zig), apart from following it: any
//! process opened with the replica role forwards, standbys too.
//!
//! `ForwardingNode` holds that connection on one thread, with no thread
//! of its own, like replica_node.zig: it connects when the first request
//! comes, keeps the connection while the master heartbeats (acking each),
//! and connects again for the next request once it is lost. One request at
//! a time: `request` hands it over, `take` tells how it ended. A request
//! that did not reach the master whole (the connection lost, or a master
//! that may be starting turned it away) is sent once more on a new
//! connection; one lost once delivered ends `unknown`: the master may have
//! run it. Whoever runs it waits on what `watch` tells until `deadline`,
//! hands back what was `ready`, then calls `step`: a `Forwarder` on a
//! thread of its own, or a simulation.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const clock_module = @import("clock.zig");
const Clock = clock_module.Clock;
const Instant = clock_module.Instant;
const Signal = clock_module.Signal;
const network = @import("network.zig");
const Network = network.Network;
const Connection = network.Connection;
const Wakeup = network.Wakeup;
const Watched = network.Watched;
const ForwardingSession = @import("forwarding_session.zig").ForwardingSession;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;

const log = std.log.scoped(.replication);

pub const Options = struct {
    /// The master's address, "host:port".
    master_address: []const u8,
    token: []const u8,
    /// A master that sends nothing, or reads nothing sent, for this long
    /// is given up on (longer than its heartbeat); so is one not reached
    /// in this long.
    timeout_ns: u64 = 5 * std.time.ns_per_s,
    /// The longest a request may take, however alive the master is.
    request_timeout_ns: u64 = 60 * std.time.ns_per_s,
    /// What the replica calls itself in its hello, at most
    /// `protocol.max_name_bytes`.
    name: []const u8 = "",
};

/// How a request ended.
pub const Outcome = union(enum) {
    /// The master's answer (forwarding.zig), allocated with the node's
    /// allocator: the caller's to free.
    answer: []u8,
    /// The master turned the replica away for good, or twice.
    refused: protocol.Refusal,
    /// Lost after it reached the master whole, or out of time then: the
    /// master may have run it, or may run it yet.
    unknown,
    /// Not reached the master whole, twice, or out of time before: the
    /// master did not run it.
    master_unreachable,
    /// Not sent: the replica holds no copy of a master yet, or memory ran
    /// out.
    failed: anyerror,
};

pub const Finished = struct {
    id: u64,
    outcome: Outcome,
};

pub const ForwardingNode = struct {
    allocator: Allocator,
    network: Network,
    options: Options,
    /// The node's own store, for its hellos.
    store: KeyValueStore,
    /// The owner's: raised to hand a request over, and to stop.
    wakeup: Wakeup,
    wakeup_ready: bool = false,
    /// The connection to the master, if one is held.
    conversation: ?*Conversation = null,
    /// The request in hand, until it ends.
    pending: ?Pending = null,
    /// How the last request ended, until taken.
    finished: ?Finished = null,

    const Pending = struct {
        id: u64,
        /// The caller's, untouched until the request ends.
        bytes: []const u8,
        /// When it was handed over: it ends by `request_timeout_ns` after.
        since: Instant,
        /// The connections it was sent on.
        attempts: u8 = 0,
    };

    /// The most connections a request is sent on.
    const max_attempts = 2;

    /// Forwards for the database of `store`, a replica's or a standby's;
    /// each hello tells its database id.
    pub fn init(allocator: Allocator, net: Network, store: *KeyValueStore, wakeup: Wakeup, options: Options) !ForwardingNode {
        return .{
            .allocator = allocator,
            .network = net,
            .options = options,
            .store = try store.share(),
            .wakeup = wakeup,
        };
    }

    /// Closes the connection, if one is held; a request in hand ends with
    /// it, untold, and an outcome not taken is freed. The wakeup stays the
    /// owner's.
    pub fn deinit(self: *ForwardingNode) void {
        if (self.conversation) |conversation| self.forget(conversation);
        if (self.finished) |finished| self.free(finished.outcome);
        self.store.deinit();
    }

    /// Frees what `outcome` holds.
    pub fn free(self: *ForwardingNode, outcome: Outcome) void {
        if (outcome == .answer) self.allocator.free(outcome.answer);
    }

    /// Hands over the request `bytes` (forwarding.zig) under `id`, at `now`,
    /// once the last one ended and was taken; they stay the caller's,
    /// untouched until it ends. `step` sends it.
    pub fn request(self: *ForwardingNode, id: u64, bytes: []const u8, now: Instant) void {
        std.debug.assert(self.pending == null and self.finished == null);
        self.pending = .{ .id = id, .bytes = bytes, .since = now };
    }

    /// How the request handed over ended, once it did.
    pub fn take(self: *ForwardingNode) ?Finished {
        defer self.finished = null;
        return self.finished;
    }

    /// Moves the request on at `now`, with what was `ready`: connects when
    /// one waits and no connection is held, receives, sends; ends the
    /// conversation on any failure, and the request with it once it may
    /// not be sent again.
    pub fn step(self: *ForwardingNode, now: Instant) void {
        self.clearWakeup();
        if (self.pending) |pending| if (now >= pending.since + self.options.request_timeout_ns) {
            log.info("a forwarded write took too long", .{});
            self.end(if (self.delivered()) .unknown else .master_unreachable);
            if (self.conversation) |conversation| self.forget(conversation);
        };
        while (true) {
            if (self.conversation == null) {
                const pending = &(self.pending orelse return);
                pending.attempts += 1;
                self.conversation = self.connect(now) catch |err| {
                    log.info("connecting to the master to forward a write failed: {t}", .{err});
                    switch (err) {
                        error.NoCopy, error.OutOfMemory => self.end(.{ .failed = err }),
                        else => self.lost(false),
                    }
                    continue;
                };
            }
            const conversation = self.conversation.?;
            if (conversation.step(self, now)) |going| {
                if (going) return;
            } else |err| {
                log.info("the connection for forwarded writes ended: {t}", .{err});
            }
            const was_delivered = self.delivered();
            self.forget(conversation);
            if (self.pending != null) self.lost(was_delivered);
        }
    }

    /// Clears the wakeup if it was ready: before the owner looks at what
    /// raised it, or a raise meanwhile is lost. `step` does it too.
    pub fn clearWakeup(self: *ForwardingNode) void {
        if (!self.wakeup_ready) return;
        self.wakeup_ready = false;
        self.wakeup.clear();
    }

    /// What to wait on before the next step: the wakeup, then the
    /// connection to the master if there is one.
    pub fn watch(self: *ForwardingNode, watched: *[2]Watched) []Watched {
        watched[0] = .{ .source = .{ .wakeup = self.wakeup }, .wanted = .{ .readable = true } };
        const conversation = self.conversation orelse return watched[0..1];
        watched[1] = .{ .source = .{ .connection = conversation.connection }, .wanted = .{
            .readable = conversation.session.inbox.unfilled().len > 0,
            .writable = conversation.session.outbox.unsent().len > 0,
        } };
        return watched[0..2];
    }

    /// When to step though nothing is ready, or null for never.
    pub fn deadline(self: *const ForwardingNode) ?Instant {
        var earliest: ?Instant = null;
        if (self.conversation) |conversation| earliest = conversation.session.deadline();
        if (self.pending) |pending| {
            const expiry = pending.since + self.options.request_timeout_ns;
            earliest = if (earliest) |known| @min(known, expiry) else expiry;
        }
        return earliest;
    }

    /// What each of `watched` (from `watch`, nothing stepped since) was
    /// ready for.
    pub fn ready(self: *ForwardingNode, watched: []const Watched) void {
        self.wakeup_ready = watched[0].ready.readable;
        if (watched.len > 1) self.conversation.?.readable = watched[1].ready.readable;
    }

    /// Whether the master may have the request in hand.
    fn delivered(self: *const ForwardingNode) bool {
        const conversation = self.conversation orelse return false;
        return self.pending != null and conversation.session.delivered();
    }

    /// The request's connection was lost, once it reached the master
    /// (`delivered`) or before: sent again unless it may have run or was
    /// sent on its last.
    fn lost(self: *ForwardingNode, was_delivered: bool) void {
        if (was_delivered) return self.end(.unknown);
        if (self.pending.?.attempts >= max_attempts) self.end(.master_unreachable);
    }

    fn end(self: *ForwardingNode, outcome: Outcome) void {
        self.finished = .{ .id = self.pending.?.id, .outcome = outcome };
        self.pending = null;
    }

    fn connect(self: *ForwardingNode, now: Instant) !*Conversation {
        const database_id = try self.store.databaseId() orelse return error.NoCopy;
        const conversation = try self.allocator.create(Conversation);
        errdefer self.allocator.destroy(conversation);
        const buffers = try self.allocator.alloc(u8, 2 * protocol.max_frame_bytes);
        errdefer self.allocator.free(buffers);
        const connection = try self.network.connect(self.options.master_address);
        conversation.* = .{
            .connection = connection,
            .buffers = buffers,
            .session = .init(buffers[0..protocol.max_frame_bytes], buffers[protocol.max_frame_bytes..], .{
                .database_id = database_id,
                .token = self.options.token,
                .name = self.options.name,
            }, self.options.timeout_ns, now),
        };
        return conversation;
    }

    fn forget(self: *ForwardingNode, conversation: *Conversation) void {
        conversation.deinit(self.allocator);
        self.allocator.destroy(conversation);
        self.conversation = null;
    }
};

/// One connection to the master.
const Conversation = struct {
    connection: Connection,
    buffers: []u8,
    session: ForwardingSession,
    /// What the connection was ready to read at the last wait.
    readable: bool = false,

    fn deinit(self: *Conversation, allocator: Allocator) void {
        self.session.deinit(allocator);
        allocator.free(self.buffers);
        self.connection.close();
    }

    /// Returns whether the conversation goes on.
    fn step(self: *Conversation, node: *ForwardingNode, now: Instant) !bool {
        const session = &self.session;
        if (self.readable) {
            while (session.inbox.unfilled().len > 0) {
                const count = self.connection.receive(session.inbox.unfilled()) catch |err| switch (err) {
                    error.WouldBlock => break,
                    error.Closed => return error.ConnectionClosed,
                };
                session.received(count, now);
                while (try session.next(node.allocator)) |event| switch (event) {
                    .ready => {},
                    .refused => |reason| {
                        log.info("the master turned a forwarded write away: {t}", .{reason});
                        // Asked again on a new connection if it may pass.
                        const pending = node.pending orelse return false;
                        if (reason.permanent() or pending.attempts >= ForwardingNode.max_attempts) node.end(.{ .refused = reason });
                        return false;
                    },
                    .answer => |bytes| node.end(.{ .answer = bytes }),
                };
            }
        }
        self.readable = false;
        // Ready: the request in hand, if any, is not sent yet.
        if (node.pending) |pending| if (session.state == .ready) session.request(pending.id, pending.bytes);
        session.pump(now);
        while (session.outbox.unsent().len > 0) {
            const count = self.connection.send(session.outbox.unsent()) catch |err| switch (err) {
                error.WouldBlock => break,
                error.Closed => return error.ConnectionClosed,
            };
            session.sent(count, now);
            session.pump(now);
        }
        if (now >= session.deadline()) return error.MasterSilent;
        return true;
    }
};

/// A `ForwardingNode` on a thread of its own: `forward` hands a request
/// over and waits for how it ended.
pub const Forwarder = struct {
    allocator: Allocator,
    io: Io,
    clock: Clock,
    network: Network,
    /// Raised by `forward` and `stop`.
    wakeup: Wakeup,
    stopping: std.atomic.Value(bool) = .init(false),
    loop_thread: ?std.Thread = null,
    /// Held by a `forward` from start to end: one at a time.
    forwarding: Io.Mutex = .init,
    /// Guards `handed` and `finished`.
    mutex: Io.Mutex = .init,
    handed: ?Handed = null,
    finished: ?Outcome = null,
    /// The id of the last request ended, raised as each does.
    ended: Signal = .{},
    /// The id of the last request handed over.
    last_id: u64 = 0,
    /// The loop's alone.
    node: ForwardingNode,

    const Handed = struct { id: u64, bytes: []const u8 };

    /// Starts the loop; the first request forwarded connects to the master.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, net: Network, store: *KeyValueStore, options: Options) !*Forwarder {
        const self = try allocator.create(Forwarder);
        errdefer allocator.destroy(self);
        const wakeup = try net.wakeup();
        errdefer wakeup.close();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .network = net,
            .wakeup = wakeup,
            .node = try .init(allocator, net, store, wakeup, options),
        };
        errdefer self.node.deinit();
        self.loop_thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Stops the thread, closes the connection and frees the forwarder.
    /// No `forward` may be under way.
    pub fn stop(self: *Forwarder) void {
        self.stopping.store(true, .release);
        self.wakeup.raise();
        if (self.loop_thread) |thread| thread.join();
        if (self.finished) |outcome| self.node.free(outcome);
        self.node.deinit();
        self.wakeup.close();
        self.allocator.destroy(self);
    }

    /// Sends the request `bytes` (forwarding.zig) to the master and waits
    /// for how it ended. An answer's bytes are allocated with the
    /// forwarder's allocator: the caller's to free. Any thread; one at a
    /// time, the others wait.
    pub fn forward(self: *Forwarder, bytes: []const u8) Outcome {
        self.forwarding.lockUncancelable(self.io);
        defer self.forwarding.unlock(self.io);
        self.last_id += 1;
        const id = self.last_id;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.handed = .{ .id = id, .bytes = bytes };
        }
        self.wakeup.raise();
        // The node ends every request in time.
        _ = self.clock.wait(&self.ended, id - 1, std.math.maxInt(Instant));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        defer self.finished = null;
        return self.finished.?;
    }

    fn run(self: *Forwarder) void {
        var watched_buffer: [2]Watched = undefined;
        while (true) {
            // Before looking: a `forward` or a `stop` raises it after.
            self.node.clearWakeup();
            if (self.stopping.load(.acquire)) return;
            const now = self.clock.now();
            if (self.takeHanded()) |handed| self.node.request(handed.id, handed.bytes, now);
            self.node.step(now);
            if (self.node.take()) |finished| {
                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    self.finished = finished.outcome;
                }
                self.clock.raise(&self.ended, finished.id);
            }
            const watched = self.node.watch(&watched_buffer);
            const timeout: ?u64 = if (self.node.deadline()) |deadline| deadline -| now else null;
            self.network.wait(watched, timeout) catch |err| {
                log.warn("waiting on the network failed: {t}", .{err});
                continue;
            };
            self.node.ready(watched);
        }
    }

    fn takeHanded(self: *Forwarder) ?Handed {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        defer self.handed = null;
        return self.handed;
    }
};
