//! Populating a new vector index from the data already there, in the
//! background, so CREATE VECTOR INDEX over a large graph returns at once
//! and holds no write lock for minutes.
//!
//! A new index starts populating: CREATE (or a replica applying it) does a
//! first batch in its own transaction, which on a small graph is all of it,
//! and leaves the rest to the `Builder` of the open database. Each batch is
//! one write transaction of bounded time (`KeyValueStore.PopulationBudget`)
//! that places the next entities by id and stores how far it got in the
//! index's state (vector_index.zig), so a crash loses no more than a batch
//! and population resumes on the next open. Writes keep the index current
//! meanwhile, also past where population got to: placing an entity is
//! idempotent. Several processes on the database share the work, each
//! batch going on from the progress it reads.
//!
//! An entity whose property is not a vector the index takes fails the
//! index: its state names the entity and why, and its other keys are left
//! to be cleared. Writes no longer keep or check it, and queries on it are
//! refused, until it is dropped (and, the data corrected, created again).
//!
//! The same builder rebuilds indexes and clears the keys no index needs
//! (vector_rebuild.zig), in batches of the same budget.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Graph = @import("graph.zig").Graph;
const KeyValueStore = @import("key_value_store.zig").KeyValueStore;
const StorageError = @import("key_value_store.zig").StorageError;
const key_encoding = @import("key_encoding.zig");
const value_encoding = @import("value_encoding.zig");
const fulltext = @import("fulltext.zig");
const vector_index = @import("vector_index.zig");
const vector_rebuild = @import("vector_rebuild.zig");

const Budget = KeyValueStore.PopulationBudget;

/// Starts populating index `definition`, created (or applied) in the write
/// transaction open: a first batch there, and the store's builder told if
/// there is more (it waits for the transaction to commit).
pub fn start(graph: *Graph, definition: fulltext.Definition) StorageError!void {
    try vector_index.setState(graph, definition.index_id, .{ .populating = .{} });
    // A failed index has keys to clear.
    if (try advance(graph, definition, graph.store.population_budget) != .online) graph.store.wakePopulation();
}

pub const Outcome = enum { populating, online, failed };

/// Takes index `definition`, if it is populating, one batch of at most
/// `budget` further, in the write transaction open, and stores where it got to.
pub fn advance(graph: *Graph, definition: fulltext.Definition, budget: Budget) StorageError!Outcome {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    var progress = switch (try vector_index.state(graph, scratch.allocator(), definition.index_id)) {
        .populating => |progress| progress,
        .online => return .online,
        .failed => return .failed,
    };
    const started = now();
    var placed: u64 = 0;
    // The scratch of one entity, dropped after it: kept for all of them, it
    // would grow with the batch.
    var entity_scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer entity_scratch.deinit();
    // One for the batch: a populating index has no generation but its first.
    var placer = (try vector_index.Placer.init(graph, scratch.allocator(), definition)).?;
    while (true) {
        const found = try nextEntities(graph, definition, progress.next);
        for (found.ids[0..found.count]) |id| {
            defer _ = entity_scratch.reset(.retain_capacity);
            const arena = entity_scratch.allocator();
            if (try valueOf(graph, arena, definition, id)) |value| switch (try vector_index.check(arena, definition, value)) {
                .invalid => |reason| {
                    try vector_index.setState(graph, definition.index_id, .{ .failed = .{ .entity = id, .reason = reason } });
                    return .failed;
                },
                else => try placer.place(arena, id, value),
            };
            progress.examined += 1;
            progress.next = id + 1;
            placed += 1;
            if (placed >= budget.entities or now() - started >= budget.nanoseconds) {
                try vector_index.setState(graph, definition.index_id, .{ .populating = progress });
                return .populating;
            }
        }
        if (found.last) {
            try vector_index.setState(graph, definition.index_id, .{ .online = .{} });
            // Writes may have removed enough entities meanwhile.
            var storage = try vector_index.IndexStorage.init(graph, scratch.allocator(), definition, 0);
            if (try storage.header()) |header| try vector_index.startRebuildIfDue(graph, definition, header);
            return .online;
        }
        progress.next = found.next;
    }
}

