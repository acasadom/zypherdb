//! Full-text queries: the part of Lucene's query syntax that Neo4j's
//! full-text indexes accept.
//!
//!     contención biológica       either term (clauses are optional by default)
//!     "nivel 3"                  a phrase: the terms in a row, in one property
//!     conten*                    a prefix
//!     contencion~  contencion~1  a fuzzy term: up to 2 (or n, at most 2) edits
//!     +bsl -animal               a required clause, an excluded one
//!     a AND b, a OR b, NOT a     the same with words (&&, ||, ! too)
//!     title:contención           only in the property `title`
//!     (a OR b) AND c             a group
//!     contención^2               a boost: the clause's score times 2
//!     \:  \"  \(                 an escaped special character
//!
//! As in Lucene: a query with required clauses matches what has all of them
//! (the optional ones only add to the score); otherwise it matches what has
//! at least one optional clause. An excluded clause removes what it matches.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Occur = enum { should, must, must_not };

pub const Clause = struct {
    occur: Occur = .should,
    kind: Kind,
    /// The property the clause is limited to (`title:`), if any.
    field: ?[]const u8 = null,
    boost: f64 = 1,

    pub const Kind = union(enum) {
        /// Text as written: analyzed like the index's text (several words:
        /// a phrase).
        term: []const u8,
        phrase: []const u8,
        prefix: []const u8,
        fuzzy: struct { text: []const u8, max_edits: u8 },
        group: []const Clause,
    };
};

pub const Error = Allocator.Error || error{InvalidQuery};

/// The parsed query; on a syntax error, `message` says what is wrong.
pub fn parse(allocator: Allocator, text: []const u8, message: *[]const u8) Error![]const Clause {
    var parser = Parser{ .allocator = allocator, .text = text, .message = message };
    const clauses = try parser.parseClauses(false);
    if (parser.position < text.len) return parser.fail("unexpected ')'");
    return clauses;
}

