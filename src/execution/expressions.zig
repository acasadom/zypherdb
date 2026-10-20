//! Expression evaluation: literals, variables, property access, operators
//! with three-valued (null) logic, CASE, IN and size().

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const BinaryOperator = @import("../query/ast.zig").BinaryOperator;
const UnaryOperator = @import("../query/ast.zig").UnaryOperator;
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const mapOf = @import("../value.zig").mapOf;
const formatFloat = @import("../value.zig").formatFloat;
const comparison = @import("comparison.zig");
const temporal_functions = @import("temporal_functions.zig");

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
        } else if (comparison.equals(needle, item)) |same| {
            if (same) return .{ .boolean = true };
        } else {
            unknown = true;
        }
    }
    return if (unknown) .{ .null = {} } else .{ .boolean = false };
}

pub fn evaluate(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!Value {
    if (self.expression_overrides) |overrides| {
        if (overrides.get(expr)) |value| return value;
    }
    return switch (self.ast.kind(expr)) {
        .integer_literal => .{ .int = self.ast.data(expr).int },
        .float_literal => .{ .float = self.ast.data(expr).float },
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
            const object = try evaluate(self, self.ast.nodeChildren(expr)[0], bindings);
            break :blk try propertyOf(self, object, self.ast.data(expr).text);
        },
        .list_comprehension => listComprehension(self, expr, bindings),
        .quantifier => quantifier(self, expr, bindings),
        .map_literal => blk: {
            const property_nodes = self.ast.nodeChildren(expr);
            const entries = try self.allocator.alloc(MapEntry, property_nodes.len);
            for (entries, property_nodes) |*entry, property_node| {
                entry.* = .{ .key = self.ast.data(property_node).text, .value = try evaluate(self, self.ast.nodeChildren(property_node)[0], bindings) };
            }
            break :blk mapOf(entries);
        },
        .subscript => blk: {
            const children = self.ast.nodeChildren(expr);
            break :blk try subscript(self, try evaluate(self, children[0], bindings), try evaluate(self, children[1], bindings));
        },
        .slice => blk: {
            const children = self.ast.nodeChildren(expr);
            break :blk try slice(self, try evaluate(self, children[0], bindings), try evaluate(self, children[1], bindings), try evaluate(self, children[2], bindings));
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

/// The list a comprehension or quantifier iterates: null stays null.
fn iterationList(self: *Executor, list_expression: Index, bindings: *Bindings) ExecutionError!?[]const Value {
    return switch (try evaluate(self, list_expression, bindings)) {
        .list => |items| items,
        .null => null,
        else => typeMismatch(self, "IN of a comprehension or quantifier needs a list"),
    };
}

/// A scope for the iteration variable: a copy of the bindings, so the
/// variable may shadow an outer one without touching it.
fn iterationScope(self: *Executor, bindings: *const Bindings) ExecutionError!Bindings {
    var scope = Bindings{ .entries = .empty };
    try scope.entries.appendSlice(self.allocator, bindings.entries.items);
    return scope;
}

/// `[x IN list WHERE predicate | projection]`.
fn listComprehension(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!Value {
    const children = self.ast.nodeChildren(expr);
    const items = try iterationList(self, children[0], bindings) orelse return .{ .null = {} };
    const variable_name = self.ast.data(expr).text;
    var scope = try iterationScope(self, bindings);
    var output = std.ArrayList(Value).empty;
    for (items) |item| {
        try scope.put(self.allocator, variable_name, item);
        if (!try evaluateBool(self, children[1], &scope)) continue;
        try output.append(self.allocator, try evaluate(self, children[2], &scope));
    }
    return .{ .list = output.items };
}

/// `any` / `all` / `none` / `single(x IN list WHERE predicate)`, with
/// three-valued logic: a null predicate result makes the answer null unless
/// the other elements already decide it.
fn quantifier(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!Value {
    const children = self.ast.nodeChildren(expr);
    const items = try iterationList(self, children[0], bindings) orelse return .{ .null = {} };
    const data = self.ast.data(expr).quantifier;
    var scope = try iterationScope(self, bindings);
    var trues: usize = 0;
    var nulls: usize = 0;
    for (items) |item| {
        try scope.put(self.allocator, data.variable_name, item);
        switch (try evaluate(self, children[1], &scope)) {
            .boolean => |b| if (b) {
                trues += 1;
            },
            .null => nulls += 1,
            else => return typeMismatch(self, "a quantifier's WHERE must be a boolean"),
        }
    }
    const falses = items.len - trues - nulls;
    const answer: ?bool = switch (data.kind) {
        .any => if (trues > 0) true else if (nulls > 0) null else false,
        .all => if (falses > 0) false else if (nulls > 0) null else true,
        .none => if (trues > 0) false else if (nulls > 0) null else true,
        .single => if (trues > 1) false else if (nulls > 0) null else trues == 1,
    };
    return if (answer) |b| .{ .boolean = b } else .{ .null = {} };
}

/// `object.key`: a node's or relationship's property, or a map's entry; null
/// when missing (or when `object` is null). Reading a property of an entity
/// the query deleted is an error (openCypher's EntityNotFound).
pub fn propertyOf(self: *Executor, object: Value, key: []const u8) ExecutionError!Value {
    switch (object) {
        .null => return .{ .null = {} },
        .map => |entries| return Value.mapGet(entries, key),
        .node => |id| {
            if (try self.graph.getProperty(id, key, self.allocator)) |value| return value;
            if (!try self.graph.hasNode(id)) return deletedEntity(self, "node", key);
            return .{ .null = {} };
        },
        .relationship => |r| {
            if (try self.graph.getEdgeProperty(r.src, r.dst, r.edge_type, key, self.allocator)) |value| return value;
            if (!try self.graph.hasEdge(r.src, r.dst, r.edge_type)) return deletedEntity(self, "relationship", key);
            return .{ .null = {} };
        },
        else => {
            if (try temporal_functions.component(self, object, key)) |value| return value;
            return typeMismatch(self, "only nodes, relationships, maps and temporal values have properties");
        },
    }
}

/// `value[index]`: a list element (a negative index counts from the end; out
/// of range is null), or a map entry / entity property by a string key.
fn subscript(self: *Executor, value: Value, index: Value) ExecutionError!Value {
    if (value.isNull() or index.isNull()) return .{ .null = {} };
    switch (value) {
        .list => |items| {
            if (index != .int) return typeMismatch(self, "a list index must be an integer");
            const position = listPosition(index.int, items.len) orelse return .{ .null = {} };
            return items[position];
        },
        .map, .node, .relationship => {
            if (index != .string) return typeMismatch(self, "a map or entity key must be a string");
            return propertyOf(self, value, index.string);
        },
        else => return typeMismatch(self, "only lists, maps and entities can be indexed"),
    }
}

/// `list[from..to]`: the elements from `from` (inclusive) to `to`
/// (exclusive); negative bounds count from the end, a null bound is open,
/// and bounds are clamped to the list.
fn slice(self: *Executor, value: Value, from: Value, to: Value) ExecutionError!Value {
    if (value.isNull()) return .{ .null = {} };
    if (value != .list) return typeMismatch(self, "only lists can be sliced");
    const items = value.list;
    const length: i64 = @intCast(items.len);
    const start = try sliceBound(self, from, 0, length);
    const end = try sliceBound(self, to, length, length);
    if (start >= end) return .{ .list = &.{} };
    return .{ .list = items[@intCast(start)..@intCast(end)] };
}

fn sliceBound(self: *Executor, bound: Value, open: i64, length: i64) ExecutionError!i64 {
    const raw = switch (bound) {
        .null => return open,
        .int => |n| n,
        else => return typeMismatch(self, "slice bounds must be integers"),
    };
    const resolved = if (raw < 0) length + raw else raw;
    return std.math.clamp(resolved, 0, length);
}

/// The position of `index` in a list of `length`, counting from the end when
/// negative; null when out of range.
fn listPosition(index: i64, length: usize) ?usize {
    const signed_length: i64 = @intCast(length);
    const resolved = if (index < 0) signed_length + index else index;
    if (resolved < 0 or resolved >= signed_length) return null;
    return @intCast(resolved);
}

pub fn applyBinaryOperator(self: *Executor, operator: BinaryOperator, left: Value, right: Value) ExecutionError!Value {
    return switch (operator) {
        .add, .subtract, .multiply, .divide, .modulo, .power => arithmetic(self, operator, left, right),
        .equal, .not_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .starts_with, .ends_with, .contains => blk: {
            // Three-valued logic: any null operand yields null.
            if (Value.isNull(left) or Value.isNull(right)) break :blk .{ .null = {} };
            break :blk switch (operator) {
                .equal => if (comparison.equals(left, right)) |same| .{ .boolean = same } else .{ .null = {} },
                .not_equal => if (comparison.equals(left, right)) |same| .{ .boolean = !same } else .{ .null = {} },
                .less_than => comparison.compare(left, right).holds(isLess),
                .greater_than => comparison.compare(left, right).holds(isGreater),
                .less_or_equal => comparison.compare(left, right).holds(isLessOrEqual),
                .greater_or_equal => comparison.compare(left, right).holds(isGreaterOrEqual),
                .starts_with, .ends_with, .contains => string_test: {
                    const left_string = asString(left) catch break :string_test .{ .null = {} };
                    const right_string = asString(right) catch break :string_test .{ .null = {} };
                    break :string_test .{ .boolean = switch (operator) {
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

fn isLess(o: std.math.Order) bool {
    return o == .lt;
}
fn isGreater(o: std.math.Order) bool {
    return o == .gt;
}
fn isLessOrEqual(o: std.math.Order) bool {
    return o != .gt;
}
fn isGreaterOrEqual(o: std.math.Order) bool {
    return o != .lt;
}

pub fn applyUnaryOperator(self: *Executor, operator: UnaryOperator, value: Value) ExecutionError!Value {
    return switch (operator) {
        .not_ => if (Value.isNull(value)) .{ .null = {} } else .{ .boolean = !try asBool(value) },
        .is_null => .{ .boolean = value.isNull() },
        .is_not_null => .{ .boolean = !value.isNull() },
        .negate => switch (value) {
            .null => .{ .null = {} },
            .int => |n| .{ .int = std.math.negate(n) catch return overflow(self) },
            .float => |x| .{ .float = -x },
            else => typeMismatch(self, "unary minus needs a number"),
        },
    };
}

/// `+ - * / % ^`. Integers overflow-checked (an error, never a silent
/// wrap-around), `/` truncating toward zero and `%` taking the dividend's
/// sign. With a float operand the result is a float (IEEE 754: dividing by
/// zero gives an infinity or NaN); `^` always gives a float. `+` also
/// concatenates strings (a number is written in decimal) and lists (or adds
/// an element to either end). Null with anything is null.
fn arithmetic(self: *Executor, operator: BinaryOperator, left: Value, right: Value) ExecutionError!Value {
    if (left.isNull() or right.isNull()) return .{ .null = {} };
    if (temporal_functions.isTemporal(left) or temporal_functions.isTemporal(right)) return temporal_functions.arithmetic(self, operator, left, right);
    if (comparison.isNumber(left) and comparison.isNumber(right) and (operator == .power or left == .float or right == .float)) {
        const a = asFloat(left);
        const b = asFloat(right);
        return .{ .float = switch (operator) {
            .add => a + b,
            .subtract => a - b,
            .multiply => a * b,
            .divide => a / b,
            .modulo => if (b == 0) std.math.nan(f64) else @rem(a, b),
            .power => std.math.pow(f64, a, b),
            else => unreachable,
        } };
    }
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
        .float => |x| try formatFloat(self.allocator, x),
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

/// A number as a float (callers check it is a number).
pub fn asFloat(value: Value) f64 {
    return switch (value) {
        .int => |n| @floatFromInt(n),
        .float => |x| x,
        else => unreachable,
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
