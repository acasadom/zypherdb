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
const AggKind = @import("../ast/ast.zig").AggKind;
const Diagnostic = @import("../diag.zig").Diagnostic;

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
    star,
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

fn tokenKindName(kind: TokenKind) []const u8 {
    return switch (kind) {
        .ident => "an identifier",
        .string => "a string",
        .integer => "an integer",
        .l_paren => "'('",
        .r_paren => "')'",
        .l_bracket => "'['",
        .r_bracket => "']'",
        .l_brace => "'{'",
        .r_brace => "'}'",
        .colon => "':'",
        .comma => "','",
        .dot => "'.'",
        .minus => "'-'",
        .star => "'*'",
        .arrow_right => "'->'",
        .arrow_left => "'<-'",
        .eq => "'='",
        .ne => "'<>'",
        .lt => "'<'",
        .gt => "'>'",
        .le => "'<='",
        .ge => "'>='",
        .eof => "end of query",
    };
}

fn tokenDesc(t: Token) []const u8 {
    return switch (t.kind) {
        .ident, .string, .integer => t.text,
        else => tokenKindName(t.kind),
    };
}

fn aggKindFromName(name: []const u8) ?AggKind {
    if (std.ascii.eqlIgnoreCase(name, "count")) return .count;
    if (std.ascii.eqlIgnoreCase(name, "sum")) return .sum;
    if (std.ascii.eqlIgnoreCase(name, "min")) return .min;
    if (std.ascii.eqlIgnoreCase(name, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(name, "collect")) return .collect;
    return null;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn add(tokens: *std.ArrayList(Token), allocator: Allocator, kind: TokenKind, text: []const u8, pos: usize) ParseError!void {
    try tokens.append(allocator, .{ .kind = kind, .text = text, .pos = pos });
}

fn tokenize(allocator: Allocator, src: []const u8, diag: ?*Diagnostic) ParseError!std.ArrayList(Token) {
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
            '*' => {
                try add(&tokens, allocator, .star, src[i .. i + 1], i);
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
                if (i >= src.len) {
                    if (diag) |d| d.set(start, "unterminated string literal", .{});
                    return error.UnexpectedEof;
                }
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
                    if (diag) |d| d.set(i, "unexpected character 0x{x:0>2}", .{c});
                    return error.UnexpectedToken;
                }
            },
        }
    }
    try add(&tokens, allocator, .eof, src[src.len..], src.len);
    return tokens;
}

/// Parses `src` into `ast` and returns the root `query` node index. On error,
/// `diag` (if non-null) is populated with a message and byte offset.
pub fn parse(ast: *Ast, src: []const u8, diag: ?*Diagnostic) ParseError!Index {
    var tokens = try tokenize(ast.allocator, src, diag);
    defer tokens.deinit(ast.allocator);

    var parser = Parser{
        .ast = ast,
        .tokens = tokens.items,
        .pos = 0,
        .diag = diag,
    };
    return parser.parseQuery();
}

