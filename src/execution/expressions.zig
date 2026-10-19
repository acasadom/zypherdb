//! Expression evaluation: literals, variables, property access, operators
//! with three-valued (null) logic, CASE, IN and size().

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const BinaryOperator = @import("../query/ast.zig").BinaryOperator;
const UnaryOperator = @import("../query/ast.zig").UnaryOperator;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const functions = @import("functions.zig");
const ExecutionError = Executor.ExecutionError;

const Bindings = @import("bindings.zig").Bindings;

/// Evaluates a SKIP or LIMIT count: a non-negative integer, else an error.
pub fn evaluateCount(self: *Executor, expr: Index) ExecutionError!usize {
    var empty = Bindings{ .entries = .empty };
    return switch (try evaluate(self, expr, &empty)) {
        .int => |n| if (n >= 0) @intCast(n) else {
            self.fail(.invalid_expression, "SKIP and LIMIT need a non-negative integer, got {d}", .{n});
            return error.InvalidExpression;
        },
        else => {
            self.fail(.invalid_expression, "SKIP and LIMIT need an integer", .{});
            return error.InvalidExpression;
        },
    };
}

pub fn evaluateBool(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!bool {
    return switch (try evaluate(self, expr, bindings)) {
        .boolean => |b| b,
        .null => false, // a null predicate filters the row out
        else => error.TypeMismatch,
    };
}

/// `needle IN list` with three-valued logic: null when the list is null,
/// true when an element equals the needle, else null if the needle or some
/// element is null (the answer is unknown), else false.
fn inList(needle: Value, list: Value) ExecutionError!Value {
    const items = switch (list) {
        .list => |items| items,
        .null => return .{ .null = {} },
        else => return error.TypeMismatch,
    };
    var unknown = Value.isNull(needle) and items.len > 0;
    for (items) |item| {
        if (Value.isNull(item)) {
            unknown = true;
        } else if (!Value.isNull(needle) and Value.eql(needle, item)) {
            return .{ .boolean = true };
        }
    }
    return if (unknown) .{ .null = {} } else .{ .boolean = false };
}

pub fn evaluate(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!Value {
    return switch (self.ast.kind(expr)) {
        .integer_literal => .{ .int = self.ast.data(expr).int },
        .string_literal => .{ .string = self.ast.data(expr).text },
        .boolean_literal => .{ .boolean = self.ast.data(expr).boolean },
        .null_literal => .{ .null = {} },
        .parameter => blk: {
            const name = self.ast.data(expr).text;
            break :blk self.parameters.get(name) orelse {
                self.fail(.parameter_missing, "missing parameter '${s}'", .{name});
                return error.ParameterMissing;
            };
        },
        .list_literal => blk: {
            var items = std.ArrayList(Value).empty;
            for (self.ast.nodeChildren(expr)) |item| {
                try items.append(self.allocator, try evaluate(self, item, bindings));
            }
            break :blk .{ .list = items.items };
        },
        .function_call => functions.call(self, expr, bindings),
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
            break :blk bindings.get(name) orelse {
                self.fail(.unknown_variable, "unknown variable '{s}'", .{name});
                return error.UnknownVariable;
            };
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
                // A property the entity does not have reads as null, unless the
                // entity itself was deleted (openCypher's EntityNotFound).
                .node => |id| {
                    if (try self.graph.getProperty(id, property, self.allocator)) |value| break :blk value;
                    if (!try self.graph.hasNode(id)) return deletedEntity(self, "node", property);
                    break :blk .{ .null = {} };
                },
                .relationship => |r| {
                    if (try self.graph.getEdgeProperty(r.src, r.dst, r.edge_type, property, self.allocator)) |value| break :blk value;
                    if (!try self.graph.hasEdge(r.src, r.dst, r.edge_type)) return deletedEntity(self, "relationship", property);
                    break :blk .{ .null = {} };
                },
                // A property access on null yields null.
                .null => break :blk .{ .null = {} },
                else => return error.TypeMismatch,
            }
        },
        .binary_operation => blk: {
            const operator = self.ast.data(expr).binary_operator;
            const children = self.ast.nodeChildren(expr);
            const l = try evaluate(self, children[0], bindings);
            const r = try evaluate(self, children[1], bindings);
            break :blk try applyBinaryOperator(self, operator, l, r);
        },
        .unary_operation => blk: {
            const operator = self.ast.data(expr).unary_operator;
            const v = try evaluate(self, self.ast.nodeChildren(expr)[0], bindings);
            break :blk try applyUnaryOperator(self, operator, v);
        },
        else => error.InvalidExpression,
    };
}

