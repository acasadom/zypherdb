//! KeyValueStore: the graph's view of the storage engine (engine.zig).
//!
//! It holds the active transaction (one read or one write), runs a single
//! operation in a transaction of its own when none is active, and keeps
//! what makes the graph's access patterns cheap: reused cursors, the record
//! cache, and a scan's prefix bounds. It knows nothing of the engine beyond
//! the contract in engine/contract.zig.
//!
//! Deliberately NO class hierarchy: a single concrete type, non-copyable,
//! with errors modeled as values (`error union`, the analogue of
//! `std::expected`) rather than exceptions.

const std = @import("std");

const engine = @import("engine.zig");
const Definition = @import("fulltext.zig").Definition;
const layout = @import("layout.zig");
const change_log = @import("change_log.zig");

const Table = engine.Table;

pub const StorageError = engine.Error || error{
    IteratorFailed,
    NodeStillConnected,
    /// The database was written in another storage format (see
    /// `Graph.checkFormat`).
    IncompatibleFormat,
    /// A write would break a uniqueness constraint (constraints.zig); the
    /// graph's `violationMessage` says which.
    ConstraintViolation,
    /// A node would have more labels than a record counts
    /// (`layout.max_labels`).
    TooManyLabels,
    /// A write on a replica, which only applies its master's change sets
    /// (`KeyValueStore.applyChangeSet`).
    ReadOnlyReplica,
};

/// The node records read in a read transaction, kept as the views the engine
/// gives (valid until the transaction ends), so reading a node again costs no
/// B-tree search: queries reach the same nodes many times (every member
/// reaches their team), and read several properties of each.
///
/// Direct-mapped by node id, with a fixed number of slots: a lookup or an
/// insertion is one array access, so a scan that reads each node once pays
/// almost nothing for it. Each slot records the transaction (`generation`)
/// it was filled in; starting a read transaction moves to a new generation,
/// which empties the cache without touching it.
pub const RecordCache = struct {
    const slot_count = 4096;

    slots: [slot_count]Slot = @splat(.{}),
    generation: u32 = 1,

    const Slot = struct { generation: u32 = 0, id: u64 = 0, bytes: []const u8 = "" };

    fn find(self: *const RecordCache, id: u64) ?[]const u8 {
        const slot = &self.slots[id % slot_count];
        return if (slot.generation == self.generation and slot.id == id) slot.bytes else null;
    }

    fn keep(self: *RecordCache, id: u64, bytes: []const u8) void {
        self.slots[id % slot_count] = .{ .generation = self.generation, .id = id, .bytes = bytes };
    }

    fn startTransaction(self: *RecordCache) void {
        self.generation +%= 1;
        if (self.generation == 0) { // wrapped around: forget every slot for real
            self.slots = @splat(.{});
            self.generation = 1;
        }
    }
};

/// See `KeyValueStore.write_transaction_memo`.
pub const WriteTransactionMemo = struct {
    /// The full-text schema version (see fulltext.zig).
    schema_version: ?u64 = null,
    /// The next relationship id, when this transaction allocated one: the
    /// graph writes it to its counter key when it commits.
    next_relationship_id: ?u64 = null,
};