const Parser = struct {
    ast: *Ast,
    tokens: []const Token,
    pos: usize,
    diag: ?*Diagnostic,

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

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        if (self.diag) |d| d.set(self.peek().pos, fmt, args);
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        const t = self.peek();
        if (t.kind != kind) {
            self.fail("expected {s}, found {s}", .{ tokenKindName(kind), tokenDesc(t) });
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }

    fn expectKeyword(self: *Parser, kw: []const u8) ParseError!void {
        if (!self.atKeyword(kw)) {
            self.fail("expected keyword {s}", .{kw});
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }

    fn expectIdent(self: *Parser) ParseError!Token {
        const t = self.peek();
        if (t.kind != .ident) {
            self.fail("expected an identifier, found {s}", .{tokenDesc(t)});
            return error.UnexpectedToken;
        }
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

        if (self.peek().kind != .eof) return error.UnexpectedToken;
        if (clauses.items.len == 0) return error.UnexpectedToken;
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
        const expr = try self.parseExpr();
        try self.expectKeyword("AS");
        const var_name = try self.internIdent();
        return self.ast.addNode(.unwind_clause, .{ .unwind = .{ .var_name = var_name } }, &.{expr});
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
        var where_expr: Index = undefined;
        if (self.atKeyword("WHERE")) {
            _ = self.advance();
            where_expr = try self.parseExpr();
        } else {
            where_expr = try self.ast.addNode(.bool_literal, .{ .boolean = true }, &.{});
        }
        try match_kids.append(self.ast.allocator, where_expr);
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

        var kids = std.ArrayList(Index).empty;
        defer kids.deinit(self.ast.allocator);
        try kids.append(self.ast.allocator, projection);

        if (self.atKeyword("ORDER")) {
            _ = self.advance();
            try self.expectKeyword("BY");
            try kids.append(self.ast.allocator, try self.parseOrderBy());
        }
        if (self.atKeyword("SKIP")) {
            _ = self.advance();
            const expr = try self.parseExpr();
            try kids.append(self.ast.allocator, try self.ast.addNode(.skip, .{ .none = {} }, &.{expr}));
        }
        if (self.atKeyword("LIMIT")) {
            _ = self.advance();
            const expr = try self.parseExpr();
            try kids.append(self.ast.allocator, try self.ast.addNode(.limit, .{ .none = {} }, &.{expr}));
        }
        if (self.atKeyword("WHERE")) {
            _ = self.advance();
            try kids.append(self.ast.allocator, try self.parseExpr());
        } else {
            try kids.append(self.ast.allocator, try self.ast.addNode(.bool_literal, .{ .boolean = true }, &.{}));
        }

        return self.ast.addNode(.with_clause, .{ .with_ = .{ .distinct = distinct } }, kids.items);
    }

    fn parseSetClause(self: *Parser) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const var_name = try self.internIdent();
            try self.expect(.dot);
            const prop = try self.internIdent();
            const var_node = try self.ast.addNode(.variable, .{ .text = var_name }, &.{});
            const access = try self.ast.addNode(.property_access, .{ .text = prop }, &.{var_node});
            try self.expect(.eq);
            const value = try self.parseExpr();
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
            const name = try self.internIdent();
            const var_node = try self.ast.addNode(.variable, .{ .text = name }, &.{});
            const item = try self.ast.addNode(.delete_item, .{ .none = {} }, &.{var_node});
            try items.append(self.ast.allocator, item);
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        return self.ast.addNode(.delete_clause, .{ .delete = .{ .detach = detach } }, items.items);
    }

    /// Parses `REMOVE n.prop, m:Label`.
    fn parseRemoveClause(self: *Parser) ParseError!Index {
        _ = self.advance(); // REMOVE
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const var_name = try self.internIdent();
            const var_node = try self.ast.addNode(.variable, .{ .text = var_name }, &.{});
            if (self.at(.colon)) {
                _ = self.advance();
                const label = try self.internIdent();
                try items.append(self.ast.allocator, try self.ast.addNode(.label_ref, .{ .text = label }, &.{var_node}));
            } else {
                try self.expect(.dot);
                const prop = try self.internIdent();
                try items.append(self.ast.allocator, try self.ast.addNode(.property_access, .{ .text = prop }, &.{var_node}));
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
                return error.UnexpectedToken;
            }
        }
        return self.ast.addNode(.merge_clause, .{ .none = {} }, &.{ pattern, on_create, on_match });
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
        if (self.at(.ident)) var_name = try self.ast.intern(self.advance().text);

        var labels = std.ArrayList([]const u8).empty;
        defer labels.deinit(self.ast.allocator);
        while (self.at(.colon)) {
            _ = self.advance();
            try labels.append(self.ast.allocator, try self.internIdent());
        }
        const labels_slice = try self.ast.internSlice(labels.items);

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
        return self.ast.addNode(.node_pattern, .{ .node_pattern = .{ .var_name = var_name, .labels = labels_slice } }, props.items);
    }

    fn parseEdgeDetails(self: *Parser) ParseError!struct { var_name: []const u8, etype: []const u8, props: std.ArrayList(Index) } {
        try self.expect(.l_bracket);
        var var_name: []const u8 = "";
        if (self.at(.ident)) var_name = try self.ast.intern(self.advance().text);
        var etype: []const u8 = "";
        if (self.at(.colon)) {
            _ = self.advance();
            etype = try self.internIdent();
        }
        var props = std.ArrayList(Index).empty;
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
        try self.expect(.r_bracket);
        return .{ .var_name = var_name, .etype = etype, .props = props };
    }

    fn parseEdgePattern(self: *Parser) ParseError!Index {
        var direction: EdgeDirection = undefined;
        if (self.at(.minus)) {
            _ = self.advance(); // -[...]->
            direction = .left_to_right;
            var d = try self.parseEdgeDetails();
            defer d.props.deinit(self.ast.allocator);
            try self.expect(.arrow_right);
            return self.ast.addNode(.edge_pattern, .{ .edge_pattern = .{ .var_name = d.var_name, .etype = d.etype, .direction = direction } }, d.props.items);
        }
        _ = self.advance(); // <-[...]-
        direction = .right_to_left;
        var d = try self.parseEdgeDetails();
        defer d.props.deinit(self.ast.allocator);
        try self.expect(.minus);
        return self.ast.addNode(.edge_pattern, .{ .edge_pattern = .{ .var_name = d.var_name, .etype = d.etype, .direction = direction } }, d.props.items);
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

    fn parseReturnClause(self: *Parser) ParseError!Index {
        var distinct = false;
        if (self.atKeyword("DISTINCT")) {
            _ = self.advance();
            distinct = true;
        }
        const projection = try self.parseProjection();

        var kids = std.ArrayList(Index).empty;
        defer kids.deinit(self.ast.allocator);
        try kids.append(self.ast.allocator, projection);

        if (self.atKeyword("ORDER")) {
            _ = self.advance();
            try self.expectKeyword("BY");
            const ob = try self.parseOrderBy();
            try kids.append(self.ast.allocator, ob);
        }

        if (self.atKeyword("SKIP")) {
            _ = self.advance();
            const expr = try self.parseExpr();
            const sk = try self.ast.addNode(.skip, .{ .none = {} }, &.{expr});
            try kids.append(self.ast.allocator, sk);
        }

        if (self.atKeyword("LIMIT")) {
            _ = self.advance();
            const expr = try self.parseExpr();
            const lim = try self.ast.addNode(.limit, .{ .none = {} }, &.{expr});
            try kids.append(self.ast.allocator, lim);
        }

        return self.ast.addNode(.return_clause, .{ .return_ = .{ .distinct = distinct } }, kids.items);
    }

    fn parseOrderBy(self: *Parser) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const expr = try self.parseExpr();
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

        // Multi-word string predicates (checked before the single-token ops,
        // since `STARTS`/`ENDS`/`CONTAINS`/`IN` lex as plain identifiers).
        if (self.atKeyword("STARTS")) {
            _ = self.advance();
            try self.expectKeyword("WITH");
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_op, .{ .bin_op = .starts_with }, &.{ lhs, rhs });
        }
        if (self.atKeyword("ENDS")) {
            _ = self.advance();
            try self.expectKeyword("WITH");
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_op, .{ .bin_op = .ends_with }, &.{ lhs, rhs });
        }
        if (self.atKeyword("CONTAINS")) {
            _ = self.advance();
            const rhs = try self.parsePrimary();
            return self.ast.addNode(.binary_op, .{ .bin_op = .contains }, &.{ lhs, rhs });
        }
        if (self.atKeyword("IN")) {
            _ = self.advance();
            const list = try self.parseListLiteral();
            return self.ast.addNode(.binary_op, .{ .bin_op = .in_ }, &.{ lhs, list });
        }

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

    /// Parses a list literal `[e0, e1, ...]` (elements are primary expressions;
    /// the empty list is allowed).
    fn parseListLiteral(self: *Parser) ParseError!Index {
        try self.expect(.l_bracket);
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (!self.at(.r_bracket)) {
            try items.append(self.ast.allocator, try self.parsePrimary());
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        try self.expect(.r_bracket);
        return self.ast.addNode(.list_literal, .{ .none = {} }, items.items);
    }

    fn parsePrimary(self: *Parser) ParseError!Index {
        if (self.atKeyword("CASE")) return self.parseCaseExpr();
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
                if (aggKindFromName(t.text)) |kind| {
                    if (self.at(.l_paren)) {
                        return self.parseAggCall(kind);
                    }
                }
                if (std.ascii.eqlIgnoreCase(t.text, "size")) {
                    if (self.at(.l_paren)) {
                        _ = self.advance();
                        const arg = try self.parseExpr();
                        try self.expect(.r_paren);
                        return self.ast.addNode(.size_fn, .{ .none = {} }, &.{arg});
                    }
                }
                const name = try self.ast.intern(t.text);
                const var_node = try self.ast.addNode(.variable, .{ .text = name }, &.{});
                if (self.at(.dot)) {
                    _ = self.advance();
                    const prop = try self.internIdent();
                    return self.ast.addNode(.property_access, .{ .text = prop }, &.{var_node});
                }
                return var_node;
            },
            .l_bracket => return self.parseListLiteral(),
            .l_paren => {
                _ = self.advance();
                const e = try self.parseExpr();
                try self.expect(.r_paren);
                return e;
            },
            else => {
                self.fail("expected an expression, found {s}", .{tokenDesc(t)});
                return error.UnexpectedToken;
            },
        }
    }

    fn parseCaseExpr(self: *Parser) ParseError!Index {
        _ = self.advance(); // CASE
        var kids = std.ArrayList(Index).empty;
        defer kids.deinit(self.ast.allocator);
        while (self.atKeyword("WHEN")) {
            _ = self.advance();
            const cond = try self.parseExpr();
            try self.expectKeyword("THEN");
            const result = try self.parseExpr();
            try kids.append(self.ast.allocator, cond);
            try kids.append(self.ast.allocator, result);
        }
        if (self.atKeyword("ELSE")) {
            _ = self.advance();
            try kids.append(self.ast.allocator, try self.parseExpr());
        }
        try self.expectKeyword("END");
        return self.ast.addNode(.case_expr, .{ .none = {} }, kids.items);
    }

    fn parseAggCall(self: *Parser, kind: AggKind) ParseError!Index {
        try self.expect(.l_paren);
        if (kind == .count and self.at(.star)) {
            _ = self.advance();
            try self.expect(.r_paren);
            return self.ast.addNode(.agg, .{ .agg = kind }, &.{});
        }
        const arg = try self.parseExpr();
        try self.expect(.r_paren);
        return self.ast.addNode(.agg, .{ .agg = kind }, &.{arg});
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseString(src: []const u8) !struct { ast: Ast, root: Index } {
    var ast = Ast.init(testing.allocator);
    errdefer ast.deinit();
    const root = try parse(&ast, src, null);
    return .{ .ast = ast, .root = root };
}

test "parses a simple MATCH/RETURN query" {
    var r = try parseString("MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born");
    defer r.ast.deinit();

    try testing.expectEqual(NodeKind.query, r.ast.kind(r.root));
    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 2), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[1]));

    // match_clause -> [pattern, where=true]
    const mc = r.ast.nodeChildren(qc[0]);
    try testing.expectEqual(@as(usize, 2), mc.len);
    try testing.expectEqual(NodeKind.pattern, r.ast.kind(mc[0]));
    try testing.expectEqual(NodeKind.bool_literal, r.ast.kind(mc[1]));
    try testing.expect(r.ast.data(mc[1]).boolean);

    // pattern -> single node
    const pc = r.ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 1), pc.len);
    try testing.expectEqualStrings("p", r.ast.data(pc[0]).node_pattern.var_name);
    try testing.expectEqualStrings("Person", r.ast.data(pc[0]).node_pattern.labels[0]);

    // return_clause -> projection -> property_access("born")
    const rc = r.ast.nodeChildren(qc[1]);
    const projc = r.ast.nodeChildren(rc[0]);
    try testing.expectEqual(@as(usize, 1), projc.len);
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
    const mc = r.ast.nodeChildren(qc[0]);
    const pc = r.ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 3), pc.len);
    try testing.expectEqualStrings("ACTED_IN", r.ast.data(pc[1]).edge_pattern.etype);
    try testing.expectEqual(EdgeDirection.left_to_right, r.ast.data(pc[1]).edge_pattern.direction);

    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(mc[1]));
    try testing.expectEqual(BinOp.and_, r.ast.data(mc[1]).bin_op);

    const rc = r.ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 2), r.ast.nodeChildren(rc[0]).len);
}

