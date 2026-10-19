//! KeyValueStore: LMDB-backed keys, prefix scans and read transactions.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const KeyValueStore = acmedb.KeyValueStore;

const testPath = @import("../support.zig").testPath;

test "KeyValueStore opens, writes and reads a key" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KeyValueStore.open(testing.allocator, path);
    defer store.deinit();

    try store.put("greeting", "hello acmedb");

    const got = try store.get("greeting");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got != null);
    try testing.expectEqualStrings("hello acmedb", got.?);
}

test "get of a missing key returns null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KeyValueStore.open(testing.allocator, path);
    defer store.deinit();

    const got = try store.get("does_not_exist");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got == null);
}

test "exists distinguishes present from absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KeyValueStore.open(testing.allocator, path);
    defer store.deinit();

    try store.put("a", "1");

    try testing.expect(try store.exists("a"));
    try testing.expect(!try store.exists("b"));
}

test "del deletes a key and is idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KeyValueStore.open(testing.allocator, path);
    defer store.deinit();

    try store.put("k", "v");
    try store.del("k");

    const got = try store.get("k");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expect(got == null);

    // Deleting an absent key is still a success.
    try store.del("k");
}

test "scanPrefix returns only the prefixed keys, in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KeyValueStore.open(testing.allocator, path);
    defer store.deinit();

    const pairs = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "n:a", .v = "1" },
        .{ .k = "n:b", .v = "2" },
        .{ .k = "n:c", .v = "3" },
        .{ .k = "x:z", .v = "9" },
    };
    for (pairs) |p| try store.put(p.k, p.v);

    var it = try store.scanPrefix("n:");
    defer it.deinit();

    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(testing.allocator);

    while (try it.next()) |entry| {
        try seen.append(testing.allocator, entry.key);
    }

    try testing.expectEqual(@as(usize, 3), seen.items.len);
    try testing.expectEqualStrings("n:a", seen.items[0]);
    try testing.expectEqualStrings("n:b", seen.items[1]);
    try testing.expectEqualStrings("n:c", seen.items[2]);
}

test "countPrefix counts the keys of a prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KeyValueStore.open(testing.allocator, path);
    defer store.deinit();

    for ([_][]const u8{ "n:a", "n:b", "x:z" }) |k| try store.put(k, "v");

    try testing.expectEqual(@as(usize, 2), try store.countPrefix("n:"));
    try testing.expectEqual(@as(usize, 0), try store.countPrefix("q:"));
}

test "read transaction batches reads and sees a consistent snapshot" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [128]u8 = undefined;
    const path = testPath(&tmp, &path_buf);

    var store = try KeyValueStore.open(testing.allocator, path);
    defer store.deinit();

    try store.put("a", "1");

    try store.beginRead();

    // Reads route through the open read txn and see the committed state.
    const a = try store.get("a");
    defer if (a) |v| testing.allocator.free(v);
    try testing.expect(a != null);
    try testing.expectEqualStrings("1", a.?);

    // A write committed after the snapshot is invisible to it (MVCC).
    try store.put("b", "2");
    try testing.expect((try store.get("b")) == null);

    // A prefix scan during the read txn borrows it (does not abort it). The
    // iterator must be deinit'd before the read txn ends (cursor → txn).
    {
        var it = try store.scanPrefix("a");
        defer it.deinit();
        try testing.expect((try it.next()) != null);
        try testing.expect((try it.next()) == null);
    }

    store.commitRead();

    // After the snapshot ends, a fresh read sees the write.
    const b = try store.get("b");
    defer if (b) |v| testing.allocator.free(v);
    try testing.expect(b != null);
    try testing.expectEqualStrings("2", b.?);
}
