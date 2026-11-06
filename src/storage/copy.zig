//! A copy of a master's database, as replication sends it to a replica that
//! has none (or one its master's log has left behind): every entry of every
//! table but the change log, read in one read transaction, written as the
//! puts of a change set (change_log.zig) after a header:
//!
//!     lsn (u64) | database id (16 bytes)      big-endian
//!     put | table | key length | key | value length | value     per entry
//!
//! The LSN is that of the last change set the copy holds; the id is the
//! master's. The engine's catalog of tables (keys of `main` starting with
//! `catalog_key_start`) is the engine's own and is not copied. Records, not
//! the engine's pages: any engine loads any engine's copy, and a replica
//! loads one as it comes, with no file of its own.
//!
//! A replica loads a copy part by part (`Loading`), in one write
//! transaction: the first part empties its tables, the last makes it a
//! replica that has applied every change set the copy holds. Readers see
//! the database as it was until then; a copy cut short changes nothing. It
//! holds in memory a part and the start of an entry the part cut, as when
//! applying a change set.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const engine = @import("engine.zig");
const change_log = @import("change_log.zig");
const Table = engine.Table;
const Transaction = engine.Transaction;

/// Keys of the main table starting with it are the engine's catalog of
/// tables (engine/contract.zig).
pub const catalog_key_start = '#';

pub const header_bytes = 8 + @sizeOf(change_log.DatabaseId);

pub const WriteError = engine.Error || Writer.Error || error{NotMaster};

/// Writes a copy of the database `transaction` (a read transaction of a
/// master) sees to `writer`; returns the LSN of the last change set it
/// holds. Fails with `NotMaster` on a database whose log is not started.
pub fn write(transaction: Transaction, writer: *Writer) WriteError!u64 {
    const state = try change_log.readState(transaction) orelse return error.NotMaster;
    const id = try change_log.databaseId(transaction) orelse return error.NotMaster;
    const lsn = state.next_lsn - 1;
    try writer.writeInt(u64, lsn, .big);
    try writer.writeAll(&id);
    inline for (comptime std.enums.values(Table)) |table| {
        if (table == .changes) continue;
        var cursor = try transaction.openCursor(table);
        defer cursor.close();
        var entry = try cursor.first();
        while (entry) |found| : (entry = try cursor.next()) {
            if (table == .main and found.key[0] == catalog_key_start) continue;
            try writePut(writer, table, found.key, found.value);
        }
    }
    return lsn;
}

fn writePut(writer: *Writer, table: Table, key: []const u8, value: []const u8) Writer.Error!void {
    try writer.writeByte(@backingInt(change_log.Operation.put));
    try writer.writeByte(@backingInt(table));
    try writer.writeInt(u32, @intCast(key.len), .big);
    try writer.writeAll(key);
    try writer.writeInt(u32, @intCast(value.len), .big);
    try writer.writeAll(value);
}

pub const LoadError = change_log.ApplyError;

/// A copy loaded part by part in one write transaction: `begin`, `add`
/// each part, `finish`.
pub const Loading = struct {
    /// The copy's header, once its bytes came.
    lsn: ?u64 = null,
    id: change_log.DatabaseId = undefined,
    /// The bytes of the header, or of an entry, the last part cut.
    leftover: std.ArrayList(u8) = .empty,

    /// Empties the database of write transaction `transaction`, but for
    /// the engine's catalog. Fails with `WriteFailed` on a master.
    pub fn begin(allocator: Allocator, transaction: Transaction) LoadError!Loading {
        if (try change_log.readState(transaction) != null) return error.WriteFailed;
        try clearMainTable(allocator, transaction);
        inline for (.{ Table.nodes, Table.relationships, Table.changes }) |table| try transaction.clear(table);
        return .{};
    }

    pub fn deinit(self: *Loading, allocator: Allocator) void {
        self.leftover.deinit(allocator);
    }

    /// Puts the entries of the next part, `bytes`, in `transaction`.
    pub fn add(self: *Loading, allocator: Allocator, transaction: Transaction, bytes: []const u8) LoadError!void {
        var rest = bytes;
        if (self.lsn == null) {
            const wanted = header_bytes - self.leftover.items.len;
            const taken = rest[0..@min(wanted, rest.len)];
            try self.leftover.appendSlice(allocator, taken);
            rest = rest[taken.len..];
            if (self.leftover.items.len < header_bytes) return;
            self.lsn = std.mem.readInt(u64, self.leftover.items[0..8], .big);
            self.id = self.leftover.items[8..header_bytes].*;
            self.leftover.clearRetainingCapacity();
        }
        if (self.leftover.items.len == 0) {
            const cut = try putWhole(transaction, rest);
            try self.leftover.appendSlice(allocator, cut);
            return;
        }
        try self.leftover.appendSlice(allocator, rest);
        const cut = try putWhole(transaction, self.leftover.items);
        std.mem.copyForwards(u8, self.leftover.items[0..cut.len], cut);
        self.leftover.shrinkRetainingCapacity(cut.len);
    }

    /// After the last part: makes the database a replica of the copy's
    /// master that has applied every change set the copy holds; returns
    /// that LSN.
    pub fn finish(self: *Loading, transaction: Transaction) LoadError!u64 {
        const lsn = self.lsn orelse return error.MalformedChangeSet;
        if (self.leftover.items.len > 0) return error.MalformedChangeSet;
        try change_log.becomeReplica(transaction, self.id, lsn);
        return lsn;
    }

    /// Puts the whole entries of `bytes`; returns the bytes of the one they
    /// cut, if any.
    fn putWhole(transaction: Transaction, bytes: []const u8) LoadError![]const u8 {
        var changes = change_log.Iterator{ .bytes = bytes, .partial = true };
        while (try changes.next()) |change| {
            // A copy only puts, and never the engine's catalog.
            if (change.operation != .put) return error.MalformedChangeSet;
            if (change.table == .main and (change.key.len == 0 or change.key[0] == catalog_key_start)) return error.MalformedChangeSet;
            try change_log.apply(transaction, change);
        }
        return changes.rest();
    }
};

fn clearMainTable(allocator: Allocator, transaction: Transaction) LoadError!void {
    var cursor = try transaction.openCursor(.main);
    defer cursor.close();
    var key: std.ArrayList(u8) = .empty;
    defer key.deinit(allocator);
    var entry = try cursor.first();
    while (entry) |found| {
        if (found.key[0] == catalog_key_start) {
            entry = try cursor.seek(&.{catalog_key_start + 1});
            continue;
        }
        // The cursor's bytes do not outlive the delete.
        key.clearRetainingCapacity();
        try key.appendSlice(allocator, found.key);
        try transaction.delete(.main, key.items);
        entry = try cursor.seek(key.items);
    }
}
