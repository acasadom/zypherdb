//! Expression grammar, one function per precedence level (loosest first):
//! OR, XOR, AND, NOT, comparisons (chained), predicates (IS NULL, STARTS
//! WITH, ENDS WITH, CONTAINS, IN), + and -, * / %, ^, unary sign, then
//! postfix access (`.key`, `[i]`, `[a..b]`) on atoms.

const std = @import("std");

const Index = @import("ast.zig").Index;
const NodeKind = @import("ast.zig").NodeKind;
const BinaryOperator = @import("ast.zig").BinaryOperator;
const AggregateKind = @import("ast.zig").AggregateKind;
const QuantifierKind = @import("ast.zig").QuantifierKind;
const describeToken = @import("lexer.zig").describeToken;

const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const TokenKind = @import("lexer.zig").TokenKind;

pub fn parseExpression(self: *Parser) ParseError!Index {
    return parseOr(self);
}

pub fn parseOr(self: *Parser) ParseError!Index {
    var lhs = try parseXor(self);
    while (self.atKeyword("OR")) {
        _ = self.advance();
        const rhs = try parseXor(self);
        lhs = try self.ast.addNode(.binary_operation, .{ .binary_operator = .or_ }, &.{ lhs, rhs });
    }
    return lhs;
}

/// `XOR` binds between `OR` and `AND`.
fn parseXor(self: *Parser) ParseError!Index {
    var lhs = try parseAnd(self);
    while (self.atKeyword("XOR")) {
        _ = self.advance();
        const rhs = try parseAnd(self);
        lhs = try self.ast.addNode(.binary_operation, .{ .binary_operator = .xor }, &.{ lhs, rhs });
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
    const first = try parsePredicate(self);
    var previous = first;
    var result: ?Index = null;
    // `a < b <= c` is `a < b AND b <= c` (b evaluated for each comparison).
    while (comparisonOperator(self.peek().kind)) |operator| {
        _ = self.advance();
        const next = try parsePredicate(self);
        const comparison = try self.ast.addNode(.binary_operation, .{ .binary_operator = operator }, &.{ previous, next });
        result = if (result) |chain| try self.ast.addNode(.binary_operation, .{ .binary_operator = .and_ }, &.{ chain, comparison }) else comparison;
        previous = next;
    }
    return result orelse first;
}

fn comparisonOperator(kind: TokenKind) ?BinaryOperator {
    return switch (kind) {
        .equal => .equal,
        .not_equal => .not_equal,
        .less_than => .less_than,
        .greater_than => .greater_than,
        .less_or_equal => .less_or_equal,
        .greater_or_equal => .greater_or_equal,
        else => null,
    };
}

/// An additive expression followed by any number of `IS [NOT] NULL`,
/// `STARTS WITH`, `ENDS WITH`, `CONTAINS` and `IN` tests, which bind tighter
/// than comparisons: `x IS NULL = y IS NULL` compares two booleans.
fn parsePredicate(self: *Parser) ParseError!Index {
    var lhs = try parseAdditive(self);
    while (true) {
        if (self.atKeyword("IS")) {
            _ = self.advance();
            const negated = self.atKeyword("NOT");
            if (negated) _ = self.advance();
            try self.expectKeyword("NULL");
            lhs = try self.ast.addNode(.unary_operation, .{ .unary_operator = if (negated) .is_not_null else .is_null }, &.{lhs});
            continue;
        }
        // `STARTS`/`ENDS`/`CONTAINS`/`IN` lex as plain identifiers.
        const operator: BinaryOperator = if (self.atKeyword("STARTS") and self.atKeywordAhead(1, "WITH"))
            .starts_with
        else if (self.atKeyword("ENDS") and self.atKeywordAhead(1, "WITH"))
            .ends_with
        else if (self.atKeyword("CONTAINS"))
            .contains
        else if (self.atKeyword("IN"))
            .in_
        else
            return lhs;
        _ = self.advance();
        if (operator == .starts_with or operator == .ends_with) _ = self.advance(); // WITH
        const rhs = try parseAdditive(self);
        lhs = try self.ast.addNode(.binary_operation, .{ .binary_operator = operator }, &.{ lhs, rhs });
    }
}

/// `+` and `-`, left-associative, over multiplicative operands.
pub fn parseAdditive(self: *Parser) ParseError!Index {
    var left = try parseMultiplicative(self);
    while (true) {
        const operator: BinaryOperator = switch (self.peek().kind) {
            .plus => .add,
            .minus => .subtract,
            else => return left,
        };
        _ = self.advance();
        const right = try parseMultiplicative(self);
        left = try self.ast.addNode(.binary_operation, .{ .binary_operator = operator }, &.{ left, right });
    }
}

/// `*`, `/` and `%`, left-associative, over powers.
fn parseMultiplicative(self: *Parser) ParseError!Index {
    var left = try parsePower(self);
    while (true) {
        const operator: BinaryOperator = switch (self.peek().kind) {
            .star => .multiply,
            .slash => .divide,
            .percent => .modulo,
            else => return left,
        };
        _ = self.advance();
        const right = try parsePower(self);
        left = try self.ast.addNode(.binary_operation, .{ .binary_operator = operator }, &.{ left, right });
    }
}

/// `^`, left-associative, over unary operands (so `-2 ^ 2` is 4.0).
fn parsePower(self: *Parser) ParseError!Index {
    var left = try parseUnary(self);
    while (self.at(.caret)) {
        _ = self.advance();
        const right = try parseUnary(self);
        left = try self.ast.addNode(.binary_operation, .{ .binary_operator = .power }, &.{ left, right });
    }
    return left;
}

/// A sign before an operand. `-` directly before an integer literal is part
/// of the literal, so the most negative integer is writable.
fn parseUnary(self: *Parser) ParseError!Index {
    if (self.at(.plus)) {
        _ = self.advance();
        return parseUnary(self);
    }
    if (self.at(.minus)) {
        _ = self.advance();
        if (self.at(.integer)) return parseIntegerLiteral(self, true);
        if (self.at(.float)) return parseFloatLiteral(self, true);
        const operand = try parseUnary(self);
        return self.ast.addNode(.unary_operation, .{ .unary_operator = .negate }, &.{operand});
    }
    return parsePrimary(self);
}

/// An integer literal token: decimal, `0x` hexadecimal or `0o` octal.
fn parseIntegerLiteral(self: *Parser, negative: bool) ParseError!Index {
    const t = self.advance();
    const digits, const base: u8 = if (std.ascii.startsWithIgnoreCase(t.text, "0x"))
        .{ t.text[2..], 16 }
    else if (std.ascii.startsWithIgnoreCase(t.text, "0o"))
        .{ t.text[2..], 8 }
    else
        .{ t.text, 10 };
    const magnitude = std.fmt.parseInt(u64, digits, base) catch |err| {
        if (err == error.Overflow) {
            self.fail("integer literal {s}{s} does not fit in 64 bits", .{ if (negative) "-" else "", t.text });
        } else {
            self.fail("invalid integer literal {s}", .{t.text});
        }
        return error.UnexpectedToken;
    };
    const limit: u64 = if (negative) @as(u64, std.math.maxInt(i64)) + 1 else std.math.maxInt(i64);
    if (magnitude > limit) {
        self.fail("integer literal {s}{s} does not fit in 64 bits", .{ if (negative) "-" else "", t.text });
        return error.UnexpectedToken;
    }
    const value: i64 = if (negative) @intCast(-@as(i128, magnitude)) else @intCast(magnitude);
    return self.ast.addNode(.integer_literal, .{ .int = value }, &.{});
}

/// A float literal token: `1.5`, `.5`, `1e3`, `1.5e-3`.
fn parseFloatLiteral(self: *Parser, negative: bool) ParseError!Index {
    const t = self.advance();
    const magnitude = std.fmt.parseFloat(f64, t.text) catch {
        self.fail("invalid float literal {s}", .{t.text});
        return error.UnexpectedToken;
    };
    if (std.math.isInf(magnitude)) {
        self.fail("float literal {s} is too large", .{t.text});
        return error.UnexpectedToken;
    }
    return self.ast.addNode(.float_literal, .{ .float = if (negative) -magnitude else magnitude }, &.{});
}

/// `EXISTS { pattern [WHERE predicate] }`, or `EXISTS { query }` with any
/// clauses that only read (MATCH, OPTIONAL MATCH, UNWIND, WITH, CALL,
/// RETURN): true if the subquery has a row for the current row. `COUNT {
/// ... }` takes the same forms and is the number of rows. Its one child is
/// a `query` node (the short form becomes one MATCH); the subquery sees the
/// variables in scope and may introduce its own.
fn parseSubqueryExpression(self: *Parser, kind: NodeKind) ParseError!Index {
    const name = if (kind == .exists_subquery) "EXISTS" else "COUNT";
    try self.expect(.left_brace);
    const query = if (atClauseKeyword(self))
        try self.parseClauses(.read_subquery)
    else
        try self.ast.addNode(.query, .{ .none = {} }, &.{try self.parseMatchBody(.match_clause)});
    if (self.ast.nodeChildren(query).len == 0) {
        self.fail("{s} needs a pattern or a query between its braces", .{name});
        return error.UnexpectedToken;
    }
    try self.expect(.right_brace);
    return self.ast.addNode(kind, .{ .none = {} }, &.{query});
}

/// True if a clause starts here (not a bare pattern).
fn atClauseKeyword(self: *const Parser) bool {
    for ([_][]const u8{ "MATCH", "OPTIONAL", "UNWIND", "WITH", "CALL", "RETURN", "CREATE", "MERGE", "SET", "DELETE", "DETACH", "REMOVE", "FOREACH" }) |keyword| {
        if (self.atKeyword(keyword)) return true;
    }
    return false;
}

/// `[p = (a)-->(b) WHERE predicate | projection]`: the projection for each
/// match of the pattern (the path variable and WHERE are optional).
fn parsePatternComprehension(self: *Parser) ParseError!Index {
    try self.expect(.left_bracket);
    const pattern = try self.parsePattern();
    const predicate = try self.parseOptionalWhere();
    try self.expect(.pipe);
    const projection = try parseExpression(self);
    try self.expect(.right_bracket);
    return self.ast.addNode(.pattern_comprehension, .{ .none = {} }, &.{ pattern, predicate, projection });
}

/// Parses a list literal `[e0, e1, ...]` (the empty list is allowed).
pub fn parseListLiteral(self: *Parser) ParseError!Index {
    if (self.atRelationshipPattern(1) or
        (self.peekAhead(1).kind == .identifier and self.peekAhead(2).kind == .equal and self.atRelationshipPattern(3)))
    {
        return parsePatternComprehension(self);
    }
    // `[x IN list ...]` is a comprehension, not a list holding `x IN list`.
    if (self.peekAhead(1).kind == .identifier and self.atKeywordAhead(2, "IN")) return parseListComprehension(self);
    try self.expect(.left_bracket);
    var items = std.ArrayList(Index).empty;
    defer items.deinit(self.ast.allocator);
    while (!self.at(.right_bracket)) {
        try items.append(self.ast.allocator, try parseExpression(self));
        if (self.at(.comma)) {
            _ = self.advance();
        } else break;
    }
    try self.expect(.right_bracket);
    return self.ast.addNode(.list_literal, .{ .none = {} }, items.items);
}

/// An atom followed by any number of postfix operators: `.key` (property or
/// map entry), `[index]` (list element, map entry by key) and `[from..to]`
/// (list slice; either end may be left out).
pub fn parsePrimary(self: *Parser) ParseError!Index {
    var expr = try parseAtom(self);
    while (true) {
        if (self.at(.dot)) {
            _ = self.advance();
            const key = try self.internIdentifier();
            expr = try self.ast.addNode(.property_access, .{ .text = key }, &.{expr});
        } else if (self.at(.left_bracket)) {
            _ = self.advance();
            const open_start = self.at(.range_dots);
            const from = if (open_start) try nullNode(self) else try parseExpression(self);
            if (self.at(.range_dots)) {
                _ = self.advance();
                const open_end = self.at(.right_bracket);
                const to = if (open_end) try nullNode(self) else try parseExpression(self);
                try self.expect(.right_bracket);
                // data.int: which ends were written (1: from, 2: to); an open end
                // is unbounded, a written one that is null makes the slice null.
                const written: i64 = @as(i64, @intFromBool(!open_start)) | (@as(i64, @intFromBool(!open_end)) << 1);
                expr = try self.ast.addNode(.slice, .{ .int = written }, &.{ expr, from, to });
            } else {
                try self.expect(.right_bracket);
                expr = try self.ast.addNode(.subscript, .{ .none = {} }, &.{ expr, from });
            }
        } else if (self.at(.left_brace) and self.ast.kind(expr) == .variable) {
            expr = try parseMapProjection(self, expr);
        } else if (self.at(.colon) and self.peekAhead(1).kind == .identifier) {
            // `n:Label:Other`: a label predicate.
            var labels = std.ArrayList([]const u8).empty;
            defer labels.deinit(self.ast.allocator);
            while (self.at(.colon) and self.peekAhead(1).kind == .identifier) {
                _ = self.advance();
                try labels.append(self.ast.allocator, try self.internIdentifier());
            }
            expr = try self.ast.addNode(.label_predicate, .{ .labels = try self.ast.internSlice(labels.items) }, &.{expr});
        } else return expr;
    }
}

fn nullNode(self: *Parser) ParseError!Index {
    return self.ast.addNode(.null_literal, .{ .none = {} }, &.{});
}

/// `x IN list [WHERE predicate]`: the iteration of a comprehension or a
/// quantifier. A missing predicate is `true`.
fn parseIteration(self: *Parser) ParseError!struct { variable_name: []const u8, list: Index, predicate: Index } {
    const variable_name = try self.internIdentifier();
    try self.expectKeyword("IN");
    const list = try parseExpression(self);
    const predicate = if (self.atKeyword("WHERE")) blk: {
        _ = self.advance();
        break :blk try parseExpression(self);
    } else try self.ast.addNode(.boolean_literal, .{ .boolean = true }, &.{});
    return .{ .variable_name = variable_name, .list = list, .predicate = predicate };
}

/// `[x IN list WHERE predicate | projection]`; the WHERE and the projection
/// are optional (no projection keeps the elements themselves).
fn parseListComprehension(self: *Parser) ParseError!Index {
    try self.expect(.left_bracket);
    const iteration = try parseIteration(self);
    const projection = if (self.at(.pipe)) blk: {
        _ = self.advance();
        break :blk try parseExpression(self);
    } else try self.ast.addNode(.variable, .{ .text = iteration.variable_name }, &.{});
    try self.expect(.right_bracket);
    return self.ast.addNode(.list_comprehension, .{ .text = iteration.variable_name }, &.{ iteration.list, iteration.predicate, projection });
}

fn quantifierFromName(name: []const u8) ?QuantifierKind {
    for ([_]QuantifierKind{ .any, .all, .none, .single }) |kind| {
        if (std.ascii.eqlIgnoreCase(@tagName(kind), name)) return kind;
    }
    return null;
}

/// `any(...)`, `all(...)`, `none(...)` or `single(x IN list WHERE predicate)`.
fn parseQuantifier(self: *Parser, kind: QuantifierKind) ParseError!Index {
    try self.expect(.left_paren);
    const iteration = try parseIteration(self);
    try self.expect(.right_paren);
    return self.ast.addNode(.quantifier, .{ .quantifier = .{ .kind = kind, .variable_name = iteration.variable_name } }, &.{ iteration.list, iteration.predicate });
}

/// A map literal `{key: value, ...}` (the empty map is allowed).
/// `subject {.a, .*, key: expression, variable}` (the `{` is next).
fn parseMapProjection(self: *Parser, subject: Index) ParseError!Index {
    try self.expect(.left_brace);
    var children = std.ArrayList(Index).empty;
    defer children.deinit(self.ast.allocator);
    try children.append(self.ast.allocator, subject);
    while (!self.at(.right_brace)) {
        if (self.at(.dot)) {
            _ = self.advance();
            if (self.at(.star)) {
                _ = self.advance();
                try children.append(self.ast.allocator, try self.ast.addNode(.map_projection_all, .{ .none = {} }, &.{}));
            } else {
                const property = try self.internIdentifier();
                try children.append(self.ast.allocator, try self.ast.addNode(.map_projection_property, .{ .text = property }, &.{}));
            }
        } else {
            const key = try self.internIdentifier();
            const value = if (self.at(.colon)) value: {
                _ = self.advance();
                break :value try parseExpression(self);
            } else try self.ast.addNode(.variable, .{ .text = key }, &.{});
            try children.append(self.ast.allocator, try self.ast.addNode(.property, .{ .text = key }, &.{value}));
        }
        if (!self.at(.comma)) break;
        _ = self.advance();
    }
    try self.expect(.right_brace);
    return self.ast.addNode(.map_projection, .{ .none = {} }, children.items);
}

fn parseMapLiteral(self: *Parser) ParseError!Index {
    try self.expect(.left_brace);
    var entries = std.ArrayList(Index).empty;
    defer entries.deinit(self.ast.allocator);
    while (!self.at(.right_brace)) {
        const key = try self.internIdentifier();
        try self.expect(.colon);
        const value = try parseExpression(self);
        try entries.append(self.ast.allocator, try self.ast.addNode(.property, .{ .text = key }, &.{value}));
        if (!self.at(.comma)) break;
        _ = self.advance();
    }
    try self.expect(.right_brace);
    return self.ast.addNode(.map_literal, .{ .none = {} }, entries.items);
}

fn parseAtom(self: *Parser) ParseError!Index {
    if (self.atKeyword("CASE")) return parseCaseExpression(self);
    const t = self.peek();
    switch (t.kind) {
        .integer => return parseIntegerLiteral(self, false),
        .float => return parseFloatLiteral(self, false),
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
            if (self.at(.left_paren)) {
                // `any(x IN ...)` etc. are quantifiers; anything else is a call.
                if (quantifierFromName(t.text)) |kind| {
                    if (self.peekAhead(1).kind == .identifier and self.atKeywordAhead(2, "IN")) return parseQuantifier(self, kind);
                }
                return parseFunctionCall(self, t.text);
            }
            if (self.at(.left_brace)) {
                if (std.ascii.eqlIgnoreCase(t.text, "exists")) return parseSubqueryExpression(self, .exists_subquery);
                if (std.ascii.eqlIgnoreCase(t.text, "count")) return parseSubqueryExpression(self, .count_subquery);
            }
            // `date.truncate(...)`: a namespaced function.
            if (self.at(.dot) and self.peekAhead(1).kind == .identifier and isNamespacedCall(self)) {
                var name = std.ArrayList(u8).empty;
                defer name.deinit(self.ast.allocator);
                try name.appendSlice(self.ast.allocator, t.text);
                while (self.at(.dot)) {
                    _ = self.advance();
                    try name.append(self.ast.allocator, '.');
                    try name.appendSlice(self.ast.allocator, self.advance().text);
                }
                return parseFunctionCall(self, name.items);
            }
            return parseVariableRef(self, t.text);
        },
        .left_bracket => return parseListLiteral(self),
        .left_brace => return parseMapLiteral(self),
        .left_paren => if (self.in_where and self.atRelationshipPattern(0)) {
            // `WHERE (a)-[:KNOWS]->(b)`: true if the pattern has a match.
            const pattern = try self.parsePattern();
            const always = try self.ast.addNode(.boolean_literal, .{ .boolean = true }, &.{});
            return self.ast.addNode(.pattern_predicate, .{ .none = {} }, &.{ pattern, always });
        } else {
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

/// True at `.name(` or `.name.name(` (after an identifier): a namespaced
/// function call rather than property accesses.
fn isNamespacedCall(self: *Parser) bool {
    var ahead: usize = 0;
    while (self.peekAhead(ahead).kind == .dot and self.peekAhead(ahead + 1).kind == .identifier) ahead += 2;
    return ahead > 0 and self.peekAhead(ahead).kind == .left_paren;
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

/// A variable (the name is already consumed; postfixes are read by
/// `parsePrimary`).
pub fn parseVariableRef(self: *Parser, text: []const u8) ParseError!Index {
    return self.ast.addNode(.variable, .{ .text = try self.ast.intern(text) }, &.{});
}

/// `CASE WHEN condition THEN result ... [ELSE result] END`, or the simple
/// form `CASE subject WHEN value THEN result ... [ELSE result] END`.
pub fn parseCaseExpression(self: *Parser) ParseError!Index {
    _ = self.advance(); // CASE
    var children = std.ArrayList(Index).empty;
    defer children.deinit(self.ast.allocator);
    const simple = !self.atKeyword("WHEN");
    if (simple) try children.append(self.ast.allocator, try parseExpression(self));
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
    return self.ast.addNode(if (simple) .simple_case_expression else .case_expression, .{ .none = {} }, children.items);
}

pub fn parseAggregateCall(self: *Parser, kind: AggregateKind) ParseError!Index {
    try self.expect(.left_paren);
    if (kind == .count and self.at(.star)) {
        _ = self.advance();
        try self.expect(.right_paren);
        return self.ast.addNode(.aggregate, .{ .aggregate = .{ .kind = kind } }, &.{});
    }
    const distinct = self.atKeyword("DISTINCT");
    if (distinct) _ = self.advance();
    const arg = try parseExpression(self);
    if (kind == .percentileDisc or kind == .percentileCont) {
        try self.expect(.comma);
        const percentile = try parseExpression(self);
        try self.expect(.right_paren);
        return self.ast.addNode(.aggregate, .{ .aggregate = .{ .kind = kind, .distinct = distinct } }, &.{ arg, percentile });
    }
    try self.expect(.right_paren);
    return self.ast.addNode(.aggregate, .{ .aggregate = .{ .kind = kind, .distinct = distinct } }, &.{arg});
}

fn aggregateKindFromName(name: []const u8) ?AggregateKind {
    if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(name, "avg")) return .avg;
    if (std.ascii.eqlIgnoreCase(name, "stDev")) return .stDev;
    if (std.ascii.eqlIgnoreCase(name, "stDevP")) return .stDevP;
    if (std.ascii.eqlIgnoreCase(name, "min")) return .min;
    if (std.ascii.eqlIgnoreCase(name, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(name, "collect")) return .collect;
    if (std.ascii.eqlIgnoreCase(name, "percentileDisc")) return .percentileDisc;
    if (std.ascii.eqlIgnoreCase(name, "percentileCont")) return .percentileCont;
    return null;
}
