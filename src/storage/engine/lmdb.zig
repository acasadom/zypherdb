//! The LMDB engine (`vendor/lmdb`): the contract of contract.zig over LMDB's
//! environment, transactions and cursors.

const std = @import("std");

const contract = @import("contract.zig");
const c = @import("lmdb_bindings.zig");

const Error = contract.Error;
const Table = contract.Table;
const Entry = contract.Entry;

/// The file of a database's directory that holds it all.
pub const data_file_name = "data.mdb";

/// The LMDB database handle of each table, indexed by `Table`.
const TableHandles = [Table.count]c.MDB_dbi;

pub const Environment = struct {
    handle: *c.MDB_env,
    tables: TableHandles,
    /// Ended read transactions kept to be renewed: renewing one costs no
    /// allocation and keeps its reader slot.
    parked_reads: [max_parked_reads]*c.MDB_txn = undefined,
    parked_read_count: usize = 0,

    const max_parked_reads = 4;

    /// Opens (or creates) the database in directory `path`, which must exist.
    pub fn open(allocator: std.mem.Allocator, path: []const u8, options: contract.Options) Error!Environment {
        var environment: ?*c.MDB_env = null;
        if (c.mdb_env_create(&environment) != 0) return error.OpenFailed;
        errdefer c.mdb_env_close(environment.?);

        // LMDB requires setting a maximum map size. This is a virtual
        // address-space reservation (sparse mmap), not RAM: the file grows as
        // pages are written. 1 TiB is plenty for an embedded graph DB on 64-bit.
        if (c.mdb_env_set_mapsize(environment.?, 1 << 40) != 0) return error.OpenFailed;
        if (c.mdb_env_set_maxdbs(environment.?, Table.count) != 0) return error.OpenFailed;

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

        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(environment.?, null, 0, &transaction) != 0) return error.OpenFailed;
        const tables = openTables(transaction.?) catch |err| {
            c.mdb_txn_abort(transaction.?);
            return err;
        };
        // LMDB frees the transaction when its commit fails.
        if (c.mdb_txn_commit(transaction.?) != 0) return error.OpenFailed;
        return .{ .handle = environment.?, .tables = tables };
    }

    fn openTables(transaction: *c.MDB_txn) Error!TableHandles {
        var tables: TableHandles = undefined;
        // The main table is LMDB's default (unnamed) database. The record
        // tables are named ones, keyed by the id as an integer: smaller trees
        // than the main one, and integer comparisons instead of byte-string
        // ones. (Their names are keys of the main table; `#` starts no key the
        // graph writes.)
        if (c.mdb_dbi_open(transaction, null, 0, &tables[@backingInt(Table.main)]) != 0) return error.OpenFailed;
        if (c.mdb_dbi_open(transaction, "#nodes", c.MDB_CREATE | c.MDB_INTEGERKEY, &tables[@backingInt(Table.nodes)]) != 0) return error.OpenFailed;
        if (c.mdb_dbi_open(transaction, "#relationships", c.MDB_CREATE | c.MDB_INTEGERKEY, &tables[@backingInt(Table.relationships)]) != 0) return error.OpenFailed;
        if (c.mdb_dbi_open(transaction, "#changes", c.MDB_CREATE, &tables[@backingInt(Table.changes)]) != 0) return error.OpenFailed;
        return tables;
    }

    pub fn close(self: *Environment) void {
        for (self.parked_reads[0..self.parked_read_count]) |transaction| c.mdb_txn_abort(transaction);
        self.parked_read_count = 0;
        c.mdb_env_close(self.handle);
    }

    /// Writes every commit so far to disk (what `full` durability does at
    /// each commit).
    pub fn sync(self: *Environment) Error!void {
        if (c.mdb_env_sync(self.handle, 1) != 0) return error.WriteFailed;
    }

    pub fn copy(self: *Environment, allocator: std.mem.Allocator, directory: []const u8) Error!void {
        const c_path = allocator.dupeSentinel(u8, directory, 0) catch return error.OutOfMemory;
        defer allocator.free(c_path);
        if (c.mdb_env_copy2(self.handle, c_path.ptr, c.MDB_CP_COMPACT) != 0) return error.WriteFailed;
    }

    pub fn beginRead(self: *Environment) Error!Transaction {
        while (self.parked_read_count > 0) {
            self.parked_read_count -= 1;
            const parked = self.parked_reads[self.parked_read_count];
            if (c.mdb_txn_renew(parked) == 0) return .{ .handle = parked, .tables = self.tables };
            c.mdb_txn_abort(parked);
        }
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.handle, null, c.MDB_RDONLY, &transaction) != 0) return error.ReadFailed;
        return .{ .handle = transaction.?, .tables = self.tables };
    }

    /// Ends read transaction `transaction`, keeping it to be renewed by a
    /// later `beginRead` while there is room.
    pub fn endRead(self: *Environment, transaction: Transaction) void {
        if (self.parked_read_count == max_parked_reads) return transaction.abort();
        c.mdb_txn_reset(transaction.handle);
        self.parked_reads[self.parked_read_count] = transaction.handle;
        self.parked_read_count += 1;
    }

    pub fn beginWrite(self: *Environment) Error!Transaction {
        var transaction: ?*c.MDB_txn = null;
        if (c.mdb_txn_begin(self.handle, null, 0, &transaction) != 0) return error.WriteFailed;
        return .{ .handle = transaction.?, .tables = self.tables };
    }
};