test "parses a reverse-direction edge chain" {
    var r = try parseString(
        "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    const mc = r.ast.nodeChildren(qc[0]);
    const pc = r.ast.nodeChildren(mc[0]);
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
    const mc = r.ast.nodeChildren(qc[0]);
    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(mc[1]));
    try testing.expectEqual(BinOp.ge, r.ast.data(mc[1]).bin_op);

    const rc = r.ast.nodeChildren(qc[1]);
    const projc = r.ast.nodeChildren(rc[0]);
    try testing.expectEqualStrings("movie", r.ast.data(projc[0]).text);
}

test "parses string predicates and IN lists" {
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title STARTS WITH 'The' RETURN m.title");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinOp.starts_with, r.ast.data(mc[1]).bin_op);
        try testing.expectEqual(NodeKind.string_literal, r.ast.kind(r.ast.nodeChildren(mc[1])[1]));
    }
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title ENDS WITH 'Wick' RETURN m.title");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinOp.ends_with, r.ast.data(mc[1]).bin_op);
    }
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title CONTAINS 'Matrix' RETURN m.title");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinOp.contains, r.ast.data(mc[1]).bin_op);
    }
    {
        var r = try parseString("MATCH (p:Person) WHERE p.name IN ['Keanu Reeves', 'Tom Hanks'] RETURN p.name");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const where_expr = mc[1];
        try testing.expectEqual(BinOp.in_, r.ast.data(where_expr).bin_op);
        const list = r.ast.nodeChildren(where_expr)[1];
        try testing.expectEqual(NodeKind.list_literal, r.ast.kind(list));
        try testing.expectEqual(@as(usize, 2), r.ast.nodeChildren(list).len);
    }
}

