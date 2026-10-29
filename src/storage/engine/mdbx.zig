//! The libmdbx engine (`vendor/libmdbx`): the contract of contract.zig over
//! libmdbx's environment, transactions and cursors.
//!
//! What it gains over LMDB: the file grows in steps and shrinks back when
//! the free space at its end passes a threshold (no fixed map size to
//! choose), stale readers of dead processes are cleared on their own, and
//! Windows is supported as well as POSIX systems.

const std = @import("std");

const contract = @import("contract.zig");
const c = @import("mdbx_bindings.zig");

const Error = contract.Error;
const Table = contract.Table;
const Entry = contract.Entry;

/// The libmdbx table handle of each table, indexed by `Table`.
const TableHandles = [Table.count]c.MDBX_dbi;

/// The file of a database's directory that holds it all.
pub const data_file_name = "mdbx.dat";

/// The file's geometry: it may grow to `size_upper`, in steps of
/// `growth_step`, and gives back the free space at its end once it passes
/// `shrink_threshold`. (The upper bound reserves address space, not memory
/// or disk.)
const geometry = struct {
    const size_upper: isize = 1 << 40;
    const growth_step: isize = 16 << 20;
    const shrink_threshold: isize = 64 << 20;
};

pub const Environment = struct {
    handle: *c.MDBX_env,
    tables: TableHandles,
    /// Ended read transactions kept to be renewed: renewing one costs no
    /// allocation and keeps its reader slot.
    parked_reads: [max_parked_reads]*c.MDBX_txn = undefined,
    parked_read_count: usize = 0,
    /// Whether this is a share of another environment (`share`), which
    /// leaves the database open when it closes.
    shared: bool = false,

    const max_parked_reads = 4;

    /// Opens (or creates) the database in directory `path`, which must exist.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: contract.Options) Error!Environment {
        // The log level is global to the process; setting it again is harmless.
        _ = c.mdbx_setup_debug(c.MDBX_LOG_ERROR, c.MDBX_DBG_DONTCHANGE, c.MDBX_LOGGER_DONTCHANGE);
        var environment: ?*c.MDBX_env = null;
        if (c.mdbx_env_create(&environment) != c.MDBX_SUCCESS) return error.OpenFailed;
        errdefer _ = c.mdbx_env_close_ex(environment.?, false);

        if (c.mdbx_env_set_option(environment.?, c.MDBX_opt_max_db, Table.count) != c.MDBX_SUCCESS) return error.OpenFailed;
        // -1: libmdbx's default (lower bound, current size, page size).
        if (c.mdbx_env_set_geometry(environment.?, -1, -1, geometry.size_upper, geometry.growth_step, geometry.shrink_threshold, -1) != c.MDBX_SUCCESS) return error.OpenFailed;

        const c_path = allocator.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
        defer allocator.free(c_path);

        // MDBX_NOSTICKYTHREADS: read transactions are not tied to a thread,
        // so one thread may hold several (the nested prefix scans a graph
        // executor needs).
        const durability_flags: c_uint = switch (options.durability) {
            .full => c.MDBX_SYNC_DURABLE,
            .relaxed => c.MDBX_NOMETASYNC,
            .deferred => c.MDBX_SAFE_NOSYNC,
        };
        if (c.mdbx_env_open(environment.?, c_path.ptr, c.MDBX_NOSTICKYTHREADS | durability_flags, 0o644) != c.MDBX_SUCCESS) return error.OpenFailed;

        var transaction: ?*c.MDBX_txn = null;
        if (c.mdbx_txn_begin(environment.?, null, c.MDBX_TXN_READWRITE, &transaction) != c.MDBX_SUCCESS) return error.OpenFailed;
        const tables = openTables(transaction.?) catch |err| {
            _ = c.mdbx_txn_abort(transaction.?);
            return err;
        };
        // libmdbx ends the transaction whether its commit succeeds or not.
        if (c.mdbx_txn_commit(transaction.?) != c.MDBX_SUCCESS) return error.OpenFailed;
        return .{ .handle = environment.?, .tables = tables };
    }

    fn openTables(transaction: *c.MDBX_txn) Error!TableHandles {
        var tables: TableHandles = undefined;
        // The main table is the default (unnamed) one. The record tables are
        // named ones, keyed by the id as an integer: smaller trees than the
        // main one, and integer comparisons instead of byte-string ones.
        if (c.mdbx_dbi_open(transaction, null, c.MDBX_DB_DEFAULTS, &tables[@backingInt(Table.main)]) != c.MDBX_SUCCESS) return error.OpenFailed;
        if (c.mdbx_dbi_open(transaction, "#nodes", c.MDBX_CREATE | c.MDBX_INTEGERKEY, &tables[@backingInt(Table.nodes)]) != c.MDBX_SUCCESS) return error.OpenFailed;
        if (c.mdbx_dbi_open(transaction, "#relationships", c.MDBX_CREATE | c.MDBX_INTEGERKEY, &tables[@backingInt(Table.relationships)]) != c.MDBX_SUCCESS) return error.OpenFailed;
        if (c.mdbx_dbi_open(transaction, "#changes", c.MDBX_CREATE, &tables[@backingInt(Table.changes)]) != c.MDBX_SUCCESS) return error.OpenFailed;
        return tables;
    }

    pub fn close(self: *Environment) void {
        for (self.parked_reads[0..self.parked_read_count]) |transaction| _ = c.mdbx_txn_abort(transaction);
        self.parked_read_count = 0;
        if (!self.shared) _ = c.mdbx_env_close_ex(self.handle, false);
    }

    /// Another environment on the same open database, for another thread.
    pub fn share(self: *Environment) Environment {
        return .{ .handle = self.handle, .tables = self.tables, .shared = true };
    }

    /// Writes every commit so far to disk (what `full` durability does at
    /// each commit).
    pub fn sync(self: *Environment) Error!void {
        const rc = c.mdbx_env_sync_ex(self.handle, true, false);
        // MDBX_RESULT_TRUE (-1): there was nothing to write.
        if (rc != c.MDBX_SUCCESS and rc != -1) return error.WriteFailed;
    }

    pub fn copy(self: *Environment, allocator: std.mem.Allocator, directory: []const u8) Error!void {
        // libmdbx copies to a file: the data file of a database in `directory`.
        const c_path = std.fs.path.joinZ(allocator, &.{ directory, data_file_name }) catch return error.OutOfMemory;
        defer allocator.free(c_path);
        if (c.mdbx_env_copy(self.handle, c_path.ptr, c.MDBX_CP_COMPACT) != c.MDBX_SUCCESS) return error.WriteFailed;
    }

    pub fn beginRead(self: *Environment) Error!Transaction {
        while (self.parked_read_count > 0) {
            self.parked_read_count -= 1;
            const parked = self.parked_reads[self.parked_read_count];
            if (c.mdbx_txn_renew(parked) == c.MDBX_SUCCESS) return .{ .handle = parked, .tables = self.tables };
            _ = c.mdbx_txn_abort(parked);
        }
        var transaction: ?*c.MDBX_txn = null;
        if (c.mdbx_txn_begin(self.handle, null, c.MDBX_TXN_RDONLY, &transaction) != c.MDBX_SUCCESS) return error.ReadFailed;
        return .{ .handle = transaction.?, .tables = self.tables };
    }

    /// Ends read transaction `transaction`, keeping it to be renewed by a
    /// later `beginRead` while there is room.
    pub fn endRead(self: *Environment, transaction: Transaction) void {
        if (self.parked_read_count == max_parked_reads) return transaction.abort();
        if (c.mdbx_txn_reset(transaction.handle) != c.MDBX_SUCCESS) return transaction.abort();
        self.parked_reads[self.parked_read_count] = transaction.handle;
        self.parked_read_count += 1;
    }

    pub fn beginWrite(self: *Environment) Error!Transaction {
        var transaction: ?*c.MDBX_txn = null;
        if (c.mdbx_txn_begin(self.handle, null, c.MDBX_TXN_READWRITE, &transaction) != c.MDBX_SUCCESS) return error.WriteFailed;
        return .{ .handle = transaction.?, .tables = self.tables };
    }
};

