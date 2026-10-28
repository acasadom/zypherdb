//! Counting from an index (`Plan.Operator.node_index_range_count`): the
//! index entries whose value is in range are the matches, each one read back
//! from its key and compared with the bounds as the WHERE would.

const std = @import("std");
const Value = @import("../value.zig").Value;
const property_indexes = @import("../storage/property_indexes.zig");
const comparison = @import("comparison.zig");

const Plan = @import("../planning/Plan.zig");
const PatternNode = Plan.PatternNode;
const OperatorIndex = Plan.OperatorIndex;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const aggregation = @import("aggregation.zig");
const expressions = @import("expressions.zig");
const operators = @import("operators.zig");
const patternOf = @import("pattern_matching.zig").patternOf;

/// Adds the count of the node's index entries in range to the RETURN, or,
/// when the keys cannot tell, hands the row on to match and count instead.
pub fn countNodes(self: *Executor, reference: Plan.NodeReference, next: OperatorIndex, bindings: *Bindings) ExecutionError!void {
    const node = patternOf(self, reference.pattern).nodes[reference.node];
    if (try exactCount(self, node, bindings)) |count| return aggregation.addCount(self, count);
    try operators.feed(self, next, bindings);
}

/// A bound of the range: its value and whether it is out of range itself.
const Bound = struct { value: Value, strict: bool };

/// How many index entries satisfy every range of `node`, or null when the
/// index cannot say: a bound that is null or of a kind the keys do not give
/// back whole, or an entry cut short.
fn exactCount(self: *Executor, node: PatternNode, bindings: *Bindings) ExecutionError!?u64 {
    const use = node.range_index.?; // planned only with one
    var lower: ?Bound = null;
    var upper: ?Bound = null;
    // The planner allows at most one range from each side.
    for (node.ranges) |range| {
        if (range.lower) |expression| lower = .{ .value = try expressions.evaluate(self, expression, bindings), .strict = range.lower_strict };
        if (range.upper) |expression| upper = .{ .value = try expressions.evaluate(self, expression, bindings), .strict = range.upper_strict };
    }
    if (!countable(lower, upper)) return null;
    var keys = try self.graph.nodesInRange(use.index_id, if (lower) |b| b.value else null, if (upper) |b| b.value else null) orelse return null;
    defer keys.deinit();
    var count: u64 = 0;
    while (try keys.nextKey()) |key| {
        // The range read is a superset: each value is checked.
        const value = property_indexes.keyValue(key) orelse return null;
        if (lower) |bound| if (!inRange(value, bound, .gt)) continue;
        if (upper) |bound| if (!inRange(value, bound, .lt)) continue;
        count += 1;
    }
    return count;
}

/// True if the bounds are numbers, or strings, or dates, or local times
/// (the kinds `property_indexes.keyValue` gives back), all of one kind.
fn countable(lower: ?Bound, upper: ?Bound) bool {
    const first_bound: Bound = lower orelse upper orelse return false;
    const first = first_bound.value;
    for ([_]?Bound{ lower, upper }) |bound| if (bound) |b| {
        const same = switch (first) {
            .int, .float => comparison.isNumber(b.value),
            .string, .date, .local_time => std.meta.activeTag(b.value) == std.meta.activeTag(first),
            else => false,
        };
        if (!same) return false;
    };
    return true;
}

/// True if `value` is on the `side` of `bound` (`.gt`: above a lower bound,
/// `.lt`: below an upper one), or equal to a bound that is not strict.
fn inRange(value: Value, bound: Bound, side: std.math.Order) bool {
    return switch (comparison.compare(value, bound.value)) {
        .ordered => |order| order == side or (order == .eq and !bound.strict),
        .unordered, .unknown => false,
    };
}
