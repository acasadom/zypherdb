//! How a replica introduces itself to its master (protocol.zig). The rest
//! of its conversation is replica_session.zig's.

const protocol = @import("protocol.zig");
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Graph = @import("../storage/graph.zig").Graph;
const integrity = @import("../storage/integrity.zig");
const storage_engine = @import("master.zig").storage_engine;

/// Fails unless the database of `store` can follow a master: one with no
/// data or a replica already. A master copies no one (`MasterDatabase`), and
/// the first copy would erase any other database's data (`DatabaseNotEmpty`).
pub fn checkCanFollow(store: *KeyValueStore) (StorageError || error{ MasterDatabase, DatabaseNotEmpty })!void {
    if (try store.changeLogState() != null) return error.MasterDatabase;
    if (try store.appliedLsn() != null) return;
    if (try integrity.holdsData(store)) return error.DatabaseNotEmpty;
}

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
