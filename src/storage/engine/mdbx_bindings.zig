//! Minimal hand-written C bindings for libmdbx (`vendor/libmdbx`).
//!
//! Like lmdb_bindings.zig: Zig 0.17.0 has no `@cImport`, so only the surface
//! engine/mdbx.zig needs is declared, with the C ABI (`extern "c"`), linking
//! against the amalgamated `mdbx.c` compiled in `build.zig`.
//!
//! Types and constants mirror `vendor/libmdbx/mdbx.h` (v0.14.4). If a new
//! function is needed, add its declaration here following the same style.

const builtin = @import("builtin");
const std = @import("std");

pub const MDBX_env = opaque {};
pub const MDBX_txn = opaque {};
pub const MDBX_cursor = opaque {};

/// `typedef uint32_t MDBX_dbi;`
pub const MDBX_dbi = u32;

/// `mdbx_mode_t`: `unsigned short` on Windows, `mode_t` elsewhere.
pub const mdbx_mode_t = if (builtin.os.tag == .windows) c_ushort else std.c.mode_t;

/// `typedef struct iovec MDBX_val;` (note the order: pointer, then length).
/// libmdbx returns pointers into its own memory map; the caller must not free
/// them, and they are only valid until the next mutation or the end of the
/// transaction.
pub const MDBX_val = extern struct {
    iov_base: ?*anyopaque,
    iov_len: usize,
};

// --- Environment flags (MDBX_env_flags_t) ---

/// Read transactions are not tied to the thread that started them, so a
/// thread may hold several at once (nested scans): LMDB's MDB_NOTLS.
pub const MDBX_NOSTICKYTHREADS: c_uint = 0x200000;
/// Durability modes: each commit synced; metadata synced with the next
/// commit; commits left to the OS (the database stays consistent).
pub const MDBX_SYNC_DURABLE: c_uint = 0;
pub const MDBX_NOMETASYNC: c_uint = 0x40000;
pub const MDBX_SAFE_NOSYNC: c_uint = 0x10000;

// --- Transaction flags (MDBX_txn_flags_t) ---

pub const MDBX_TXN_READWRITE: c_uint = 0;
pub const MDBX_TXN_RDONLY: c_uint = 0x20000;

// --- Table flags (MDBX_db_flags_t) ---

pub const MDBX_DB_DEFAULTS: c_uint = 0;
pub const MDBX_INTEGERKEY: c_uint = 0x08;
pub const MDBX_CREATE: c_uint = 0x40000;

/// MDBX_put_flags_t: insert or overwrite.
pub const MDBX_UPSERT: c_uint = 0;

// --- Results ---

pub const MDBX_SUCCESS: c_int = 0;
/// Returned by mdbx_get / mdbx_del / mdbx_cursor_get when a key is absent.
pub const MDBX_NOTFOUND: c_int = -30798;

// --- Options (MDBX_option_t, counted from MDBX_opt_max_db) ---

pub const MDBX_opt_max_db: c_int = 0;

// --- Cursor operations (MDBX_cursor_op, counted from MDBX_FIRST) ---

pub const MDBX_FIRST: c_int = 0;
pub const MDBX_NEXT: c_int = 8;
pub const MDBX_SET_KEY: c_int = 16;
/// Position at the first key greater than or equal to the specified key.
pub const MDBX_SET_RANGE: c_int = 17;

// --- Logging (MDBX_log_level_t, MDBX_debug_flags_t) ---

/// Errors only: libmdbx logs notices (an empty file at creation,
/// readahead...) by default, and warns on stderr when it opens a database
/// after an unclean shutdown, which it handles itself; a library must not
/// write to its host program's stderr for that.
pub const MDBX_LOG_ERROR: c_int = 1;
pub const MDBX_DBG_DONTCHANGE: c_int = -1;
/// `MDBX_LOGGER_DONTCHANGE`: keep the current logger (a pointer of all ones).
pub const MDBX_LOGGER_DONTCHANGE: *const anyopaque = @ptrFromInt(std.math.maxInt(usize));

pub extern "c" fn mdbx_setup_debug(log_level: c_int, debug_flags: c_int, logger: ?*const anyopaque) c_int;

// --- Environment ---

pub extern "c" fn mdbx_env_create(env: *?*MDBX_env) c_int;
pub extern "c" fn mdbx_env_set_option(env: *MDBX_env, option: c_int, value: u64) c_int;
pub extern "c" fn mdbx_env_set_geometry(env: *MDBX_env, size_lower: isize, size_now: isize, size_upper: isize, growth_step: isize, shrink_threshold: isize, pagesize: isize) c_int;
pub extern "c" fn mdbx_env_open(env: *MDBX_env, pathname: [*:0]const u8, flags: c_uint, mode: mdbx_mode_t) c_int;
pub extern "c" fn mdbx_env_close_ex(env: *MDBX_env, dont_sync: bool) c_int;
pub extern "c" fn mdbx_env_sync_ex(env: *MDBX_env, force: bool, nonblock: bool) c_int;

// --- Transactions ---

pub extern "c" fn mdbx_txn_begin(env: *MDBX_env, parent: ?*MDBX_txn, flags: c_uint, txn: *?*MDBX_txn) c_int;
pub extern "c" fn mdbx_txn_commit(txn: *MDBX_txn) c_int;
pub extern "c" fn mdbx_txn_abort(txn: *MDBX_txn) c_int;
/// Ends a read transaction but keeps its handle (and reader slot) for
/// `mdbx_txn_renew`, which starts it again on the latest snapshot.
pub extern "c" fn mdbx_txn_reset(txn: *MDBX_txn) c_int;
pub extern "c" fn mdbx_txn_renew(txn: *MDBX_txn) c_int;

// --- Tables ---

pub extern "c" fn mdbx_dbi_open(txn: *MDBX_txn, name: ?[*:0]const u8, flags: c_uint, dbi: *MDBX_dbi) c_int;

// --- Key/value operations ---

pub extern "c" fn mdbx_get(txn: *const MDBX_txn, dbi: MDBX_dbi, key: *const MDBX_val, data: *MDBX_val) c_int;
pub extern "c" fn mdbx_put(txn: *MDBX_txn, dbi: MDBX_dbi, key: *const MDBX_val, data: *MDBX_val, flags: c_uint) c_int;
pub extern "c" fn mdbx_del(txn: *MDBX_txn, dbi: MDBX_dbi, key: *const MDBX_val, data: ?*const MDBX_val) c_int;

// --- Cursors ---

pub extern "c" fn mdbx_cursor_open(txn: *MDBX_txn, dbi: MDBX_dbi, cursor: *?*MDBX_cursor) c_int;
pub extern "c" fn mdbx_cursor_close(cursor: *MDBX_cursor) void;
pub extern "c" fn mdbx_cursor_get(cursor: *MDBX_cursor, key: *MDBX_val, data: *MDBX_val, op: c_int) c_int;
