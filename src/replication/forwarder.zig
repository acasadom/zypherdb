//! A replica's forwarded writes, sent to its master over a connection of
//! their own (forwarding_session.zig), apart from following it: any
//! process opened with the replica role forwards, standbys too.
//!
//! `ForwardingNode` holds that connection on one thread, with no thread
//! of its own, like replica_node.zig: it connects when the first request
//! comes, keeps the connection while the master heartbeats (acking each),
//! and connects again for the next request once it is lost. Requests go one
//! after the other on that connection, up to `protocol.max_writes_in_flight`
//! waiting for their answers: `request` hands one over while there is
//! `room`, `take` tells how each ended. A request that did not reach the
//! master whole (the connection lost, or a master that may be starting
//! turned it away) is sent once more on a new connection; one lost once
//! delivered ends `unknown`: the master may have run it. Whoever runs it
//! waits on what `watch` tells until `deadline`, hands back what was
//! `ready`, then calls `step`: a `Forwarder` on a thread of its own, or a
//! simulation.

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
    /// A master not reached, or that does not answer the writer hello,
    /// within this long is given up on; once it answers, one silent for
    /// `protocol.heartbeats_per_timeout` of its heartbeat intervals.
    answer_timeout_ns: u64 = 5 * std.time.ns_per_s,
    /// The longest a request may take, however alive the master is.
    request_timeout_ns: u64 = 30 * std.time.ns_per_s,
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
    /// The requests handed over, in order, until they end; and those that
    /// ended out of time while the connection still holds them.
    pending: std.ArrayList(Pending),
    /// How requests ended, in order, until taken.
    finished: std.ArrayList(Finished),

    const Pending = struct {
        id: u64,
        /// A copy of the caller's, the node's.
        bytes: []u8,
        /// When it was handed over: it ends by `request_timeout_ns` after.
        since: Instant,
        /// The connections it was sent on, failed to open, or turned away.
        attempts: u8 = 0,
        /// Handed to the session of the connection held.
        handed: bool = false,
        /// Ended out of time, its caller told; kept until its answer comes
        /// or the connection ends, so the session may still send it.
        ended: bool = false,
    };

    /// The most connections a request is sent on.
    const max_attempts = 2;

    /// Forwards for the database of `store`, a replica's or a standby's;
    /// each hello tells its database id.
    pub fn init(allocator: Allocator, net: Network, store: *KeyValueStore, wakeup: Wakeup, options: Options) !ForwardingNode {
        var pending: std.ArrayList(Pending) = try .initCapacity(allocator, 2 * protocol.max_writes_in_flight);
        errdefer pending.deinit(allocator);
        var finished: std.ArrayList(Finished) = try .initCapacity(allocator, protocol.max_writes_in_flight);
        errdefer finished.deinit(allocator);
        return .{
            .allocator = allocator,
            .network = net,
            .options = options,
            .store = try store.share(),
            .wakeup = wakeup,
            .pending = pending,
            .finished = finished,
        };
    }

    /// Closes the connection, if one is held; requests in hand end with
    /// it, untold, and outcomes not taken are freed. The wakeup stays the
    /// owner's.
    pub fn deinit(self: *ForwardingNode) void {
        if (self.conversation) |conversation| self.forget(conversation);
        for (self.pending.items) |pending| self.allocator.free(pending.bytes);
        self.pending.deinit(self.allocator);
        for (self.finished.items) |finished| self.free(finished.outcome);
        self.finished.deinit(self.allocator);
        self.store.deinit();
    }

    /// Frees what `outcome` holds.
    pub fn free(self: *ForwardingNode, outcome: Outcome) void {
        if (outcome == .answer) self.allocator.free(outcome.answer);
    }

    /// Whether `request` may hand one more over: fewer than
    /// `protocol.max_writes_in_flight` are in hand or ended and not taken.
    pub fn room(self: *const ForwardingNode) bool {
        var in_hand: usize = 0;
        for (self.pending.items) |pending| {
            if (!pending.ended) in_hand += 1;
        }
        return in_hand + self.finished.items.len < protocol.max_writes_in_flight;
    }

    /// Hands over the request `bytes` (forwarding.zig) under `id`, handed
    /// to the node's owner at `since`, while there is `room`; the node
    /// copies them. `step` sends it, after those handed before.
    pub fn request(self: *ForwardingNode, id: u64, bytes: []const u8, since: Instant) void {
        std.debug.assert(self.room());
        const copy = self.allocator.dupe(u8, bytes) catch |err| {
            self.finished.appendAssumeCapacity(.{ .id = id, .outcome = .{ .failed = err } });
            return;
        };
        self.pending.appendAssumeCapacity(.{ .id = id, .bytes = copy, .since = since });
    }

    /// How the oldest request ended of those that did and were not taken.
    pub fn take(self: *ForwardingNode) ?Finished {
        if (self.finished.items.len == 0) return null;
        return self.finished.orderedRemove(0);
    }

    /// Moves the requests on at `now`, with what was `ready`: connects
    /// when some wait and no connection is held, receives, sends; ends the
    /// conversation on any failure, and each request with it that may not
    /// be sent again.
    pub fn step(self: *ForwardingNode, now: Instant) void {
        self.clearWakeup();
        self.endOutOfTime(now);
        while (true) {
            if (self.conversation == null) {
                if (!self.anyWaiting()) return;
                self.conversation = self.connect(now) catch |err| {
                    log.info("connecting to the master to forward a write failed: {t}", .{err});
                    switch (err) {
                        error.NoCopy, error.OutOfMemory => self.endWaiting(.{ .failed = err }),
                        else => self.turnedAway(null),
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
            self.lost(conversation);
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
        for (self.pending.items) |pending| {
            if (pending.ended) continue;
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

    /// Whether a request waits for a connection.
    fn anyWaiting(self: *const ForwardingNode) bool {
        for (self.pending.items) |pending| {
            if (!pending.ended and !pending.handed) return true;
        }
        return false;
    }

    /// Ends each request that took too long: `unknown` if the session may
    /// send it yet, or sent it.
    fn endOutOfTime(self: *ForwardingNode, now: Instant) void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const pending = &self.pending.items[index];
            if (pending.ended or now < pending.since + self.options.request_timeout_ns) {
                index += 1;
                continue;
            }
            log.info("a forwarded write took too long", .{});
            const kept = pending.handed and !self.conversation.?.session.withdraw(pending.id);
            if (!kept) {
                self.end(index, .master_unreachable);
                continue;
            }
            self.finished.appendAssumeCapacity(.{ .id = pending.id, .outcome = .unknown });
            pending.ended = true;
            index += 1;
        }
    }

    /// The answer to request `id` came: its bytes are the node's.
    fn answered(self: *ForwardingNode, id: u64, bytes: []u8) void {
        const index = self.indexOf(id) orelse unreachable;
        if (!self.pending.items[index].ended) return self.end(index, .{ .answer = bytes });
        self.allocator.free(bytes);
        self.remove(index);
    }

    /// The connection is lost: each request handed to it that reached the
    /// master ends `unknown`; the others, and those waiting for it, wait
    /// for the next unless it was their last.
    fn lost(self: *ForwardingNode, conversation: *Conversation) void {
        // Before those handed to it are told from those waiting; a refusal
        // counted already.
        if (conversation.session.state != .refused) self.turnedAway(null);
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const pending = &self.pending.items[index];
            if (pending.ended) {
                self.remove(index);
                continue;
            }
            if (!pending.handed) {
                index += 1;
                continue;
            }
            if (conversation.session.delivered(pending.id)) {
                self.end(index, .unknown);
                continue;
            }
            if (pending.attempts >= max_attempts) {
                self.end(index, .master_unreachable);
                continue;
            }
            pending.handed = false;
            index += 1;
        }
        self.forget(conversation);
    }

    /// A connection failed to open, was lost, or the master turned it
    /// away (`refusal`): each request waiting, not handed to it, ends
    /// unless it may be tried once more.
    fn turnedAway(self: *ForwardingNode, refusal: ?protocol.Refusal) void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const pending = &self.pending.items[index];
            if (pending.ended or pending.handed) {
                index += 1;
                continue;
            }
            pending.attempts += 1;
            if (refusal) |reason| if (reason.permanent() or pending.attempts >= max_attempts) {
                self.end(index, .{ .refused = reason });
                continue;
            };
            if (pending.attempts >= max_attempts) {
                self.end(index, .master_unreachable);
                continue;
            }
            index += 1;
        }
    }

    fn endWaiting(self: *ForwardingNode, outcome: Outcome) void {
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const pending = self.pending.items[index];
            if (pending.ended or pending.handed) {
                index += 1;
                continue;
            }
            self.end(index, outcome);
        }
    }

    /// Hands the session every request waiting, in order, while it takes
    /// more.
    fn hand(self: *ForwardingNode, session: *ForwardingSession) void {
        for (self.pending.items) |*pending| {
            if (session.full()) return;
            if (pending.ended or pending.handed) continue;
            session.request(pending.id, pending.bytes);
            pending.handed = true;
            pending.attempts += 1;
        }
    }

    fn end(self: *ForwardingNode, index: usize, outcome: Outcome) void {
        self.finished.appendAssumeCapacity(.{ .id = self.pending.items[index].id, .outcome = outcome });
        self.remove(index);
    }

    fn remove(self: *ForwardingNode, index: usize) void {
        self.allocator.free(self.pending.orderedRemove(index).bytes);
    }

    fn indexOf(self: *const ForwardingNode, id: u64) ?usize {
        for (self.pending.items, 0..) |pending, index| {
            if (pending.id == id) return index;
        }
        return null;
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
            }, self.options.answer_timeout_ns, now),
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
                        node.turnedAway(reason);
                        return false;
                    },
                    .answer => |answer| node.answered(answer.id, answer.bytes),
                };
            }
        }
        self.readable = false;
        if (session.state == .ready) node.hand(session);
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
    /// Guards what follows, up to `node`.
    mutex: Io.Mutex = .init,
    /// The requests `forward` handed over and the node has not yet, in
    /// order.
    handed: std.ArrayList(Handed),
    /// How requests ended, until their `forward` takes them.
    finished: std.ArrayList(Finished),
    /// The `forward`s under way: at most `protocol.max_writes_in_flight`,
    /// the others wait.
    in_flight: usize = 0,
    /// The id of the last request handed over.
    last_id: u64 = 0,
    /// Grows as requests end and as `forward`s return; `changed` is
    /// raised to it.
    changes: u64 = 0,
    changed: Signal = .{},
    /// The loop's alone.
    node: ForwardingNode,

    const Handed = struct { id: u64, bytes: []const u8, since: Instant };

    /// Starts the loop; the first request forwarded connects to the master.
    pub fn start(allocator: Allocator, io: Io, clock: Clock, net: Network, store: *KeyValueStore, options: Options) !*Forwarder {
        const self = try allocator.create(Forwarder);
        errdefer allocator.destroy(self);
        var handed: std.ArrayList(Handed) = try .initCapacity(allocator, protocol.max_writes_in_flight);
        errdefer handed.deinit(allocator);
        var finished: std.ArrayList(Finished) = try .initCapacity(allocator, protocol.max_writes_in_flight);
        errdefer finished.deinit(allocator);
        const wakeup = try net.wakeup();
        errdefer wakeup.close();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .network = net,
            .wakeup = wakeup,
            .handed = handed,
            .finished = finished,
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
        for (self.finished.items) |finished| self.node.free(finished.outcome);
        self.finished.deinit(self.allocator);
        self.handed.deinit(self.allocator);
        self.node.deinit();
        self.wakeup.close();
        self.allocator.destroy(self);
    }

    /// Sends the request `bytes` (forwarding.zig) to the master and waits
    /// for how it ended. An answer's bytes are allocated with the
    /// forwarder's allocator: the caller's to free. Any thread; up to
    /// `protocol.max_writes_in_flight` at once, the others wait.
    pub fn forward(self: *Forwarder, bytes: []const u8) Outcome {
        self.mutex.lockUncancelable(self.io);
        while (self.in_flight == protocol.max_writes_in_flight) self.waitForChange();
        self.in_flight += 1;
        self.last_id += 1;
        const id = self.last_id;
        self.handed.appendAssumeCapacity(.{ .id = id, .bytes = bytes, .since = self.clock.now() });
        self.mutex.unlock(self.io);
        self.wakeup.raise();
        self.mutex.lockUncancelable(self.io);
        // The node ends every request in time.
        const outcome = taken: while (true) {
            for (self.finished.items, 0..) |finished, index| {
                if (finished.id == id) break :taken self.finished.swapRemove(index).outcome;
            }
            self.waitForChange();
        };
        self.in_flight -= 1;
        self.changes += 1;
        const changes = self.changes;
        self.mutex.unlock(self.io);
        self.clock.raise(&self.changed, changes);
        return outcome;
    }

    /// Waits, with the mutex held, for the next change.
    fn waitForChange(self: *Forwarder) void {
        const seen = self.changes;
        self.mutex.unlock(self.io);
        defer self.mutex.lockUncancelable(self.io);
        _ = self.clock.wait(&self.changed, seen, std.math.maxInt(Instant));
    }

    fn run(self: *Forwarder) void {
        var watched_buffer: [2]Watched = undefined;
        while (true) {
            // Before looking: a `forward` or a `stop` raises it after.
            self.node.clearWakeup();
            if (self.stopping.load(.acquire)) return;
            const now = self.clock.now();
            self.handOver();
            self.node.step(now);
            self.collect();
            const watched = self.node.watch(&watched_buffer);
            const timeout: ?u64 = if (self.node.deadline()) |deadline| deadline -| now else null;
            self.network.wait(watched, timeout) catch |err| {
                log.warn("waiting on the network failed: {t}", .{err});
                continue;
            };
            self.node.ready(watched);
        }
    }

    /// Hands the node the requests `forward` handed over, while it has
    /// room.
    fn handOver(self: *Forwarder) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        while (count < self.handed.items.len and self.node.room()) : (count += 1) {
            const handed = self.handed.items[count];
            self.node.request(handed.id, handed.bytes, handed.since);
        }
        std.mem.copyForwards(Handed, self.handed.items[0 .. self.handed.items.len - count], self.handed.items[count..]);
        self.handed.shrinkRetainingCapacity(self.handed.items.len - count);
    }

    /// Tells each `forward` waiting how its request ended.
    fn collect(self: *Forwarder) void {
        const changes = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var any = false;
            while (self.node.take()) |finished| {
                self.finished.appendAssumeCapacity(finished);
                any = true;
            }
            if (!any) return;
            self.changes += 1;
            break :blk self.changes;
        };
        self.clock.raise(&self.changed, changes);
    }
};
