//! Expression grammar of the openCypher subset, by precedence (lowest
//! first): OR, AND, NOT, comparisons (incl. STARTS WITH / ENDS WITH /
//! CONTAINS / IN), then primaries (literals, variables, property access,
//! lists, CASE, size() and aggregate calls).

const std = @import("std");

const Index = @import("ast.zig").Index;
const BinaryOperator = @import("ast.zig").BinaryOperator;
const AggregateKind = @import("ast.zig").AggregateKind;
const describeToken = @import("lexer.zig").describeToken;

const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;

pub fn parseExpression(self: *Parser) ParseError!Index {
    return parseOr(self);
}

pub fn parseOr(self: *Parser) ParseError!Index {
    var lhs = try parseAnd(self);
    while (self.atKeyword("OR")) {
        _ = self.advance();
        const rhs = try parseAnd(self);
        lhs = try self.ast.addNode(.binary_operation, .{ .binary_operator = .or_ }, &.{ lhs, rhs });
    }
    return lhs;
}

pub fn parseAnd(self: *Parser) ParseError!Index {
    var lhs = try parseNot(self);
    while (self.atKeyword("AND")) {
        _ = self.advance();
        const rhs = try parseNot(self);
        lhs = try self.ast.addNode(.binary_operation, .{ .binary_operator = .and_ }, &.{ lhs, rhs });
    }
    return lhs;
}

pub fn parseNot(self: *Parser) ParseError!Index {
    if (self.atKeyword("NOT")) {
        _ = self.advance();
        const operand = try parseNot(self);
        return self.ast.addNode(.unary_operation, .{ .unary_operator = .not_ }, &.{operand});
    }
    return parseComparison(self);
}

pub fn parseComparison(self: *Parser) ParseError!Index {
    const lhs = try parsePrimary(self);

    // Multi-word string predicates (checked before the single-token ops,
    // since `STARTS`/`ENDS`/`CONTAINS`/`IN` lex as plain identifiers).
    if (self.atKeyword("STARTS")) {
        _ = self.advance();
        try self.expectKeyword("WITH");
        const rhs = try parsePrimary(self);
        return self.ast.addNode(.binary_operation, .{ .binary_operator = .starts_with }, &.{ lhs, rhs });
    }
    if (self.atKeyword("ENDS")) {
        _ = self.advance();
        try self.expectKeyword("WITH");
        const rhs = try parsePrimary(self);
        return self.ast.addNode(.binary_operation, .{ .binary_operator = .ends_with }, &.{ lhs, rhs });
    }
    if (self.atKeyword("CONTAINS")) {
        _ = self.advance();
        const rhs = try parsePrimary(self);
        return self.ast.addNode(.binary_operation, .{ .binary_operator = .contains }, &.{ lhs, rhs });
    }
    if (self.atKeyword("IN")) {
        _ = self.advance();
        const list = try parsePrimary(self); // any expression yielding a list
        return self.ast.addNode(.binary_operation, .{ .binary_operator = .in_ }, &.{ lhs, list });
    }

    const operator: ?BinaryOperator = switch (self.peek().kind) {
        .equal => .equal,
        .not_equal => .not_equal,
        .less_than => .less_than,
        .greater_than => .greater_than,
        .less_or_equal => .less_or_equal,
        .greater_or_equal => .greater_or_equal,
        else => null,
    };
    if (operator) |o| {
        _ = self.advance();
        const rhs = try parsePrimary(self);
        return self.ast.addNode(.binary_operation, .{ .binary_operator = o }, &.{ lhs, rhs });
    }
    return lhs;
}

/// Parses a list literal `[e0, e1, ...]` (elements are primary expressions;
/// the empty list is allowed).
pub fn parseListLiteral(self: *Parser) ParseError!Index {
    try self.expect(.left_bracket);
    var items = std.ArrayList(Index).empty;
    defer items.deinit(self.ast.allocator);
    while (!self.at(.right_bracket)) {
        try items.append(self.ast.allocator, try parsePrimary(self));
        if (self.at(.comma)) {
            _ = self.advance();
        } else break;
    }
    try self.expect(.right_bracket);
    return self.ast.addNode(.list_literal, .{ .none = {} }, items.items);
}

