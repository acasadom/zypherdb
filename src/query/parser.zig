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

const Ast = @import("ast.zig").Ast;
const Index = @import("ast.zig").Index;
const NodeKind = @import("ast.zig").NodeKind;
const EdgeDirection = @import("ast.zig").EdgeDirection;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;
const lexer = @import("lexer.zig");
const Token = lexer.Token;
const TokenKind = lexer.TokenKind;
const tokenize = lexer.tokenize;
const describeTokenKind = lexer.describeTokenKind;
const describeToken = lexer.describeToken;
const expression_parser = @import("expression_parser.zig");

pub const ParseError = lexer.LexError;

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
    return parser.parseUnion();
}

pub const Parser = struct {
    ast: *Ast,
    tokens: []const Token,
    pos: usize,
    diagnostic: ?*Diagnostic,
    /// Parsing a WHERE predicate, where a pattern is an expression
    /// (`WHERE (a)-->(b)`).
    in_where: bool = false,

    pub fn peek(self: *const Parser) Token {
        return self.tokens[self.pos];
    }

    /// The token `offset` places after the next one (the last token, the end
    /// of input, when past it).
    pub fn peekAhead(self: *const Parser, offset: usize) Token {
        return self.tokens[@min(self.pos + offset, self.tokens.len - 1)];
    }

    /// True if the token `offset` places ahead is the (unquoted) keyword.
    pub fn atKeywordAhead(self: *const Parser, offset: usize, keyword: []const u8) bool {
        const t = self.peekAhead(offset);
        return t.kind == .identifier and !t.quoted and std.ascii.eqlIgnoreCase(t.text, keyword);
    }

    pub fn at(self: *const Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    pub fn advance(self: *Parser) Token {
        const t = self.tokens[self.pos];
        if (t.kind != .end_of_input) self.pos += 1;
        return t;
    }

    pub fn atKeyword(self: *const Parser, keyword: []const u8) bool {
        const t = self.peek();
        return t.kind == .identifier and !t.quoted and std.ascii.eqlIgnoreCase(t.text, keyword);
    }

    pub fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        if (self.diagnostic) |d| d.set(.parse, self.peek().pos, fmt, args);
    }

    pub fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        const t = self.peek();
        if (t.kind != kind) {
            self.fail("expected {s}, found {s}", .{ describeTokenKind(kind), describeToken(t) });
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }

    pub fn expectKeyword(self: *Parser, keyword: []const u8) ParseError!void {
        if (!self.atKeyword(keyword)) {
            self.fail("expected keyword {s}", .{keyword});
            return error.UnexpectedToken;
        }
        _ = self.advance();
    }

    pub fn expectIdentifier(self: *Parser) ParseError!Token {
        const t = self.peek();
        if (t.kind != .identifier) {
            self.fail("expected an identifier, found {s}", .{describeToken(t)});
            return error.UnexpectedToken;
        }
        return self.advance();
    }

    /// Consumes an identifier and interns its text into the AST arena.
    pub fn internIdentifier(self: *Parser) ParseError![]const u8 {
        const t = try self.expectIdentifier();
        return self.ast.intern(t.text);
    }

    /// Unescapes `\'` and `\\` and interns the result into the AST arena.
    pub fn internString(self: *Parser, raw: []const u8) ParseError![]const u8 {
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

    /// A query is a sequence of clauses, as in openCypher: reading clauses
    /// (MATCH, OPTIONAL MATCH, UNWIND), WITH, updating clauses (CREATE, MERGE,
    /// SET, DELETE, REMOVE) and a final RETURN. After an update, reading again
    /// needs a WITH in between; the query ends with RETURN or an update.
    /// Queries joined by `UNION` (rows from all, without duplicates) or
    /// `UNION ALL` (all rows); one query alone is just that query. The parts
    /// return the same columns, and a union does not mix the two forms.
    fn parseUnion(self: *Parser) ParseError!Index {
        const first = try self.parseQuery();
        if (!self.atKeyword("UNION")) return first;
        var parts = std.ArrayList(Index).empty;
        defer parts.deinit(self.ast.allocator);
        try parts.append(self.ast.allocator, first);
        var all: ?bool = null;
        while (self.atKeyword("UNION")) {
            _ = self.advance();
            const this_all = self.atKeyword("ALL");
            if (this_all) _ = self.advance();
            if (all != null and all.? != this_all) {
                self.fail("UNION and UNION ALL cannot be mixed", .{});
                return error.UnexpectedToken;
            }
            all = this_all;
            const part = try self.parseQuery();
            try self.checkSameColumns(first, part);
            try parts.append(self.ast.allocator, part);
        }
        return self.ast.addNode(.union_query, .{ .boolean = all.? }, parts.items);
    }

    /// The parts of a union must end in RETURN with the same column names.
    fn checkSameColumns(self: *Parser, a: Index, b: Index) ParseError!void {
        const a_items = self.returnItems(a) orelse return self.failUnion("each part of a UNION must end with RETURN");
        const b_items = self.returnItems(b) orelse return self.failUnion("each part of a UNION must end with RETURN");
        if (a_items.len != b_items.len) return self.failUnion("the parts of a UNION must return the same columns");
        for (a_items, b_items) |x, y| {
            const x_name = self.columnName(x);
            const y_name = self.columnName(y);
            const same = if (x_name != null and y_name != null)
                std.mem.eql(u8, x_name.?, y_name.?)
            else
                x_name == null and y_name == null and self.ast.sameExpression(self.ast.nodeChildren(x)[0], self.ast.nodeChildren(y)[0]);
            if (!same) return self.failUnion("the parts of a UNION must return the same columns");
        }
    }

    fn failUnion(self: *Parser, comptime message: []const u8) ParseError {
        self.fail(message, .{});
        return error.UnexpectedToken;
    }

    /// The projection items of a query's final RETURN, if it ends with one.
    fn returnItems(self: *Parser, query: Index) ?[]const Index {
        const clauses = self.ast.nodeChildren(query);
        const last = clauses[clauses.len - 1];
        if (self.ast.kind(last) != .return_clause) return null;
        for (self.ast.nodeChildren(last)) |child| {
            if (self.ast.kind(child) == .projection) return self.ast.nodeChildren(child);
        }
        return null;
    }

    /// A column's name: its alias, or the variable it projects.
    fn columnName(self: *Parser, item: Index) ?[]const u8 {
        const alias = self.ast.data(item).text;
        if (alias.len > 0) return alias;
        const expression = self.ast.nodeChildren(item)[0];
        if (self.ast.kind(expression) == .variable) return self.ast.data(expression).text;
        return null;
    }

    fn parseQuery(self: *Parser) ParseError!Index {
        var clauses = std.ArrayList(Index).empty;
        defer clauses.deinit(self.ast.allocator);

        var after_update = false;
        var last_reads = false; // the last clause reads (it cannot end the query)
        while (self.peek().kind != .end_of_input and !self.atKeyword("UNION")) {
            if (self.atKeyword("MATCH") or self.atKeyword("OPTIONAL") or self.atKeyword("UNWIND")) {
                if (after_update) {
                    self.fail("a WITH is needed between an updating clause and {s}", .{describeToken(self.peek())});
                    return error.UnexpectedToken;
                }
                const clause = if (self.atKeyword("MATCH"))
                    try self.parseMatchClause()
                else if (self.atKeyword("OPTIONAL"))
                    try self.parseOptionalMatchClause()
                else
                    try self.parseUnwindClause();
                try clauses.append(self.ast.allocator, clause);
                last_reads = true;
            } else if (self.atKeyword("WITH")) {
                try clauses.append(self.ast.allocator, try self.parseWithClause());
                after_update = false;
                last_reads = true;
            } else if (self.atKeyword("RETURN")) {
                _ = self.advance();
                try clauses.append(self.ast.allocator, try self.parseReturnClause());
                if (self.peek().kind != .end_of_input and !self.atKeyword("UNION")) {
                    self.fail("RETURN must be the last clause, found {s} after it", .{describeToken(self.peek())});
                    return error.UnexpectedToken;
                }
                last_reads = false;
            } else if (try self.parseUpdatingClause()) |clause| {
                try clauses.append(self.ast.allocator, clause);
                after_update = true;
                last_reads = false;
            } else {
                self.fail("unexpected {s} (unsupported syntax or missing clause)", .{describeToken(self.peek())});
                return error.UnexpectedToken;
            }
        }
        if (clauses.items.len == 0) {
            self.fail("expected a clause (MATCH, CREATE, RETURN, ...)", .{});
            return error.UnexpectedToken;
        }
        if (last_reads) {
            self.fail("a query must end with RETURN or an updating clause", .{});
            return error.UnexpectedToken;
        }
        return self.ast.addNode(.query, .{ .none = {} }, clauses.items);
    }

    /// CREATE, MERGE, SET, DELETE, DETACH DELETE or REMOVE; null if the next
    /// token starts none of them.
    fn parseUpdatingClause(self: *Parser) ParseError!?Index {
        if (self.atKeyword("CREATE")) {
            _ = self.advance();
            return try self.parseCreateClause();
        }
        if (self.atKeyword("MERGE")) return try self.parseMergeClause();
        if (self.atKeyword("SET")) {
            _ = self.advance();
            return try self.parseSetClause();
        }
        if (self.atKeyword("DELETE")) {
            _ = self.advance();
            return try self.parseDeleteClause(false);
        }
        if (self.atKeyword("DETACH")) {
            _ = self.advance();
            try self.expectKeyword("DELETE");
            return try self.parseDeleteClause(true);
        }
        if (self.atKeyword("REMOVE")) return try self.parseRemoveClause();
        return null;
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
        const expr = try expression_parser.parseExpression(self);
        try self.expectKeyword("AS");
        const variable_name = try self.internIdentifier();
        return self.ast.addNode(.unwind_clause, .{ .unwind = .{ .variable_name = variable_name } }, &.{expr});
    }

    pub fn parseMatchBody(self: *Parser, kind: NodeKind) ParseError!Index {
        var match_kids = std.ArrayList(Index).empty;
        defer match_kids.deinit(self.ast.allocator);
        while (true) {
            const pattern = try self.parsePattern();
            try match_kids.append(self.ast.allocator, pattern);
            if (self.at(.comma)) {
                _ = self.advance();
            } else break;
        }
        try match_kids.append(self.ast.allocator, try self.parseOptionalWhere());
        return self.ast.addNode(kind, .{ .none = {} }, match_kids.items);
    }

    /// `WHERE predicate`, or `true` when there is none.
    pub fn parseOptionalWhere(self: *Parser) ParseError!Index {
        if (!self.atKeyword("WHERE")) return self.ast.addNode(.boolean_literal, .{ .boolean = true }, &.{});
        _ = self.advance();
        const saved = self.in_where;
        self.in_where = true;
        defer self.in_where = saved;
        return expression_parser.parseExpression(self);
    }

    /// If a node pattern `(name:Label {...})` starts `offset` tokens ahead,
    /// the offset just past its `)`.
    pub fn nodePatternEnd(self: *const Parser, offset: usize) ?usize {
        var i = offset;
        if (self.peekAhead(i).kind != .left_paren) return null;
        i += 1;
        if (self.peekAhead(i).kind == .identifier) i += 1;
        while (self.peekAhead(i).kind == .colon and self.peekAhead(i + 1).kind == .identifier) i += 2;
        if (self.peekAhead(i).kind == .left_brace) {
            var depth: usize = 0;
            while (true) : (i += 1) {
                switch (self.peekAhead(i).kind) {
                    .left_brace => depth += 1,
                    .right_brace => {
                        depth -= 1;
                        if (depth == 0) break;
                    },
                    .end_of_input => return null,
                    else => {},
                }
            }
            i += 1;
        }
        if (self.peekAhead(i).kind != .right_paren) return null;
        return i + 1;
    }

    /// True if a relationship pattern (`(a)-->`, `(a)<-`, `(a)-[`, `(a)--(`)
    /// starts `offset` tokens ahead.
    pub fn atRelationshipPattern(self: *const Parser, offset: usize) bool {
        const end = self.nodePatternEnd(offset) orelse return false;
        return switch (self.peekAhead(end).kind) {
            .arrow_left => true,
            .minus => switch (self.peekAhead(end + 1).kind) {
                .left_bracket, .arrow_right => true,
                .minus => self.peekAhead(end + 2).kind == .left_paren,
                else => false,
            },
            else => false,
        };
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
            const expr = try expression_parser.parseExpression(self);
            try children.append(self.ast.allocator, try self.ast.addNode(.skip, .{ .none = {} }, &.{expr}));
        }
        if (self.atKeyword("LIMIT")) {
            _ = self.advance();
            const expr = try expression_parser.parseExpression(self);
            try children.append(self.ast.allocator, try self.ast.addNode(.limit, .{ .none = {} }, &.{expr}));
        }
        try children.append(self.ast.allocator, try self.parseOptionalWhere());

        return self.ast.addNode(.with_clause, .{ .with_ = .{ .distinct = distinct } }, children.items);
    }

    fn parseSetClause(self: *Parser) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            // `n.prop = v`, `n = map`, `n += map` or `n:Label...`.
            const variable_name = try self.internIdentifier();
            const var_node = try self.ast.addNode(.variable, .{ .text = variable_name }, &.{});
            if (self.at(.colon)) {
                while (self.at(.colon)) {
                    _ = self.advance();
                    const label = try self.internIdentifier();
                    try items.append(self.ast.allocator, try self.ast.addNode(.label_reference, .{ .text = label }, &.{var_node}));
                }
            } else if (self.at(.dot)) {
                _ = self.advance();
                const property = try self.internIdentifier();
                const access = try self.ast.addNode(.property_access, .{ .text = property }, &.{var_node});
                try self.expect(.equal);
                const value = try expression_parser.parseExpression(self);
                try items.append(self.ast.allocator, try self.ast.addNode(.set_item, .{ .none = {} }, &.{ access, value }));
            } else {
                const merge = self.at(.plus);
                if (merge) _ = self.advance();
                try self.expect(.equal);
                const value = try expression_parser.parseExpression(self);
                try items.append(self.ast.allocator, try self.ast.addNode(.set_properties, .{ .boolean = merge }, &.{ var_node, value }));
            }
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

    /// Parses the comma-separated patterns of `CREATE` (keyword consumed).
    fn parseCreateClause(self: *Parser) ParseError!Index {
        var patterns = std.ArrayList(Index).empty;
        defer patterns.deinit(self.ast.allocator);
        try patterns.append(self.ast.allocator, try self.parsePattern());
        while (self.at(.comma)) {
            _ = self.advance();
            try patterns.append(self.ast.allocator, try self.parsePattern());
        }
        return self.ast.addNode(.create_clause, .{ .none = {} }, patterns.items);
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

    /// A chain `(a)-[r]->(b)...`, optionally named as a path: `p = (a)-->(b)`
    /// (the pattern's data.text is the path variable, empty if none).
    pub fn parsePattern(self: *Parser) ParseError!Index {
        var children = std.ArrayList(Index).empty;
        defer children.deinit(self.ast.allocator);

        var path_variable: []const u8 = "";
        if (self.at(.identifier) and self.peekAhead(1).kind == .equal) {
            path_variable = try self.ast.intern(self.advance().text);
            _ = self.advance(); // `=`
        }

        try children.append(self.ast.allocator, try self.parseNodePattern());
        while (self.at(.minus) or self.at(.arrow_left)) {
            try children.append(self.ast.allocator, try self.parseEdgePattern());
            try children.append(self.ast.allocator, try self.parseNodePattern());
        }
        return self.ast.addNode(.pattern, .{ .text = path_variable }, children.items);
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
                const value = try expression_parser.parseExpression(self);
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

    const EdgeDetails = struct {
        variable_name: []const u8 = "",
        edge_types: []const []const u8 = &.{},
        variable_length: bool = false,
        min_hops: u32 = 1,
        max_hops: ?u32 = 1,
        properties: std.ArrayList(Index) = .empty,
    };

    /// `[variable:A|B*min..max {properties}]`; every part is optional.
    fn parseEdgeDetails(self: *Parser) ParseError!EdgeDetails {
        try self.expect(.left_bracket);
        var details = EdgeDetails{};
        if (self.at(.identifier)) details.variable_name = try self.ast.intern(self.advance().text);
        if (self.at(.colon)) {
            var types = std.ArrayList([]const u8).empty;
            defer types.deinit(self.ast.allocator);
            _ = self.advance();
            try types.append(self.ast.allocator, try self.internIdentifier());
            while (self.at(.pipe)) {
                _ = self.advance();
                if (self.at(.colon)) _ = self.advance(); // `:A|:B` is accepted too
                try types.append(self.ast.allocator, try self.internIdentifier());
            }
            details.edge_types = try self.ast.internSlice(types.items);
        }
        if (self.at(.star)) try self.parseHops(&details);
        if (self.at(.left_brace)) {
            _ = self.advance();
            while (!self.at(.right_brace)) {
                const name = try self.internIdentifier();
                try self.expect(.colon);
                const value = try expression_parser.parseExpression(self);
                const property = try self.ast.addNode(.property, .{ .text = name }, &.{value});
                try details.properties.append(self.ast.allocator, property);
                if (self.at(.comma)) {
                    _ = self.advance();
                } else break;
            }
            try self.expect(.right_brace);
        }
        try self.expect(.right_bracket);
        return details;
    }

    /// `*`, `*n`, `*min..`, `*..max` or `*min..max` (`*` alone: 1 to unbounded).
    fn parseHops(self: *Parser, details: *EdgeDetails) ParseError!void {
        _ = self.advance(); // `*`
        details.variable_length = true;
        details.min_hops = 1;
        details.max_hops = null;
        if (self.at(.integer)) {
            const n = try self.parseHopCount();
            details.min_hops = n;
            details.max_hops = n; // `*n`: exactly n, unless a range follows
        }
        if (self.at(.range_dots)) {
            _ = self.advance();
            details.max_hops = if (self.at(.integer)) try self.parseHopCount() else null;
        }
    }

    fn parseHopCount(self: *Parser) ParseError!u32 {
        const t = self.advance();
        return std.fmt.parseInt(u32, t.text, 10) catch {
            self.fail("invalid number of hops {s}", .{t.text});
            return error.UnexpectedToken;
        };
    }

    /// Parses an edge between two node patterns. Each end is read on its own:
    /// `<-` or `-` before, `->` or `-` after, with optional `[...]` details in
    /// between. One arrow gives the direction; none or both mean either way.
    fn parseEdgePattern(self: *Parser) ParseError!Index {
        const points_left = self.at(.arrow_left);
        if (points_left) _ = self.advance() else try self.expect(.minus);
        var details = if (self.at(.left_bracket)) try self.parseEdgeDetails() else EdgeDetails{};
        defer details.properties.deinit(self.ast.allocator);
        const points_right = self.at(.arrow_right);
        if (points_right) _ = self.advance() else try self.expect(.minus);

        const direction: EdgeDirection = if (points_left == points_right)
            .undirected
        else if (points_right)
            .left_to_right
        else
            .right_to_left;
        return self.ast.addNode(.edge_pattern, .{ .edge_pattern = .{
            .variable_name = details.variable_name,
            .edge_types = details.edge_types,
            .direction = direction,
            .variable_length = details.variable_length,
            .min_hops = details.min_hops,
            .max_hops = details.max_hops,
        } }, details.properties.items);
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
        const expr = try expression_parser.parseExpression(self);
        var alias: []const u8 = "";
        if (self.atKeyword("AS")) {
            _ = self.advance();
            alias = try self.internIdentifier();
        }
        return self.ast.addNode(.projection_item, .{ .text = alias }, &.{expr});
    }

    pub fn parseReturnClause(self: *Parser) ParseError!Index {
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
            const expr = try expression_parser.parseExpression(self);
            const skip = try self.ast.addNode(.skip, .{ .none = {} }, &.{expr});
            try children.append(self.ast.allocator, skip);
        }

        if (self.atKeyword("LIMIT")) {
            _ = self.advance();
            const expr = try expression_parser.parseExpression(self);
            const limit = try self.ast.addNode(.limit, .{ .none = {} }, &.{expr});
            try children.append(self.ast.allocator, limit);
        }

        return self.ast.addNode(.return_clause, .{ .return_ = .{ .distinct = distinct } }, children.items);
    }

    fn parseOrderBy(self: *Parser) ParseError!Index {
        var items = std.ArrayList(Index).empty;
        defer items.deinit(self.ast.allocator);
        while (true) {
            const expr = try expression_parser.parseExpression(self);
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
};