pub const Transaction = struct {
    handle: *c.MDBX_txn,
    tables: TableHandles,

    /// A failed commit is aborted: the transaction is over either way.
    pub fn commit(self: Transaction) Error!void {
        if (c.mdbx_txn_commit(self.handle) != c.MDBX_SUCCESS) return error.WriteFailed;
    }

    pub fn abort(self: Transaction) void {
        _ = c.mdbx_txn_abort(self.handle);
    }

    pub fn get(self: Transaction, table: Table, key: []const u8) Error!?[]const u8 {
        const key_val = makeVal(key);
        var data_val = empty_val;
        const rc = c.mdbx_get(self.handle, self.tables[@backingInt(table)], &key_val, &data_val);
        if (rc == c.MDBX_NOTFOUND) return null;
        if (rc != c.MDBX_SUCCESS) return error.ReadFailed;
        return valSlice(data_val);
    }

    pub fn put(self: Transaction, table: Table, key: []const u8, value: []const u8) Error!void {
        const key_val = makeVal(key);
        var data_val = makeVal(value);
        if (c.mdbx_put(self.handle, self.tables[@backingInt(table)], &key_val, &data_val, c.MDBX_UPSERT) != c.MDBX_SUCCESS) return error.WriteFailed;
    }

    pub fn delete(self: Transaction, table: Table, key: []const u8) Error!void {
        const key_val = makeVal(key);
        const rc = c.mdbx_del(self.handle, self.tables[@backingInt(table)], &key_val, null);
        if (rc != c.MDBX_SUCCESS and rc != c.MDBX_NOTFOUND) return error.DeleteFailed;
    }

    pub fn clear(self: Transaction, table: Table) Error!void {
        std.debug.assert(table != .main);
        if (c.mdbx_drop(self.handle, self.tables[@backingInt(table)], false) != c.MDBX_SUCCESS) return error.DeleteFailed;
    }

    pub fn openCursor(self: Transaction, table: Table) Error!Cursor {
        var cursor: ?*c.MDBX_cursor = null;
        if (c.mdbx_cursor_open(self.handle, self.tables[@backingInt(table)], &cursor) != c.MDBX_SUCCESS) return error.ReadFailed;
        return .{ .handle = cursor.? };
    }
};