test "parses WITH and SKIP clauses" {
    var r = try parseString(
        "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt ORDER BY cnt DESC SKIP 1 LIMIT 5 WHERE cnt > 1 RETURN p.name, cnt",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 3), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.with_clause, r.ast.kind(qc[1]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[2]));

    // with_clause children: [projection, order_by, skip, limit, where].
    const wc = r.ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 5), wc.len);
    try testing.expectEqual(NodeKind.projection, r.ast.kind(wc[0]));
    try testing.expectEqual(NodeKind.order_by, r.ast.kind(wc[1]));
    try testing.expectEqual(NodeKind.skip, r.ast.kind(wc[2]));
    try testing.expectEqual(NodeKind.limit, r.ast.kind(wc[3]));
    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(wc[4]));

    // projection has two items: `p` and `count(m) AS cnt`.
    const projc = r.ast.nodeChildren(wc[0]);
    try testing.expectEqual(@as(usize, 2), projc.len);
    try testing.expectEqual(NodeKind.variable, r.ast.kind(r.ast.nodeChildren(projc[0])[0]));
    try testing.expectEqualStrings("cnt", r.ast.data(projc[1]).text);
}

test "parses OPTIONAL MATCH" {
    var r = try parseString(
        "MATCH (a:Person) OPTIONAL MATCH (a)-[:KNOWS]->(b:Person) RETURN a.name, b.name",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 3), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.optional_match_clause, r.ast.kind(qc[1]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[2]));

    // optional_match_clause children: [pattern, where].
    const omc = r.ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 2), omc.len);
    try testing.expectEqual(NodeKind.pattern, r.ast.kind(omc[0]));
}

