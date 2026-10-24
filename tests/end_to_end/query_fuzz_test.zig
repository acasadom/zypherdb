//! A short run of the query fuzzer (tests/fuzz/query.zig) with fixed seeds,
//! so `zig build test` keeps it passing. Long runs with random seeds:
//! `zig build fuzz -- query --seeds 100`.

const std = @import("std");
const testing = std.testing;
const support = @import("../support.zig");
const query_fuzzer = @import("../fuzz/query.zig");

/// Seeds that found each of the deliberate planner and executor mutations
/// the fuzzer was checked with, within their first 150 queries.
const seeds = [_]u64{ 100, 101, 102, 103, 104, 105, 111, 115 };

test "the query fuzzer: the same rows with optimizations off, prepared, and partitioned" {
    for (seeds) |seed| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var buffer: [256]u8 = undefined;
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        var statistics = query_fuzzer.run(testing.allocator, support.testPath(&tmp, &buffer), .{ .seed = seed, .queries = 150 }, &output.writer) catch |err| {
            std.debug.print("{s}", .{output.written()});
            return err;
        };
        statistics.deinit(testing.allocator);
    }
}
