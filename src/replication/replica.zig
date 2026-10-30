//! How a replica introduces itself to its master (protocol.zig). The rest
//! of its conversation is replica_session.zig's.

const protocol = @import("protocol.zig");
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Graph = @import("../storage/graph.zig").Graph;
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