test "parses lists: collect, size and UNWIND" {
    {
        var r = try parseString("MATCH (m:Movie) RETURN collect(m.title)");
        defer r.ast.deinit();
        const rc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[1]);
        const item = r.ast.nodeChildren(rc[0])[0];
        try testing.expectEqual(NodeKind.agg, r.ast.kind(r.ast.nodeChildren(item)[0]));
        try testing.expectEqual(AggKind.collect, r.ast.data(r.ast.nodeChildren(item)[0]).agg);
    }
    {
        var r = try parseString("RETURN size([1, 2, 3])");
        defer r.ast.deinit();
        const rc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const item = r.ast.nodeChildren(rc[0])[0];
        try testing.expectEqual(NodeKind.size_fn, r.ast.kind(r.ast.nodeChildren(item)[0]));
    }
    {
        var r = try parseString("UNWIND [1, 2, 3] AS x RETURN x");
        defer r.ast.deinit();
        const qc = r.ast.nodeChildren(r.root);
        try testing.expectEqual(@as(usize, 2), qc.len);
        try testing.expectEqual(NodeKind.unwind_clause, r.ast.kind(qc[0]));
        try testing.expectEqualStrings("x", r.ast.data(qc[0]).unwind.var_name);
        const expr = r.ast.nodeChildren(qc[0])[0];
        try testing.expectEqual(NodeKind.list_literal, r.ast.kind(expr));
    }
}

