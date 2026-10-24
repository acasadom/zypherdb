//! The outcome of running a query, for the query fuzzer's oracles: its rows
//! (sorted, unless the query orders them), or the error it failed with.
//! Values compare as openCypher's ORDER BY does (`Value.order`), so 1 and
//! 1.0 are equal and NaN equals NaN: an aggregate may legitimately keep
//! either of two equal values.

const std = @import("std");
const Allocator = std.mem.Allocator;
const acmedb = @import("acmedb");
const Value = acmedb.Value;
const Row = acmedb.Row;

pub const Outcome = union(enum) {
    rows: []const []const Value,
    failure: anyerror,

    /// `rows` as an outcome: sorted unless `ordered` (the query sorted them).
    pub fn fromRows(allocator: Allocator, rows: []const Row, ordered: bool) Allocator.Error!Outcome {
        const values = try allocator.alloc([]const Value, rows.len);
        for (values, rows) |*row_values, row| row_values.* = row.items;
        if (!ordered) sortRows(values);
        return .{ .rows = values };
    }

    /// The union of `parts` as one outcome (sorted); a failure if one failed.
    pub fn concatenated(allocator: Allocator, parts: []const Outcome) Allocator.Error!Outcome {
        var values = std.ArrayList([]const Value).empty;
        for (parts) |part| switch (part) {
            .failure => return part,
            .rows => |rows| try values.appendSlice(allocator, rows),
        };
        sortRows(values.items);
        return .{ .rows = values.items };
    }

    pub fn eql(a: Outcome, b: Outcome) bool {
        switch (a) {
            .failure => |err| return b == .failure and b.failure == err,
            .rows => |rows| {
                if (b != .rows or b.rows.len != rows.len) return false;
                for (rows, b.rows) |left, right| if (orderRows(left, right) != .eq) return false;
                return true;
            },
        }
    }

    /// A hash that equal outcomes share (for comparing runs on two engines).
    pub fn digest(self: Outcome, hasher: *std.hash.Wyhash) void {
        switch (self) {
            .failure => |err| hasher.update(@errorName(err)),
            .rows => |rows| for (rows) |row| {
                for (row) |value| hasher.update(std.mem.asBytes(&value.hash()));
                hasher.update("\n");
            },
        }
    }

    pub fn format(self: Outcome, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .failure => |err| try writer.print("error {t}\n", .{err}),
            .rows => |rows| {
                try writer.print("{d} row(s)\n", .{rows.len});
                for (rows[0..@min(rows.len, 20)]) |row| try writer.print("  {any}\n", .{row});
                if (rows.len > 20) try writer.writeAll("  ...\n");
            },
        }
    }
};

fn sortRows(rows: [][]const Value) void {
    std.mem.sort([]const Value, rows, {}, struct {
        fn lessThan(_: void, a: []const Value, b: []const Value) bool {
            return orderRows(a, b) == .lt;
        }
    }.lessThan);
}

fn orderRows(a: []const Value, b: []const Value) std.math.Order {
    for (a, b) |left, right| {
        const order = Value.order(left, right);
        if (order != .eq) return order;
    }
    return std.math.order(a.len, b.len);
}
