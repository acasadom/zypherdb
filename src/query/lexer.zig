//! Lexer: splits openCypher query text into tokens.
//!
//! Tokens are views into the source (no copies). Keywords are not a token
//! kind: they lex as identifiers and the parser matches them
//! case-insensitively; a backtick-quoted identifier is never a keyword.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;

pub const LexError = error{
    UnexpectedToken,
    UnexpectedEof,
    OutOfMemory,
};

pub const TokenKind = enum {
    identifier,
    parameter, // `$name`: the text is the name
    string,
    integer,
    float, // `1.5`, `.5`, `1e3`, `1.5e-3`
    left_paren,
    right_paren,
    left_bracket,
    right_bracket,
    left_brace,
    right_brace,
    colon,
    comma,
    dot,
    range_dots, // `..` in a list slice
    minus,
    star,
    plus,
    slash,
    percent,
    caret, // `^`
    pipe, // `|`
    arrow_right,
    arrow_left,
    equal,
    not_equal,
    less_than,
    greater_than,
    less_or_equal,
    greater_or_equal,
    end_of_input,
};

pub const Token = struct {
    kind: TokenKind,
    /// Lexeme: content for ident/string/integer, symbol for punctuation.
    text: []const u8,
    /// Byte offset of the token start in the source.
    pos: usize,
    /// A backtick-quoted identifier: never a keyword or function name.
    quoted: bool = false,
};

pub fn describeTokenKind(kind: TokenKind) []const u8 {
    return switch (kind) {
        .identifier => "an identifier",
        .parameter => "a parameter",
        .string => "a string",
        .integer => "an integer",
        .float => "a float",
        .left_paren => "'('",
        .right_paren => "')'",
        .left_bracket => "'['",
        .right_bracket => "']'",
        .left_brace => "'{'",
        .right_brace => "'}'",
        .colon => "':'",
        .comma => "','",
        .dot => "'.'",
        .range_dots => "'..'",
        .minus => "'-'",
        .star => "'*'",
        .plus => "'+'",
        .slash => "'/'",
        .percent => "'%'",
        .caret => "'^'",
        .pipe => "'|'",
        .arrow_right => "'->'",
        .arrow_left => "'<-'",
        .equal => "'='",
        .not_equal => "'<>'",
        .less_than => "'<'",
        .greater_than => "'>'",
        .less_or_equal => "'<='",
        .greater_or_equal => "'>='",
        .end_of_input => "end of query",
    };
}

pub fn describeToken(t: Token) []const u8 {
    return switch (t.kind) {
        .identifier, .parameter, .string, .integer, .float => t.text,
        else => describeTokenKind(t.kind),
    };
}

