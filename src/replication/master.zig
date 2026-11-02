//! The master's decisions in a conversation with one replica (protocol.zig):
//! whom it serves, and from where it goes on, after the replica's `hello`
//! or after the ack of a copy. Sending is master_session.zig's.

const std = @import("std");
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

/// Answers a replica's `writer_hello` for the master `store`, which expects
/// `token`: why it is refused, or null if its writes are run. Only a
/// replica of this master forwards them.
pub fn answerWriter(store: *KeyValueStore, hello: protocol.WriterHello, token: []const u8) StorageError!?protocol.Refusal {
    if (hello.protocol_version != protocol.version) return .protocol_version;
    if (!protocol.tokensMatch(hello.token, token)) return .token;
    if (try store.changeLogState() == null) return .not_master;
    const id = try store.databaseId() orelse return .not_master;
    if (!std.mem.eql(u8, &hello.database_id, &id)) return .database_id;
    return null;
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
