//! The clock replication runs on (replication/clock.zig): waiting for a
//! signal ends when its value grows, the deadline comes or it stops.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const clock_module = zypherdb.replication_clock;
const Signal = clock_module.Signal;
const SystemClock = clock_module.SystemClock;

const millisecond = clock_module.nanoseconds_per_millisecond;

test "a wait ends at its deadline with the value unchanged" {
    var system: SystemClock = .{ .io = testing.io };
    const clock = system.clock();
    var signal: Signal = .{};
    clock.raise(&signal, 3);
    const start = clock.now();
    try testing.expectEqual(@as(?u64, 3), clock.wait(&signal, 3, start + 20 * millisecond));
    try testing.expect(clock.now() >= start + 20 * millisecond);
}

test "a wait for a value already past returns at once" {
    var system: SystemClock = .{ .io = testing.io };
    const clock = system.clock();
    var signal: Signal = .{};
    clock.raise(&signal, 5);
    // Raising never lowers.
    clock.raise(&signal, 2);
    try testing.expectEqual(@as(?u64, 5), clock.wait(&signal, 4, clock.now() + 60_000 * millisecond));
}

fn raiseLater(clock: clock_module.Clock, signal: *Signal, value: ?u64) void {
    testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    if (value) |raised| clock.raise(signal, raised) else clock.stop(signal);
}

test "a raise from another thread wakes a wait" {
    var system: SystemClock = .{ .io = testing.io };
    const clock = system.clock();
    var signal: Signal = .{};
    const thread = try std.Thread.spawn(.{}, raiseLater, .{ clock, &signal, @as(?u64, 7) });
    defer thread.join();
    const start = clock.now();
    try testing.expectEqual(@as(?u64, 7), clock.wait(&signal, 0, start + 60_000 * millisecond));
    // Woken, not timed out.
    try testing.expect(clock.now() < start + 30_000 * millisecond);
}

test "a stop wakes a wait for good" {
    var system: SystemClock = .{ .io = testing.io };
    const clock = system.clock();
    var signal: Signal = .{};
    const thread = try std.Thread.spawn(.{}, raiseLater, .{ clock, &signal, @as(?u64, null) });
    defer thread.join();
    try testing.expectEqual(@as(?u64, null), clock.wait(&signal, 0, clock.now() + 60_000 * millisecond));
    clock.raise(&signal, 9);
    try testing.expectEqual(@as(?u64, null), clock.wait(&signal, 0, clock.now() + 60_000 * millisecond));
}