pub fn parsePrimary(self: *Parser) ParseError!Index {
    if (self.atKeyword("CASE")) return parseCaseExpression(self);
    const t = self.peek();
    switch (t.kind) {
        .integer => {
            _ = self.advance();
            const v = std.fmt.parseInt(i64, t.text, 10) catch {
                self.fail("integer literal {s} does not fit in 64 bits", .{t.text});
                return error.UnexpectedToken;
            };
            return self.ast.addNode(.integer_literal, .{ .int = v }, &.{});
        },
        .string => {
            _ = self.advance();
            const s = try self.internString(t.text);
            return self.ast.addNode(.string_literal, .{ .text = s }, &.{});
        },
        .parameter => {
            _ = self.advance();
            return self.ast.addNode(.parameter, .{ .text = try self.ast.intern(t.text) }, &.{});
        },
        .identifier => if (t.quoted) {
            _ = self.advance();
            return parseVariableRef(self, t.text);
        } else {
            _ = self.advance();
            if (std.ascii.eqlIgnoreCase(t.text, "true")) return self.ast.addNode(.boolean_literal, .{ .boolean = true }, &.{});
            if (std.ascii.eqlIgnoreCase(t.text, "false")) return self.ast.addNode(.boolean_literal, .{ .boolean = false }, &.{});
            if (std.ascii.eqlIgnoreCase(t.text, "null")) return self.ast.addNode(.null_literal, .{ .none = {} }, &.{});
            if (aggregateKindFromName(t.text)) |kind| {
                if (self.at(.left_paren)) {
                    return parseAggregateCall(self, kind);
                }
            }
            if (self.at(.left_paren)) return parseFunctionCall(self, t.text);
            return parseVariableRef(self, t.text);
        },
        .left_bracket => return parseListLiteral(self),
        .left_paren => {
            _ = self.advance();
            const e = try parseExpression(self);
            try self.expect(.right_paren);
            return e;
        },
        else => {
            self.fail("expected an expression, found {s}", .{describeToken(t)});
            return error.UnexpectedToken;
        },
    }
}

/// A function call `name(argument, ...)` (the name is already consumed).
/// Which functions exist, and their arity, is checked before execution.
fn parseFunctionCall(self: *Parser, name: []const u8) ParseError!Index {
    try self.expect(.left_paren);
    var arguments = std.ArrayList(Index).empty;
    defer arguments.deinit(self.ast.allocator);
    if (!self.at(.right_paren)) {
        try arguments.append(self.ast.allocator, try parseExpression(self));
        while (self.at(.comma)) {
            _ = self.advance();
            try arguments.append(self.ast.allocator, try parseExpression(self));
        }
    }
    try self.expect(.right_paren);
    return self.ast.addNode(.function_call, .{ .text = try self.ast.intern(name) }, arguments.items);
}

/// A variable, optionally followed by `.property` (the name is already consumed).
pub fn parseVariableRef(self: *Parser, text: []const u8) ParseError!Index {
    const name = try self.ast.intern(text);
    const var_node = try self.ast.addNode(.variable, .{ .text = name }, &.{});
    if (self.at(.dot)) {
        _ = self.advance();
        const property = try self.internIdentifier();
        return self.ast.addNode(.property_access, .{ .text = property }, &.{var_node});
    }
    return var_node;
}

pub fn parseCaseExpression(self: *Parser) ParseError!Index {
    _ = self.advance(); // CASE
    var children = std.ArrayList(Index).empty;
    defer children.deinit(self.ast.allocator);
    while (self.atKeyword("WHEN")) {
        _ = self.advance();
        const cond = try parseExpression(self);
        try self.expectKeyword("THEN");
        const result = try parseExpression(self);
        try children.append(self.ast.allocator, cond);
        try children.append(self.ast.allocator, result);
    }
    if (self.atKeyword("ELSE")) {
        _ = self.advance();
        try children.append(self.ast.allocator, try parseExpression(self));
    }
    try self.expectKeyword("END");
    return self.ast.addNode(.case_expression, .{ .none = {} }, children.items);
}

pub fn parseAggregateCall(self: *Parser, kind: AggregateKind) ParseError!Index {
    try self.expect(.left_paren);
    if (kind == .count and self.at(.star)) {
        _ = self.advance();
        try self.expect(.right_paren);
        return self.ast.addNode(.aggregate, .{ .aggregate = kind }, &.{});
    }
    const arg = try parseExpression(self);
    try self.expect(.right_paren);
    return self.ast.addNode(.aggregate, .{ .aggregate = kind }, &.{arg});
}

fn aggregateKindFromName(name: []const u8) ?AggregateKind {
    if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(name, "min")) return .min;
    if (std.ascii.eqlIgnoreCase(name, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(name, "collect")) return .collect;
    return null;
}
