//! The expressions of a query, compiled once with its plan: one instruction
//! per AST node, indexed as the AST is, so execution (`execution/
//! expressions.zig`) reads resolved operations instead of AST kinds and
//! names. Constants carry their value, a variable its slot, a parameter its
//! index, a call its function, a constant `=~` pattern its compiled regex,
//! and a pattern or subquery in an expression the chain that runs it.
//!
//! Indexing by AST node keeps what is keyed by node working unchanged (the
//! values that replace an aggregate's sub-expressions, diagnostics). A node
//! that is not an expression gets `invalid`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast_module = @import("../query/ast.zig");
const Ast = ast_module.Ast;
const Index = ast_module.Index;
const Slot = @import("../execution/bindings.zig").Slot;
const no_slot = @import("../execution/bindings.zig").no_slot;
const functions = @import("../execution/functions.zig");
const regex = @import("../text/regex.zig");

pub const Instruction = struct {
    /// The expressions the operation reads (a map literal: its values).
    operands: []const Index = &.{},
    operation: Operation = .invalid,
};

pub const Operation = union(enum) {
    invalid,
    integer_constant: i64,
    float_constant: f64,
    string_constant: []const u8,
    boolean_constant: bool,
    null_constant,
    slot: Slot,
    /// An index into `Program.parameter_names` (and the run's values).
    parameter: u32,
    /// `object.name`, the object being any expression.
    property: []const u8,
    /// `variable.name`: the variable's slot is read directly.
    slot_property: struct { slot: Slot, name: []const u8 },
    call: functions.Function,
    /// `regex` is the compiled pattern of `=~` when it is a valid constant.
    binary: struct { operator: ast_module.BinaryOperator, regex: ?regex.Regex = null },
    unary: ast_module.UnaryOperator,
    // Operations with temporaries of their own (see `evaluateComplex`).
    list,
    map: []const []const u8,
    labels: []const []const u8,
    case_,
    simple_case,
    subscript,
    /// Which bounds were written (bit 0: from, bit 1: to).
    slice: i64,
    comprehension,
    quantifier,
    map_projection,
    /// A pattern or subquery inside an expression, run by `chain`.
    subplan: struct { chain: u32, kind: SubplanKind },
};

pub const SubplanKind = enum { exists, count, list };

pub const Program = struct {
    instructions: []const Instruction,
    /// The query's parameters, in order of first appearance.
    parameter_names: []const []const u8,

    pub const empty: Program = .{ .instructions = &.{}, .parameter_names = &.{} };

    /// Compiles every expression node of `ast`. `slot_of` and `chains` are
    /// the plan's (empty for a schema command, which has no variables).
    /// O(nodes); each constant regex is compiled once.
    pub fn compile(allocator: Allocator, ast: *const Ast, slot_of: []const Slot, chains: *const std.AutoHashMapUnmanaged(Index, u32)) Allocator.Error!Program {
        const instructions = try allocator.alloc(Instruction, ast.nodes.items.len);
        var parameters = std.StringHashMapUnmanaged(u32).empty;
        var names = std.ArrayList([]const u8).empty;
        for (instructions, 0..) |*instruction, position| {
            const node: Index = @intCast(position);
            const children = ast.nodeChildren(node);
            const data = ast.data(node);
            instruction.* = .{ .operands = children };
            instruction.operation = switch (ast.kind(node)) {
                .integer_literal => .{ .integer_constant = data.int },
                .float_literal => .{ .float_constant = data.float },
                .string_literal => .{ .string_constant = data.text },
                .boolean_literal => .{ .boolean_constant = data.boolean },
                .null_literal => .null_constant,
                .variable => .{ .slot = slotAt(slot_of, node) },
                .parameter => parameter: {
                    const entry = try parameters.getOrPut(allocator, data.text);
                    if (!entry.found_existing) {
                        entry.value_ptr.* = @intCast(names.items.len);
                        try names.append(allocator, data.text);
                    }
                    break :parameter .{ .parameter = entry.value_ptr.* };
                },
                .property_access => if (ast.kind(children[0]) == .variable)
                    .{ .slot_property = .{ .slot = slotAt(slot_of, children[0]), .name = data.text } }
                else
                    .{ .property = data.text },
                .function_call => if (functions.resolve(data.text)) |function| .{ .call = function } else .invalid,
                .binary_operation => .{ .binary = .{ .operator = data.binary_operator, .regex = try constantRegex(allocator, ast, node) } },
                .unary_operation => .{ .unary = data.unary_operator },
                .list_literal => .list,
                .map_literal => map: {
                    const keys = try allocator.alloc([]const u8, children.len);
                    const values = try allocator.alloc(Index, children.len);
                    for (keys, values, children) |*key, *value, entry| {
                        key.* = ast.data(entry).text;
                        value.* = ast.nodeChildren(entry)[0];
                    }
                    instruction.operands = values;
                    break :map .{ .map = keys };
                },
                .label_predicate => .{ .labels = data.labels },
                .case_expression => .case_,
                .simple_case_expression => .simple_case,
                .subscript => .subscript,
                .slice => .{ .slice = if (data == .int) data.int else 0 },
                .list_comprehension => .comprehension,
                .quantifier => .quantifier,
                .map_projection => .map_projection,
                .pattern_predicate, .exists_subquery, .count_subquery, .pattern_comprehension => if (chains.get(node)) |chain| .{ .subplan = .{
                    .chain = chain,
                    .kind = switch (ast.kind(node)) {
                        .count_subquery => .count,
                        .pattern_comprehension => .list,
                        else => .exists,
                    },
                } } else .invalid,
                else => .invalid,
            };
        }
        return .{ .instructions = instructions, .parameter_names = names.items };
    }
};

fn slotAt(slot_of: []const Slot, node: Index) Slot {
    return if (node < slot_of.len) slot_of[node] else no_slot;
}

/// The compiled pattern of `text =~ 'constant'`, or null: another operator,
/// a pattern that is not a constant, or an invalid one (which keeps failing
/// when, and only if, it is evaluated: a CASE branch never taken must not).
fn constantRegex(allocator: Allocator, ast: *const Ast, node: Index) Allocator.Error!?regex.Regex {
    if (ast.data(node).binary_operator != .regex_match) return null;
    const pattern = ast.nodeChildren(node)[1];
    if (ast.kind(pattern) != .string_literal) return null;
    var problem = regex.Problem{};
    return regex.Regex.compile(allocator, ast.data(pattern).text, &problem) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidRegex => null,
    };
}
