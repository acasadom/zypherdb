//! Minimal hand-written C bindings for LMDB (`vendor/lmdb`).
//!
//! Zig 0.17.0 removed `@cImport`, so instead of a generated binding we declare
//! only the small surface `KeyValueStore` needs: the three opaque handles, `MDB_val`,
//! and ~15 extern functions. Everything uses the C ABI (`extern "c"`), so these
//! declarations link directly against the `mdb.c`/`midl.c` compiled in
//! `build.zig`.
//!
//! Types and constants mirror `vendor/lmdb/lmdb.h` (LMDB_1.0.2). If a new LMDB
//! function is needed, add its declaration here following the same style.

pub const MDB_env = opaque {};
pub const MDB_txn = opaque {};
pub const MDB_cursor = opaque {};

/// `typedef unsigned int MDB_dbi;`
pub const MDB_dbi = c_uint;

/// Generic key/data record. LMDB returns pointers into its own memory map; the
/// caller must not free them, and they are only valid until the next mutation
/// or the end of the transaction.
pub const MDB_val = extern struct {
    mv_size: usize,
    mv_data: ?*anyopaque,
};

// --- Flags and error codes (from lmdb.h) ---

/// Open the environment read-only.
pub const MDB_RDONLY: c_uint = 0x20000;
/// Track read transactions per-txn instead of per-thread, so a single thread
/// can hold several concurrent readers (needed for nested scans). Each read
/// txn then owns a reader-table slot until it is aborted.
pub const MDB_NOTLS: c_uint = 0x200000;
/// Returned by mdb_get / mdb_del / mdb_cursor_get when a key is absent.
pub const MDB_NOTFOUND: c_int = -30798;

// --- Cursor operations (MDB_cursor_op enum values, counted from MDB_FIRST) ---

/// Position at next data item.
pub const MDB_NEXT: c_int = 8;
/// Position at first key greater than or equal to the specified key.
pub const MDB_SET_RANGE: c_int = 17;

// --- Environment ---

pub extern "c" fn mdb_env_create(env: *?*MDB_env) c_int;
pub extern "c" fn mdb_env_set_mapsize(env: *MDB_env, size: usize) c_int;
pub extern "c" fn mdb_env_open(env: *MDB_env, path: [*:0]const u8, flags: c_uint, mode: c_uint) c_int;
pub extern "c" fn mdb_env_close(env: *MDB_env) void;

// --- Transactions ---

pub extern "c" fn mdb_txn_begin(env: *MDB_env, parent: ?*MDB_txn, flags: c_uint, txn: *?*MDB_txn) c_int;
pub extern "c" fn mdb_txn_commit(txn: *MDB_txn) c_int;
pub extern "c" fn mdb_txn_abort(txn: *MDB_txn) void;

// --- Databases ---

pub extern "c" fn mdb_dbi_open(txn: *MDB_txn, name: ?[*:0]const u8, flags: c_uint, dbi: *MDB_dbi) c_int;

// --- Key/value operations ---

pub extern "c" fn mdb_get(txn: *MDB_txn, dbi: MDB_dbi, key: *MDB_val, data: *MDB_val) c_int;
pub extern "c" fn mdb_put(txn: *MDB_txn, dbi: MDB_dbi, key: *MDB_val, data: *MDB_val, flags: c_uint) c_int;
pub extern "c" fn mdb_del(txn: *MDB_txn, dbi: MDB_dbi, key: *MDB_val, data: ?*MDB_val) c_int;

// --- Cursors ---

pub extern "c" fn mdb_cursor_open(txn: *MDB_txn, dbi: MDB_dbi, cursor: *?*MDB_cursor) c_int;
pub extern "c" fn mdb_cursor_close(cursor: *MDB_cursor) void;
pub extern "c" fn mdb_cursor_get(cursor: *MDB_cursor, key: *MDB_val, data: *MDB_val, op: c_int) c_int;
