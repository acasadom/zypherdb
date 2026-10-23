//! EXPLAIN and PROFILE. EXPLAIN plans the query and returns the plan's
//! lines (planning/explain.zig) without running it; PROFILE runs it, in its
//! own transaction (its writes commit), and returns the same lines with
//! what each operator did: the rows it made and the time spent in it.
//!
//! Each line is a row `[depth, operator, details, estimated_rows, rows,
//! time_ms]`; `rows` and `time_ms` are null in EXPLAIN, and on a line that
//! names an expression. The query's own rows are kept in
//! `Executor.profiled_rows`, and the parent of each line (the plan as a
//! tree) in `Executor.plan_parents`.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Plan = @import("../planning/Plan.zig");
const OperatorIndex = Plan.OperatorIndex;
const builder = @import("../planning/builder.zig");
const explain = @import("../planning/explain.zig");
const Statistics = @import("../planning/statistics.zig").Statistics;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Row = Executor.Row;

/// What PROFILE measures for each operator. Time is exclusive: the time an
/// operator hands to the next one is the next one's.
pub const Profile = struct {
    /// How many rows each operator was handed.
    rows_in: []u64,
    /// How many rows a RETURN made (after aggregating and paging).
    returned: []u64,
    nanoseconds: []u64,
    /// The operator the time goes to now, and since when.
    active: ?OperatorIndex = null,
    since: i96 = 0,

    pub fn init(allocator: std.mem.Allocator, operator_count: usize) std.mem.Allocator.Error!Profile {
        const counters = try allocator.alloc(u64, operator_count * 3);
        @memset(counters, 0);
        return .{
            .rows_in = counters[0..operator_count],
            .returned = counters[operator_count .. 2 * operator_count],
            .nanoseconds = counters[2 * operator_count ..],
            .since = now(),
        };
    }

    /// The time from now goes to `operator`; returns the operator it went
    /// to before, for `leave`.
    pub fn enter(self: *Profile, operator: OperatorIndex) ?OperatorIndex {
        const previous = self.active;
        self.switchTo(operator);
        return previous;
    }

    pub fn leave(self: *Profile, previous: ?OperatorIndex) void {
        self.switchTo(previous);
    }

    fn switchTo(self: *Profile, operator: ?OperatorIndex) void {
        const time = now();
        if (self.active) |active| self.nanoseconds[active] += @intCast(@max(time - self.since, 0));
        self.active = operator;
        self.since = time;
    }
};

fn now() i96 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
}

/// Runs an `explain` statement (EXPLAIN or PROFILE).
pub fn run(executor: *Executor, statement: Index) ExecutionError![]const Row {
    const ast = executor.ast;
    const root = ast.nodeChildren(statement)[0];
    const profiling = ast.data(statement).explain == .profile;
    try executor.check(root);
    const writes = profiling and executor.writes(root);
    if (writes) try executor.graph.beginWrite() else try executor.graph.beginRead();
    errdefer if (writes) executor.graph.abortWrite() else executor.graph.abortRead();

    var statistics = Statistics{ .graph = executor.graph, .allocator = executor.allocator };
    const plan = try builder.build(.{ .ast = ast, .statistics = &statistics, .allocator = executor.allocator }, root);
    var profile: ?Profile = null;
    if (profiling) {
        profile = try Profile.init(executor.allocator, plan.operators.len);
        executor.profile = &profile.?;
        defer executor.profile = null;
        executor.profiled_rows = try executor.execute(&plan, root);
    }
    const plan_lines = try explain.lines(ast, &plan, root, &statistics, executor.allocator);
    const parents = try executor.allocator.alloc(?usize, plan_lines.len);
    for (parents, plan_lines) |*parent, line| parent.* = line.parent;
    executor.plan_parents = parents;

    if (writes) try executor.graph.commitWrite() else executor.graph.commitRead();
    return rows(executor, &plan, plan_lines, if (profile) |*measured| measured else null);
}

/// One row per line of the plan.
fn rows(executor: *Executor, plan: *const Plan, plan_lines: []const explain.Line, profile: ?*const Profile) ExecutionError![]const Row {
    const allocator = executor.allocator;
    const output = try allocator.alloc(Row, plan_lines.len);
    for (output, plan_lines) |*row, line| {
        row.* = .empty;
        try row.appendSlice(allocator, &.{
            .{ .int = line.depth },
            .{ .string = line.name },
            .{ .string = line.details },
            if (line.estimated_rows) |estimate| .{ .int = @intFromFloat(@round(@min(estimate, 9.0e18))) } else .null,
        });
        const measured = profile orelse {
            try row.appendSlice(allocator, &.{ .null, .null });
            continue;
        };
        const operator = line.operator orelse {
            try row.appendSlice(allocator, &.{ .null, .null });
            continue;
        };
        try row.appendSlice(allocator, &.{
            .{ .int = @intCast(rowsMade(plan, measured, operator)) },
            .{ .float = @as(f64, @floatFromInt(measured.nanoseconds[operator])) / 1e6 },
        });
    }
    return output;
}

/// The rows `operator` made: those its successor in the chain was handed
/// (a RETURN's are counted at its end; the last operator of a chain makes
/// what it was handed).
fn rowsMade(plan: *const Plan, profile: *const Profile, operator: OperatorIndex) u64 {
    return switch (plan.operators[operator]) {
        .return_ => profile.returned[operator],
        .procedure_call => |call| if (call.ends_query) profile.returned[operator] else profile.rows_in[operator + 1],
        .output, .discard => profile.rows_in[operator],
        else => profile.rows_in[operator + 1],
    };
}
