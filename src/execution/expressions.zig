//! Expression evaluation: literals, variables, property access, operators
//! with three-valued (null) logic, CASE, IN and size().

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const BinOp = @import("../query/ast.zig").BinOp;
const UnOp = @import("../query/ast.zig").UnOp;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");
const ExecError = Executor.ExecError;

const Bindings = @import("bindings.zig").Bindings;

/// Evaluates a non-negative integer literal (used by SKIP and LIMIT).
pub fn evalCountExpr(self: *Executor, expr: Index) ExecError!usize {
    var empty = Bindings{ .entries = .empty };
    return switch (try eval(self, expr, &empty)) {
        .int => |n| if (n < 0) 0 else @as(usize, @intCast(n)),
        else => 0,
    };
}

pub fn evalBool(self: *Executor, expr: Index, bindings: *Bindings) ExecError!bool {
    return switch (try eval(self, expr, bindings)) {
        .boolean => |b| b,
        .null => false, // a null predicate filters the row out
        else => error.TypeMismatch,
    };
}

/// True if `needle` equals any element of the `list_literal` node. A null
/// needle matches nothing (`null IN [...]` is null, treated as false here).
pub fn inList(self: *Executor, needle: Value, list_node: Index, bindings: *Bindings) ExecError!bool {
    if (Value.isNull(needle)) return false;
    for (self.ast.nodeChildren(list_node)) |item| {
        const v = try eval(self, item, bindings);
        if (Value.eql(needle, v)) return true;
    }
    return false;
}

