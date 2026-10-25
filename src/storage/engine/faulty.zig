//! A storage engine that fails on purpose: it wraps the engine ZypherDB is
//! built with and makes the N-th fallible operation fail, so tests can check
//! that every engine error reaches the caller as an error (no panic, no leak)
//! and leaves the database as it was before the failed transaction.
//!
//! Used only by the module build.zig makes for the fault tests and the
//! fuzzers (build option `fault_injection`, see engine.zig): the library
//! itself never includes it, so it pays nothing for it.
//!
//! Failures are realistic for an LMDB-like engine: a failure inside a write
//! transaction breaks it (every later operation on it fails, and so does its
//! commit, which aborts it), and a failed commit leaves nothing written.
//! A plan can also leave the transaction usable after a failure, which no
//! engine does but which shows a write error the layers above ignored: the
//! transaction then commits without that write.
//!
//! The plan can also crash the process (SIGKILL to itself) at a chosen
//! crash point: before each fallible operation, and after each commit. The
//! crash tests (tests/fuzz/crash.zig) use it to stop a writer exactly there.
//!
//! The plan (`faults`) is one global: tests that use it run one database at
//! a time on one thread.

const std = @import("std");

const contract = @import("contract.zig");

const Error = contract.Error;
const Table = contract.Table;
const Entry = contract.Entry;

/// The engine operations that can fail.
pub const Operation = enum { open, sync, begin_read, begin_write, commit, get, put, delete, open_cursor, first, find, seek, next };

/// When to fail, and what happened so far.
pub const Plan = struct {
    /// The number of fallible operations so far (counted also when nothing
    /// is meant to fail, to size a test's fault points).
    operations: u64 = 0,
    /// The operation (counting from 0) that fails, if any.
    fail_at: ?u64 = null,
    /// After the first failure every operation fails (a dead disk), instead
    /// of only that one (a transient error).
    persistent: bool = false,
    /// A failure in a write transaction breaks it (see the module comment).
    breaks_writer: bool = true,
    /// The failures injected, and the operation that failed first.
    injected: u64 = 0,
    first_failed: ?Operation = null,
    /// A failure broke the current write transaction (see the module comment).
    writer_broken: bool = false,
    /// The crash points so far, and the one where the process kills itself.
    crash_points: u64 = 0,
    crash_at: ?u64 = null,

    /// Starts counting again, failing at `fail_at`.
    pub fn arm(self: *Plan, fail_at: ?u64, persistent: bool, breaks_writer: bool) void {
        self.* = .{ .fail_at = fail_at, .persistent = persistent, .breaks_writer = breaks_writer };
    }

    /// No more failures (the counts stay, for the report).
    pub fn disarm(self: *Plan) void {
        self.fail_at = null;
        self.persistent = false;
    }

    /// True if `operation` must fail now; `in_writer` if it runs in a write
    /// transaction.
    fn fails(self: *Plan, operation: Operation, in_writer: bool) bool {
        self.crashPoint();
        const number = self.operations;
        self.operations += 1;
        const due = if (self.fail_at) |at| number == at or (self.persistent and number > at) else false;
        if (!due and !(in_writer and self.writer_broken)) return false;
        self.injected += 1;
        if (self.first_failed == null) self.first_failed = operation;
        if (in_writer and self.breaks_writer) self.writer_broken = true;
        return true;
    }

    /// A place the process may crash: it kills itself here if `crash_at` says.
    fn crashPoint(self: *Plan) void {
        const number = self.crash_points;
        self.crash_points += 1;
        if (self.crash_at == number) std.posix.raise(.KILL) catch unreachable;
    }
};

/// The global plan every wrapped engine follows.
pub var faults: Plan = .{};

