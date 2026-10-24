//! Cypher text of a part of the AST: an expression, a pattern, a
//! projection, a SET or DELETE item. EXPLAIN shows it as an operator's
//! details. The text is canonical, not the source as written: keywords in
//! upper case, single-quoted strings, parentheses only where precedence
//! needs them, and `{…}` for the body of a subquery.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("ast.zig").Ast;
const Index = @import("ast.zig").Index;
const BinaryOperator = @import("ast.zig").BinaryOperator;
const formatFloat = @import("../value.zig").formatFloat;

/// The text of `node`, allocated with `allocator`.
pub fn text(ast: *const Ast, allocator: Allocator, node: Index) Allocator.Error![]const u8 {
    var printer = Printer{ .ast = ast, .allocator = allocator };
    try printer.write(node);
    return printer.output.items;
}

/// The text of each of `nodes`, joined by `separator`.
pub fn joined(ast: *const Ast, allocator: Allocator, nodes: []const Index, separator: []const u8) Allocator.Error![]const u8 {
    var printer = Printer{ .ast = ast, .allocator = allocator };
    try printer.list(nodes, separator);
    return printer.output.items;
}

pub const Printer = struct {
    ast: *const Ast,
    allocator: Allocator,
    output: std.ArrayList(u8) = .empty,

    pub fn append(self: *Printer, piece: []const u8) Allocator.Error!void {
        try self.output.appendSlice(self.allocator, piece);
    }

    fn print(self: *Printer, comptime format: []const u8, arguments: anytype) Allocator.Error!void {
        try self.output.print(self.allocator, format, arguments);
    }

    pub fn list(self: *Printer, nodes: []const Index, separator: []const u8) Allocator.Error!void {
        for (nodes, 0..) |node, position| {
            if (position > 0) try self.append(separator);
            try self.write(node);
        }
    }

    /// A name, in backticks unless it is a plain identifier (none for the
    /// empty name of an anonymous element).
    pub fn name(self: *Printer, identifier: []const u8) Allocator.Error!void {
        if (identifier.len == 0) return;
        if (isPlainIdentifier(identifier)) return self.append(identifier);
        try self.append("`");
        for (identifier) |byte| {
            if (byte == '`') try self.append("`");
            try self.output.append(self.allocator, byte);
        }
        try self.append("`");
    }

    /// `node`, in parentheses if it binds less tightly than `context`.
    fn operand(self: *Printer, node: Index, context: u8) Allocator.Error!void {
        const parenthesized = precedence(self.ast, node) < context;
        if (parenthesized) try self.append("(");
        try self.write(node);
        if (parenthesized) try self.append(")");
    }

    pub fn write(self: *Printer, node: Index) Allocator.Error!void {
        const ast = self.ast;
        const children = ast.nodeChildren(node);
        switch (ast.kind(node)) {
            .variable => try self.name(ast.data(node).text),
            .property_access => {
                try self.operand(children[0], postfix_precedence);
                try self.append(".");
                try self.name(ast.data(node).text);
            },
            .integer_literal => try self.print("{d}", .{ast.data(node).int}),
            .float_literal => try self.append(try formatFloat(self.allocator, ast.data(node).float)),
            .string_literal => try self.string(ast.data(node).text),
            .boolean_literal => try self.append(if (ast.data(node).boolean) "true" else "false"),
            .null_literal => try self.append("null"),
            .parameter => {
                try self.append("$");
                try self.name(ast.data(node).text);
            },
            .list_literal => {
                try self.append("[");
                try self.list(children, ", ");
                try self.append("]");
            },
            .map_literal => {
                try self.append("{");
                try self.list(children, ", ");
                try self.append("}");
            },
            .property => {
                try self.name(ast.data(node).text);
                try self.append(": ");
                try self.write(children[0]);
            },
            .subscript => {
                try self.operand(children[0], postfix_precedence);
                try self.append("[");
                try self.write(children[1]);
                try self.append("]");
            },
            .slice => {
                const written = ast.data(node).int;
                try self.operand(children[0], postfix_precedence);
                try self.append("[");
                if (written & 1 != 0) try self.write(children[1]);
                try self.append("..");
                if (written & 2 != 0) try self.write(children[2]);
                try self.append("]");
            },
            .list_comprehension => {
                try self.append("[");
                try self.iteration(ast.data(node).text, children[0], children[1]);
                const projection = children[2];
                const keeps_elements = ast.kind(projection) == .variable and std.mem.eql(u8, ast.data(projection).text, ast.data(node).text);
                if (!keeps_elements) {
                    try self.append(" | ");
                    try self.write(projection);
                }
                try self.append("]");
            },
            .quantifier => {
                const quantifier = ast.data(node).quantifier;
                try self.print("{s}(", .{@tagName(quantifier.kind)});
                try self.iteration(quantifier.variable_name, children[0], children[1]);
                try self.append(")");
            },
            .function_call => {
                try self.append(ast.data(node).text);
                try self.append("(");
                try self.list(children, ", ");
                try self.append(")");
            },
            .aggregate => {
                const call = ast.data(node).aggregate;
                try self.print("{s}(", .{@tagName(call.kind)});
                if (call.distinct) try self.append("DISTINCT ");
                if (children.len == 0) try self.append("*") else try self.list(children, ", ");
                try self.append(")");
            },
            .pattern_predicate => try self.write(children[0]),
            .pattern_comprehension => {
                try self.append("[");
                try self.write(children[0]);
                if (!isTrue(ast, children[1])) {
                    try self.append(" WHERE ");
                    try self.write(children[1]);
                }
                try self.append(" | ");
                try self.write(children[2]);
                try self.append("]");
            },
            .exists_subquery => try self.append("EXISTS {…}"),
            .count_subquery => try self.append("COUNT {…}"),
            .case_expression => {
                try self.append("CASE");
                var position: usize = 0;
                while (position + 1 < children.len) : (position += 2) {
                    try self.append(" WHEN ");
                    try self.write(children[position]);
                    try self.append(" THEN ");
                    try self.write(children[position + 1]);
                }
                try self.caseElse(children, position);
            },
            .simple_case_expression => {
                try self.append("CASE ");
                try self.write(children[0]);
                var position: usize = 1;
                while (position + 1 < children.len) : (position += 2) {
                    try self.append(" WHEN ");
                    try self.write(children[position]);
                    try self.append(" THEN ");
                    try self.write(children[position + 1]);
                }
                try self.caseElse(children, position);
            },
            .binary_operation => {
                const operator = ast.data(node).binary_operator;
                const own = binaryPrecedence(operator);
                // `^` groups to the left, as the others do: a right operand of
                // the same precedence needs parentheses.
                try self.operand(children[0], own);
                try self.print(" {s} ", .{binarySymbol(operator)});
                try self.operand(children[1], own + 1);
            },
            .unary_operation => switch (ast.data(node).unary_operator) {
                .not_ => {
                    try self.append("NOT ");
                    try self.operand(children[0], not_precedence);
                },
                .negate => {
                    try self.append("-");
                    try self.operand(children[0], negate_precedence);
                },
                .is_null => {
                    try self.operand(children[0], comparison_precedence + 1);
                    try self.append(" IS NULL");
                },
                .is_not_null => {
                    try self.operand(children[0], comparison_precedence + 1);
                    try self.append(" IS NOT NULL");
                },
            },
            .map_projection => {
                try self.operand(children[0], postfix_precedence);
                try self.append("{");
                try self.list(children[1..], ", ");
                try self.append("}");
            },
            .map_projection_property => {
                try self.append(".");
                try self.name(ast.data(node).text);
            },
            .map_projection_all => try self.append(".*"),
            .label_predicate => {
                try self.operand(children[0], postfix_precedence);
                try self.labels(ast.data(node).labels, ":");
            },
            .pattern => try self.pattern(node),
            .projection => try self.list(children, ", "),
            .projection_item => {
                try self.write(children[0]);
                const alias = ast.data(node).text;
                if (alias.len > 0) {
                    try self.append(" AS ");
                    try self.name(alias);
                }
            },
            .order_by => {
                try self.append("ORDER BY ");
                try self.list(children, ", ");
            },
            .order_item => {
                try self.write(children[0]);
                if (!ast.data(node).order_item.ascending) try self.append(" DESC");
            },
            .skip => {
                try self.append("SKIP ");
                try self.write(children[0]);
            },
            .limit => {
                try self.append("LIMIT ");
                try self.write(children[0]);
            },
            .set_item => {
                try self.write(children[0]);
                try self.append(" = ");
                try self.write(children[1]);
            },
            .set_properties => {
                try self.write(children[0]);
                try self.append(if (ast.data(node).boolean) " += " else " = ");
                try self.write(children[1]);
            },
            .label_reference => {
                try self.write(children[0]);
                try self.append(":");
                try self.name(ast.data(node).text);
            },
            .delete_item => try self.write(children[0]),
            else => try self.append("…"),
        }
    }

    fn caseElse(self: *Printer, children: []const Index, position: usize) Allocator.Error!void {
        if (position < children.len) {
            try self.append(" ELSE ");
            try self.write(children[position]);
        }
        try self.append(" END");
    }

    fn iteration(self: *Printer, variable: []const u8, list_expression: Index, predicate: Index) Allocator.Error!void {
        try self.name(variable);
        try self.append(" IN ");
        try self.write(list_expression);
        if (!isTrue(self.ast, predicate)) {
            try self.append(" WHERE ");
            try self.write(predicate);
        }
    }

    fn string(self: *Printer, value: []const u8) Allocator.Error!void {
        try self.append("'");
        for (value) |byte| switch (byte) {
            '\'' => try self.append("\\'"),
            '\\' => try self.append("\\\\"),
            '\n' => try self.append("\\n"),
            '\t' => try self.append("\\t"),
            else => try self.output.append(self.allocator, byte),
        };
        try self.append("'");
    }

    fn labels(self: *Printer, names: []const []const u8, separator: []const u8) Allocator.Error!void {
        for (names, 0..) |label, position| {
            try self.append(if (position == 0) ":" else separator);
            try self.name(label);
        }
    }

    /// `p = (a:L {k: v})-[r:T|U*1..3]->(b)`, inside `shortestPath(...)` if
    /// it is one.
    pub fn pattern(self: *Printer, node: Index) Allocator.Error!void {
        const ast = self.ast;
        const path_variable = ast.data(node).text;
        if (path_variable.len > 0) {
            try self.name(path_variable);
            try self.append(" = ");
        }
        var shortest: ?[]const u8 = null;
        for (ast.nodeChildren(node)) |element| {
            if (ast.kind(element) != .edge_pattern) continue;
            switch (ast.data(element).edge_pattern.shortest) {
                .none => {},
                .one => shortest = "shortestPath(",
                .all => shortest = "allShortestPaths(",
            }
        }
        if (shortest) |opening| try self.append(opening);
        for (ast.nodeChildren(node)) |element| switch (ast.kind(element)) {
            .node_pattern => try self.nodePattern(element),
            .edge_pattern => try self.edgePattern(element),
            else => {},
        };
        if (shortest != null) try self.append(")");
    }

    pub fn nodePattern(self: *Printer, node: Index) Allocator.Error!void {
        const data = self.ast.data(node).node_pattern;
        try self.append("(");
        if (data.variable_name.len > 0) try self.name(data.variable_name);
        try self.labels(data.labels, ":");
        try self.properties(node, data.variable_name.len > 0 or data.labels.len > 0);
        try self.append(")");
    }

    fn edgePattern(self: *Printer, node: Index) Allocator.Error!void {
        const data = self.ast.data(node).edge_pattern;
        try self.append(if (data.direction == .right_to_left) "<-" else "-");
        const plain = data.variable_name.len == 0 and data.edge_types.len == 0 and !data.variable_length and self.ast.nodeChildren(node).len == 0;
        if (!plain) {
            try self.append("[");
            if (data.variable_name.len > 0) try self.name(data.variable_name);
            try self.labels(data.edge_types, "|");
            if (data.variable_length) try self.hops(data.min_hops, data.max_hops);
            try self.properties(node, data.variable_name.len > 0 or data.edge_types.len > 0 or data.variable_length);
            try self.append("]");
        }
        try self.append(if (data.direction == .left_to_right) "->" else "-");
    }

    /// A variable length: `*` is 1 or more; `*2` exactly 2; `*2..`,
    /// `*..3`, `*2..3` ranges.
    pub fn hops(self: *Printer, min_hops: u32, max_hops: ?u32) Allocator.Error!void {
        try self.append("*");
        if (max_hops == min_hops) return self.print("{d}", .{min_hops});
        if (min_hops == 1 and max_hops == null) return;
        if (min_hops != 1) try self.print("{d}", .{min_hops});
        try self.append("..");
        if (max_hops) |max| try self.print("{d}", .{max});
    }

    /// The `{name: value}` entries of a node or edge pattern, if it has any.
    fn properties(self: *Printer, element: Index, after_something: bool) Allocator.Error!void {
        const entries = self.ast.nodeChildren(element);
        if (entries.len == 0) return;
        if (after_something) try self.append(" ");
        try self.append("{");
        try self.list(entries, ", ");
        try self.append("}");
    }
};