const Parser = struct {
    allocator: Allocator,
    text: []const u8,
    position: usize = 0,
    message: *[]const u8,

    fn fail(self: *Parser, message: []const u8) Error {
        self.message.* = message;
        return error.InvalidQuery;
    }

    fn parseClauses(self: *Parser, in_group: bool) Error![]const Clause {
        var clauses = std.ArrayList(Clause).empty;
        var next_occur: ?Occur = null;
        var previous_and = false;
        while (true) {
            self.skipSpaces();
            if (self.position >= self.text.len) break;
            if (self.text[self.position] == ')') {
                if (!in_group) return self.fail("unexpected ')'");
                break;
            }
            if (self.atWord("AND") or self.atSymbol("&&")) {
                if (clauses.items.len == 0) return self.fail("AND needs a clause before it");
                const last = &clauses.items[clauses.items.len - 1];
                if (last.occur == .should) last.occur = .must;
                previous_and = true;
                continue;
            }
            if (self.atWord("OR") or self.atSymbol("||")) continue;
            if (self.atWord("NOT") or self.atSymbol("!")) {
                next_occur = .must_not;
                continue;
            }
            var occur: Occur = next_occur orelse .should;
            next_occur = null;
            switch (self.text[self.position]) {
                '+' => {
                    occur = .must;
                    self.position += 1;
                },
                '-' => {
                    occur = .must_not;
                    self.position += 1;
                },
                else => {},
            }
            if (previous_and and occur == .should) occur = .must;
            previous_and = false;
            var clause = try self.parseClause();
            clause.occur = occur;
            try clauses.append(self.allocator, clause);
        }
        return clauses.items;
    }

    fn parseClause(self: *Parser) Error!Clause {
        var field: ?[]const u8 = null;
        // `name:` before a term, phrase or group.
        if (self.fieldEnd()) |end| {
            field = self.text[self.position..end];
            self.position = end + 1;
        }
        if (self.position >= self.text.len) return self.fail("a field needs something to search for after ':'");
        var clause: Clause = switch (self.text[self.position]) {
            '"' => .{ .kind = .{ .phrase = try self.parsePhrase() } },
            '(' => group: {
                self.position += 1;
                const inner = try self.parseClauses(true);
                if (self.position >= self.text.len or self.text[self.position] != ')') return self.fail("a '(' has no ')'");
                self.position += 1;
                break :group .{ .kind = .{ .group = inner } };
            },
            else => try self.parseTerm(),
        };
        clause.field = field;
        if (self.position < self.text.len and self.text[self.position] == '^') {
            self.position += 1;
            const start = self.position;
            while (self.position < self.text.len and (std.ascii.isDigit(self.text[self.position]) or self.text[self.position] == '.')) self.position += 1;
            clause.boost = std.fmt.parseFloat(f64, self.text[start..self.position]) catch return self.fail("'^' needs a number: term^2");
        }
        return clause;
    }

    fn parsePhrase(self: *Parser) Error![]const u8 {
        self.position += 1; // opening quote
        var phrase = std.ArrayList(u8).empty;
        while (self.position < self.text.len) : (self.position += 1) {
            const c = self.text[self.position];
            if (c == '\\' and self.position + 1 < self.text.len) {
                self.position += 1;
                try phrase.append(self.allocator, self.text[self.position]);
            } else if (c == '"') {
                self.position += 1;
                return phrase.items;
            } else try phrase.append(self.allocator, c);
        }
        return self.fail("a phrase has no closing '\"'");
    }

    fn parseTerm(self: *Parser) Error!Clause {
        var term = std.ArrayList(u8).empty;
        var prefix = false;
        while (self.position < self.text.len) {
            const c = self.text[self.position];
            if (c == '\\' and self.position + 1 < self.text.len) {
                try term.append(self.allocator, self.text[self.position + 1]);
                self.position += 2;
                continue;
            }
            if (isSeparator(c) or c == '^' or c == '~') break;
            if (c == '*') {
                self.position += 1;
                if (self.position < self.text.len and !isSeparator(self.text[self.position]) and self.text[self.position] != '^') {
                    return self.fail("'*' is only supported at the end of a term: conten*");
                }
                prefix = true;
                break;
            }
            if (c == '?') return self.fail("'?' wildcards are not supported; use a prefix (conten*) or a fuzzy term (contencion~)");
            if (c == '"' or c == '(' or c == ':') return self.fail("unexpected special character; escape it with '\\'");
            try term.append(self.allocator, c);
            self.position += 1;
        }
        if (term.items.len == 0) return self.fail("expected a term");
        if (prefix) return .{ .kind = .{ .prefix = term.items } };
        if (self.position < self.text.len and self.text[self.position] == '~') {
            self.position += 1;
            var max_edits: u8 = 2;
            if (self.position < self.text.len and std.ascii.isDigit(self.text[self.position])) {
                max_edits = @min(self.text[self.position] - '0', 2);
                self.position += 1;
            }
            return .{ .kind = .{ .fuzzy = .{ .text = term.items, .max_edits = max_edits } } };
        }
        return .{ .kind = .{ .term = term.items } };
    }

    /// The position of the ':' if a field name starts here.
    fn fieldEnd(self: *const Parser) ?usize {
        var i = self.position;
        while (i < self.text.len and (std.ascii.isAlphanumeric(self.text[i]) or self.text[i] == '_')) i += 1;
        if (i == self.position or i >= self.text.len or self.text[i] != ':') return null;
        return i;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.position < self.text.len and std.ascii.isWhitespace(self.text[self.position])) self.position += 1;
    }

    /// An operator word (AND, OR, NOT) standing alone; consumed if so.
    fn atWord(self: *Parser, word: []const u8) bool {
        const end = self.position + word.len;
        if (end > self.text.len or !std.mem.eql(u8, self.text[self.position..end], word)) return false;
        if (end < self.text.len and !std.ascii.isWhitespace(self.text[end]) and self.text[end] != '(' and self.text[end] != '"') return false;
        self.position = end;
        return true;
    }

    fn atSymbol(self: *Parser, symbol: []const u8) bool {
        if (!std.mem.startsWith(u8, self.text[self.position..], symbol)) return false;
        self.position += symbol.len;
        return true;
    }
};

fn isSeparator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == ')';
}
