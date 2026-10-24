//! A short run of the fault fuzzer (tests/fuzz/faults.zig) with fixed
//! seeds, so `zig build test` keeps it passing: every storage failure is
//! reported as an error and leaves the database as it was. Long runs with
//! random seeds: `zig build fuzz -- faults --seeds 100`.

const std = @import("std");
const testing = std.testing;
const support = @import("../support.zig");
const fault_fuzzer = @import("../fuzz/faults.zig");

/// Seeds that found each of the deliberate mutations the fuzzer was checked
/// with (a transaction left open, a write error ignored, a leak), within
/// their first 40 statements.
const seeds = [_]u64{ 1000, 1001, 1003, 1010, 1012, 1021 };

test "the fault fuzzer: storage failures leave nothing behind" {
    for (seeds) |seed| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        var twin_tmp = testing.tmpDir(.{});
        defer twin_tmp.cleanup();
        var buffer: [256]u8 = undefined;
        var twin_buffer: [256]u8 = undefined;
        var output = std.Io.Writer.Allocating.init(testing.allocator);
        defer output.deinit();
        _ = fault_fuzzer.run(testing.allocator, support.testPath(&tmp, &buffer), support.testPath(&twin_tmp, &twin_buffer), .{ .seed = seed, .steps = 40 }, &output.writer) catch |err| {
            std.debug.print("{s}", .{output.written()});
            return err;
        };
    }
}
