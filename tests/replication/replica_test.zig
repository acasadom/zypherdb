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

test "only an empty database or a replica can follow a master" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;

    var store = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "database", &path));
    defer store.deinit();
    try replica.checkCanFollow(&store);

    try store.put("a", "value");
    try testing.expectError(error.DatabaseNotEmpty, replica.checkCanFollow(&store));

    // Once a replica, what it holds is its master's, whatever it is.
    _ = try store.applyChangeSet(1, "");
    try replica.checkCanFollow(&store);
}

test "a record alone makes a database hold data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [256]u8 = undefined;

    var store = try KeyValueStore.open(testing.allocator, try directoryAt(&tmp, "database", &path));
    defer store.deinit();
    try store.beginWrite();
    try store.putDamagedNode(1, "record");
    try store.commitWrite();
    try testing.expectError(error.DatabaseNotEmpty, replica.checkCanFollow(&store));
}

test "an applier holds a change set while the next has come whole" {
    const Group = zypherdb.replication_replica_node.Group;
    const Work = zypherdb.replication_replica_node.Work;
    const part = struct {
        fn of(lsn: u64, final: bool) Work {
            return .{ .change_set_part = .{ .lsn = lsn, .final = final, .bytes = &.{} } };
        }
    }.of;
    const copy: Work = .{ .copy_part = .{ .final = false, .bytes = &.{} } };

    var group: Group = .{};
    // None waiting, or one partly come, or a copy: committed now.
    try testing.expect(!group.holds(part(1, true), &.{}));
    try testing.expect(!group.holds(part(1, true), &.{part(2, false)}));
    try testing.expect(!group.holds(part(1, true), &.{copy}));
    // The next whole: held, and a part that is not the last has no say.
    try testing.expect(group.holds(part(1, true), &.{part(2, true)}));
    try testing.expect(group.holds(part(2, true), &.{ part(3, false), part(3, true) }));
    try testing.expect(!group.holds(part(3, false), &.{part(3, true)}));
    try testing.expect(!group.holds(part(3, true), &.{}));
    // Not without end.
    var held: usize = 0;
    while (group.holds(part(1, true), &.{part(1, true)})) held += 1;
    try testing.expectEqual(@as(usize, 1023), held);
}
