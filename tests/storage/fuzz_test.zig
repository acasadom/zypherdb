//! A short run of the storage fuzzer (tests/fuzz/storage.zig) with fixed
//! seeds, so `zig build test` keeps it passing. Long runs with random seeds:
//! `zig build fuzz -- storage --seeds 100`.

const std = @import("std");
const testing = std.testing;
const support = @import("../support.zig");
const storage_fuzzer = @import("../fuzz/storage.zig");

/// Two seeds of each mix: with transactions or without, with every kind of
/// value or a narrow few (which break uniqueness constraints often).
const seeds = [_]u64{ 1, 10, 12, 13, 14, 18, 2, 17 };

test "the storage fuzzer: the database (and a replica, on even seeds) equals its model, and passes the integrity check" {
    for (seeds) |seed| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [256]u8 = undefined;
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        const path = support.testPath(&tmp, &buffer);
        try tmp.dir.createDirPath(testing.io, "replica");
        var replica_buffer: [256]u8 = undefined;
        const replica = try std.fmt.bufPrint(&replica_buffer, "{s}/replica", .{path});
        _ = storage_fuzzer.run(testing.allocator, path, .{ .seed = seed, .steps = 300, .replica = replica }, &output.writer) catch |err| {
            std.debug.print("{s}", .{output.written()});
            return err;
        };
    }
}
