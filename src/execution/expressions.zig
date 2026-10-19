//! Expression evaluation: literals, variables, property access, operators
//! with three-valued (null) logic, CASE, IN and size().

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const BinaryOperator = @import("../query/ast.zig").BinaryOperator;
const UnaryOperator = @import("../query/ast.zig").UnaryOperator;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;

/// Evaluates a non-negative integer literal (used by SKIP and LIMIT).
pub fn evaluateCount(self: *Executor, expr: Index) ExecutionError!usize {
    var empty = Bindings{ .entries = .empty };
    return switch (try evaluate(self, expr, &empty)) {
        .int => |n| if (n < 0) 0 else @as(usize, @intCast(n)),
        else => 0,
    };
}

pub fn evaluateBool(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!bool {
    return switch (try evaluate(self, expr, bindings)) {
        .boolean => |b| b,
        .null => false, // a null predicate filters the row out
        else => error.TypeMismatch,
    };
}

/// True if `needle` equals any element of the `list_literal` node. A null
/// needle matches nothing (`null IN [...]` is null, treated as false here).
pub fn inList(self: *Executor, needle: Value, list_node: Index, bindings: *Bindings) ExecutionError!bool {
    if (Value.isNull(needle)) return false;
    for (self.ast.nodeChildren(list_node)) |item| {
        const v = try evaluate(self, item, bindings);
        if (Value.eql(needle, v)) return true;
    }
    return false;
}

pub fn evaluate(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!Value {
    return switch (self.ast.kind(expr)) {
        .integer_literal => .{ .int = self.ast.data(expr).int },
        .string_literal => .{ .string = self.ast.data(expr).text },
        .boolean_literal => .{ .boolean = self.ast.data(expr).boolean },
        .null_literal => .{ .null = {} },
        .list_literal => blk: {
            var items = std.ArrayList(Value).empty;
            for (self.ast.nodeChildren(expr)) |item| {
                try items.append(self.allocator, try evaluate(self, item, bindings));
            }
            break :blk .{ .list = items.items };
        },
        .size_function => blk: {
            const v = try evaluate(self, self.ast.nodeChildren(expr)[0], bindings);
            const n: usize = switch (v) {
                .list => |items| items.len,
                .string => |s| s.len,
                .null => return error.TypeMismatch,
                else => return error.TypeMismatch,
            };
            break :blk .{ .int = @intCast(n) };
        },
        .case_expression => blk: {
            const children = self.ast.nodeChildren(expr);
            const else_present = (children.len % 2) == 1;
            const num_pairs = children.len / 2;
            var p: usize = 0;
            while (p < num_pairs) : (p += 1) {
                if (try evaluateBool(self, children[p * 2], bindings)) {
                    break :blk try evaluate(self, children[p * 2 + 1], bindings);
                }
            }
            if (else_present) {
                break :blk try evaluate(self, children[children.len - 1], bindings);
            }
            break :blk .{ .null = {} };
        },
        .variable => blk: {
            const name = self.ast.data(expr).text;
            switch (bindings.get(name) orelse {
                self.fail(.unknown_variable, "unknown variable '{s}'", .{name});
                return error.UnknownVariable;
            }) {
                .value => |v| break :blk v,
                .node, .edge => return error.TypeMismatch,
            }
        },
        .property_access => blk: {
            const object = self.ast.nodeChildren(expr)[0];
            if (self.ast.kind(object) != .variable) return error.InvalidExpression;
            const name = self.ast.data(object).text;
            const property = self.ast.data(expr).text;
            switch (bindings.get(name) orelse {
                self.fail(.unknown_variable, "unknown variable '{s}'", .{name});
                return error.UnknownVariable;
            }) {
                .node => |id| {
                    const v = (try self.graph.getProperty(id, property, self.allocator)) orelse {
                        self.fail(.missing_property, "node has no property '{s}'", .{property});
                        return error.MissingProperty;
                    };
                    break :blk v;
                },
                .edge => |e| {
                    const v = (try self.graph.getEdgeProperty(e.src, e.dst, e.edge_type, property, self.allocator)) orelse {
                        self.fail(.missing_property, "relationship has no property '{s}'", .{property});
                        return error.MissingProperty;
                    };
                    break :blk v;
                },
                .value => |v| {
                    // A property access on null yields null.
                    if (Value.isNull(v)) break :blk .{ .null = {} };
                    return error.TypeMismatch;
                },
            }
        },
        .binary_operation => blk: {
            const operator = self.ast.data(expr).binary_operator;
            const children = self.ast.nodeChildren(expr);
            if (operator == .in_) {
                // RHS is a list literal, not a scalar value.
                const l = try evaluate(self, children[0], bindings);
                break :blk .{ .boolean = try inList(self, l, children[1], bindings) };
            }
            const l = try evaluate(self, children[0], bindings);
            const r = try evaluate(self, children[1], bindings);
            break :blk try applyBinaryOperator(operator, l, r);
        },
        .unary_operation => blk: {
            const operator = self.ast.data(expr).unary_operator;
            const v = try evaluate(self, self.ast.nodeChildren(expr)[0], bindings);
            break :blk try applyUnaryOperator(operator, v);
        },
        else => error.InvalidExpression,
    };
}

pub fn applyBinaryOperator(operator: BinaryOperator, left: Value, right: Value) ExecutionError!Value {
    return switch (operator) {
        .equal, .not_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .starts_with, .ends_with, .contains => blk: {
            // Three-valued logic: any null operand yields null.
            if (Value.isNull(left) or Value.isNull(right)) break :blk .{ .null = {} };
            break :blk switch (operator) {
                .equal => .{ .boolean = Value.eql(left, right) },
                .not_equal => .{ .boolean = !Value.eql(left, right) },
                .less_than, .greater_than, .less_or_equal, .greater_or_equal => comparison: {
                    const left_int = try asInt(left);
                    const right_int = try asInt(right);
                    break :comparison .{ .boolean = switch (operator) {
                        .less_than => left_int < right_int,
                        .greater_than => left_int > right_int,
                        .less_or_equal => left_int <= right_int,
                        .greater_or_equal => left_int >= right_int,
                        else => unreachable,
                    } };
                },
                .starts_with, .ends_with, .contains => comparison: {
                    const left_string = try asString(left);
                    const right_string = try asString(right);
                    break :comparison .{ .boolean = switch (operator) {
                        .starts_with => std.mem.startsWith(u8, left_string, right_string),
                        .ends_with => std.mem.endsWith(u8, left_string, right_string),
                        .contains => std.mem.indexOf(u8, left_string, right_string) != null,
                        else => unreachable,
                    } };
                },
                else => unreachable,
            };
        },
        .and_ => blk: {
            const left_bool = try asOptionalBool(left);
            const right_bool = try asOptionalBool(right);
            if (left_bool == false or right_bool == false) break :blk .{ .boolean = false };
            if (left_bool == null or right_bool == null) break :blk .{ .null = {} };
            break :blk .{ .boolean = true };
        },
        .or_ => blk: {
            const left_bool = try asOptionalBool(left);
            const right_bool = try asOptionalBool(right);
            if (left_bool == true or right_bool == true) break :blk .{ .boolean = true };
            if (left_bool == null or right_bool == null) break :blk .{ .null = {} };
            break :blk .{ .boolean = false };
        },
        .in_ => unreachable, // handled in `evaluate` (RHS is a list literal)
    };
}

pub fn applyUnaryOperator(operator: UnaryOperator, value: Value) ExecutionError!Value {
    return switch (operator) {
        .not_ => if (Value.isNull(value)) .{ .null = {} } else .{ .boolean = !try asBool(value) },
    };
}

pub fn asInt(value: Value) ExecutionError!i64 {
    return switch (value) {
        .int => |n| n,
        else => error.TypeMismatch,
    };
}

pub fn asString(value: Value) ExecutionError![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.TypeMismatch,
    };
}

pub fn asBool(value: Value) ExecutionError!bool {
    return switch (value) {
        .boolean => |b| b,
        else => error.TypeMismatch,
    };
}

/// Three-valued boolean coercion: `null` for null, an error for non-boolean.
pub fn asOptionalBool(value: Value) ExecutionError!?bool {
    return switch (value) {
        .boolean => |b| b,
        .null => null,
        else => error.TypeMismatch,
    };
}