pub const Cursor = struct {
    handle: *c.MDBX_cursor,

    pub fn close(self: Cursor) void {
        c.mdbx_cursor_close(self.handle);
    }

    pub fn first(self: Cursor) Error!?Entry {
        var key_val = empty_val;
        return self.move(&key_val, c.MDBX_FIRST);
    }

    /// The value of exactly `key` (libmdbx positions the cursor from where
    /// it is, which is cheap when `key` is near its last one).
    pub fn find(self: Cursor, key: []const u8) Error!?[]const u8 {
        var key_val = makeVal(key);
        const entry = try self.move(&key_val, c.MDBX_SET_KEY) orelse return null;
        return entry.value;
    }

    pub fn seek(self: Cursor, key: []const u8) Error!?Entry {
        var key_val = makeVal(key);
        return self.move(&key_val, c.MDBX_SET_RANGE);
    }

    pub fn next(self: Cursor) Error!?Entry {
        var key_val = empty_val;
        return self.move(&key_val, c.MDBX_NEXT);
    }

    fn move(self: Cursor, key_val: *c.MDBX_val, operation: c_int) Error!?Entry {
        var data_val = empty_val;
        const rc = c.mdbx_cursor_get(self.handle, key_val, &data_val, operation);
        if (rc == c.MDBX_NOTFOUND) return null;
        if (rc != c.MDBX_SUCCESS) return error.ReadFailed;
        return .{ .key = valSlice(key_val.*), .value = valSlice(data_val) };
    }
};

const empty_val = c.MDBX_val{ .iov_base = null, .iov_len = 0 };

fn makeVal(bytes: []const u8) c.MDBX_val {
    const ptr: *anyopaque = @ptrCast(@constCast(bytes.ptr));
    return .{ .iov_base = ptr, .iov_len = bytes.len };
}

fn valSlice(v: c.MDBX_val) []const u8 {
    if (v.iov_len == 0) return &.{};
    const p: [*]const u8 = @ptrCast(v.iov_base.?);
    return p[0..v.iov_len];
}

comptime {
    contract.check(@This());
}
