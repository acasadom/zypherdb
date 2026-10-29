//! A lock for the few, short critical sections of replication's threads
//! (who holds which connection), needing no `std.Io`.

const std = @import("std");

pub const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};
