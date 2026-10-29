//! The master's side of a conversation with one replica (protocol.zig):
//! answering its `hello`, sending it a copy of the database, then the
//! change sets it has not applied and heartbeats. Each step reads the
//! master's `KeyValueStore` and writes frames to a `std.Io.Writer`; who
//! listens, waits and flushes is the caller's business.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const build_options = @import("build_options");

const protocol = @import("protocol.zig");
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Graph = @import("../storage/graph.zig").Graph;
const change_log = @import("../storage/change_log.zig");

pub const storage_engine = @tagName(build_options.storage_engine);

/// What the master answers a replica's `hello`.
pub const Answer = union(enum) {
    refused: protocol.Refusal,
    /// The replica resumes: change sets follow from this LSN.
    stream: u64,
    /// The replica starts again from a copy of the database.
    snapshot,
};

/// Answers `hello` for the master `store`, which expects `token`. The token
/// is checked before anything about the database is told.
pub fn answer(store: *KeyValueStore, hello: protocol.Hello, token: []const u8) StorageError!Answer {
    if (hello.protocol_version != protocol.version) return .{ .refused = .protocol_version };
    if (!protocol.tokensMatch(hello.token, token)) return .{ .refused = .token };
    if (hello.storage_format != Graph.format_version) return .{ .refused = .storage_format };
    if (!std.mem.eql(u8, hello.storage_engine, storage_engine)) return .{ .refused = .storage_engine };
    const state = try store.changeLogState() orelse return .{ .refused = .not_master };
    const replica_of = hello.database_id orelse return .snapshot;
    const id = try store.databaseId() orelse return .{ .refused = .not_master };
    if (!std.mem.eql(u8, &replica_of, &id)) return .{ .refused = .database_id };
    return goOn(state, hello.applied_lsn);
}

/// Where a replica of this master that applied up to `applied_lsn` goes on
/// from: after its `hello`, or after the `ack` of a copy it was sent.
pub fn resumeFrom(store: *KeyValueStore, applied_lsn: u64) StorageError!Answer {
    const state = try store.changeLogState() orelse return .{ .refused = .not_master };
    return goOn(state, applied_lsn);
}

fn goOn(state: change_log.State, applied_lsn: u64) Answer {
    if (applied_lsn >= state.next_lsn) return .{ .refused = .ahead };
    if (applied_lsn + 1 < state.oldest_lsn) return .snapshot;
    return .{ .stream = applied_lsn + 1 };
}

/// Sends the copy of the database `copy` reads (the file
/// `KeyValueStore.data_file_name` a `copyDatabase` wrote), in parts, then
/// its size.
pub fn sendSnapshot(writer: *Writer, copy: *Reader) error{ ReadFailed, WriteFailed }!void {
    var size: u64 = 0;
    while (true) {
        const buffered = copy.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        const part = buffered[0..@min(buffered.len, protocol.part_bytes)];
        try protocol.write(writer, .{ .snapshot_part = part });
        copy.toss(part.len);
        size += part.len;
    }
    try protocol.write(writer, .{ .snapshot_end = size });
}

/// Sends the change sets of `store` from `next.*` up to its last, each in
/// parts, advancing `next.*` past each sent; returns how many. Fails with
/// `ChangeSetDropped` if the log no longer holds `next.*` (the replica
/// starts again from a copy), `NotMaster` if it is no longer started.
pub fn sendChangeSets(store: *KeyValueStore, writer: *Writer, next: *u64) (StorageError || Writer.Error || error{ ChangeSetDropped, NotMaster })!u64 {
    const state = try store.changeLogState() orelse return error.NotMaster;
    var sent: u64 = 0;
    while (next.* < state.next_lsn) : (next.* += 1) {
        const change_set = try store.changeSet(next.*) orelse return error.ChangeSetDropped;
        defer store.allocator.free(change_set);
        var rest: []const u8 = change_set;
        while (true) {
            const length = @min(rest.len, protocol.part_bytes);
            try protocol.write(writer, .{ .change_set_part = .{ .lsn = next.*, .final = length == rest.len, .bytes = rest[0..length] } });
            rest = rest[length..];
            if (rest.len == 0) break;
        }
        sent += 1;
    }
    return sent;
}

/// Sends the LSN of `store`'s last change set.
pub fn sendHeartbeat(store: *KeyValueStore, writer: *Writer) (StorageError || Writer.Error || error{NotMaster})!void {
    const state = try store.changeLogState() orelse return error.NotMaster;
    try protocol.write(writer, .{ .heartbeat = state.next_lsn - 1 });
}