pub const KeyValueStore = struct {
    environment: engine.Environment,
    allocator: std.mem.Allocator,
    active_write_transaction: ?engine.Transaction = null,
    active_read_transaction: ?engine.Transaction = null,
    /// Counts the read transactions begun, so a scan's cursor goes back to
    /// the pool only of the transaction it was opened in.
    read_transaction_number: u64 = 0,
    /// A cursor on the node table of the active read transaction.
    node_cursor: ?engine.Cursor = null,
    /// The id `node_cursor` is positioned on, if it is.
    node_cursor_id: ?u64 = null,
    /// A cursor of the active read transaction that `view` reuses: the engine
    /// finds a key near the cursor's last one without searching down from
    /// the root, so reads in key order (a scan's nodes) are cheaper.
    read_cursor: ?engine.Cursor = null,
    /// Cursors of the active read transaction that finished prefix scans
    /// gave back, reused by the next scans (last in, first out): a nested
    /// scan gets the cursor the scan at its depth used before, which is near
    /// where it starts now (the next node's edges), so the engine
    /// repositions it without searching from the root.
    cursor_pool: [16]engine.Cursor = undefined,
    pooled_cursors: usize = 0,
    /// Node records found in the active read transaction (see `RecordCache`).
    records: *RecordCache,
    /// Values that only the active write transaction can change, kept by the
    /// layer above for the transaction's life; cleared when a transaction
    /// starts or ends.
    write_transaction_memo: WriteTransactionMemo = .{},
    /// The schema definitions decoded at one schema version (see
    /// `fulltext.cachedDefinitions`), kept while the version stays; owned
    /// here so they live as long as the database.
    schema_definitions: ?SchemaDefinitions = null,
    /// Whether the change log is started on this database (change_log.zig),
    /// once known; only this process writes to it.
    change_log_started: ?bool = null,
    /// The writes of the active write transaction, while the change log is
    /// started.
    change_recorder: ?change_log.Recorder = null,
    /// The most bytes of change sets the log keeps.
    change_log_limit: u64 = 512 << 20,
    /// Whether this database is a replica (change_log.zig), once known.
    replica: ?bool = null,

    pub const SchemaDefinitions = struct {
        version: u64,
        arena: std.heap.ArenaAllocator,
        definitions: []const Definition,
    };

    pub const Durability = engine.Durability;
    pub const Options = engine.Options;

    /// Opens (or creates) a database at `path`. The directory must exist.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) StorageError!KeyValueStore {
        return openWithOptions(allocator, path, .{});
    }

    pub fn openWithOptions(allocator: std.mem.Allocator, path: []const u8, options: Options) StorageError!KeyValueStore {
        var environment = try engine.Environment.open(allocator, path, options);
        errdefer environment.close();
        const records = allocator.create(RecordCache) catch return error.OutOfMemory;
        records.* = .{};
        return .{ .environment = environment, .allocator = allocator, .records = records };
    }

    /// Writes every commit so far to disk (what `full` durability does at
    /// each commit).
    pub fn sync(self: *KeyValueStore) StorageError!void {
        return self.environment.sync();
    }

    pub fn deinit(self: *KeyValueStore) void {
        self.forgetSchemaDefinitions();
        self.stopRecording();
        self.environment.close();
        self.allocator.destroy(self.records);
    }

    /// Begins an explicit write transaction. Until `commitWrite`/`abortWrite`,
    /// `put`/`del`/`get`/`exists`/`scanPrefix` run on this transaction (and see
    /// its uncommitted writes). Not reentrant (there is a single writer anyway).
    pub fn beginWrite(self: *KeyValueStore) StorageError!void {
        if (self.inTransaction()) return error.WriteFailed;
        const transaction = try self.environment.beginWrite();
        errdefer transaction.abort();
        try self.refuseOnReplica(transaction);
        if (self.change_log_started orelse true) {
            const state = try change_log.readState(transaction);
            self.change_log_started = state != null;
            if (state) |started| self.change_recorder = .{ .state = started };
        }
        self.active_write_transaction = transaction;
        self.write_transaction_memo = .{};
    }

    /// With the change log started, the transaction's writes become its
    /// next change set, in the same commit.
    pub fn commitWrite(self: *KeyValueStore) StorageError!void {
        const transaction = self.active_write_transaction orelse return error.WriteFailed;
        defer self.stopRecording();
        if (self.change_recorder) |*recorder| recorder.finish(transaction, self.change_log_limit) catch |err| {
            self.abortWrite();
            return err;
        };
        self.active_write_transaction = null;
        self.write_transaction_memo = .{};
        try transaction.commit();
    }

    pub fn abortWrite(self: *KeyValueStore) void {
        if (self.active_write_transaction) |transaction| {
            transaction.abort();
            self.active_write_transaction = null;
        }
        self.stopRecording();
        self.write_transaction_memo = .{};
        // They may hold a schema change that never happened.
        self.forgetSchemaDefinitions();
    }

    fn stopRecording(self: *KeyValueStore) void {
        if (self.change_recorder) |*recorder| recorder.deinit(self.allocator);
        self.change_recorder = null;
    }

    fn refuseOnReplica(self: *KeyValueStore, transaction: engine.Transaction) StorageError!void {
        if (self.replica orelse true) self.replica = try change_log.appliedLsn(transaction) != null;
        if (self.replica.?) return error.ReadOnlyReplica;
    }

    /// Records a write the active write transaction has just made, if the
    /// change log is started.
    fn recordChange(self: *KeyValueStore, transaction: engine.Transaction, change: change_log.Change) StorageError!void {
        if (self.change_recorder) |*recorder| try recorder.record(self.allocator, transaction, change);
    }

    // --- The change log (change_log.zig) ------------------------------------

    /// Starts the change log on this database, if it is not started: from
    /// the next write transaction on, each one's changes are logged. A replica
    /// of the database as it is now starts from a copy of it.
    pub fn startChangeLog(self: *KeyValueStore) StorageError!void {
        if (self.inTransaction()) return error.WriteFailed;
        const transaction = try self.environment.beginWrite();
        errdefer transaction.abort();
        try self.refuseOnReplica(transaction);
        _ = try change_log.start(transaction);
        try transaction.commit();
        self.change_log_started = true;
    }

    /// The change log's state, or null if it was never started.
    pub fn changeLogState(self: *KeyValueStore) StorageError!?change_log.State {
        if (self.activeTransaction()) |transaction| return change_log.readState(transaction);
        const transaction = try self.environment.beginRead();
        defer self.environment.endRead(transaction);
        return change_log.readState(transaction);
    }

    /// The change set of transaction `lsn` (owned by the caller: free with
    /// `self.allocator.free`), or null if the log does not hold it.
    pub fn changeSet(self: *KeyValueStore, lsn: u64) StorageError!?[]u8 {
        if (self.activeTransaction()) |transaction| return change_log.changeSet(transaction, self.allocator, lsn);
        const transaction = try self.environment.beginRead();
        defer self.environment.endRead(transaction);
        return change_log.changeSet(transaction, self.allocator, lsn);
    }

    /// Applies change set `lsn` of this replica's master, `bytes`, in a write
    /// transaction of its own that also records it as applied (so a crash
    /// loses it whole or keeps it whole). A change set already applied is
    /// skipped; one whose predecessor is missing fails with
    /// `ChangeSetOutOfOrder`. The first one applied makes the database a
    /// replica, which refuses every other write. A database whose change
    /// log is started (a master) applies none (`WriteFailed`).
    pub fn applyChangeSet(self: *KeyValueStore, lsn: u64, bytes: []const u8) (StorageError || error{ MalformedChangeSet, ChangeSetOutOfOrder })!change_log.Applied {
        if (self.inTransaction()) return error.WriteFailed;
        const transaction = try self.environment.beginWrite();
        errdefer transaction.abort();
        if (try change_log.readState(transaction) != null) return error.WriteFailed;
        if (try change_log.applyNext(transaction, lsn, bytes) == .already_applied) {
            transaction.abort();
            return .already_applied;
        }
        try transaction.commit();
        self.replica = true;
        return .applied;
    }

    /// On a replica, the LSN of the last change set applied; null on a
    /// database that is not one.
    pub fn appliedLsn(self: *KeyValueStore) StorageError!?u64 {
        if (self.activeTransaction()) |transaction| return change_log.appliedLsn(transaction);
        const transaction = try self.environment.beginRead();
        defer self.environment.endRead(transaction);
        return change_log.appliedLsn(transaction);
    }

    /// Frees the cached schema definitions, if any.
    pub fn forgetSchemaDefinitions(self: *KeyValueStore) void {
        if (self.schema_definitions) |*cached| cached.arena.deinit();
        self.schema_definitions = null;
    }

    /// Begins an explicit read transaction (an MVCC snapshot). Until
    /// `commitRead`/`abortRead`, `get`/`exists`/`scanPrefix` run on this
    /// transaction, so a query's reads are batched into one transaction instead
    /// of one per read. Reads see the committed state as of `beginRead`
    /// (snapshot isolation), not writes committed afterwards.
    pub fn beginRead(self: *KeyValueStore) StorageError!void {
        if (self.inTransaction()) return error.ReadFailed;
        self.active_read_transaction = try self.environment.beginRead();
        self.read_transaction_number += 1;
        self.records.startTransaction();
    }

    /// Ends the active read transaction. For a read-only transaction "commit"
    /// and "abort" are equivalent (nothing is written); both just release it.
    pub fn commitRead(self: *KeyValueStore) void {
        self.abortRead();
    }

    pub fn abortRead(self: *KeyValueStore) void {
        for (self.cursor_pool[0..self.pooled_cursors]) |cursor| cursor.close();
        self.pooled_cursors = 0;
        if (self.node_cursor) |cursor| {
            cursor.close();
            self.node_cursor = null;
            self.node_cursor_id = null;
        }
        if (self.read_cursor) |cursor| {
            cursor.close();
            self.read_cursor = null;
        }
        if (self.active_read_transaction) |transaction| {
            self.environment.endRead(transaction);
            self.active_read_transaction = null;
        }
    }

    /// The active transaction, read or write.
    fn activeTransaction(self: *const KeyValueStore) ?engine.Transaction {
        return self.active_write_transaction orelse self.active_read_transaction;
    }

    pub fn inTransaction(self: *const KeyValueStore) bool {
        return self.activeTransaction() != null;
    }

    /// Runs `operation` in a write transaction of its own, committed at once.
    fn autocommit(self: *KeyValueStore, comptime operation: anytype, arguments: anytype) StorageError!void {
        try self.beginWrite();
        errdefer self.abortWrite();
        try @call(.auto, operation, arguments);
        try self.commitWrite();
    }

    /// Like `autocommit`, also while a read transaction is active (which
    /// keeps its snapshot).
    fn commitAlone(self: *KeyValueStore, comptime operation: anytype, arguments: anytype) StorageError!void {
        const reading = self.active_read_transaction;
        self.active_read_transaction = null;
        defer self.active_read_transaction = reading;
        try self.autocommit(operation, arguments);
    }

    /// The write transaction, or null if a new one must be made for one change.
    fn writer(self: *const KeyValueStore) ?engine.Transaction {
        return self.active_write_transaction;
    }

    // --- The main table: byte-string keys -----------------------------------

    /// Outside a write transaction it commits at once, even while a read
    /// transaction is active (which keeps its snapshot).
    pub fn put(self: *KeyValueStore, key: []const u8, value: []const u8) StorageError!void {
        const transaction = self.writer() orelse return self.commitAlone(put, .{ self, key, value });
        try transaction.put(.main, key, value);
        try self.recordChange(transaction, .{ .operation = .put, .table = .main, .key = key, .value = value });
    }

    /// Idempotent: deleting a missing key is a success. Commits at once
    /// outside a write transaction, like `put`.
    pub fn del(self: *KeyValueStore, key: []const u8) StorageError!void {
        const transaction = self.writer() orelse return self.commitAlone(del, .{ self, key });
        try transaction.delete(.main, key);
        try self.recordChange(transaction, .{ .operation = .delete, .table = .main, .key = key });
    }

    /// An absent key is a normal result: `null`, not an error.
    /// The returned value is an owned copy for the caller (free with
    /// `self.allocator.free`).
    pub fn get(self: *KeyValueStore, key: []const u8) StorageError!?[]u8 {
        if (self.activeTransaction()) |transaction| return self.copy(try transaction.get(.main, key));
        const transaction = try self.environment.beginRead();
        defer self.environment.endRead(transaction);
        return self.copy(try transaction.get(.main, key));
    }

    pub fn exists(self: *KeyValueStore, key: []const u8) StorageError!bool {
        if (self.activeTransaction()) |transaction| return try transaction.get(.main, key) != null;
        const transaction = try self.environment.beginRead();
        defer self.environment.endRead(transaction);
        return try transaction.get(.main, key) != null;
    }

    /// The value of `key` without copying it, inside the active transaction
    /// (null without one, or if the key is absent: callers then use `get`).
    /// The bytes are the engine's own: valid until the transaction ends or writes.
    pub fn view(self: *KeyValueStore, key: []const u8) StorageError!?[]const u8 {
        if (self.active_read_transaction) |transaction| {
            if (self.read_cursor == null) self.read_cursor = try transaction.openCursor(.main);
            return self.read_cursor.?.find(key);
        }
        const transaction = self.active_write_transaction orelse return null;
        return transaction.get(.main, key);
    }

    fn copy(self: *KeyValueStore, bytes: ?[]const u8) StorageError!?[]u8 {
        return self.allocator.dupe(u8, bytes orelse return null) catch error.OutOfMemory;
    }

    // --- The node table: one record per node id ------------------------------

    /// How far ahead of the node cursor `viewNode` walks instead of searching.
    const max_node_steps = 4;

    /// Moves the node cursor forward to `id` if it is a few records ahead
    /// (a scan reads nodes in id order, and the label index interleaves
    /// labels only lightly): a step costs no B-tree search. The record if
    /// found, `absent` if `id` is not there (the cursor passed it), `far` if
    /// `id` is not just ahead (search instead).
    fn stepToNode(self: *KeyValueStore, id: u64) StorageError!Step {
        const at = self.node_cursor_id orelse return .far;
        if (id <= at or id - at > max_node_steps) return .far;
        for (0..max_node_steps) |_| {
            const entry = try self.node_cursor.?.next() orelse {
                self.node_cursor_id = null;
                return .far;
            };
            const found = std.mem.bytesToValue(u64, entry.key[0..@sizeOf(u64)]);
            self.node_cursor_id = found;
            if (found == id) return .{ .found = entry.value };
            if (found > id) return .absent;
        }
        return .far;
    }

    const Step = union(enum) { found: []const u8, absent, far };

    /// The record of node `id` in the active transaction, without copying
    /// (null if absent, or outside a transaction: then use `getNode`).
    pub fn viewNode(self: *KeyValueStore, id: u64) StorageError!?[]const u8 {
        const transaction = self.active_read_transaction orelse {
            const writing = self.active_write_transaction orelse return null;
            const bytes = (try writing.get(.nodes, std.mem.asBytes(&id))) orelse return null;
            layout.assertRecord(bytes);
            return bytes;
        };
        if (self.records.find(id)) |bytes| return bytes;
        if (self.node_cursor == null) self.node_cursor = try transaction.openCursor(.nodes);
        const bytes = switch (try self.stepToNode(id)) {
            .found => |bytes| bytes,
            .absent => return null,
            .far => found: {
                const found = try self.node_cursor.?.find(std.mem.asBytes(&id));
                self.node_cursor_id = if (found != null) id else null;
                break :found found orelse return null;
            },
        };
        layout.assertRecord(bytes); // checked once: kept records were
        self.records.keep(id, bytes);
        return bytes;
    }

    /// A copy of the record of node `id`, allocated with the store's allocator.
    pub fn getNode(self: *KeyValueStore, id: u64) StorageError!?[]u8 {
        if (self.inTransaction()) return self.copy(try self.viewNode(id));
        try self.beginRead();
        defer self.abortRead();
        return self.copy(try self.viewNode(id));
    }

    pub fn putNode(self: *KeyValueStore, id: u64, record: []const u8) StorageError!void {
        layout.assertRecord(record);
        const transaction = self.writer() orelse return self.autocommit(putNode, .{ self, id, record });
        try transaction.put(.nodes, std.mem.asBytes(&id), record);
        try self.recordChange(transaction, .{ .operation = .put, .table = .nodes, .key = std.mem.asBytes(&id), .value = record });
    }

    /// Writes `record` as node `id`'s record without checking its layout, in
    /// the active write transaction: for tests that damage a database on
    /// purpose (`putNode` refuses malformed records in checked builds).
    pub fn putDamagedNode(self: *KeyValueStore, id: u64, record: []const u8) StorageError!void {
        const transaction = self.writer().?;
        try transaction.put(.nodes, std.mem.asBytes(&id), record);
        try self.recordChange(transaction, .{ .operation = .put, .table = .nodes, .key = std.mem.asBytes(&id), .value = record });
    }

    pub fn deleteNode(self: *KeyValueStore, id: u64) StorageError!void {
        const transaction = self.writer() orelse return self.autocommit(deleteNode, .{ self, id });
        try transaction.delete(.nodes, std.mem.asBytes(&id));
        try self.recordChange(transaction, .{ .operation = .delete, .table = .nodes, .key = std.mem.asBytes(&id) });
    }

    /// Iterates every node id, in ascending order (the keys yielded are the
    /// ids in native byte order).
    pub fn scanNodes(self: *KeyValueStore) StorageError!PrefixIterator {
        return self.scan(.nodes, "", "", null);
    }

    // --- The relationship table: one record per relationship id --------------

    /// The record of relationship `id` in the active transaction, without
    /// copying (null if absent, or outside a transaction).
    pub fn viewRelationship(self: *KeyValueStore, id: u64) StorageError!?[]const u8 {
        const transaction = self.activeTransaction() orelse return null;
        const bytes = (try transaction.get(.relationships, std.mem.asBytes(&id))) orelse return null;
        layout.assertRelationshipRecord(bytes);
        return bytes;
    }

    pub fn putRelationship(self: *KeyValueStore, id: u64, record: []const u8) StorageError!void {
        layout.assertRelationshipRecord(record);
        const transaction = self.writer() orelse return self.autocommit(putRelationship, .{ self, id, record });
        try transaction.put(.relationships, std.mem.asBytes(&id), record);
        try self.recordChange(transaction, .{ .operation = .put, .table = .relationships, .key = std.mem.asBytes(&id), .value = record });
    }

    pub fn deleteRelationship(self: *KeyValueStore, id: u64) StorageError!void {
        const transaction = self.writer() orelse return self.autocommit(deleteRelationship, .{ self, id });
        try transaction.delete(.relationships, std.mem.asBytes(&id));
        try self.recordChange(transaction, .{ .operation = .delete, .table = .relationships, .key = std.mem.asBytes(&id) });
    }

    /// Iterates every relationship id, in ascending order (the keys yielded
    /// are the ids in native byte order, the values their records).
    pub fn scanRelationships(self: *KeyValueStore) StorageError!PrefixIterator {
        return self.scan(.relationships, "", "", null);
    }

    /// Iterates every key of the main table, in key order.
    pub fn scanAll(self: *KeyValueStore) StorageError!PrefixIterator {
        return self.scan(.main, "", "", null);
    }

    // --- Scans ---------------------------------------------------------------

    /// Iterator over all key/value pairs whose key starts with `prefix`, in
    /// lexicographic order.
    pub fn scanPrefix(self: *KeyValueStore, prefix: []const u8) StorageError!PrefixIterator {
        return self.scanRange(prefix, prefix, null);
    }

    /// The keys with `prefix` from `start` (the first at or after it) to
    /// `upper` (inclusive; null: to the end of the prefix), in key order.
    pub fn scanRange(self: *KeyValueStore, prefix: []const u8, start: []const u8, upper: ?[]const u8) StorageError!PrefixIterator {
        return self.scan(.main, prefix, start, upper);
    }

    /// True if some key starts with `prefix`. In a read transaction it only
    /// positions a pooled cursor (no iterator is made): an existence test as
    /// cheap as a point lookup.
    pub fn hasPrefix(self: *KeyValueStore, prefix: []const u8) StorageError!bool {
        if (self.active_read_transaction != null and self.pooled_cursors > 0) {
            const entry = try self.cursor_pool[self.pooled_cursors - 1].seek(prefix) orelse return false;
            return std.mem.startsWith(u8, entry.key, prefix);
        }
        var iterator = try self.scanPrefix(prefix);
        defer iterator.deinit();
        return try iterator.next() != null;
    }

    pub fn countPrefix(self: *KeyValueStore, prefix: []const u8) StorageError!usize {
        var iterator = try self.scanPrefix(prefix);
        defer iterator.deinit();

        var count: usize = 0;
        while (try iterator.next()) |_| count += 1;
        return count;
    }

    /// A scan of `table` in the active transaction, or in a read transaction
    /// of its own that the iterator ends.
    fn scan(self: *KeyValueStore, table: Table, prefix: []const u8, start: []const u8, upper: ?[]const u8) StorageError!PrefixIterator {
        if (self.activeTransaction()) |transaction| return self.scanIn(transaction, false, table, prefix, start, upper);
        const transaction = self.environment.beginRead() catch return error.IteratorFailed;
        errdefer self.environment.endRead(transaction);
        return self.scanIn(transaction, true, table, prefix, start, upper);
    }

    fn scanIn(self: *KeyValueStore, transaction: engine.Transaction, owns_transaction: bool, table: Table, prefix: []const u8, start: []const u8, upper: ?[]const u8) StorageError!PrefixIterator {
        // Only main-table cursors of the active read transaction are pooled.
        const reusable = !owns_transaction and self.active_read_transaction != null and table == .main;
        const cursor = if (reusable and self.pooled_cursors > 0) cursor: {
            self.pooled_cursors -= 1;
            break :cursor self.cursor_pool[self.pooled_cursors];
        } else transaction.openCursor(table) catch return error.IteratorFailed;
        errdefer cursor.close();

        var iterator_prefix = Prefix{};
        if (prefix.len <= iterator_prefix.inline_bytes.len) {
            @memcpy(iterator_prefix.inline_bytes[0..prefix.len], prefix);
            iterator_prefix.length = prefix.len;
        } else {
            iterator_prefix.heap = self.allocator.dupe(u8, prefix) catch return error.OutOfMemory;
        }
        errdefer if (iterator_prefix.heap) |bytes| self.allocator.free(bytes);
        const owned_upper = if (upper) |bytes| self.allocator.dupe(u8, bytes) catch return error.OutOfMemory else null;
        errdefer if (owned_upper) |bytes| self.allocator.free(bytes);

        const current = (if (start.len == 0) cursor.first() else cursor.seek(start)) catch return error.IteratorFailed;
        return .{
            .store = self,
            .transaction = if (owns_transaction) transaction else null,
            .pool_read_transaction = if (reusable) self.read_transaction_number else null,
            .cursor = cursor,
            .prefix_storage = iterator_prefix,
            .upper = owned_upper,
            .current = current orelse .{ .key = "", .value = "" },
            .finished = current == null,
        };
    }
};