pub fn eval(self: *Executor, expr: Index, bindings: *Bindings) ExecError!Value {
    return switch (self.ast.kind(expr)) {
        .int_literal => .{ .int = self.ast.data(expr).int },
        .string_literal => .{ .str = self.ast.data(expr).text },
        .bool_literal => .{ .boolean = self.ast.data(expr).boolean },
        .list_literal => blk: {
            var items = std.ArrayList(Value).empty;
            for (self.ast.nodeChildren(expr)) |item| {
                try items.append(self.allocator, try eval(self, item, bindings));
            }
            break :blk .{ .list = items.items };
        },
        .size_fn => blk: {
            const v = try eval(self, self.ast.nodeChildren(expr)[0], bindings);
            const n: usize = switch (v) {
                .list => |items| items.len,
                .str => |s| s.len,
                .null => return error.TypeMismatch,
                else => return error.TypeMismatch,
            };
            break :blk .{ .int = @intCast(n) };
        },
        .case_expr => blk: {
            const kids = self.ast.nodeChildren(expr);
            const else_present = (kids.len % 2) == 1;
            const num_pairs = kids.len / 2;
            var p: usize = 0;
            while (p < num_pairs) : (p += 1) {
                if (try evalBool(self, kids[p * 2], bindings)) {
                    break :blk try eval(self, kids[p * 2 + 1], bindings);
                }
            }
            if (else_present) {
                break :blk try eval(self, kids[kids.len - 1], bindings);
            }
            break :blk .{ .null = {} };
        },
        .variable => blk: {
            const name = self.ast.data(expr).text;
            switch (bindings.get(name) orelse {
                self.fail(.unknown_var, "unknown variable '{s}'", .{name});
                return error.UnknownVar;
            }) {
                .value => |v| break :blk v,
                .node, .edge => return error.TypeMismatch,
            }
        },
        .property_access => blk: {
            const obj = self.ast.nodeChildren(expr)[0];
            if (self.ast.kind(obj) != .variable) return error.InvalidExpr;
            const name = self.ast.data(obj).text;
            const prop = self.ast.data(expr).text;
            switch (bindings.get(name) orelse {
                self.fail(.unknown_var, "unknown variable '{s}'", .{name});
                return error.UnknownVar;
            }) {
                .node => |id| {
                    const v = (try self.graph.getProp(id, prop, self.allocator)) orelse {
                        self.fail(.missing_prop, "node has no property '{s}'", .{prop});
                        return error.MissingProp;
                    };
                    break :blk v;
                },
                .edge => |e| {
                    const v = (try self.graph.getEdgeProp(e.src, e.dst, e.etype, prop, self.allocator)) orelse {
                        self.fail(.missing_prop, "relationship has no property '{s}'", .{prop});
                        return error.MissingProp;
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
        .binary_op => blk: {
            const op = self.ast.data(expr).bin_op;
            const kids = self.ast.nodeChildren(expr);
            if (op == .in_) {
                // RHS is a list literal, not a scalar value.
                const l = try eval(self, kids[0], bindings);
                break :blk .{ .boolean = try inList(self, l, kids[1], bindings) };
            }
            const l = try eval(self, kids[0], bindings);
            const r = try eval(self, kids[1], bindings);
            break :blk try applyBinOp(op, l, r);
        },
        .unary_op => blk: {
            const op = self.ast.data(expr).un_op;
            const v = try eval(self, self.ast.nodeChildren(expr)[0], bindings);
            break :blk try applyUnOp(op, v);
        },
        else => error.InvalidExpr,
    };
}

pub fn applyBinOp(op: BinOp, l: Value, r: Value) ExecError!Value {
    return switch (op) {
        .eq, .ne, .lt, .gt, .le, .ge, .starts_with, .ends_with, .contains => blk: {
            // Three-valued logic: any null operand yields null.
            if (Value.isNull(l) or Value.isNull(r)) break :blk .{ .null = {} };
            break :blk switch (op) {
                .eq => .{ .boolean = Value.eql(l, r) },
                .ne => .{ .boolean = !Value.eql(l, r) },
                .lt, .gt, .le, .ge => blk2: {
                    const li = try asInt(l);
                    const ri = try asInt(r);
                    break :blk2 .{ .boolean = switch (op) {
                        .lt => li < ri,
                        .gt => li > ri,
                        .le => li <= ri,
                        .ge => li >= ri,
                        else => unreachable,
                    } };
                },
                .starts_with, .ends_with, .contains => blk2: {
                    const ls = try asStr(l);
                    const rs = try asStr(r);
                    break :blk2 .{ .boolean = switch (op) {
                        .starts_with => std.mem.startsWith(u8, ls, rs),
                        .ends_with => std.mem.endsWith(u8, ls, rs),
                        .contains => std.mem.indexOf(u8, ls, rs) != null,
                        else => unreachable,
                    } };
                },
                else => unreachable,
            };
        },
        .and_ => blk: {
            const lb = try asBoolOpt(l);
            const rb = try asBoolOpt(r);
            if (lb == false or rb == false) break :blk .{ .boolean = false };
            if (lb == null or rb == null) break :blk .{ .null = {} };
            break :blk .{ .boolean = true };
        },
        .or_ => blk: {
            const lb = try asBoolOpt(l);
            const rb = try asBoolOpt(r);
            if (lb == true or rb == true) break :blk .{ .boolean = true };
            if (lb == null or rb == null) break :blk .{ .null = {} };
            break :blk .{ .boolean = false };
        },
        .in_ => unreachable, // handled in `eval` (RHS is a list literal)
    };
}

pub fn applyUnOp(op: UnOp, v: Value) ExecError!Value {
    return switch (op) {
        .not_ => if (Value.isNull(v)) .{ .null = {} } else .{ .boolean = !try asBool(v) },
    };
}

pub fn asInt(v: Value) ExecError!i64 {
    return switch (v) {
        .int => |n| n,
        else => error.TypeMismatch,
    };
}

pub fn asStr(v: Value) ExecError![]const u8 {
    return switch (v) {
        .str => |s| s,
        else => error.TypeMismatch,
    };
}

pub fn asBool(v: Value) ExecError!bool {
    return switch (v) {
        .boolean => |b| b,
        else => error.TypeMismatch,
    };
}

/// Three-valued boolean coercion: `null` for null, an error for non-boolean.
pub fn asBoolOpt(v: Value) ExecError!?bool {
    return switch (v) {
        .boolean => |b| b,
        .null => null,
        else => error.TypeMismatch,
    };
}
