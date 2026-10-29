//! The change log: what each committed write transaction changed, in order,
//! so that a replica applying the same changes in the same order holds the
//! same database. Changes are kept as the key-value writes themselves, not as
//! the queries that made them: a query may not give the same result twice
//! (`randomUUID()`, `timestamp()`, the order behind a LIMIT), its writes do.
//!
//! Once started on a database (`KeyValueStore.startChangeLog`), every write
//! transaction that changes something gets the next log sequence number
//! (LSN, from 1) and writes its change set in the same transaction as its
//! changes, so the log and the data never disagree. The log is kept up to a
//! size (`KeyValueStore.change_log_limit`): past it, the oldest change sets
//! go, whether or not a replica has read them (a replica that missed one
//! starts again from a copy of the database).
//!
//! Table `changes` (engine/contract.zig), keys:
//!
//!     lsn (u64) | chunk (u32)    a part of the change set of transaction lsn
//!     12 zero bytes              the log's state (`State`)
//!
//! both big-endian, so the parts sort by LSN, then in order. A change set is
//! the transaction's writes in order, cut into chunks of at most
//! `chunk_bytes` (a write may straddle two):
//!
//!     put:    0x01 | table (u8) | key length (u32) | key | value length (u32) | value
//!     delete: 0x02 | table (u8) | key length (u32) | key

const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine.zig");
pub const Table = engine.Table;
const Transaction = engine.Transaction;

/// The largest part of a change set kept under one key: a transaction's
/// changes are written as they come, never all held in memory.
pub const chunk_bytes: usize = 1 << 20;

pub const Operation = enum(u8) { put = 0x01, delete = 0x02 };

/// One write of a change set. `key` and `value` are views into it.
pub const Change = struct {
    operation: Operation,
    table: Table,
    key: []const u8,
    /// Empty for a delete.
    value: []const u8 = "",
};

/// Where the log stands.
pub const State = struct {
    /// The LSN the next change set gets.
    next_lsn: u64 = 1,
    /// The oldest change set kept (equal to `next_lsn` when none is).
    oldest_lsn: u64 = 1,
    /// The bytes of the change sets kept.
    bytes: u64 = 0,

    const encoded_length = 24;

    fn encode(self: State) [encoded_length]u8 {
        var bytes: [encoded_length]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], self.next_lsn, .big);
        std.mem.writeInt(u64, bytes[8..16], self.oldest_lsn, .big);
        std.mem.writeInt(u64, bytes[16..24], self.bytes, .big);
        return bytes;
    }

    fn decode(bytes: []const u8) ?State {
        if (bytes.len != encoded_length) return null;
        return .{
            .next_lsn = std.mem.readInt(u64, bytes[0..8], .big),
            .oldest_lsn = std.mem.readInt(u64, bytes[8..16], .big),
            .bytes = std.mem.readInt(u64, bytes[16..24], .big),
        };
    }
};

const state_key: [12]u8 = @splat(0);

fn chunkKey(lsn: u64, chunk: u32) [12]u8 {
    var key: [12]u8 = undefined;
    std.mem.writeInt(u64, key[0..8], lsn, .big);
    std.mem.writeInt(u32, key[8..12], chunk, .big);
    return key;
}

/// The log's state in `transaction`, or null if the log was never started.
pub fn readState(transaction: Transaction) engine.Error!?State {
    const bytes = try transaction.get(.changes, &state_key) orelse return null;
    return State.decode(bytes) orelse error.ReadFailed;
}

/// Starts the log, if it is not started, in write transaction `transaction`.
pub fn start(transaction: Transaction) engine.Error!State {
    if (try readState(transaction)) |state| return state;
    const state = State{};
    try transaction.put(.changes, &state_key, &state.encode());
    return state;
}

/// The change set of transaction `lsn`, its chunks joined (owned by the
/// caller), or null if the log does not hold it.
pub fn changeSet(transaction: Transaction, allocator: Allocator, lsn: u64) (engine.Error || Allocator.Error)!?[]u8 {
    var joined = std.ArrayList(u8).empty;
    errdefer joined.deinit(allocator);
    var chunk: u32 = 0;
    while (try transaction.get(.changes, &chunkKey(lsn, chunk))) |part| : (chunk += 1) {
        try joined.appendSlice(allocator, part);
    }
    if (chunk == 0) return null;
    return try joined.toOwnedSlice(allocator);
}

