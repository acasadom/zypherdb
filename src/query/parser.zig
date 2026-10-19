//! Hand-written recursive-descent parser for the openCypher subset.
//!
//! Produces an arena AST (see `src/query/ast.zig`). The subset covers:
//!
//! - `MATCH` with a chain of node/edge patterns (`(var:Label {k: v})`,
//!   `-[var:TYPE]->`, `<-[var:TYPE]-`).
//! - `WHERE` with comparisons (`=`, `<>`, `<`, `>`, `<=`, `>=`), boolean
//!   `AND`/`OR`/`NOT`, and literals/property access.
//! - `RETURN` with expressions and optional `AS` aliases.
//!
//! Keywords are case-insensitive; identifiers are case-sensitive.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = @import("ast.zig").Ast;
const Index = @import("ast.zig").Index;
const NodeKind = @import("ast.zig").NodeKind;
const BinaryOperator = @import("ast.zig").BinaryOperator;
const EdgeDirection = @import("ast.zig").EdgeDirection;
const AggregateKind = @import("ast.zig").AggregateKind;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const tokenize = lexer.tokenize;
const describeTokenKind = lexer.describeTokenKind;
const describeToken = lexer.describeToken;

pub const ParseError = lexer.LexError;

fn aggregateKindFromName(name: []const u8) ?AggregateKind {
    if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(name, "min")) return .min;
    if (std.ascii.eqlIgnoreCase(name, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(name, "collect")) return .collect;
    return null;
}

/// Parses `src` into `ast` and returns the root `query` node index. On error,
/// `diagnostic` (if non-null) is populated with a message and byte offset.
pub fn parse(ast: *Ast, src: []const u8, diagnostic: ?*Diagnostic) ParseError!Index {
    var tokens = try tokenize(ast.allocator, src, diagnostic);
    defer tokens.deinit(ast.allocator);

    var parser = Parser{
        .ast = ast,
        .tokens = tokens.items,
        .pos = 0,
        .diagnostic = diagnostic,
    };
    return parser.parseQuery();
}