test "parses multi-label, CASE, REMOVE and MERGE ON" {
    {
        var r = try parseString("MATCH (n:Person:Employee) RETURN n.name");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const np = r.ast.data(r.ast.nodeChildren(mc[0])[0]).node_pattern;
        try testing.expectEqual(@as(usize, 2), np.labels.len);
        try testing.expectEqualStrings("Person", np.labels[0]);
        try testing.expectEqualStrings("Employee", np.labels[1]);
    }
    {
        var r = try parseString("RETURN CASE WHEN 1 > 0 THEN 'yes' ELSE 'no' END");
        defer r.ast.deinit();
        const rc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const item = r.ast.nodeChildren(rc[0])[0];
        try testing.expectEqual(NodeKind.case_expr, r.ast.kind(r.ast.nodeChildren(item)[0]));
    }
    {
        var r = try parseString("MATCH (n:Person) REMOVE n.name, n:Person");
        defer r.ast.deinit();
        const qc = r.ast.nodeChildren(r.root);
        try testing.expectEqual(NodeKind.remove_clause, r.ast.kind(qc[1]));
        const rc = r.ast.nodeChildren(qc[1]);
        try testing.expectEqual(@as(usize, 2), rc.len);
        try testing.expectEqual(NodeKind.property_access, r.ast.kind(rc[0]));
        try testing.expectEqual(NodeKind.label_ref, r.ast.kind(rc[1]));
    }
    {
        var r = try parseString("MERGE (n:Person {name: 'X'}) ON CREATE SET n.c = 1 ON MATCH SET n.m = 1");
        defer r.ast.deinit();
        const qc = r.ast.nodeChildren(r.root);
        const mc = r.ast.nodeChildren(qc[0]);
        try testing.expectEqual(@as(usize, 3), mc.len); // pattern + on_create + on_match
        try testing.expectEqual(NodeKind.pattern, r.ast.kind(mc[0]));
        try testing.expectEqual(NodeKind.set_clause, r.ast.kind(mc[1]));
        try testing.expectEqual(NodeKind.set_clause, r.ast.kind(mc[2]));
    }
}

test "parses write clauses (CREATE, SET, DELETE)" {
    var r = try parseString(
        "MATCH (a:Person {name: 'Keanu Reeves'}) CREATE (a)-[:KNOWS]->(b:Person {name: 'Neo'}) SET b.born = 1964 DELETE a RETURN b.name",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 5), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.create_clause, r.ast.kind(qc[1]));
    try testing.expectEqual(NodeKind.set_clause, r.ast.kind(qc[2]));
    try testing.expectEqual(NodeKind.delete_clause, r.ast.kind(qc[3]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[4]));

    // create_clause -> pattern (node edge node)
    const cc = r.ast.nodeChildren(qc[1]);
    const cpc = r.ast.nodeChildren(cc[0]);
    try testing.expectEqual(@as(usize, 3), cpc.len);
    try testing.expectEqualStrings("KNOWS", r.ast.data(cpc[1]).edge_pattern.etype);

    // set_clause -> one set_item (property_access + value)
    const sc = r.ast.nodeChildren(qc[2]);
    try testing.expectEqual(@as(usize, 1), sc.len);
    try testing.expectEqual(NodeKind.set_item, r.ast.kind(sc[0]));
    const sic = r.ast.nodeChildren(sc[0]);
    try testing.expectEqual(NodeKind.property_access, r.ast.kind(sic[0]));
    try testing.expectEqualStrings("born", r.ast.data(sic[0]).text);
}

test "reports unterminated string" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:Person {name: 'Keanu}) RETURN p.born", null));
}

test "reports unexpected token" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:Person) RETURN", null));
}

test "diagnostics carry a message and position" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    var diag = Diagnostic.init();
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:Person) RETURN )", &diag));
    try testing.expectEqualStrings("expected an expression, found ')'", diag.message());
    try testing.expectEqual(@as(usize, 24), diag.pos);

    var diag2 = Diagnostic.init();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:Person {name: 'Keanu}) RETURN p.born", &diag2));
    try testing.expectEqualStrings("unterminated string literal", diag2.message());
}