fn isTrue(ast: *const Ast, node: Index) bool {
    return ast.kind(node) == .boolean_literal and ast.data(node).boolean;
}

fn isPlainIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    for (identifier, 0..) |byte, position| {
        const valid = std.ascii.isAlphabetic(byte) or byte == '_' or (position > 0 and std.ascii.isDigit(byte));
        if (!valid) return false;
    }
    return true;
}

const or_precedence = 1;
const xor_precedence = 2;
const and_precedence = 3;
const not_precedence = 4;
const comparison_precedence = 5;
const additive_precedence = 6;
const multiplicative_precedence = 7;
const power_precedence = 8;
const negate_precedence = 9;
const postfix_precedence = 10;
const atom_precedence = 11;

fn binaryPrecedence(operator: BinaryOperator) u8 {
    return switch (operator) {
        .or_ => or_precedence,
        .xor => xor_precedence,
        .and_ => and_precedence,
        .equal, .not_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .starts_with, .ends_with, .contains, .regex_match, .in_ => comparison_precedence,
        .add, .subtract => additive_precedence,
        .multiply, .divide, .modulo => multiplicative_precedence,
        .power => power_precedence,
    };
}

fn precedence(ast: *const Ast, node: Index) u8 {
    return switch (ast.kind(node)) {
        .binary_operation => binaryPrecedence(ast.data(node).binary_operator),
        .unary_operation => switch (ast.data(node).unary_operator) {
            .not_ => not_precedence,
            .negate => negate_precedence,
            .is_null, .is_not_null => comparison_precedence,
        },
        .property_access, .subscript, .slice, .label_predicate, .map_projection => postfix_precedence,
        .integer_literal, .float_literal => if (isNegativeLiteral(ast, node)) negate_precedence else atom_precedence,
        else => atom_precedence,
    };
}

fn isNegativeLiteral(ast: *const Ast, node: Index) bool {
    return switch (ast.kind(node)) {
        .integer_literal => ast.data(node).int < 0,
        .float_literal => ast.data(node).float < 0,
        else => false,
    };
}

fn binarySymbol(operator: BinaryOperator) []const u8 {
    return switch (operator) {
        .equal => "=",
        .not_equal => "<>",
        .less_than => "<",
        .greater_than => ">",
        .less_or_equal => "<=",
        .greater_or_equal => ">=",
        .and_ => "AND",
        .or_ => "OR",
        .xor => "XOR",
        .starts_with => "STARTS WITH",
        .ends_with => "ENDS WITH",
        .contains => "CONTAINS",
        .regex_match => "=~",
        .in_ => "IN",
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .modulo => "%",
        .power => "^",
    };
}