const Parser = struct {
    ast: *Ast,
    tokens: []const Token,
    pos: usize,
    diagnostic: ?*Diagnostic,

    fn peek(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn at(self: *const Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (t.kind != .end_of_input) self.pos += 1;
        return t;
    }

    fn atKeyword(self: *const Parser, keyword: []const u8) bool {
        const t = self.peek();
        return t.kind == .identifier and !t.quoted and std.ascii.eqlIgnoreCase(t.text, keyword);
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        if (self.diagnostic) |d| d.set(.parse, self.peek().pos, fmt, args);
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        const t = self.peek();
        if (t.kind != kind) {
            self.fail("expected {s}, found {s}", .{ describeTokenKind(kind), describeToken(t) });
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }

    fn expectKeyword(self: *Parser, keyword: []const u8) ParseError!void {
        if (!self.atKeyword(keyword)) {
            self.fail("expected keyword {s}", .{keyword});
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }

    fn expectIdentifier(self: *Parser) ParseError!Token {
        const t = self.peek();
        if (t.kind != .identifier) {
            self.fail("expected an identifier, found {s}", .{describeToken(t)});
            return error.UnexpectedToken;
        }
        return self.advance();
    }

    /// Consumes an identifier and interns its text into the AST arena.
    fn internIdentifier(self: *Parser) ParseError![]const u8 {
        const t = try self.expectIdentifier();
        return self.ast.intern(t.text);
    }

    /// Unescapes `\'` and `\\` and interns the result into the AST arena.
    fn internString(self: *Parser, raw: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
            return self.ast.intern(raw);
        }
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(self.ast.allocator);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                switch (raw[i]) {
                    '\\', '\'' => try buffer.append(self.ast.allocator, raw[i]),
                    else => {
                        try buffer.append(self.ast.allocator, '\\');
                        try buffer.append(self.ast.allocator, raw[i]);
                    },
                }
            } else {
                try buffer.append(self.ast.allocator, raw[i]);
            }
        }
        return self.ast.intern(buffer.items);
    }

    // --- Grammar -----------------------------------------------------------

    fn parseQuery(self: *Parser) ParseError!Index {
        var clauses = std.ArrayList(Index).empty;
        defer clauses.deinit(self.ast.allocator);

        if (self.atKeyword("MATCH")) {
            try clauses.append(self.ast.allocator, try self.parseMatchClause());
        }

        if (self.atKeyword("OPTIONAL")) {
            try clauses.append(self.ast.allocator, try self.parseOptionalMatchClause());
        }

        if (self.atKeyword("UNWIND")) {
            try clauses.append(self.ast.allocator, try self.parseUnwindClause());
        }

        if (self.atKeyword("WITH")) {
            try clauses.append(self.ast.allocator, try self.parseWithClause());
            // An optional second MATCH after WITH continues the traversal.
            if (self.atKeyword("MATCH")) {
                try clauses.append(self.ast.allocator, try self.parseMatchClause());
            }
        }

        while (true) {
            if (self.atKeyword("CREATE")) {
                _ = self.advance();
                const pattern = try self.parsePattern();
                const cc = try self.ast.addNode(.create_clause, .{ .none = {} }, &.{pattern});
                try clauses.append(self.ast.allocator, cc);
            } else if (self.atKeyword("MERGE")) {
                try clauses.append(self.ast.allocator, try self.parseMergeClause());
            } else if (self.atKeyword("SET")) {
                _ = self.advance();
                const sc = try self.parseSetClause();
                try clauses.append(self.ast.allocator, sc);
            } else if (self.atKeyword("DELETE")) {
                _ = self.advance();
                const dc = try self.parseDeleteClause(false);
                try clauses.append(self.ast.allocator, dc);
            } else if (self.atKeyword("DETACH")) {
                _ = self.advance();
                try self.expectKeyword("DELETE");
                const dc = try self.parseDeleteClause(true);
                try clauses.append(self.ast.allocator, dc);
            } else if (self.atKeyword("REMOVE")) {
                try clauses.append(self.ast.allocator, try self.parseRemoveClause());
            } else break;
        }

        if (self.atKeyword("RETURN")) {
            _ = self.advance();
            const rc = try self.parseReturnClause();
            try clauses.append(self.ast.allocator, rc);
        }

        if (self.peek().kind != .end_of_input) {
            self.fail("unexpected {s} (unsupported syntax or missing clause)", .{describeToken(self.peek())});
            return error.UnexpectedToken;
        }
        if (clauses.items.len == 0) {
            self.fail("expected a clause (MATCH, CREATE, RETURN, ...)", .{});
            return error.UnexpectedToken;
        }
        return self.ast.addNode(.query, .{ .none = {} }, clauses.items);
    }

    fn parseMatchClause(self: *Parser) ParseError!Index {
        _ = self.advance(); // MATCH
        return self.parseMatchBody(.match_clause);
    }

    fn parseOptionalMatchClause(self: *Parser) ParseError!Index {
        _ = self.advance(); // OPTIONAL
        try self.expectKeyword("MATCH");
        return self.parseMatchBody(.optional_match_clause);
    }

    fn parseUnwindClause(self: *Parser) ParseError!Index {
        _ = self.advance(); // UNWIND
        const expr = try self.parseExpression();
        try self.expectKeyword("AS");
        const variable_name = try self.internIdentifier();
        return self.ast.addNode(.unwind_clause, .{ .unwind = .{ .variable_name = variable_name } }, &.{expr});
    }

    fn parseMatchBody(self: *Parser, kind: NodeKind) ParseError!Index {
        var match_kids = std.ArrayList(Index).empty;
        defer match_kids.deinit(self.ast.allocator);
        while (true) {
            const pattern = try self.parsePattern();
            try match_kids.append(self.ast.allocator, pattern);
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        var where_expression: Index = undefined;
        if (self.atKeyword("WHERE")) {
            _ = self.advance();
            where_expression = try self.parseExpression();
        } else {
            where_expression = try self.ast.addNode(.boolean_literal, .{ .boolean = true }, &.{});
        }
        try match_kids.append(self.ast.allocator, where_expression);
        return self.ast.addNode(kind, .{ .none = {} }, match_kids.items);
    }

    fn parseWithClause(self: *Parser) ParseError!Index {
        _ = self.advance(); // WITH
        var distinct = false;
        if (self.atKeyword("DISTINCT")) {
            _ = self.advance();
            distinct = true;
        }
        const projection = try self.parseProjection();

        var children = std.ArrayList(Index).empty;
        defer children.deinit(self.ast.allocator);
        try children.append(self.ast.allocator, projection);

        if (self.atKeyword("ORDER")) {
            _ = self.advance();
            try self.expectKeyword("BY");
            try children.append(self.ast.allocator, try self.parseOrderBy());
        }
        if (self.atKeyword("SKIP")) {
            _ = self.advance();
            const expr = try self.parseExpression();
            try children.append(self.ast.allocator, try self.ast.addNode(.skip, .{ .none = {} }, &.{expr}));
        }
        if (self.atKeyword("LIMIT")) {
            _ = self.advance();
            const expr = try self.parseExpression();
            try children.append(self.ast.allocator, try self.ast.addNode(.limit, .{ .none = {} }, &.{expr}));
        }
        if (self.atKeyword("WHERE")) {
            _ = self.advance();
            try children.append(self.ast.allocator, try self.parseExpression());
        } else {
            try children.append(self.ast.allocator, try self.ast.addNode(.boolean_literal, .{ .boolean = true }, &.{}));
        }

        return self.ast.addNode(.with_clause, .{ .with_ = .{ .distinct = distinct } }, children.items);
    }

    fn parseSetClause(self: *Parser) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const variable_name = try self.internIdentifier();
            try self.expect(.dot);
            const property = try self.internIdentifier();
            const var_node = try self.ast.addNode(.variable, .{ .text = variable_name }, &.{});
            const access = try self.ast.addNode(.property_access, .{ .text = property }, &.{var_node});
            try self.expect(.equal);
            const value = try self.parseExpression();
            const item = try self.ast.addNode(.set_item, .{ .none = {} }, &.{ access, value });
            try items.append(self.ast.allocator, item);
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        return self.ast.addNode(.set_clause, .{ .none = {} }, items.items);
    }

    fn parseDeleteClause(self: *Parser, detach: bool) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const name = try self.internIdentifier();
            const var_node = try self.ast.addNode(.variable, .{ .text = name }, &.{});
            const item = try self.ast.addNode(.delete_item, .{ .none = {} }, &.{var_node});
            try items.append(self.ast.allocator, item);
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        return self.ast.addNode(.delete_clause, .{ .delete = .{ .detach = detach } }, items.items);
    }

    /// Parses `REMOVE n.property, m:Label`.
    fn parseRemoveClause(self: *Parser) ParseError!Index {
        _ = self.advance(); // REMOVE
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const variable_name = try self.internIdentifier();
            const var_node = try self.ast.addNode(.variable, .{ .text = variable_name }, &.{});
            if (self.at(.colon)) {
                _ = self.advance();
                const label = try self.internIdentifier();
                try items.append(self.ast.allocator, try self.ast.addNode(.label_reference, .{ .text = label }, &.{var_node}));
            } else {
                try self.expect(.dot);
                const property = try self.internIdentifier();
                try items.append(self.ast.allocator, try self.ast.addNode(.property_access, .{ .text = property }, &.{var_node}));
            }
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        return self.ast.addNode(.remove_clause, .{ .none = {} }, items.items);
    }

    /// Parses `MERGE pattern [ON CREATE SET ...] [ON MATCH SET ...]`.
    fn parseMergeClause(self: *Parser) ParseError!Index {
        _ = self.advance(); // MERGE
        const pattern = try self.parsePattern();

        var on_create = try self.ast.addNode(.set_clause, .{ .none = {} }, &.{});
        var on_match = try self.ast.addNode(.set_clause, .{ .none = {} }, &.{});
        var seen: u2 = 0;
        while (seen < 2 and self.atKeyword("ON")) {
            _ = self.advance();
            if (self.atKeyword("CREATE")) {
                _ = self.advance();
                try self.expectKeyword("SET");
                on_create = try self.parseSetClause();
                seen |= 1;
            } else if (self.atKeyword("MATCH")) {
                _ = self.advance();
                try self.expectKeyword("SET");
                on_match = try self.parseSetClause();
                seen |= 2;
            } else {
                self.fail("expected CREATE or MATCH after ON, found {s}", .{describeToken(self.peek())});
                return error.UnexpectedToken;
            }
        }
        return self.ast.addNode(.merge_clause, .{ .none = {} }, &.{ pattern, on_create, on_match });
    }

    fn parsePattern(self: *Parser) ParseError!Index {
        var children = std.ArrayList(Index).empty;
        defer children.deinit(self.ast.allocator);

        try children.append(self.ast.allocator, try self.parseNodePattern());
        while (self.at(.minus) or self.at(.arrow_left)) {
            try children.append(self.ast.allocator, try self.parseEdgePattern());
            try children.append(self.ast.allocator, try self.parseNodePattern());
        }
        return self.ast.addNode(.pattern, .{ .none = {} }, children.items);
    }

    fn parseNodePattern(self: *Parser) ParseError!Index {
        try self.expect(.left_paren);
        var variable_name: []const u8 = "";
        if (self.at(.identifier)) variable_name = try self.ast.intern(self.advance().text);

        var labels = std.ArrayList([]const u8).empty;
        defer labels.deinit(self.ast.allocator);
        while (self.at(.colon)) {
            _ = self.advance();
            try labels.append(self.ast.allocator, try self.internIdentifier());
        }
        const labels_slice = try self.ast.internSlice(labels.items);

        var properties = std.ArrayList(Index).empty;
        defer properties.deinit(self.ast.allocator);
        if (self.at(.left_brace)) {
            _ = self.advance();
            while (!self.at(.right_brace)) {
                const name = try self.internIdentifier();
                try self.expect(.colon);
                const value = try self.parsePrimary();
                const property = try self.ast.addNode(.property, .{ .text = name }, &.{value});
                try properties.append(self.ast.allocator, property);
                if (self.at(.comma)) {
                    _ = self.advance();
                } else break;
            }
            try self.expect(.right_brace);
        }

        try self.expect(.right_paren);
        return self.ast.addNode(.node_pattern, .{ .node_pattern = .{ .variable_name = variable_name, .labels = labels_slice } }, properties.items);
    }

    fn parseEdgeDetails(self: *Parser) ParseError!struct { variable_name: []const u8, edge_type: []const u8, properties: std.ArrayList(Index) } {
        try self.expect(.left_bracket);
        var variable_name: []const u8 = "";
        if (self.at(.identifier)) variable_name = try self.ast.intern(self.advance().text);
        var edge_type: []const u8 = "";
        if (self.at(.colon)) {
            _ = self.advance();
            edge_type = try self.internIdentifier();
        }
        var properties = std.ArrayList(Index).empty;
        if (self.at(.left_brace)) {
            _ = self.advance();
            while (!self.at(.right_brace)) {
                const name = try self.internIdentifier();
                try self.expect(.colon);
                const value = try self.parsePrimary();
                const property = try self.ast.addNode(.property, .{ .text = name }, &.{value});
                try properties.append(self.ast.allocator, property);
                if (self.at(.comma)) {
                    _ = self.advance();
                } else break;
            }
            try self.expect(.right_brace);
        }
        try self.expect(.right_bracket);
        return .{ .variable_name = variable_name, .edge_type = edge_type, .properties = properties };
    }

    fn parseEdgePattern(self: *Parser) ParseError!Index {
        var direction: EdgeDirection = undefined;
        if (self.at(.minus)) {
            _ = self.advance(); // -[...]->
            direction = .left_to_right;
            var d = try self.parseEdgeDetails();
            defer d.properties.deinit(self.ast.allocator);
            try self.expect(.arrow_right);
            return self.ast.addNode(.edge_pattern, .{ .edge_pattern = .{ .variable_name = d.variable_name, .edge_type = d.edge_type, .direction = direction } }, d.properties.items);
        }
        _ = self.advance(); // <-[...]-
        direction = .right_to_left;
        var d = try self.parseEdgeDetails();
        defer d.properties.deinit(self.ast.allocator);
        try self.expect(.minus);
        return self.ast.addNode(.edge_pattern, .{ .edge_pattern = .{ .variable_name = d.variable_name, .edge_type = d.edge_type, .direction = direction } }, d.properties.items);
    }

    fn parseProjection(self: *Parser) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            try items.append(self.ast.allocator, try self.parseProjectionItem());
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        return self.ast.addNode(.projection, .{ .none = {} }, items.items);
    }

    fn parseProjectionItem(self: *Parser) ParseError!Index {
        const expr = try self.parseExpression();
        var alias: []const u8 = "";
        if (self.atKeyword("AS")) {
            _ = self.advance();
            alias = try self.internIdentifier();
        }
        return self.ast.addNode(.projection_item, .{ .text = alias }, &.{expr});
    }

    fn parseReturnClause(self: *Parser) ParseError!Index {
        var distinct = false;
        if (self.atKeyword("DISTINCT")) {
            _ = self.advance();
            distinct = true;
        }
        const projection = try self.parseProjection();

        var children = std.ArrayList(Index).empty;
        defer children.deinit(self.ast.allocator);
        try children.append(self.ast.allocator, projection);

        if (self.atKeyword("ORDER")) {
            _ = self.advance();
            try self.expectKeyword("BY");
            const order_by = try self.parseOrderBy();
            try children.append(self.ast.allocator, order_by);
        }

        if (self.atKeyword("SKIP")) {
            _ = self.advance();
            const expr = try self.parseExpression();
            const skip = try self.ast.addNode(.skip, .{ .none = {} }, &.{expr});
            try children.append(self.ast.allocator, skip);
        }

        if (self.atKeyword("LIMIT")) {
            _ = self.advance();
            const expr = try self.parseExpression();
            const limit = try self.ast.addNode(.limit, .{ .none = {} }, &.{expr});
            try children.append(self.ast.allocator, limit);
        }

        return self.ast.addNode(.return_clause, .{ .return_ = .{ .distinct = distinct } }, children.items);
    }

    fn parseOrderBy(self: *Parser) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const expr = try self.parseExpression();
            var ascending = true;
            if (self.atKeyword("DESC")) {
                _ = self.advance();
                ascending = false;
            } else if (self.atKeyword("ASC")) {
                _ = self.advance();
            }
            const item = try self.ast.addNode(.order_item, .{ .order_item = .{ .ascending = ascending } }, &.{expr});
            try items.append(self.ast.allocator, item);
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        return self.ast.addNode(.order_by, .{ .none = {} }, items.items);
    }

    fn parseExpression(self: *Parser) ParseError!Index {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!Index {
        var lhs = try self.parseAnd();
        while (self.atKeyword("OR")) {
            _ = self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.ast.addNode(.binary_operation, .{ .binary_operator = .or_ }, &.{ lhs, rhs });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) ParseError!Index {
        var lhs = try self.parseNot();
        while (self.atKeyword("AND")) {
            _ = self.advance();
            const rhs = try self.parseNot();
            lhs = try self.ast.addNode(.binary_operation, .{ .binary_operator = .and_ }, &.{ lhs, rhs });
        }
        return lhs;
    }

    fn parseNot(self: *Parser) ParseError!Index {
        if (self.atKeyword("NOT")) {
            _ = self.advance();
            const operand = try self.parseNot();
            return self.ast.addNode(.unary_operation, .{ .unary_operator = .not_ }, &.{operand});
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!Index {
        const lhs = try self.parsePrimary();

        // Multi-word string predicates (checked before the single-token ops,
        // since `STARTS`/`ENDS`/`CONTAINS`/`IN` lex as plain identifiers).
        if (self.atKeyword("STARTS")) {
            _ = self.advance();
            try self.expectKeyword("WITH");
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_operation, .{ .binary_operator = .starts_with }, &.{ lhs, rhs });
        }
        if (self.atKeyword("ENDS")) {
            _ = self.advance();
            try self.expectKeyword("WITH");
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_operation, .{ .binary_operator = .ends_with }, &.{ lhs, rhs });
        }
        if (self.atKeyword("CONTAINS")) {
            _ = self.advance();
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_operation, .{ .binary_operator = .contains }, &.{ lhs, rhs });
        }
        if (self.atKeyword("IN")) {
            _ = self.advance();
            const list = try self.parseListLiteral();
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
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_operation, .{ .binary_operator = o }, &.{ lhs, rhs });
        }
        return lhs;
    }

    /// Parses a list literal `[e0, e1, ...]` (elements are primary expressions;
    /// the empty list is allowed).
    fn parseListLiteral(self: *Parser) ParseError!Index {
        try self.expect(.left_bracket);
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (!self.at(.right_bracket)) {
            try items.append(self.ast.allocator, try self.parsePrimary());
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        try self.expect(.right_bracket);
        return self.ast.addNode(.list_literal, .{ .none = {} }, items.items);
    }

    fn parsePrimary(self: *Parser) ParseError!Index {
        if (self.atKeyword("CASE")) return self.parseCaseExpression();
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
            .identifier => if (t.quoted) {
                _ = self.advance();
                return self.parseVariableRef(t.text);
            } else {
                _ = self.advance();
                if (std.ascii.eqlIgnoreCase(t.text, "true")) return self.ast.addNode(.boolean_literal, .{ .boolean = true }, &.{});
                if (std.ascii.eqlIgnoreCase(t.text, "false")) return self.ast.addNode(.boolean_literal, .{ .boolean = false }, &.{});
                if (aggregateKindFromName(t.text)) |kind| {
                    if (self.at(.left_paren)) {
                        return self.parseAggregateCall(kind);
                    }
                }
                if (std.ascii.eqlIgnoreCase(t.text, "size")) {
                    if (self.at(.left_paren)) {
                        _ = self.advance();
                        const arg = try self.parseExpression();
                        try self.expect(.right_paren);
                        return self.ast.addNode(.size_function, .{ .none = {} }, &.{arg});
                    }
                }
                return self.parseVariableRef(t.text);
            },
            .left_bracket => return self.parseListLiteral(),
            .left_paren => {
                _ = self.advance();
                const e = try self.parseExpression();
                try self.expect(.right_paren);
                return e;
            },
            else => {
                self.fail("expected an expression, found {s}", .{describeToken(t)});
                return error.UnexpectedToken;
            },
        }
    }

    /// A variable, optionally followed by `.property` (the name is already consumed).
    fn parseVariableRef(self: *Parser, text: []const u8) ParseError!Index {
        const name = try self.ast.intern(text);
        const var_node = try self.ast.addNode(.variable, .{ .text = name }, &.{});
        if (self.at(.dot)) {
            _ = self.advance();
            const property = try self.internIdentifier();
            return self.ast.addNode(.property_access, .{ .text = property }, &.{var_node});
        }
        return var_node;
    }

    fn parseCaseExpression(self: *Parser) ParseError!Index {
        _ = self.advance(); // CASE
        var children = std.ArrayList(Index).empty;
        defer children.deinit(self.ast.allocator);
        while (self.atKeyword("WHEN")) {
            _ = self.advance();
            const cond = try self.parseExpression();
            try self.expectKeyword("THEN");
            const result = try self.parseExpression();
            try children.append(self.ast.allocator, cond);
            try children.append(self.ast.allocator, result);
        }
        if (self.atKeyword("ELSE")) {
            _ = self.advance();
            try children.append(self.ast.allocator, try self.parseExpression());
        }
        try self.expectKeyword("END");
        return self.ast.addNode(.case_expression, .{ .none = {} }, children.items);
    }

    fn parseAggregateCall(self: *Parser, kind: AggregateKind) ParseError!Index {
        try self.expect(.left_paren);
        if (kind == .count and self.at(.star)) {
            _ = self.advance();
            try self.expect(.right_paren);
            return self.ast.addNode(.aggregate, .{ .aggregate = kind }, &.{});
        }
        const arg = try self.parseExpression();
        try self.expect(.right_paren);
        return self.ast.addNode(.aggregate, .{ .aggregate = kind }, &.{arg});
    }
};
