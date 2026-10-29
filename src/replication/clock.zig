//! The time replication runs on: what time it is, and waiting for a
//! `Signal` (a new change set, a stop) until a deadline. An interface, so
//! a simulation can run replication on a clock of its own; `SystemClock`
//! is the real one.

const std = @import("std");
const Io = std.Io;

/// Nanoseconds since an arbitrary start, never going back.
pub const Instant = u64;

pub const nanoseconds_per_millisecond: u64 = 1_000_000;

/// A value threads wait to grow: the master's last LSN, which each commit
/// raises. Stopped, it wakes every waiter for good.
pub const Signal = struct {
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    value: u64 = 0,
    stopped: bool = false,
};

pub const Clock = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now: *const fn (context: *anyopaque) Instant,
        wait: *const fn (context: *anyopaque, signal: *Signal, seen: u64, deadline: Instant) ?u64,
        raise: *const fn (context: *anyopaque, signal: *Signal, value: u64) void,
        stop: *const fn (context: *anyopaque, signal: *Signal) void,
    };

    pub fn now(self: Clock) Instant {
        return self.vtable.now(self.context);
    }

    /// Waits until `signal`'s value is past `seen` or `deadline` comes;
    /// returns the value then, or null once `signal` is stopped.
    pub fn wait(self: Clock, signal: *Signal, seen: u64, deadline: Instant) ?u64 {
        return self.vtable.wait(self.context, signal, seen, deadline);
    }

    /// Raises `signal`'s value to `value` (never lowers it), waking its
    /// waiters.
    pub fn raise(self: Clock, signal: *Signal, value: u64) void {
        self.vtable.raise(self.context, signal, value);
    }

    /// Stops `signal`, waking its waiters.
    pub fn stop(self: Clock, signal: *Signal) void {
        self.vtable.stop(self.context, signal);
    }
};

/// The operating system's monotonic clock, through `io` (a multithreaded
/// `std.Io`: waiters and raisers run on threads of their own).
pub const SystemClock = struct {
    io: Io,

    pub fn clock(self: *SystemClock) Clock {
        return .{ .context = self, .vtable = &.{ .now = now, .wait = wait, .raise = raise, .stop = stop } };
    }

    fn now(context: *anyopaque) Instant {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        return @intCast(Io.Clock.awake.now(self.io).nanoseconds);
    }

    fn wait(context: *anyopaque, signal: *Signal, seen: u64, deadline: Instant) ?u64 {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        signal.mutex.lockUncancelable(self.io);
        defer signal.mutex.unlock(self.io);
        const timeout: Io.Timeout = .{ .deadline = .{ .raw = .fromNanoseconds(deadline), .clock = .awake } };
        while (!signal.stopped and signal.value <= seen) {
            signal.condition.waitTimeout(self.io, &signal.mutex, timeout) catch |err| switch (err) {
                error.Timeout, error.Canceled => break,
            };
        }
        return if (signal.stopped) null else signal.value;
    }

    fn raise(context: *anyopaque, signal: *Signal, value: u64) void {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        signal.mutex.lockUncancelable(self.io);
        defer signal.mutex.unlock(self.io);
        if (value <= signal.value) return;
        signal.value = value;
        signal.condition.broadcast(self.io);
    }

    fn stop(context: *anyopaque, signal: *Signal) void {
        const self: *SystemClock = @ptrCast(@alignCast(context));
        signal.mutex.lockUncancelable(self.io);
        defer signal.mutex.unlock(self.io);
        signal.stopped = true;
        signal.condition.broadcast(self.io);
    }
};
