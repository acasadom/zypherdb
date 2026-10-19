//! The `=` and `<`-family operators of openCypher: comparability, as opposed
//! to the total orderability of `Value.order` (used by ORDER BY, DISTINCT and
//! grouping). They answer null when the answer is unknown: a null operand,
//! or values of types that do not compare.

const std = @import("std");
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const orderNumbers = @import("../value.zig").orderNumbers;

/// `a = b`: true, false, or null (unknown). Numbers compare by value
/// (`1 = 1.0`) and NaN equals nothing; lists and maps compare element by
/// element, unknown if an element pair is and no pair differs; values of
/// different types are never equal.
pub fn equals(a: Value, b: Value) ?bool {
    if (a == .null or b == .null) return null;
    if (isNumber(a) and isNumber(b)) {
        if (isNan(a) or isNan(b)) return false;
        return orderNumbers(a, b) == .eq;
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .list => |items| equalSequences(items, b.list),
        .map => |entries| equalMaps(entries, b.map),
        else => Value.eql(a, b),
    };
}

fn equalSequences(a: []const Value, b: []const Value) ?bool {
    if (a.len != b.len) return false;
    var unknown = false;
    for (a, b) |x, y| {
        const same = equals(x, y) orelse {
            unknown = true;
            continue;
        };
        if (!same) return false;
    }
    return if (unknown) null else true;
}

fn equalMaps(a: []const MapEntry, b: []const MapEntry) ?bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.key, y.key)) return false;
    }
    var unknown = false;
    for (a, b) |x, y| {
        const same = equals(x.value, y.value) orelse {
            unknown = true;
            continue;
        };
        if (!same) return false;
    }
    return if (unknown) null else true;
}

/// The outcome of comparing two values with `<`, `<=`, `>`, `>=`.
pub const Comparison = union(enum) {
    ordered: std.math.Order,
    /// A NaN is involved: every comparison is false.
    unordered,
    /// Null, or types that do not compare: every comparison is null.
    unknown,

    /// The value of `left operator right` for this outcome.
    pub fn holds(self: Comparison, comptime test_order: fn (std.math.Order) bool) Value {
        return switch (self) {
            .ordered => |o| .{ .boolean = test_order(o) },
            .unordered => .{ .boolean = false },
            .unknown => .{ .null = {} },
        };
    }
};

/// Numbers with numbers, strings with strings, booleans with booleans
/// (`false < true`) and lists lexicographically; anything else is unknown.
pub fn compare(a: Value, b: Value) Comparison {
    if (a == .null or b == .null) return .unknown;
    if (isNumber(a) and isNumber(b)) {
        if (isNan(a) or isNan(b)) return .unordered;
        return .{ .ordered = orderNumbers(a, b) };
    }
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return .unknown;
    return switch (a) {
        .string => |x| .{ .ordered = std.mem.order(u8, x, b.string) },
        .boolean => |x| .{ .ordered = std.math.order(@intFromBool(x), @intFromBool(b.boolean)) },
        .list => |x| compareSequences(x, b.list),
        else => .unknown,
    };
}

fn compareSequences(a: []const Value, b: []const Value) Comparison {
    const common = @min(a.len, b.len);
    for (a[0..common], b[0..common]) |x, y| {
        const outcome = compare(x, y);
        switch (outcome) {
            .ordered => |o| if (o != .eq) return outcome,
            .unordered, .unknown => return outcome,
        }
    }
    return .{ .ordered = std.math.order(a.len, b.len) };
}

pub fn isNumber(v: Value) bool {
    return v == .int or v == .float;
}

fn isNan(v: Value) bool {
    return v == .float and std.math.isNan(v.float);
}
