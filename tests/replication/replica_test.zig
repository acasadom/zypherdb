//! How a replica introduces itself (replication/replica.zig).

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const protocol = zypherdb.replication_protocol;
const replica = zypherdb.replication_replica;

const support = @import("../support.zig");
const testPath = support.testPath;

const token = "the master's token";

/// The path of directory `name` in `tmp`, created.
fn directoryAt(tmp: *testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var base_buffer: [128]u8 = undefined;
    try tmp.dir.createDirPath(testing.io, name);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(tmp, &base_buffer), name });
}

test "a replica introduces itself by what it holds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;

    const empty = try replica.hello(null, token);
    try testing.expectEqual(@as(?protocol.DatabaseId, null), empty.database_id);
    try testing.expectEqual(@as(u64, 0), empty.applied_lsn);
    try testing.expectEqualStrings(zypherdb.storage_engine, empty.storage_engine);
    try testing.expectEqualStrings(token, empty.token);

    var store = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "master", &path));
    defer store.deinit();
    // A database that is no replica yet has nothing to resume.
    try store.put("a", "value");
    try testing.expectEqual(@as(?protocol.DatabaseId, null), (try replica.hello(&store, token)).database_id);
    try store.startChangeLog();
    try testing.expectError(error.MasterDatabase, replica.hello(&store, token));
}