/// One batch of background work on the database `store` opened, in a
/// write transaction of its own (allowed on a replica: it writes only the
/// indexes' keys): clearing keys no index needs first, else rebuilding the
/// first index being rebuilt, else populating the first one populating.
/// False if there was nothing to do.
pub fn advanceAny(store: *KeyValueStore) StorageError!bool {
    try store.beginLocalWrite();
    errdefer store.abortWrite();
    var graph = Graph.init(store, store.allocator);
    var scratch = std.heap.ArenaAllocator.init(store.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const budget = store.population_budget;
    const done = try vector_rebuild.clearGarbage(&graph, budget) or
        try vector_rebuild.advanceAny(&graph, arena, budget) or
        try populateFirst(&graph, arena, budget);
    if (!done) {
        store.abortWrite();
        return false;
    }
    try store.commitWrite();
    return true;
}

fn populateFirst(graph: *Graph, arena: Allocator, budget: Budget) StorageError!bool {
    const definition = try firstPopulating(graph, arena) orelse return false;
    _ = try advance(graph, definition, budget);
    return true;
}

/// Whether some index of the database `store` opened is populating.
pub fn anyPopulating(store: *KeyValueStore) StorageError!bool {
    try store.beginRead();
    defer store.abortRead();
    var graph = Graph.init(store, store.allocator);
    var scratch = std.heap.ArenaAllocator.init(store.allocator);
    defer scratch.deinit();
    return try firstPopulating(&graph, scratch.allocator()) != null;
}

/// Whether some index of the database `store` opened is being rebuilt.
pub fn anyRebuilding(store: *KeyValueStore) StorageError!bool {
    try store.beginRead();
    defer store.abortRead();
    var graph = Graph.init(store, store.allocator);
    var scratch = std.heap.ArenaAllocator.init(store.allocator);
    defer scratch.deinit();
    return vector_rebuild.anyRebuilding(&graph, scratch.allocator());
}

/// Whether the database `store` opened has background work left: an
/// index populating or being rebuilt, or keys to clear.
pub fn anyWork(store: *KeyValueStore) StorageError!bool {
    try store.beginRead();
    defer store.abortRead();
    var graph = Graph.init(store, store.allocator);
    var scratch = std.heap.ArenaAllocator.init(store.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    return try firstPopulating(&graph, arena) != null or
        try vector_rebuild.anyRebuilding(&graph, arena) or
        try vector_rebuild.anyGarbage(&graph, arena);
}

fn firstPopulating(graph: *Graph, arena: Allocator) StorageError!?fulltext.Definition {
    for (try fulltext.all(graph, arena)) |definition| {
        if (definition.kind != .vector) continue;
        if (try vector_index.state(graph, arena, definition.index_id) == .populating) return definition;
    }
    return null;
}

/// Does all the background work left, batch after batch (what the
/// builder does, for code that has none).
pub fn finish(store: *KeyValueStore) StorageError!void {
    while (try advanceAny(store)) {}
}

/// The entities after `first`, in id order, that the next batch looks at.
const Found = struct {
    ids: [batch_length]u64 = undefined,
    count: usize = 0,
    /// Where the next look goes on from.
    next: u64,
    /// Nothing is left after these.
    last: bool,
};

/// Ids looked for at a time: collected before placing them, since no scan
/// may stay open across writes.
const batch_length = 64;
/// Relationships of other types read at most per look, so a rare type does
/// not make one look scan the whole table.
const max_skipped = 4096;

fn nextEntities(graph: *Graph, definition: fulltext.Definition, first: u64) StorageError!Found {
    var found = Found{ .next = first, .last = false };
    switch (definition.entity) {
        .nodes => {
            var nodes = try graph.nodesWithLabelFrom(definition.labels_or_types[0], first);
            defer nodes.deinit();
            while (found.count < batch_length) {
                const id = try nodes.next() orelse {
                    found.last = true;
                    break;
                };
                found.ids[found.count] = id;
                found.count += 1;
                found.next = id + 1;
            }
        },
        .relationships => {
            var relationships = try graph.store.scanRelationshipsFrom(first);
            defer relationships.deinit();
            var skipped: usize = 0;
            while (found.count < batch_length and skipped < max_skipped) {
                const entry = try relationships.next() orelse {
                    found.last = true;
                    break;
                };
                const id = std.mem.readInt(u64, entry.key[0..8], .native);
                found.next = id + 1;
                if (!std.mem.eql(u8, key_encoding.decodeRelationshipRecord(entry.value).edge_type, definition.labels_or_types[0])) {
                    skipped += 1;
                    continue;
                }
                found.ids[found.count] = id;
                found.count += 1;
            }
        },
    }
    return found;
}

/// The value entity `id` holds in the index's property, if any.
fn valueOf(graph: *Graph, arena: Allocator, definition: fulltext.Definition, id: u64) StorageError!?@import("../value.zig").Value {
    const property = definition.properties[0];
    switch (definition.entity) {
        .nodes => return vector_index.decodedProperty(arena, .{ .bytes = try graph.recordCopy(id, arena) }, property),
        .relationships => {
            var key = std.ArrayList(u8).empty;
            try key_encoding.appendEdgePropertyKey(&key, arena, id, property);
            const encoded = try graph.store.view(key.items) orelse return null;
            return try value_encoding.decodeValue(encoded, arena);
        },
    }
}

fn now() u64 {
    return @intCast(Io.Clock.awake.now(Io.Threaded.global_single_threaded.io()).nanoseconds);
}

// --- The builder ------------------------------------------------------------------

/// The thread that does the background work of the vector indexes of one
/// open database, on a store of its own. It runs while there is some: from
/// the open of a database with some, and from each
/// `KeyValueStore.wakePopulation`; it ends when none is left. A batch at a
/// time, so stopping waits for one.
pub const Builder = struct {
    allocator: Allocator,
    threaded: Io.Threaded,
    store: KeyValueStore,
    thread: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    /// Under `mutex`: the thread is in its loop.
    running: bool = false,
    /// Under `mutex`: woken since the thread last looked for work.
    pending: bool = false,
    stopping: bool = false,

    /// Pause after a batch fails, before trying again.
    const retry_pause = Io.Duration.fromSeconds(1);

    /// A builder for the database `owner` opened, which it tells (and the
    /// shares of it made from now on) to wake it. Stop it before `owner`
    /// closes.
    pub fn start(allocator: Allocator, owner: *KeyValueStore) StorageError!*Builder {
        const self = allocator.create(Builder) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .threaded = .init(allocator, .{}), .store = undefined };
        errdefer self.threaded.deinit();
        self.store = try owner.share();
        errdefer self.store.deinit();
        // Work a crash or a close cut short goes on.
        const work_left = try anyWork(&self.store);
        owner.population_waker = .{ .context = self, .wake = wake };
        self.store.population_waker = owner.population_waker;
        if (work_left) wake(self);
        return self;
    }

    /// Waits for the batch under way, if any, and ends the thread.
    pub fn stop(self: *Builder) void {
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.condition.broadcast(io);
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(io);
        if (thread) |running| running.join();
        self.store.deinit();
        self.threaded.deinit();
        self.allocator.destroy(self);
    }

    /// Runs the thread if it is not running. If it cannot be started, the
    /// population waits for the next wake or open.
    fn wake(context: *anyopaque) void {
        const self: *Builder = @ptrCast(@alignCast(context));
        const io = self.threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return;
        self.pending = true;
        if (self.running) return self.condition.broadcast(io);
        // A thread that left its loop has ended, or is about to.
        if (self.thread) |ended| ended.join();
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
        self.running = self.thread != null;
    }

    fn run(self: *Builder) void {
        const io = self.threaded.io();
        while (true) {
            self.mutex.lockUncancelable(io);
            if (self.stopping) return self.leave(io);
            self.pending = false;
            self.mutex.unlock(io);
            const more = advanceAny(&self.store) catch {
                self.mutex.lockUncancelable(io);
                if (!self.stopping) {
                    const timeout: Io.Timeout = .{ .duration = .{ .raw = retry_pause, .clock = .awake } };
                    self.condition.waitTimeout(io, &self.mutex, timeout) catch {};
                }
                self.mutex.unlock(io);
                continue;
            };
            if (more) continue;
            self.mutex.lockUncancelable(io);
            if (self.stopping or !self.pending) return self.leave(io);
            self.mutex.unlock(io);
        }
    }

    /// Under `mutex`, which it unlocks.
    fn leave(self: *Builder, io: Io) void {
        self.running = false;
        self.mutex.unlock(io);
    }
};