/// `Inner` (an engine, see contract.zig) with failures injected by `faults`.
pub fn Wrap(comptime Inner: type) type {
    return struct {
        pub const Environment = struct {
            inner: Inner.Environment,

            pub fn open(allocator: std.mem.Allocator, path: []const u8, options: contract.Options) Error!Environment {
                if (faults.fails(.open, false)) return error.OpenFailed;
                return .{ .inner = try Inner.Environment.open(allocator, path, options) };
            }

            pub fn close(self: *Environment) void {
                self.inner.close();
            }

            pub fn sync(self: *Environment) Error!void {
                if (faults.fails(.sync, false)) return error.WriteFailed;
                return self.inner.sync();
            }

            pub fn beginRead(self: *Environment) Error!Transaction {
                if (faults.fails(.begin_read, false)) return error.ReadFailed;
                return .{ .inner = try self.inner.beginRead(), .writes = false };
            }

            pub fn endRead(self: *Environment, transaction: Transaction) void {
                self.inner.endRead(transaction.inner);
            }

            pub fn beginWrite(self: *Environment) Error!Transaction {
                faults.writer_broken = false;
                if (faults.fails(.begin_write, false)) return error.WriteFailed;
                return .{ .inner = try self.inner.beginWrite(), .writes = true };
            }
        };

        pub const Transaction = struct {
            inner: Inner.Transaction,
            writes: bool,

            /// A failed commit is aborted, as the contract says.
            pub fn commit(self: Transaction) Error!void {
                if (faults.fails(.commit, self.writes)) {
                    self.inner.abort();
                    faults.writer_broken = false;
                    return error.WriteFailed;
                }
                try self.inner.commit();
                faults.crashPoint();
            }

            pub fn abort(self: Transaction) void {
                if (self.writes) faults.writer_broken = false;
                self.inner.abort();
            }

            pub fn get(self: Transaction, table: Table, key: []const u8) Error!?[]const u8 {
                if (faults.fails(.get, self.writes)) return error.ReadFailed;
                return self.inner.get(table, key);
            }

            pub fn put(self: Transaction, table: Table, key: []const u8, value: []const u8) Error!void {
                if (faults.fails(.put, self.writes)) return error.WriteFailed;
                return self.inner.put(table, key, value);
            }

            pub fn delete(self: Transaction, table: Table, key: []const u8) Error!void {
                if (faults.fails(.delete, self.writes)) return error.DeleteFailed;
                return self.inner.delete(table, key);
            }

            pub fn openCursor(self: Transaction, table: Table) Error!Cursor {
                if (faults.fails(.open_cursor, self.writes)) return error.ReadFailed;
                return .{ .inner = try self.inner.openCursor(table), .writes = self.writes };
            }
        };

        pub const Cursor = struct {
            inner: Inner.Cursor,
            writes: bool,

            pub fn close(self: Cursor) void {
                self.inner.close();
            }

            pub fn first(self: Cursor) Error!?Entry {
                if (faults.fails(.first, self.writes)) return error.ReadFailed;
                return self.inner.first();
            }

            pub fn find(self: Cursor, key: []const u8) Error!?[]const u8 {
                if (faults.fails(.find, self.writes)) return error.ReadFailed;
                return self.inner.find(key);
            }

            pub fn seek(self: Cursor, key: []const u8) Error!?Entry {
                if (faults.fails(.seek, self.writes)) return error.ReadFailed;
                return self.inner.seek(key);
            }

            pub fn next(self: Cursor) Error!?Entry {
                if (faults.fails(.next, self.writes)) return error.ReadFailed;
                return self.inner.next();
            }
        };

        comptime {
            contract.check(@This());
        }
    };
}

test "the plan fails the chosen operation, or every one from it" {
    var plan = Plan{};
    plan.arm(2, false, true);
    try std.testing.expect(!plan.fails(.get, false));
    try std.testing.expect(!plan.fails(.get, false));
    try std.testing.expect(plan.fails(.next, false));
    try std.testing.expect(!plan.fails(.get, false));
    try std.testing.expectEqual(Operation.next, plan.first_failed.?);

    plan.arm(1, true, true);
    try std.testing.expect(!plan.fails(.get, false));
    try std.testing.expect(plan.fails(.get, false));
    try std.testing.expect(plan.fails(.put, false));
    try std.testing.expectEqual(2, plan.injected);
}

test "a failure in a write transaction breaks it, unless the plan says not to" {
    var plan = Plan{};
    plan.arm(0, false, true);
    try std.testing.expect(plan.fails(.put, true));
    try std.testing.expect(plan.fails(.get, true));
    try std.testing.expect(!plan.fails(.get, false));

    plan.arm(0, false, false);
    try std.testing.expect(plan.fails(.put, true));
    try std.testing.expect(!plan.fails(.get, true));
}
