//! KeyValueStore: a minimal RAII wrapper over LMDB.
//!
//! Deliberately NO class hierarchy: a single concrete type, movable (through
//! pointers to LMDB opaques) and non-copyable, with errors modeled as values
//! (`error union`, the analogue of `std::expected`) rather than exceptions.
//! This is the first building block of the storage layer on which the key
//! encoding for nodes, edges and properties will later be built.

const std = @import("std");

const c = @import("lmdb_bindings.zig");

pub const StorageError = error{
    OpenFailed,
    WriteFailed,
    ReadFailed,
    DeleteFailed,
    IteratorFailed,
    OutOfMemory,
    NodeStillConnected,
};

pub const KeyValueStore = struct {
    environment: *c.MDB_env,
    database: c.MDB_dbi,
    node_database: c.MDB_dbi,
    node_cursor: ?*c.MDB_cursor = null,
    allocator: std.mem.Allocator,
    active_write_transaction: ?*c.MDB_txn,
    active_read_transaction: ?*c.MDB_txn,
    /// A cursor of the active read transaction that `view` reuses: LMDB
    /// finds a key near the cursor's last one without searching down from
    /// the root, so reads in key order (a scan's nodes) are cheaper.
    read_cursor: ?*c.MDB_cursor = null,
    /// Cursors of the active read transaction that finished prefix scans
    /// gave back, reused by the next scans (last in, first out): a nested
    /// scan gets the cursor the scan at its depth used before, which is near
    /// where it starts now (the next node's edges), so LMDB repositions it
    /// without searching from the root.
    cursor_pool: [16]*c.MDB_cursor = undefined,
    pooled_cursors: usize = 0,

    /// How much a commit waits for the disk.
    pub const Durability = enum {
        /// Each commit is on disk when it returns (the default).
        full,
        /// Each commit's data is on disk, its metadata page is flushed with
        /// the next one: a power failure can lose the last commit, never
        /// corrupt the database.
        relaxed,
        /// Commits are left to the operating system to write (or to `sync`):
        /// a power failure can lose the recent commits; the database stays
        /// consistent where the file system keeps writes in order.
        deferred,
    };

    pub const Options = struct { durability: Durability = .full };

    /// Opens (or creates) an LMDB environment at `path`. The directory must exist.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) StorageError!KeyValueStore {
        return openWithOptions(allocator, path, .{});
    }

    pub fn openWithOptions(allocator: std.mem.Allocator, path: []const u8, options: Options) StorageError!KeyValueStore {
        var environment: ?*c.MDB_env = null;
        if (c.mdb_env_create(&environment) != 0) return error.OpenFailed;
        errdefer c.mdb_env_close(environment.?);

        // LMDB requires setting a maximum map size. This is a virtual
        // address-space reservation (sparse mmap), not RAM: the file grows as
        // pages are written. 1 TiB is plenty for an embedded graph DB on 64-bit.
        if (c.mdb_env_set_mapsize(environment.?, 1 << 40) != 0) return error.OpenFailed;
        if (c.mdb_env_set_maxdbs(environment.?, 2) != 0) return error.OpenFailed;

        const c_path = allocator.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
        defer allocator.free(c_path);

        // MDB_NOTLS: without it a thread may hold only one read transaction at
        // a time, which would forbid the nested prefix scans a graph executor
        // needs. With it, each read transaction owns its reader slot until aborted.
        const durability_flags: c_uint = switch (options.durability) {
            .full => 0,
            .relaxed => c.MDB_NOMETASYNC,
            .deferred => c.MDB_NOSYNC,
        };
        if (c.mdb_env_open(environment.?, c_path.ptr, c.MDB_NOTLS | durability_flags, 0o644) != 0) return error.OpenFailed;

        // Opens the default (unnamed) database inside a transaction.
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(environment.?, null, 0, &transaction) != 0) return error.OpenFailed;
        errdefer _ = c.mdb_txn_abort(transaction.?);

        var database: c.MDB_dbi = 0;
        if (c.mdb_dbi_open(transaction.?, null, 0, &database) != 0) return error.OpenFailed;
        // Node records live in a table of their own, keyed by the id as an
        // integer: a smaller tree than the one holding every other key, and
        // integer comparisons instead of byte-string ones. (Its name is a key
        // of the main table; `#` starts no key the graph writes.)
        var node_database: c.MDB_dbi = 0;
        if (c.mdb_dbi_open(transaction.?, "#nodes", c.MDB_CREATE | c.MDB_INTEGERKEY, &node_database) != 0) return error.OpenFailed;
        if (c.mdb_txn_commit(transaction.?) != 0) {
            _ = c.mdb_txn_abort(transaction.?);
            return error.OpenFailed;
        }

        return .{ .environment = environment.?, .database = database, .node_database = node_database, .allocator = allocator, .active_write_transaction = null, .active_read_transaction = null };
    }

    /// Writes every commit so far to disk (what `full` durability does at
    /// each commit).
    pub fn sync(self: *KeyValueStore) StorageError!void {
        if (c.mdb_env_sync(self.environment, 1) != 0) return error.WriteFailed;
    }

    pub fn deinit(self: *KeyValueStore) void {
        c.mdb_env_close(self.environment);
    }

    /// Begins an explicit write transaction. Until `commitWrite`/`abortWrite`,
    /// `put`/`del`/`get`/`exists`/`scanPrefix` run on this transaction (and see
    /// its uncommitted writes). Not reentrant (LMDB is single-writer anyway).
    pub fn beginWrite(self: *KeyValueStore) StorageError!void {
        if (self.active_write_transaction != null or self.active_read_transaction != null) return error.WriteFailed;
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, 0, &transaction) != 0) return error.WriteFailed;
        self.active_write_transaction = transaction.?;
    }

    pub fn commitWrite(self: *KeyValueStore) StorageError!void {
        const transaction = self.active_write_transaction orelse return error.WriteFailed;
        self.active_write_transaction = null;
        if (c.mdb_txn_commit(transaction) != 0) {
            _ = c.mdb_txn_abort(transaction);
            return error.WriteFailed;
        }
    }

    pub fn abortWrite(self: *KeyValueStore) void {
        if (self.active_write_transaction) |transaction| {
            _ = c.mdb_txn_abort(transaction);
            self.active_write_transaction = null;
        }
    }

    /// Begins an explicit read transaction (an MVCC snapshot). Until
    /// `commitRead`/`abortRead`, `get`/`exists`/`scanPrefix` run on this
    /// transaction, so a query's reads are batched into one transaction instead
    /// of one per read. Reads see the committed state as of `beginRead`
    /// (snapshot isolation), not writes committed afterwards.
    pub fn beginRead(self: *KeyValueStore) StorageError!void {
        if (self.active_write_transaction != null or self.active_read_transaction != null) return error.ReadFailed;
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, c.MDB_RDONLY, &transaction) != 0) return error.ReadFailed;
        self.active_read_transaction = transaction.?;
    }

    /// Ends the active read transaction. For a read-only transaction "commit"
    /// and "abort" are equivalent (nothing is written); both just release it.
    pub fn commitRead(self: *KeyValueStore) void {
        self.abortRead();
    }

    pub fn abortRead(self: *KeyValueStore) void {
        for (self.cursor_pool[0..self.pooled_cursors]) |cursor| c.mdb_cursor_close(cursor);
        self.pooled_cursors = 0;
        if (self.node_cursor) |cursor| {
            c.mdb_cursor_close(cursor);
            self.node_cursor = null;
        }
        if (self.read_cursor) |cursor| {
            c.mdb_cursor_close(cursor);
            self.read_cursor = null;
        }
        if (self.active_read_transaction) |transaction| {
            _ = c.mdb_txn_abort(transaction);
            self.active_read_transaction = null;
        }
    }

    pub fn put(self: *KeyValueStore, key: []const u8, value: []const u8) StorageError!void {
        if (self.active_write_transaction) |transaction| return self.putIn(transaction, key, value);
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, 0, &transaction) != 0) return error.WriteFailed;
        errdefer _ = c.mdb_txn_abort(transaction.?);
        try self.putIn(transaction.?, key, value);
        if (c.mdb_txn_commit(transaction.?) != 0) {
            _ = c.mdb_txn_abort(transaction.?);
            return error.WriteFailed;
        }
    }

    /// An absent key is a normal result: `null`, not an error.
    /// The returned value is an owned copy for the caller (free with
    /// `self.allocator.free`).
    pub fn get(self: *KeyValueStore, key: []const u8) StorageError!?[]u8 {
        if (self.active_write_transaction) |transaction| return self.getIn(transaction, key);
        if (self.active_read_transaction) |transaction| return self.getIn(transaction, key);
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, c.MDB_RDONLY, &transaction) != 0) return error.ReadFailed;
        defer _ = c.mdb_txn_abort(transaction.?);
        return self.getIn(transaction.?, key);
    }

    /// The value of `key` without copying it, inside the active transaction
    /// (null without one, or if the key is absent: callers then use `get`).
    /// The bytes are LMDB's own: valid until the transaction ends or writes.
    pub fn view(self: *KeyValueStore, key: []const u8) StorageError!?[]const u8 {
        var key_val = makeVal(key);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = if (self.active_read_transaction) |transaction| rc: {
            if (self.read_cursor == null) {
                if (c.mdb_cursor_open(transaction, self.database, &self.read_cursor) != 0) return error.ReadFailed;
            }
            break :rc c.mdb_cursor_get(self.read_cursor.?, &key_val, &data_val, c.MDB_SET_KEY);
        } else if (self.active_write_transaction) |transaction|
            c.mdb_get(transaction, self.database, &key_val, &data_val)
        else
            return null;
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return error.ReadFailed;
        return valSlice(data_val);
    }

    // --- The node table: one record per node id ------------------------------

    /// The record of node `id` in the active transaction, without copying
    /// (null if absent, or outside a transaction: then use `getNode`).
    pub fn viewNode(self: *KeyValueStore, id: u64) StorageError!?[]const u8 {
        var key = id;
        var key_val = c.MDB_val{ .mv_size = @sizeOf(u64), .mv_data = &key };
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = if (self.active_read_transaction) |transaction| rc: {
            if (self.node_cursor == null) {
                if (c.mdb_cursor_open(transaction, self.node_database, &self.node_cursor) != 0) return error.ReadFailed;
            }
            break :rc c.mdb_cursor_get(self.node_cursor.?, &key_val, &data_val, c.MDB_SET_KEY);
        } else if (self.active_write_transaction) |transaction|
            c.mdb_get(transaction, self.node_database, &key_val, &data_val)
        else
            return null;
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return error.ReadFailed;
        return valSlice(data_val);
    }

    /// A copy of the record of node `id`, allocated with the store's allocator.
    pub fn getNode(self: *KeyValueStore, id: u64) StorageError!?[]u8 {
        if (self.inTransaction()) {
            const bytes = (try self.viewNode(id)) orelse return null;
            return self.allocator.dupe(u8, bytes) catch error.OutOfMemory;
        }
        try self.beginRead();
        defer self.abortRead();
        const bytes = (try self.viewNode(id)) orelse return null;
        return self.allocator.dupe(u8, bytes) catch error.OutOfMemory;
    }

    pub fn putNode(self: *KeyValueStore, id: u64, record: []const u8) StorageError!void {
        var key = id;
        var key_val = c.MDB_val{ .mv_size = @sizeOf(u64), .mv_data = &key };
        var data_val = makeVal(record);
        const transaction = self.active_write_transaction orelse return self.autocommit(putNodeIn, .{ self, id, record });
        if (c.mdb_put(transaction, self.node_database, &key_val, &data_val, 0) != 0) return error.WriteFailed;
    }

    fn putNodeIn(self: *KeyValueStore, id: u64, record: []const u8) StorageError!void {
        return self.putNode(id, record);
    }

    pub fn deleteNode(self: *KeyValueStore, id: u64) StorageError!void {
        var key = id;
        var key_val = c.MDB_val{ .mv_size = @sizeOf(u64), .mv_data = &key };
        const transaction = self.active_write_transaction orelse return self.autocommit(deleteNodeIn, .{ self, id });
        const rc = c.mdb_del(transaction, self.node_database, &key_val, null);
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.DeleteFailed;
    }

    fn deleteNodeIn(self: *KeyValueStore, id: u64) StorageError!void {
        return self.deleteNode(id);
    }

    /// Runs `operation` in a write transaction of its own, committed at once.
    fn autocommit(self: *KeyValueStore, comptime operation: anytype, arguments: anytype) StorageError!void {
        try self.beginWrite();
        errdefer self.abortWrite();
        try @call(.auto, operation, arguments);
        try self.commitWrite();
    }

    /// Iterates every node id, in ascending order (the keys yielded are the
    /// ids in native byte order).
    pub fn scanNodes(self: *KeyValueStore) StorageError!PrefixIterator {
        if (self.active_write_transaction) |transaction| return self.scanIn(transaction, self.node_database, "", false);
        if (self.active_read_transaction) |transaction| return self.scanIn(transaction, self.node_database, "", false);
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, c.MDB_RDONLY, &transaction) != 0) return error.IteratorFailed;
        errdefer _ = c.mdb_txn_abort(transaction.?);
        return self.scanIn(transaction.?, self.node_database, "", true);
    }

    pub fn inTransaction(self: *const KeyValueStore) bool {
        return self.active_write_transaction != null or self.active_read_transaction != null;
    }

    pub fn exists(self: *KeyValueStore, key: []const u8) StorageError!bool {
        if (self.active_write_transaction) |transaction| return self.existsIn(transaction, key);
        if (self.active_read_transaction) |transaction| return self.existsIn(transaction, key);
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, c.MDB_RDONLY, &transaction) != 0) return error.ReadFailed;
        defer _ = c.mdb_txn_abort(transaction.?);
        return self.existsIn(transaction.?, key);
    }

    /// Idempotent: deleting a missing key is a success.
    pub fn del(self: *KeyValueStore, key: []const u8) StorageError!void {
        if (self.active_write_transaction) |transaction| return self.delIn(transaction, key);
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, 0, &transaction) != 0) return error.DeleteFailed;
        errdefer _ = c.mdb_txn_abort(transaction.?);
        try self.delIn(transaction.?, key);
        if (c.mdb_txn_commit(transaction.?) != 0) {
            _ = c.mdb_txn_abort(transaction.?);
            return error.DeleteFailed;
        }
    }

    /// Iterator over all key/value pairs whose key starts with `prefix`, in
    /// lexicographic order (LMDB's natural order).
    pub fn scanPrefix(self: *KeyValueStore, prefix: []const u8) StorageError!PrefixIterator {
        if (self.active_write_transaction) |transaction| return self.scanPrefixIn(transaction, prefix, false);
        if (self.active_read_transaction) |transaction| return self.scanPrefixIn(transaction, prefix, false);
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.environment, null, c.MDB_RDONLY, &transaction) != 0) return error.IteratorFailed;
        errdefer _ = c.mdb_txn_abort(transaction.?);
        return self.scanPrefixIn(transaction.?, prefix, true);
    }

    pub fn countPrefix(self: *KeyValueStore, prefix: []const u8) StorageError!usize {
        var iterator = try self.scanPrefix(prefix);
        defer iterator.deinit();

        var count: usize = 0;
        while (try iterator.next()) |_| count += 1;
        return count;
    }

    fn putIn(self: *KeyValueStore, transaction: *c.MDB_txn, key: []const u8, value: []const u8) StorageError!void {
        var key_val = makeVal(key);
        var data_val = makeVal(value);
        if (c.mdb_put(transaction, self.database, &key_val, &data_val, 0) != 0) return error.WriteFailed;
    }

    fn getIn(self: *KeyValueStore, transaction: *c.MDB_txn, key: []const u8) StorageError!?[]u8 {
        var key_val = makeVal(key);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_get(transaction, self.database, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return error.ReadFailed;
        const bytes = valSlice(data_val);
        return self.allocator.dupe(u8, bytes) catch error.OutOfMemory;
    }

    fn existsIn(self: *KeyValueStore, transaction: *c.MDB_txn, key: []const u8) StorageError!bool {
        var key_val = makeVal(key);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_get(transaction, self.database, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return false;
        if (rc != 0) return error.ReadFailed;
        return true;
    }

    fn delIn(self: *KeyValueStore, transaction: *c.MDB_txn, key: []const u8) StorageError!void {
        var key_val = makeVal(key);
        const rc = c.mdb_del(transaction, self.database, &key_val, null);
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.DeleteFailed;
    }

    fn scanPrefixIn(self: *KeyValueStore, transaction: *c.MDB_txn, prefix: []const u8, owns_txn: bool) StorageError!PrefixIterator {
        return self.scanIn(transaction, self.database, prefix, owns_txn);
    }

    fn scanIn(self: *KeyValueStore, transaction: *c.MDB_txn, database: c.MDB_dbi, prefix: []const u8, owns_txn: bool) StorageError!PrefixIterator {
        // Only main-table cursors are pooled.
        const reusable = !owns_txn and transaction == self.active_read_transaction and database == self.database;
        var cursor: ?*c.MDB_cursor = null;
        if (reusable and self.pooled_cursors > 0) {
            self.pooled_cursors -= 1;
            cursor = self.cursor_pool[self.pooled_cursors];
        } else if (c.mdb_cursor_open(transaction, database, &cursor) != 0) return error.IteratorFailed;
        errdefer c.mdb_cursor_close(cursor.?);

        var iterator_prefix = Prefix{};
        if (prefix.len <= iterator_prefix.inline_bytes.len) {
            @memcpy(iterator_prefix.inline_bytes[0..prefix.len], prefix);
            iterator_prefix.length = prefix.len;
        } else {
            iterator_prefix.heap = self.allocator.dupe(u8, prefix) catch return error.OutOfMemory;
        }
        errdefer if (iterator_prefix.heap) |bytes| self.allocator.free(bytes);

        var key_val = makeVal(prefix);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_cursor_get(cursor.?, &key_val, &data_val, if (prefix.len == 0) c.MDB_FIRST else c.MDB_SET_RANGE);
        const finished = rc == c.MDB_NOTFOUND;
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.IteratorFailed;

        return .{
            .store = self,
            .transaction = if (owns_txn) transaction else null,
            .pool_transaction = if (reusable) transaction else null,
            .cursor = cursor.?,
            .prefix_storage = iterator_prefix,
            .key = key_val,
            .data = data_val,
            .finished = finished,
        };
    }
};

/// Single-pass iterator over a prefix scan. Owns the cursor; aborts the
/// transaction only if it owns one (a scan over a borrowed write transaction must not
/// abort it).
pub const PrefixIterator = struct {
    store: *KeyValueStore,
    transaction: ?*c.MDB_txn, // null = borrowed from an active write/read transaction
    /// The read transaction whose cursor pool the cursor goes back to.
    pool_transaction: ?*c.MDB_txn,
    cursor: *c.MDB_cursor,
    prefix_storage: Prefix,
    key: c.MDB_val,
    data: c.MDB_val,
    finished: bool,

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn deinit(self: *PrefixIterator) void {
        const store = self.store;
        const back_to_pool = self.pool_transaction != null and self.pool_transaction == store.active_read_transaction and
            store.pooled_cursors < store.cursor_pool.len;
        if (back_to_pool) {
            store.cursor_pool[store.pooled_cursors] = self.cursor;
            store.pooled_cursors += 1;
        } else c.mdb_cursor_close(self.cursor);
        if (self.transaction) |t| _ = c.mdb_txn_abort(t);
        if (self.prefix_storage.heap) |bytes| store.allocator.free(bytes);
    }

    fn inRange(self: *const PrefixIterator) bool {
        if (self.finished or self.key.mv_data == null) return false;
        const prefix = self.prefix_storage.bytes();
        const k: [*]const u8 = @ptrCast(self.key.mv_data.?);
        if (self.key.mv_size < prefix.len) return false;
        return std.mem.eql(u8, k[0..prefix.len], prefix);
    }

    /// Returns the next key/value pair, or `null` at the end. The returned
    /// views point into LMDB memory and are only valid until the next call to
    /// `next`.
    pub fn next(self: *PrefixIterator) StorageError!?Entry {
        if (!self.inRange()) {
            self.finished = true;
            return null;
        }
        const k: [*]const u8 = @ptrCast(self.key.mv_data.?);
        const v: [*]const u8 = @ptrCast(self.data.mv_data.?);
        const entry = Entry{ .key = k[0..self.key.mv_size], .value = v[0..self.data.mv_size] };

        const rc = c.mdb_cursor_get(self.cursor, &self.key, &self.data, c.MDB_NEXT);
        if (rc == c.MDB_NOTFOUND) {
            self.finished = true;
        } else if (rc != 0) {
            return error.IteratorFailed;
        }
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

fn makeVal(bytes: []const u8) c.MDB_val {
    const ptr: *anyopaque = @ptrCast(@constCast(bytes.ptr));
    return .{ .mv_size = bytes.len, .mv_data = ptr };
}

fn valSlice(v: c.MDB_val) []const u8 {
    if (v.mv_size == 0) return &.{};
    const p: [*]const u8 = @ptrCast(v.mv_data.?);
    return p[0..v.mv_size];
}
