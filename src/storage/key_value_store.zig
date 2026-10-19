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
    env: *c.MDB_env,
    dbi: c.MDB_dbi,
    allocator: std.mem.Allocator,
    active_txn: ?*c.MDB_txn,
    active_read_txn: ?*c.MDB_txn,

    /// Opens (or creates) an LMDB environment at `path`. The directory must exist.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) StorageError!KeyValueStore {
        var env: ?*c.MDB_env = null;
        if (c.mdb_env_create(&env) != 0) return error.OpenFailed;
        errdefer c.mdb_env_close(env.?);

        // LMDB requires setting a maximum map size. This is a virtual
        // address-space reservation (sparse mmap), not RAM: the file grows as
        // pages are written. 1 TiB is plenty for an embedded graph DB on 64-bit.
        if (c.mdb_env_set_mapsize(env.?, 1 << 40) != 0) return error.OpenFailed;

        const c_path = allocator.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
        defer allocator.free(c_path);

        // MDB_NOTLS: without it a thread may hold only one read transaction at
        // a time, which would forbid the nested prefix scans a graph executor
        // needs. With it, each read txn owns its reader slot until aborted.
        if (c.mdb_env_open(env.?, c_path.ptr, c.MDB_NOTLS, 0o644) != 0) return error.OpenFailed;

        // Opens the default (unnamed) database inside a transaction.
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(env.?, null, 0, &txn) != 0) return error.OpenFailed;
        errdefer _ = c.mdb_txn_abort(txn.?);

        var dbi: c.MDB_dbi = 0;
        if (c.mdb_dbi_open(txn.?, null, 0, &dbi) != 0) return error.OpenFailed;
        if (c.mdb_txn_commit(txn.?) != 0) {
            _ = c.mdb_txn_abort(txn.?);
            return error.OpenFailed;
        }

        return .{ .env = env.?, .dbi = dbi, .allocator = allocator, .active_txn = null, .active_read_txn = null };
    }

    pub fn deinit(self: *KeyValueStore) void {
        c.mdb_env_close(self.env);
    }

    /// Begins an explicit write transaction. Until `commitWrite`/`abortWrite`,
    /// `put`/`del`/`get`/`exists`/`scanPrefix` run on this transaction (and see
    /// its uncommitted writes). Not reentrant (LMDB is single-writer anyway).
    pub fn beginWrite(self: *KeyValueStore) StorageError!void {
        if (self.active_txn != null or self.active_read_txn != null) return error.WriteFailed;
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, 0, &txn) != 0) return error.WriteFailed;
        self.active_txn = txn.?;
    }

    pub fn commitWrite(self: *KeyValueStore) StorageError!void {
        const txn = self.active_txn orelse return error.WriteFailed;
        self.active_txn = null;
        if (c.mdb_txn_commit(txn) != 0) {
            _ = c.mdb_txn_abort(txn);
            return error.WriteFailed;
        }
    }

    pub fn abortWrite(self: *KeyValueStore) void {
        if (self.active_txn) |txn| {
            _ = c.mdb_txn_abort(txn);
            self.active_txn = null;
        }
    }

    /// Begins an explicit read transaction (an MVCC snapshot). Until
    /// `commitRead`/`abortRead`, `get`/`exists`/`scanPrefix` run on this
    /// transaction, so a query's reads are batched into one transaction instead
    /// of one per read. Reads see the committed state as of `beginRead`
    /// (snapshot isolation), not writes committed afterwards.
    pub fn beginRead(self: *KeyValueStore) StorageError!void {
        if (self.active_txn != null or self.active_read_txn != null) return error.ReadFailed;
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return error.ReadFailed;
        self.active_read_txn = txn.?;
    }

    /// Ends the active read transaction. For a read-only transaction "commit"
    /// and "abort" are equivalent (nothing is written); both just release it.
    pub fn commitRead(self: *KeyValueStore) void {
        self.abortRead();
    }

    pub fn abortRead(self: *KeyValueStore) void {
        if (self.active_read_txn) |txn| {
            _ = c.mdb_txn_abort(txn);
            self.active_read_txn = null;
        }
    }

    pub fn put(self: *KeyValueStore, key: []const u8, value: []const u8) StorageError!void {
        if (self.active_txn) |txn| return self.putIn(txn, key, value);
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, 0, &txn) != 0) return error.WriteFailed;
        errdefer _ = c.mdb_txn_abort(txn.?);
        try self.putIn(txn.?, key, value);
        if (c.mdb_txn_commit(txn.?) != 0) {
            _ = c.mdb_txn_abort(txn.?);
            return error.WriteFailed;
        }
    }

    /// An absent key is a normal result: `null`, not an error.
    /// The returned value is an owned copy for the caller (free with
    /// `self.allocator.free`).
    pub fn get(self: *KeyValueStore, key: []const u8) StorageError!?[]u8 {
        if (self.active_txn) |txn| return self.getIn(txn, key);
        if (self.active_read_txn) |txn| return self.getIn(txn, key);
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return error.ReadFailed;
        defer _ = c.mdb_txn_abort(txn.?);
        return self.getIn(txn.?, key);
    }

    pub fn exists(self: *KeyValueStore, key: []const u8) StorageError!bool {
        if (self.active_txn) |txn| return self.existsIn(txn, key);
        if (self.active_read_txn) |txn| return self.existsIn(txn, key);
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return error.ReadFailed;
        defer _ = c.mdb_txn_abort(txn.?);
        return self.existsIn(txn.?, key);
    }

    /// Idempotent: deleting a missing key is a success.
    pub fn del(self: *KeyValueStore, key: []const u8) StorageError!void {
        if (self.active_txn) |txn| return self.delIn(txn, key);
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, 0, &txn) != 0) return error.DeleteFailed;
        errdefer _ = c.mdb_txn_abort(txn.?);
        try self.delIn(txn.?, key);
        if (c.mdb_txn_commit(txn.?) != 0) {
            _ = c.mdb_txn_abort(txn.?);
            return error.DeleteFailed;
        }
    }

    /// Iterator over all key/value pairs whose key starts with `prefix`, in
    /// lexicographic order (LMDB's natural order).
    pub fn scanPrefix(self: *KeyValueStore, prefix: []const u8) StorageError!PrefixIterator {
        if (self.active_txn) |txn| return self.scanPrefixIn(txn, prefix, false);
        if (self.active_read_txn) |txn| return self.scanPrefixIn(txn, prefix, false);
        var txn: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.env, null, c.MDB_RDONLY, &txn) != 0) return error.IteratorFailed;
        errdefer _ = c.mdb_txn_abort(txn.?);
        return self.scanPrefixIn(txn.?, prefix, true);
    }

    pub fn countPrefix(self: *KeyValueStore, prefix: []const u8) StorageError!usize {
        var it = try self.scanPrefix(prefix);
        defer it.deinit();

        var count: usize = 0;
        while (try it.next()) |_| count += 1;
        return count;
    }

    fn putIn(self: *KeyValueStore, txn: *c.MDB_txn, key: []const u8, value: []const u8) StorageError!void {
        var key_val = makeVal(key);
        var data_val = makeVal(value);
        if (c.mdb_put(txn, self.dbi, &key_val, &data_val, 0) != 0) return error.WriteFailed;
    }

    fn getIn(self: *KeyValueStore, txn: *c.MDB_txn, key: []const u8) StorageError!?[]u8 {
        var key_val = makeVal(key);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_get(txn, self.dbi, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return error.ReadFailed;
        const bytes = valSlice(data_val);
        return self.allocator.dupe(u8, bytes) catch error.OutOfMemory;
    }

    fn existsIn(self: *KeyValueStore, txn: *c.MDB_txn, key: []const u8) StorageError!bool {
        var key_val = makeVal(key);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_get(txn, self.dbi, &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return false;
        if (rc != 0) return error.ReadFailed;
        return true;
    }

    fn delIn(self: *KeyValueStore, txn: *c.MDB_txn, key: []const u8) StorageError!void {
        var key_val = makeVal(key);
        const rc = c.mdb_del(txn, self.dbi, &key_val, null);
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.DeleteFailed;
    }

    fn scanPrefixIn(self: *KeyValueStore, txn: *c.MDB_txn, prefix: []const u8, owns_txn: bool) StorageError!PrefixIterator {
        var cursor: ?*c.MDB_cursor = null;
        if (c.mdb_cursor_open(txn, self.dbi, &cursor) != 0) return error.IteratorFailed;
        errdefer c.mdb_cursor_close(cursor.?);

        const owned_prefix = self.allocator.dupe(u8, prefix) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_prefix);

        var key_val = makeVal(prefix);
        var data_val = c.MDB_val{ .mv_size = 0, .mv_data = null };
        const rc = c.mdb_cursor_get(cursor.?, &key_val, &data_val, c.MDB_SET_RANGE);
        const finished = rc == c.MDB_NOTFOUND;
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.IteratorFailed;

        return .{
            .store = self,
            .txn = if (owns_txn) txn else null,
            .cursor = cursor.?,
            .prefix = owned_prefix,
            .key = key_val,
            .data = data_val,
            .finished = finished,
        };
    }
};