/// Identifiers are ASCII letters/digits/`_` plus any non-ASCII byte, so UTF-8
/// names (`Pérsona`, `año`) lex as one identifier. The bytes are kept verbatim.
fn isIdentifierStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentifierContinuation(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The end of the decimal number starting at `start`: digits, then a
/// fraction (`.` and digits; `1..3` stays a range) and an exponent if present.
fn scanNumber(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
    if (i + 1 < src.len and src[i] == '.' and std.ascii.isDigit(src[i + 1])) {
        i += 1;
        while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
    }
    if (i < src.len and (src[i] == 'e' or src[i] == 'E')) {
        var j = i + 1;
        if (j < src.len and (src[j] == '+' or src[j] == '-')) j += 1;
        if (j < src.len and std.ascii.isDigit(src[j])) {
            i = j;
            while (i < src.len and std.ascii.isDigit(src[i])) i += 1;
        }
    }
    return i;
}

fn add(tokens: *std.ArrayList(Token), allocator: Allocator, kind: TokenKind, text: []const u8, pos: usize) LexError!void {
    try tokens.append(allocator, .{ .kind = kind, .text = text, .pos = pos });
}

pub fn tokenize(allocator: Allocator, src: []const u8, diagnostic: ?*Diagnostic) LexError!std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => i += 1,
            '+' => {
                try add(&tokens, allocator, .plus, src[i .. i + 1], i);
                i += 1;
            },
            '%' => {
                try add(&tokens, allocator, .percent, src[i .. i + 1], i);
                i += 1;
            },
            '^' => {
                try add(&tokens, allocator, .caret, src[i .. i + 1], i);
                i += 1;
            },
            '|' => {
                try add(&tokens, allocator, .pipe, src[i .. i + 1], i);
                i += 1;
            },
            '/' => {
                if (std.mem.startsWith(u8, src[i..], "//")) {
                    // Line comment, to the end of the line.
                    while (i < src.len and src[i] != '\n') i += 1;
                } else if (std.mem.startsWith(u8, src[i..], "/*")) {
                    // Block comment.
                    const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse {
                        if (diagnostic) |d| d.set(.parse, i, "unterminated comment", .{});
                        return error.UnexpectedEof;
                    };
                    i = end + 2;
                } else {
                    try add(&tokens, allocator, .slash, src[i .. i + 1], i);
                    i += 1;
                }
            },
            '(' => {
                try add(&tokens, allocator, .left_paren, src[i .. i + 1], i);
                i += 1;
            },
            ')' => {
                try add(&tokens, allocator, .right_paren, src[i .. i + 1], i);
                i += 1;
            },
            '[' => {
                try add(&tokens, allocator, .left_bracket, src[i .. i + 1], i);
                i += 1;
            },
            ']' => {
                try add(&tokens, allocator, .right_bracket, src[i .. i + 1], i);
                i += 1;
            },
            '{' => {
                try add(&tokens, allocator, .left_brace, src[i .. i + 1], i);
                i += 1;
            },
            '}' => {
                try add(&tokens, allocator, .right_brace, src[i .. i + 1], i);
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
                // `.5` is a float, unless the dot follows something it can
                // be a property access on (`n.5` is not a number).
                const after_operand = tokens.items.len > 0 and switch (tokens.items[tokens.items.len - 1].kind) {
                    .identifier, .parameter, .right_paren, .right_bracket, .right_brace => true,
                    else => false,
                };
                if (!after_operand and i + 1 < src.len and std.ascii.isDigit(src[i + 1])) {
                    const start = i;
                    i = scanNumber(src, i);
                    try add(&tokens, allocator, .float, src[start..i], start);
                } else if (i + 1 < src.len and src[i + 1] == '.') {
                    try add(&tokens, allocator, .range_dots, src[i .. i + 2], i);
                    i += 2;
                } else {
                    try add(&tokens, allocator, .dot, src[i .. i + 1], i);
                    i += 1;
                }
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
                    if (diagnostic) |d| d.set(.parse, start, "unterminated string literal", .{});
                    return error.UnexpectedEof;
                }
                try add(&tokens, allocator, .string, src[content_start..i], start);
                i += 1; // closing quote
            },
            '$' => {
                // Parameter: `$name` or `$0` (the name is an identifier or digits).
                const start = i;
                i += 1;
                const name_start = i;
                while (i < src.len and isIdentifierContinuation(src[i])) i += 1;
                if (i == name_start) {
                    if (diagnostic) |d| d.set(.parse, start, "expected a parameter name after '$'", .{});
                    return error.UnexpectedToken;
                }
                try add(&tokens, allocator, .parameter, src[name_start..i], start);
            },
            '`' => {
                // Quoted identifier: any bytes up to the closing backtick.
                const start = i;
                const end = std.mem.indexOfScalarPos(u8, src, i + 1, '`') orelse {
                    if (diagnostic) |d| d.set(.parse, start, "unterminated quoted identifier", .{});
                    return error.UnexpectedEof;
                };
                if (end == i + 1) {
                    if (diagnostic) |d| d.set(.parse, start, "empty quoted identifier", .{});
                    return error.UnexpectedToken;
                }
                try tokens.append(allocator, .{ .kind = .identifier, .text = src[i + 1 .. end], .pos = start, .quoted = true });
                i = end + 1;
            },
            '0'...'9' => {
                // Decimal, or hexadecimal (`0x1F`) / octal (`0o17`), or a
                // float. Trailing letters stay in the token so the parser
                // reports the malformed literal.
                const start = i;
                const prefixed = src[i] == '0' and i + 1 < src.len and std.mem.indexOfScalar(u8, "xXoO", src[i + 1]) != null;
                if (!prefixed) i = scanNumber(src, i);
                const is_float = std.mem.indexOfAny(u8, src[start..i], ".eE") != null;
                while (i < src.len and (std.ascii.isAlphanumeric(src[i]) or src[i] == '_')) i += 1;
                try add(&tokens, allocator, if (is_float) .float else .integer, src[start..i], start);
            },
            '<' => {
                if (i + 1 < src.len) {
                    if (src[i + 1] == '-') {
                        try add(&tokens, allocator, .arrow_left, src[i .. i + 2], i);
                        i += 2;
                        continue;
                    }
                    if (src[i + 1] == '=') {
                        try add(&tokens, allocator, .less_or_equal, src[i .. i + 2], i);
                        i += 2;
                        continue;
                    }
                    if (src[i + 1] == '>') {
                        try add(&tokens, allocator, .not_equal, src[i .. i + 2], i);
                        i += 2;
                        continue;
                    }
                }
                try add(&tokens, allocator, .less_than, src[i .. i + 1], i);
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
                try add(&tokens, allocator, .equal, src[i .. i + 1], i);
                i += 1;
            },
            '>' => {
                if (i + 1 < src.len and src[i + 1] == '=') {
                    try add(&tokens, allocator, .greater_or_equal, src[i .. i + 2], i);
                    i += 2;
                } else {
                    try add(&tokens, allocator, .greater_than, src[i .. i + 1], i);
                    i += 1;
                }
            },
            else => {
                if (isIdentifierStart(c)) {
                    const start = i;
                    while (i < src.len and isIdentifierContinuation(src[i])) i += 1;
                    try add(&tokens, allocator, .identifier, src[start..i], start);
                } else {
                    if (diagnostic) |d| d.set(.parse, i, "unexpected character 0x{x:0>2}", .{c});
                    return error.UnexpectedToken;
                }
            },
        }
    }
    try add(&tokens, allocator, .end_of_input, src[src.len..], src.len);
    return tokens;
}