pub fn applyBinaryOperator(self: *Executor, operator: BinaryOperator, left: Value, right: Value) ExecutionError!Value {
    return switch (operator) {
        .add, .subtract, .multiply, .divide, .modulo => arithmetic(self, operator, left, right),
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
        .in_ => inList(left, right),
    };
}

pub fn applyUnaryOperator(self: *Executor, operator: UnaryOperator, value: Value) ExecutionError!Value {
    return switch (operator) {
        .not_ => if (Value.isNull(value)) .{ .null = {} } else .{ .boolean = !try asBool(value) },
        .negate => switch (value) {
            .null => .{ .null = {} },
            .int => |n| .{ .int = std.math.negate(n) catch return overflow(self) },
            else => typeMismatch(self, "unary minus needs a number"),
        },
    };
}

/// `+ - * / %`. Integers overflow-checked (an error, never a silent
/// wrap-around), `/` truncating toward zero and `%` taking the dividend's
/// sign; `+` also concatenates strings (a number is written in decimal) and
/// lists (or adds an element to either end). Null with anything is null.
fn arithmetic(self: *Executor, operator: BinaryOperator, left: Value, right: Value) ExecutionError!Value {
    if (left.isNull() or right.isNull()) return .{ .null = {} };
    if (left == .int and right == .int) {
        const a = left.int;
        const b = right.int;
        const result = switch (operator) {
            .add => std.math.add(i64, a, b),
            .subtract => std.math.sub(i64, a, b),
            .multiply => std.math.mul(i64, a, b),
            .divide => if (b == 0) return divisionByZero(self) else std.math.divTrunc(i64, a, b),
            .modulo => if (b == 0) return divisionByZero(self) else if (b == -1) 0 else @rem(a, b),
            else => unreachable,
        } catch return overflow(self);
        return .{ .int = result };
    }
    if (operator != .add) return typeMismatch(self, "arithmetic needs numbers");
    if (left == .list or right == .list) return concatenateLists(self, left, right);
    if (left == .string or right == .string) {
        const left_text = try textOf(self, left);
        const right_text = try textOf(self, right);
        return .{ .string = try std.mem.concat(self.allocator, u8, &.{ left_text, right_text }) };
    }
    return typeMismatch(self, "+ needs numbers, strings or lists");
}

/// `list + list`, `list + element` or `element + list`.
fn concatenateLists(self: *Executor, left: Value, right: Value) ExecutionError!Value {
    const left_items: []const Value = if (left == .list) left.list else &.{left};
    const right_items: []const Value = if (right == .list) right.list else &.{right};
    return .{ .list = try std.mem.concat(self.allocator, Value, &.{ left_items, right_items }) };
}

/// A string operand of `+`: a string, or an integer in decimal.
fn textOf(self: *Executor, value: Value) ExecutionError![]const u8 {
    return switch (value) {
        .string => |s| s,
        .int => |n| try std.fmt.allocPrint(self.allocator, "{d}", .{n}),
        else => typeMismatch(self, "+ can join a string only with a string or a number"),
    };
}

fn overflow(self: *Executor) ExecutionError {
    self.fail(.arithmetic, "integer overflow: the result does not fit in 64 bits", .{});
    return error.IntegerOverflow;
}

fn divisionByZero(self: *Executor) ExecutionError {
    self.fail(.arithmetic, "division by zero", .{});
    return error.DivisionByZero;
}

fn typeMismatch(self: *Executor, comptime message: []const u8) ExecutionError {
    self.fail(.type_mismatch, message, .{});
    return error.TypeMismatch;
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

fn deletedEntity(self: *Executor, kind: []const u8, property: []const u8) ExecutionError {
    self.fail(.invalid_expression, "cannot read property '{s}' of a deleted {s}", .{ property, kind });
    return error.InvalidExpression;
}
