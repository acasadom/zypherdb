//! What a storage engine provides to the layers above it: the one boundary
//! between acmedb and the key-value store underneath (LMDB, libmdbx, ...).
//!
//! An engine is a namespace (a Zig file) chosen at compile time (see
//! `engine.zig`), with three types:
//!
//! - `Environment`: an open database at a path.
//!     `open(allocator, path, Options) Error!Environment`, `close()`,
//!     `sync() Error!void`, `beginRead() Error!Transaction`,
//!     `endRead(Transaction)` (ends a read transaction, perhaps keeping it
//!     to be begun again cheaply), `beginWrite() Error!Transaction`.
//! - `Transaction`: a snapshot (read) or the single writer (write).
//!     `commit() Error!void` (a failed commit is aborted), `abort()` (a
//!     read transaction ends better with `Environment.endRead`),
//!     `get(Table, key) Error!?[]const u8`, `put(Table, key, value) Error!void`,
//!     `delete(Table, key) Error!void` (deleting an absent key succeeds),
//!     `openCursor(Table) Error!Cursor`.
//! - `Cursor`: a position in one table of one transaction, in key order.
//!     `close()`, `first() Error!?Entry`, `find(key) Error!?[]const u8` (the
//!     value of exactly `key`), `seek(key) Error!?Entry` (the first key at or
//!     after `key`), `next() Error!?Entry`.
//!
//! The contract every engine keeps:
//! - Reads never copy: the bytes a `get` or a cursor returns are the
//!   engine's, valid until the transaction ends or writes (the layers above
//!   rely on it to read records without allocating).
//! - One write transaction at a time per environment; any number of read
//!   transactions, also several at once in one thread (nested scans), each a
//!   consistent snapshot as of its start.
//! - Several processes may open the same database (the multiprocess model:
//!   one writer at a time, readers never blocked).
//! - Keys of the `main` table are byte strings in lexicographic order. Keys of
//!   the integer tables (`nodes`, `relationships`) are 8-byte native-endian
//!   u64, in numeric order; an engine whose order is lexicographic must
//!   translate them.
//! - Every change goes through `Transaction.put`/`delete` of a write
//!   transaction, so a change log (for replication) can be taken there.

const std = @import("std");

/// Failures an engine reports. Absent keys are not errors (they are `null`).
pub const Error = error{
    OpenFailed,
    WriteFailed,
    ReadFailed,
    DeleteFailed,
    OutOfMemory,
};

/// The tables of a database. `main` holds every key the graph scans by
/// prefix (indexes, adjacency, metadata); the others hold records by id.
pub const Table = enum {
    main,
    nodes,
    relationships,

    pub const count = @typeInfo(Table).@"enum".field_names.len;

    /// True for the tables keyed by a u64 id.
    pub fn hasIntegerKeys(table: Table) bool {
        return table != .main;
    }
};

/// A key and its value, both the engine's bytes (see the contract above).
pub const Entry = struct { key: []const u8, value: []const u8 };

/// How much a commit waits for the disk.
pub const Durability = enum {
    /// Each commit is on disk when it returns (the default).
    full,
    /// Each commit's data is on disk, its metadata page is flushed with the
    /// next one: a power failure can lose the last commit, never corrupt the
    /// database.
    relaxed,
    /// Commits are left to the operating system to write (or to `sync`): a
    /// power failure can lose the recent commits; the database stays
    /// consistent where the file system keeps writes in order.
    deferred,
};

pub const Options = struct { durability: Durability = .full };

/// Fails the build, naming what is missing, if `Engine` lacks a declaration
/// of the contract (signatures are checked by their use).
pub fn check(comptime Engine: type) void {
    const required = .{
        .{ Engine, &.{"Environment", "Transaction", "Cursor"} },
        .{ Engine.Environment, &.{ "open", "close", "sync", "beginRead", "endRead", "beginWrite" } },
        .{ Engine.Transaction, &.{ "commit", "abort", "get", "put", "delete", "openCursor" } },
        .{ Engine.Cursor, &.{ "close", "first", "find", "seek", "next" } },
    };
    inline for (required) |entry| {
        inline for (entry[1]) |name| {
            if (!@hasDecl(entry[0], name)) @compileError(@typeName(entry[0]) ++ " lacks `" ++ name ++ "` (see engine/contract.zig)");
        }
    }
}

test "the integer tables are the record tables" {
    try std.testing.expect(!Table.main.hasIntegerKeys());
    try std.testing.expect(Table.nodes.hasIntegerKeys());
    try std.testing.expect(Table.relationships.hasIntegerKeys());
}
