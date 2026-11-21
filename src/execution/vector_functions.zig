//! `vector.similarity.cosine(a, b)` and `vector.similarity.euclidean(a, b)`:
//! the similarity of two lists of numbers of the same length, scored as a
//! vector index scores (src/vector/similarity.zig), in [0, 1].
//!
//! Null if either list is null, or under cosine if one is all zeros (it
//! has no direction). Lists of other lengths, empty ones, or elements that
//! are not finite numbers fail. O(length).

const std = @import("std");

const Value = @import("../value.zig").Value;
const similarity = @import("../vector/similarity.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Function = @import("functions.zig").Function;

pub const entries = [_]struct { []const u8, Function }{
    .{ "vector.similarity.cosine", scoreFunction(.cosine) },
    .{ "vector.similarity.euclidean", scoreFunction(.euclidean) },
};

fn scoreFunction(comptime chosen: similarity.Similarity) Function {
    return .{ .min_arguments = 2, .max_arguments = 2, .implementation = struct {
        fn apply(self: *Executor, arguments: []const Value) ExecutionError!Value {
            return score(self, chosen, arguments);
        }
    }.apply };
}

fn score(self: *Executor, chosen: similarity.Similarity, arguments: []const Value) ExecutionError!Value {
    const name = if (chosen == .cosine) "vector.similarity.cosine" else "vector.similarity.euclidean";
    if (arguments[0] == .null or arguments[1] == .null) return .{ .null = {} };
    const a = try numbers(self, name, arguments[0]);
    const b = try numbers(self, name, arguments[1]);
    if (a.len != b.len) {
        self.fail(.invalid_expression, "{s}() needs two vectors of the same length, not {d} and {d}", .{ name, a.len, b.len });
        return error.InvalidExpression;
    }
    return if (similarity.scoreOfNumbers(chosen, a, b)) |value| .{ .float = value } else .{ .null = {} };
}

/// The finite numbers of a non-empty list.
fn numbers(self: *Executor, name: []const u8, value: Value) ExecutionError![]const f64 {
    if (value != .list or value.list.len == 0) {
        self.fail(.type_mismatch, "{s}() takes two non-empty lists of numbers", .{name});
        return error.TypeMismatch;
    }
    const result = try self.allocator.alloc(f64, value.list.len);
    for (result, value.list) |*number, item| {
        number.* = switch (item) {
            .int => |int| @floatFromInt(int),
            .float => |float| float,
            else => {
                self.fail(.type_mismatch, "{s}() takes two non-empty lists of numbers", .{name});
                return error.TypeMismatch;
            },
        };
        if (!std.math.isFinite(number.*)) {
            self.fail(.invalid_expression, "{s}() takes finite numbers, not NaN or infinity", .{name});
            return error.InvalidExpression;
        }
    }
    return result;
}