/// Single-pass iterator over a prefix scan. Owns the cursor; aborts the
/// transaction only if it owns one (a scan over a borrowed write txn must not
/// abort it).
pub const PrefixIterator = struct {
    store: *KeyValueStore,
    txn: ?*c.MDB_txn, // null = borrowed from an active write/read txn
    cursor: *c.MDB_cursor,
    prefix: []u8,
    key: c.MDB_val,
    data: c.MDB_val,
    finished: bool,

    pub const Entry = struct { key: []const u8, value: []const u8 };

    pub fn deinit(self: *PrefixIterator) void {
        c.mdb_cursor_close(self.cursor);
        if (self.txn) |t| _ = c.mdb_txn_abort(t);
        self.store.allocator.free(self.prefix);
    }

    fn inRange(self: *const PrefixIterator) bool {
        if (self.finished or self.key.mv_data == null) return false;
        const k: [*]const u8 = @ptrCast(self.key.mv_data.?);
        if (self.key.mv_size < self.prefix.len) return false;
        return std.mem.eql(u8, k[0..self.prefix.len], self.prefix);
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

fn makeVal(bytes: []const u8) c.MDB_val {
    const ptr: *anyopaque = @ptrCast(@constCast(bytes.ptr));
    return .{ .mv_size = bytes.len, .mv_data = ptr };
}

fn valSlice(v: c.MDB_val) []const u8 {
    if (v.mv_size == 0) return &.{};
    const p: [*]const u8 = @ptrCast(v.mv_data.?);
    return p[0..v.mv_size];
}