/// Single-pass iterator over a prefix scan. Owns the cursor; ends the
/// transaction only if it owns one (a scan over a borrowed transaction must
/// not end it).
pub const PrefixIterator = struct {
    store: *KeyValueStore,
    /// A read transaction of its own; null = borrowed from the active
    /// write/read transaction.
    transaction: ?engine.Transaction,
    /// The number of the read transaction whose cursor pool the cursor goes
    /// back to (see `KeyValueStore.read_transaction_number`).
    pool_read_transaction: ?u64,
    cursor: engine.Cursor,
    prefix_storage: Prefix,
    /// The last key in range (inclusive), owned; null: the prefix's end.
    upper: ?[]u8 = null,
    /// The entry `next` returns, unless `finished`. (Not an optional: the
    /// optional's padding, copied at every step, stalled the next read.)
    current: Entry,
    finished: bool,

    pub const Entry = engine.Entry;

    pub fn deinit(self: *PrefixIterator) void {
        const store = self.store;
        const back_to_pool = self.pool_read_transaction != null and store.active_read_transaction != null and
            self.pool_read_transaction == store.read_transaction_number and store.pooled_cursors < store.cursor_pool.len;
        if (back_to_pool) {
            store.cursor_pool[store.pooled_cursors] = self.cursor;
            store.pooled_cursors += 1;
        } else self.cursor.close();
        if (self.transaction) |transaction| store.environment.endRead(transaction);
        if (self.prefix_storage.heap) |bytes| store.allocator.free(bytes);
        if (self.upper) |bytes| store.allocator.free(bytes);
    }

    fn inRange(self: *const PrefixIterator, key: []const u8) bool {
        if (!std.mem.startsWith(u8, key, self.prefix_storage.bytes())) return false;
        if (self.upper) |upper| return std.mem.order(u8, key, upper) != .gt;
        return true;
    }

    /// Returns the next key/value pair, or `null` at the end. The returned
    /// views point into the engine's memory and are only valid until the
    /// next call to `next`.
    pub fn next(self: *PrefixIterator) StorageError!?Entry {
        if (self.finished or !self.inRange(self.current.key)) {
            self.finished = true;
            return null;
        }
        const entry = self.current;
        if (self.cursor.next() catch return error.IteratorFailed) |following| {
            self.current = following;
        } else self.finished = true;
        return entry;
    }
};

/// A scan's prefix: inline when short (most are), else on the heap.
const Prefix = struct {
    inline_bytes: [48]u8 = undefined,
    length: usize = 0,
    heap: ?[]u8 = null,

    fn bytes(self: *const Prefix) []const u8 {
        return self.heap orelse self.inline_bytes[0..self.length];
    }
};