pub const Transaction = struct {
    handle: *c.MDB_txn,
    tables: TableHandles,

    /// A failed commit is aborted: the transaction is over either way.
    pub fn commit(self: Transaction) Error!void {
        // LMDB frees the transaction when its commit fails.
        if (c.mdb_txn_commit(self.handle) != 0) return error.WriteFailed;
    }

    pub fn abort(self: Transaction) void {
        c.mdb_txn_abort(self.handle);
    }

    pub fn get(self: Transaction, table: Table, key: []const u8) Error!?[]const u8 {
        var key_val = makeVal(key);
        var data_val = empty_val;
        const rc = c.mdb_get(self.handle, self.tables[@backingInt(table)], &key_val, &data_val);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return error.ReadFailed;
        return valSlice(data_val);
    }

    pub fn put(self: Transaction, table: Table, key: []const u8, value: []const u8) Error!void {
        var key_val = makeVal(key);
        var data_val = makeVal(value);
        if (c.mdb_put(self.handle, self.tables[@backingInt(table)], &key_val, &data_val, 0) != 0) return error.WriteFailed;
    }

    pub fn delete(self: Transaction, table: Table, key: []const u8) Error!void {
        var key_val = makeVal(key);
        const rc = c.mdb_del(self.handle, self.tables[@backingInt(table)], &key_val, null);
        if (rc != 0 and rc != c.MDB_NOTFOUND) return error.DeleteFailed;
    }

    pub fn openCursor(self: Transaction, table: Table) Error!Cursor {
        var cursor: ?*c.MDB_cursor = null;
        if (c.mdb_cursor_open(self.handle, self.tables[@backingInt(table)], &cursor) != 0) return error.ReadFailed;
        return .{ .handle = cursor.? };
    }
};

pub const Cursor = struct {
    handle: *c.MDB_cursor,

    pub fn close(self: Cursor) void {
        c.mdb_cursor_close(self.handle);
    }

    pub fn first(self: Cursor) Error!?Entry {
        var key_val = empty_val;
        return self.move(&key_val, c.MDB_FIRST);
    }

    /// The value of exactly `key` (LMDB positions the cursor from where it
    /// is, which is cheap when `key` is near its last one).
    pub fn find(self: Cursor, key: []const u8) Error!?[]const u8 {
        var key_val = makeVal(key);
        const entry = try self.move(&key_val, c.MDB_SET_KEY) orelse return null;
        return entry.value;
    }

    pub fn seek(self: Cursor, key: []const u8) Error!?Entry {
        var key_val = makeVal(key);
        return self.move(&key_val, c.MDB_SET_RANGE);
    }

    pub fn next(self: Cursor) Error!?Entry {
        var key_val = empty_val;
        return self.move(&key_val, c.MDB_NEXT);
    }

    fn move(self: Cursor, key_val: *c.MDB_val, operation: c_int) Error!?Entry {
        var data_val = empty_val;
        const rc = c.mdb_cursor_get(self.handle, key_val, &data_val, operation);
        if (rc == c.MDB_NOTFOUND) return null;
        if (rc != 0) return error.ReadFailed;
        return .{ .key = valSlice(key_val.*), .value = valSlice(data_val) };
    }
};

const empty_val = c.MDB_val{ .mv_size = 0, .mv_data = null };

fn makeVal(bytes: []const u8) c.MDB_val {
    const ptr: *anyopaque = @ptrCast(@constCast(bytes.ptr));
    return .{ .mv_size = bytes.len, .mv_data = ptr };
}

fn valSlice(v: c.MDB_val) []const u8 {
    if (v.mv_size == 0) return &.{};
    const p: [*]const u8 = @ptrCast(v.mv_data.?);
    return p[0..v.mv_size];
}

comptime {
    contract.check(@This());
}
