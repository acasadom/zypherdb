//! A replica's side of its conversation with the master (protocol.zig):
//! introducing itself, receiving a copy of the master's database, then
//! applying the change sets that follow. Each step reads frames from a
//! `std.Io.Reader` or writes them to a `std.Io.Writer`; who connects,
//! waits, flushes and puts the copy in place is the caller's business.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const protocol = @import("protocol.zig");
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Graph = @import("../storage/graph.zig").Graph;
const change_log = @import("../storage/change_log.zig");
const storage_engine = @import("master.zig").storage_engine;

/// The `hello` of the replica `store` (null for one with no database yet)
/// to a master that expects `token`. Fails with `MasterDatabase` if `store`
/// is a master: it copies no one.
pub fn hello(store: ?*KeyValueStore, token: []const u8) (StorageError || error{MasterDatabase})!protocol.Hello {
    var message: protocol.Hello = .{
        .storage_format = Graph.format_version,
        .storage_engine = storage_engine,
        .database_id = null,
        .applied_lsn = 0,
        .token = token,
    };
    const database = store orelse return message;
    if (try database.changeLogState() != null) return error.MasterDatabase;
    message.applied_lsn = try database.appliedLsn() orelse return message;
    message.database_id = try database.databaseId();
    return message;
}

/// What the master answered a `hello`.
pub const Answer = union(enum) {
    refused: protocol.Refusal,
    /// Change sets follow, from the one after the replica's last.
    stream,
    /// A copy of the master's database follows (`receiveSnapshot`).
    snapshot,
};

pub const ConversationError = protocol.ReadError || error{UnexpectedMessage};

/// Reads the master's answer to the `hello` of a replica that applied up
/// to `applied_lsn`. A copy's first part is left in `reader` for
/// `receiveSnapshot`.
pub fn receiveAnswer(reader: *Reader, applied_lsn: u64) ConversationError!Answer {
    if (try reader.peekByte() == @backingInt(protocol.Kind.snapshot_part)) return .snapshot;
    return switch (try protocol.read(reader)) {
        .refused => |reason| .{ .refused = reason },
        .stream => |first| if (first == applied_lsn + 1) .stream else error.UnexpectedMessage,
        else => error.UnexpectedMessage,
    };
}

/// Writes the copy of the master's database that `reader` holds to `copy`
/// (the file `KeyValueStore.data_file_name` of an empty directory); returns
/// its size. Once the copy is opened, `KeyValueStore.becomeReplica` makes it
/// a replica and tells the LSN to `sendAck`.
pub fn receiveSnapshot(reader: *Reader, copy: *Writer) (ConversationError || Writer.Error || error{SnapshotSizeMismatch})!u64 {
    var size: u64 = 0;
    while (true) switch (try protocol.read(reader)) {
        .snapshot_part => |bytes| {
            try copy.writeAll(bytes);
            size += bytes.len;
        },
        .snapshot_end => |sent| return if (sent == size) size else error.SnapshotSizeMismatch,
        else => return error.UnexpectedMessage,
    };
}

/// Tells the master the LSN of the last change set applied.
pub fn sendAck(writer: *Writer, applied_lsn: u64) Writer.Error!void {
    try protocol.write(writer, .{ .ack = applied_lsn });
}

/// What one message from a streaming master did to the replica.
pub const Received = union(enum) {
    /// A part of a change set, kept until its final one.
    part,
    /// Change set LSN is applied (now, or it already was).
    change_set: u64,
    /// The master's last LSN.
    heartbeat: u64,
};

/// Gathers the parts of a change set and applies it once whole.
pub const ChangeSetReceiver = struct {
    bytes: std.ArrayList(u8) = .empty,
    /// The LSN of the parts gathered, null if none.
    lsn: ?u64 = null,

    pub fn deinit(self: *ChangeSetReceiver, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    /// Handles `message`, read from the master, for the replica `store`.
    /// A part of another change set than the one gathered, or a message a
    /// streaming master does not send, fails with `UnexpectedMessage`.
    pub fn receive(self: *ChangeSetReceiver, store: *KeyValueStore, message: protocol.Message) (StorageError || error{ UnexpectedMessage, MalformedChangeSet, ChangeSetOutOfOrder })!Received {
        switch (message) {
            .heartbeat => |last| return .{ .heartbeat = last },
            .change_set_part => |part| {
                if (self.lsn) |lsn| if (lsn != part.lsn) return error.UnexpectedMessage;
                self.lsn = part.lsn;
                try self.bytes.appendSlice(store.allocator, part.bytes);
                if (!part.final) return .part;
                defer {
                    self.bytes.clearRetainingCapacity();
                    self.lsn = null;
                }
                _ = try store.applyChangeSet(part.lsn, self.bytes.items);
                return .{ .change_set = part.lsn };
            },
            else => return error.UnexpectedMessage,
        }
    }
};