/// Records the writes of one write transaction and, when it commits, adds
/// them to the log as its change set.
pub const Recorder = struct {
    state: State,
    /// The part of the change set not yet written.
    pending: std.ArrayList(u8) = .empty,
    /// The chunks of this change set written so far, and their bytes.
    chunks: u32 = 0,
    bytes: u64 = 0,

    pub fn deinit(self: *Recorder, allocator: Allocator) void {
        self.pending.deinit(allocator);
    }

    /// Records a write `transaction` has just made.
    pub fn record(self: *Recorder, allocator: Allocator, transaction: Transaction, change: Change) (engine.Error || Allocator.Error)!void {
        try self.pending.append(allocator, @backingInt(change.operation));
        try self.pending.append(allocator, @backingInt(change.table));
        try appendBytes(&self.pending, allocator, change.key);
        if (change.operation == .put) try appendBytes(&self.pending, allocator, change.value);
        while (self.pending.items.len >= chunk_bytes) try self.writeChunk(transaction, chunk_bytes);
    }

    /// Before `transaction` commits: writes the rest of the change set, gives
    /// it its LSN, and drops the oldest change sets past `limit` bytes (never
    /// this one). A transaction that changed nothing gets no LSN.
    pub fn finish(self: *Recorder, transaction: Transaction, limit: u64) engine.Error!void {
        if (self.pending.items.len > 0) try self.writeChunk(transaction, self.pending.items.len);
        if (self.chunks == 0) return;
        self.state.next_lsn += 1;
        self.state.bytes += self.bytes;
        while (self.state.bytes > limit and self.state.oldest_lsn + 1 < self.state.next_lsn) {
            self.state.bytes -= try dropChangeSet(transaction, self.state.oldest_lsn);
            self.state.oldest_lsn += 1;
        }
        try transaction.put(.changes, &state_key, &self.state.encode());
    }

    fn writeChunk(self: *Recorder, transaction: Transaction, length: usize) engine.Error!void {
        try transaction.put(.changes, &chunkKey(self.state.next_lsn, self.chunks), self.pending.items[0..length]);
        self.chunks += 1;
        self.bytes += length;
        const rest = self.pending.items.len - length;
        std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[length..]);
        self.pending.shrinkRetainingCapacity(rest);
    }
};

/// Deletes the change set of transaction `lsn`; returns its bytes.
fn dropChangeSet(transaction: Transaction, lsn: u64) engine.Error!u64 {
    var bytes: u64 = 0;
    var chunk: u32 = 0;
    while (try transaction.get(.changes, &chunkKey(lsn, chunk))) |part| : (chunk += 1) {
        bytes += part.len;
        try transaction.delete(.changes, &chunkKey(lsn, chunk));
    }
    return bytes;
}

fn appendBytes(list: *std.ArrayList(u8), allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .big);
    try list.appendSlice(allocator, &length);
    try list.appendSlice(allocator, bytes);
}

/// The writes of a change set, in order.
pub const Iterator = struct {
    bytes: []const u8,
    position: usize = 0,

    /// The next write, null at the end, or an error if the bytes are not a
    /// change set.
    pub fn next(self: *Iterator) error{MalformedChangeSet}!?Change {
        if (self.position == self.bytes.len) return null;
        const operation = std.enums.fromInt(Operation, try self.byte()) orelse return error.MalformedChangeSet;
        const table = std.enums.fromInt(Table, try self.byte()) orelse return error.MalformedChangeSet;
        if (table == .changes) return error.MalformedChangeSet; // the log never logs itself
        const key = try self.sized();
        const value = if (operation == .put) try self.sized() else "";
        return .{ .operation = operation, .table = table, .key = key, .value = value };
    }

    fn byte(self: *Iterator) error{MalformedChangeSet}!u8 {
        if (self.position >= self.bytes.len) return error.MalformedChangeSet;
        self.position += 1;
        return self.bytes[self.position - 1];
    }

    fn sized(self: *Iterator) error{MalformedChangeSet}![]const u8 {
        if (self.bytes.len - self.position < 4) return error.MalformedChangeSet;
        const length = std.mem.readInt(u32, self.bytes[self.position..][0..4], .big);
        self.position += 4;
        if (self.bytes.len - self.position < length) return error.MalformedChangeSet;
        self.position += length;
        return self.bytes[self.position - length .. self.position];
    }
};

/// Makes the writes of change set `bytes` in write transaction `transaction`.
pub fn apply(transaction: Transaction, bytes: []const u8) (engine.Error || error{MalformedChangeSet})!void {
    var changes = Iterator{ .bytes = bytes };
    while (try changes.next()) |change| {
        // An integer key goes to the engine aligned, as a u64 (it is not,
        // inside the change set).
        var id: u64 = undefined;
        const key = if (change.table.hasIntegerKeys()) aligned: {
            if (change.key.len != @sizeOf(u64)) return error.MalformedChangeSet;
            @memcpy(std.mem.asBytes(&id), change.key);
            break :aligned std.mem.asBytes(&id);
        } else change.key;
        switch (change.operation) {
            .put => try transaction.put(change.table, key, change.value),
            .delete => try transaction.delete(change.table, key),
        }
    }
}
