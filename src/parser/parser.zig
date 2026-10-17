//! Hand-written recursive-descent parser for the openCypher subset.
//!
//! Produces an arena AST (see `src/ast/ast.zig`). The subset covers:
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
const Ast = @import("../ast/ast.zig").Ast;
const Index = @import("../ast/ast.zig").Index;
const NodeKind = @import("../ast/ast.zig").NodeKind;
const BinOp = @import("../ast/ast.zig").BinOp;
const EdgeDirection = @import("../ast/ast.zig").EdgeDirection;

pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    OutOfMemory,
};

pub const TokenKind = enum {
    ident,
    string,
    integer,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    colon,
    comma,
    dot,
    minus,
    arrow_right,
    arrow_left,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    /// Lexeme: content for ident/string/integer, symbol for punctuation.
    text: []const u8,
    /// Byte offset of the token start in the source.
    pos: usize,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn add(tokens: *std.ArrayList(Token), allocator: Allocator, kind: TokenKind, text: []const u8, pos: usize) ParseError!void {
    try tokens.append(allocator, .{ .kind = kind, .text = text, .pos = pos });
}

fn tokenize(allocator: Allocator, src: []const u8) ParseError!std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => i += 1,
            '(' => {
                try add(&tokens, allocator, .l_paren, src[i .. i + 1], i);
                i += 1;
            },
            ')' => {
                try add(&tokens, allocator, .r_paren, src[i .. i + 1], i);
                i += 1;
            },
            '[' => {
                try add(&tokens, allocator, .l_bracket, src[i .. i + 1], i);
                i += 1;
            },
            ']' => {
                try add(&tokens, allocator, .r_bracket, src[i .. i + 1], i);
                i += 1;
            },
            '{' => {
                try add(&tokens, allocator, .l_brace, src[i .. i + 1], i);
                i += 1;
            },
            '}' => {
                try add(&tokens, allocator, .r_brace, src[i .. i + 1], i);
                i += 1;
            },
            ':' => {
                try add(&tokens, allocator, .colon, src[i .. i + 1], i);
                i += 1;
            },
            ',' => {
                try add(&tokens, allocator, .comma, src[i .. i + 1], i);
                i += 1;
            },
            '.' => {
                try add(&tokens, allocator, .dot, src[i .. i + 1], i);
                i += 1;
            },
            '\'' => {
                const start = i;
                i += 1; // opening quote
                const content_start = i;
                while (i < src.len) {
                    if (src[i] == '\\') {
                        i += 2; // skip escaped char
                        continue;
                    }
                    if (src[i] == '\'') break;
                    i += 1;
                }
                if (i >= src.len) return error.UnexpectedEof;
                try add(&tokens, allocator, .string, src[content_start..i], start);
                i += 1; // closing quote
            },
            '0'...'9' => {
                const start = i;
                while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
                try add(&tokens, allocator, .integer, src[start..i], start);
            },
            '<' => {
                if (i + 1 < src.len) {
                    if (src[i + 1] == '-') {
                        try add(&tokens, allocator, .arrow_left, src[i .. i + 2], i);
                        i += 2;
                        continue;
                    }
                    if (src[i + 1] == '=') {
                        try add(&tokens, allocator, .le, src[i .. i + 2], i);
                        i += 2;
                        continue;
                    }
                    if (src[i + 1] == '>') {
                        try add(&tokens, allocator, .ne, src[i .. i + 2], i);
                        i += 2;
                        continue;
                    }
                }
                try add(&tokens, allocator, .lt, src[i .. i + 1], i);
                i += 1;
            },
            '-' => {
                if (i + 1 < src.len and src[i + 1] == '>') {
                    try add(&tokens, allocator, .arrow_right, src[i .. i + 2], i);
                    i += 2;
                } else {
                    try add(&tokens, allocator, .minus, src[i .. i + 1], i);
                    i += 1;
                }
            },
            '=' => {
                try add(&tokens, allocator, .eq, src[i .. i + 1], i);
                i += 1;
            },
            '>' => {
                if (i + 1 < src.len and src[i + 1] == '=') {
                    try add(&tokens, allocator, .ge, src[i .. i + 2], i);
                    i += 2;
                } else {
                    try add(&tokens, allocator, .gt, src[i .. i + 1], i);
                    i += 1;
                }
            },
            else => {
                if (isIdentStart(c)) {
                    const start = i;
                    while (i < src.len and isIdentCont(src[i])) i += 1;
                    try add(&tokens, allocator, .ident, src[start..i], start);
                } else {
                    return error.UnexpectedToken;
                }
            },
        }
    }
    try add(&tokens, allocator, .eof, src[src.len..], src.len);
    return tokens;
}

/// Parses `src` into `ast` and returns the root `query` node index.
pub fn parse(ast: *Ast, src: []const u8) ParseError!Index {
    var tokens = try tokenize(ast.allocator, src);
    defer tokens.deinit(ast.allocator);

    var parser = Parser{
        .ast = ast,
        .tokens = tokens.items,
        .pos = 0,
    };
    return parser.parseQuery();
}

const Parser = struct {
    ast: *Ast,
    tokens: []const Token,
    pos: usize,

    fn peek(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    fn at(self: *const Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (t.kind != .eof) self.pos += 1;
        return t;
    }

    fn atKeyword(self: *const Parser, kw: []const u8) bool {
        const t = self.peek();
        return t.kind == .ident and std.ascii.eqlIgnoreCase(t.text, kw);
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        const t = self.peek();
        if (t.kind != kind) return error.UnexpectedToken;
        _ = self.advance();
    }

    fn expectKeyword(self: *Parser, kw: []const u8) ParseError!void {
        if (!self.atKeyword(kw)) return error.UnexpectedToken;
        _ = self.advance();
    }

    fn expectIdent(self: *Parser) ParseError!Token {
        const t = self.peek();
        if (t.kind != .ident) return error.UnexpectedToken;
        return self.advance();
    }

    /// Consumes an identifier and interns its text into the AST arena.
    fn internIdent(self: *Parser) ParseError![]const u8 {
        const t = try self.expectIdent();
        return self.ast.intern(t.text);
    }

    /// Unescapes `\'` and `\\` and interns the result into the AST arena.
    fn internString(self: *Parser, raw: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
            return self.ast.intern(raw);
        }
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.ast.allocator);
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                switch (raw[i]) {
                    '\\', '\'' => try buf.append(self.ast.allocator, raw[i]),
                    else => {
                        try buf.append(self.ast.allocator, '\\');
                        try buf.append(self.ast.allocator, raw[i]);
                    },
                }
            } else {
                try buf.append(self.ast.allocator, raw[i]);
            }
        }
        return self.ast.intern(buf.items);
    }

    // --- Grammar -----------------------------------------------------------

    fn parseQuery(self: *Parser) ParseError!Index {
        try self.expectKeyword("MATCH");
        const pattern = try self.parsePattern();

        var where_expr: Index = undefined;
        if (self.atKeyword("WHERE")) {
            _ = self.advance();
            where_expr = try self.parseExpr();
        } else {
            where_expr = try self.ast.addNode(.bool_literal, .{ .boolean = true }, &.{});
        }

        try self.expectKeyword("RETURN");
        const projection = try self.parseProjection();

        if (self.peek().kind != .eof) return error.UnexpectedToken;
        return self.ast.addNode(.query, .{ .none = {} }, &.{ pattern, where_expr, projection });
    }

    fn parsePattern(self: *Parser) ParseError!Index {
        var kids = std.ArrayList(Index).empty;
        defer kids.deinit(self.ast.allocator);

        try kids.append(self.ast.allocator, try self.parseNodePattern());
        while (self.at(.minus) or self.at(.arrow_left)) {
            try kids.append(self.ast.allocator, try self.parseEdgePattern());
            try kids.append(self.ast.allocator, try self.parseNodePattern());
        }
        return self.ast.addNode(.pattern, .{ .none = {} }, kids.items);
    }

    fn parseNodePattern(self: *Parser) ParseError!Index {
        try self.expect(.l_paren);
        var var_name: []const u8 = "";
        var label: []const u8 = "";
        if (self.at(.ident)) var_name = try self.ast.intern(self.advance().text);
        if (self.at(.colon)) {
            _ = self.advance();
            label = try self.internIdent();
        }

        var props = std.ArrayList(Index).empty;
        defer props.deinit(self.ast.allocator);
        if (self.at(.l_brace)) {
            _ = self.advance();
            while (!self.at(.r_brace)) {
                const name = try self.internIdent();
                try self.expect(.colon);
                const value = try self.parsePrimary();
                const prop = try self.ast.addNode(.property, .{ .text = name }, &.{value});
                try props.append(self.ast.allocator, prop);
                if (self.at(.comma)) {
                    _ = self.advance();
                } else break;
            }
            try self.expect(.r_brace);
        }

        try self.expect(.r_paren);
        return self.ast.addNode(.node_pattern, .{ .node_pattern = .{ .var_name = var_name, .label = label } }, props.items);
    }

    fn parseEdgeDetails(self: *Parser) ParseError!struct { var_name: []const u8, etype: []const u8 } {
        try self.expect(.l_bracket);
        var var_name: []const u8 = "";
        if (self.at(.ident)) var_name = try self.ast.intern(self.advance().text);
        var etype: []const u8 = "";
        if (self.at(.colon)) {
            _ = self.advance();
            etype = try self.internIdent();
        }
        try self.expect(.r_bracket);
        return .{ .var_name = var_name, .etype = etype };
    }

    fn parseEdgePattern(self: *Parser) ParseError!Index {
        var direction: EdgeDirection = undefined;
        if (self.at(.minus)) {
            _ = self.advance(); // -[...]->
            direction = .left_to_right;
            const d = try self.parseEdgeDetails();
            try self.expect(.arrow_right);
            return self.ast.addNode(.edge_pattern, .{ .edge_pattern = .{ .var_name = d.var_name, .etype = d.etype, .direction = direction } }, &.{});
        }
        _ = self.advance(); // <-[...]-
        direction = .right_to_left;
        const d = try self.parseEdgeDetails();
        try self.expect(.minus);
        return self.ast.addNode(.edge_pattern, .{ .edge_pattern = .{ .var_name = d.var_name, .etype = d.etype, .direction = direction } }, &.{});
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
        const expr = try self.parseExpr();
        var alias: []const u8 = "";
        if (self.atKeyword("AS")) {
            _ = self.advance();
            alias = try self.internIdent();
        }
        return self.ast.addNode(.projection_item, .{ .text = alias }, &.{expr});
    }

    fn parseExpr(self: *Parser) ParseError!Index {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!Index {
        var lhs = try self.parseAnd();
        while (self.atKeyword("OR")) {
            _ = self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.ast.addNode(.binary_op, .{ .bin_op = .or_ }, &.{ lhs, rhs });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) ParseError!Index {
        var lhs = try self.parseNot();
        while (self.atKeyword("AND")) {
            _ = self.advance();
            const rhs = try self.parseNot();
            lhs = try self.ast.addNode(.binary_op, .{ .bin_op = .and_ }, &.{ lhs, rhs });
        }
        return lhs;
    }

    fn parseNot(self: *Parser) ParseError!Index {
        if (self.atKeyword("NOT")) {
            _ = self.advance();
            const operand = try self.parseNot();
            return self.ast.addNode(.unary_op, .{ .un_op = .not_ }, &.{operand});
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) ParseError!Index {
        const lhs = try self.parsePrimary();
        const op: ?BinOp = switch (self.peek().kind) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            else => null,
        };
        if (op) |o| {
            _ = self.advance();
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_op, .{ .bin_op = o }, &.{ lhs, rhs });
        }
        return lhs;
    }

    fn parsePrimary(self: *Parser) ParseError!Index {
        const t = self.peek();
        switch (t.kind) {
            .integer => {
                _ = self.advance();
                const v = std.fmt.parseInt(i64, t.text, 10) catch return error.UnexpectedToken;
                return self.ast.addNode(.int_literal, .{ .int = v }, &.{});
            },
            .string => {
                _ = self.advance();
                const s = try self.internString(t.text);
                return self.ast.addNode(.string_literal, .{ .text = s }, &.{});
            },
            .ident => {
                _ = self.advance();
                if (std.ascii.eqlIgnoreCase(t.text, "true")) return self.ast.addNode(.bool_literal, .{ .boolean = true }, &.{});
                if (std.ascii.eqlIgnoreCase(t.text, "false")) return self.ast.addNode(.bool_literal, .{ .boolean = false }, &.{});
                const name = try self.ast.intern(t.text);
                const var_node = try self.ast.addNode(.variable, .{ .text = name }, &.{});
                if (self.at(.dot)) {
                    _ = self.advance();
                    const prop = try self.internIdent();
                    return self.ast.addNode(.property_access, .{ .text = prop }, &.{var_node});
                }
                return var_node;
            },
            .l_paren => {
                _ = self.advance();
                const e = try self.parseExpr();
                try self.expect(.r_paren);
                return e;
            },
            else => return error.UnexpectedToken,
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseString(src: []const u8) !struct { ast: Ast, root: Index } {
    var ast = Ast.init(testing.allocator);
    errdefer ast.deinit();
    const root = try parse(&ast, src);
    return .{ .ast = ast, .root = root };
}

test "parses a simple MATCH/RETURN query" {
    var r = try parseString("MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born");
    defer r.ast.deinit();

    try testing.expectEqual(NodeKind.query, r.ast.kind(r.root));
    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 3), qc.len);

    // pattern -> single node, no edges
    try testing.expectEqual(NodeKind.pattern, r.ast.kind(qc[0]));
    const pc = r.ast.nodeChildren(qc[0]);
    try testing.expectEqual(@as(usize, 1), pc.len);
    try testing.expectEqual(NodeKind.node_pattern, r.ast.kind(pc[0]));
    try testing.expectEqualStrings("p", r.ast.data(pc[0]).node_pattern.var_name);
    try testing.expectEqualStrings("Person", r.ast.data(pc[0]).node_pattern.label);
    // one property {name: 'Keanu Reeves'}
    const nprops = r.ast.nodeChildren(pc[0]);
    try testing.expectEqual(@as(usize, 1), nprops.len);
    try testing.expectEqual(NodeKind.property, r.ast.kind(nprops[0]));
    try testing.expectEqualStrings("name", r.ast.data(nprops[0]).text);

    // no WHERE -> true
    try testing.expectEqual(NodeKind.bool_literal, r.ast.kind(qc[1]));
    try testing.expect(r.ast.data(qc[1]).boolean);

    // projection -> item -> property_access("born", variable("p"))
    try testing.expectEqual(NodeKind.projection, r.ast.kind(qc[2]));
    const projc = r.ast.nodeChildren(qc[2]);
    try testing.expectEqual(@as(usize, 1), projc.len);
    try testing.expectEqual(NodeKind.projection_item, r.ast.kind(projc[0]));
    const ic = r.ast.nodeChildren(projc[0]);
    try testing.expectEqual(NodeKind.property_access, r.ast.kind(ic[0]));
    try testing.expectEqualStrings("born", r.ast.data(ic[0]).text);
}

test "parses an edge, WHERE with AND, and multiple RETURN items" {
    var r = try parseString(
        "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE p.name = 'Keanu Reeves' AND m.released > 2000 RETURN p.name, m.title",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    const pc = r.ast.nodeChildren(qc[0]);
    try testing.expectEqual(@as(usize, 3), pc.len);
    try testing.expectEqual(NodeKind.edge_pattern, r.ast.kind(pc[1]));
    try testing.expectEqualStrings("ACTED_IN", r.ast.data(pc[1]).edge_pattern.etype);
    try testing.expectEqual(EdgeDirection.left_to_right, r.ast.data(pc[1]).edge_pattern.direction);
    try testing.expectEqualStrings("Movie", r.ast.data(pc[2]).node_pattern.label);

    // WHERE = AND
    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(qc[1]));
    try testing.expectEqual(BinOp.and_, r.ast.data(qc[1]).bin_op);

    // projection = two items
    try testing.expectEqual(NodeKind.projection, r.ast.kind(qc[2]));
    try testing.expectEqual(@as(usize, 2), r.ast.nodeChildren(qc[2]).len);
}

test "parses a reverse-direction edge chain" {
    var r = try parseString(
        "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    const pc = r.ast.nodeChildren(qc[0]);
    try testing.expectEqual(@as(usize, 5), pc.len); // node edge node edge node
    try testing.expectEqual(EdgeDirection.left_to_right, r.ast.data(pc[1]).edge_pattern.direction);
    try testing.expectEqualStrings("DIRECTED", r.ast.data(pc[1]).edge_pattern.etype);
    try testing.expectEqual(EdgeDirection.right_to_left, r.ast.data(pc[3]).edge_pattern.direction);
    try testing.expectEqualStrings("ACTED_IN", r.ast.data(pc[3]).edge_pattern.etype);
}

test "parses RETURN alias and comparison operators" {
    var r = try parseString("MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title AS movie");
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    // WHERE = binary_op ge
    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(qc[1]));
    try testing.expectEqual(BinOp.ge, r.ast.data(qc[1]).bin_op);

    // projection item alias = "movie"
    const projc = r.ast.nodeChildren(qc[2]);
    try testing.expectEqualStrings("movie", r.ast.data(projc[0]).text);
}

test "reports unterminated string" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:Person {name: 'Keanu}) RETURN p.born"));
}

test "reports unexpected token" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:Person) RETURN"));
}
