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
    /// A backtick-quoted identifier: never a keyword or function name.
    quoted: bool = false,
};

pub fn tokenKindName(kind: TokenKind) []const u8 {
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

pub fn tokenDesc(t: Token) []const u8 {
    return switch (t.kind) {
        .ident, .string, .integer => t.text,
        else => tokenKindName(t.kind),
    };
}


/// Identifiers are ASCII letters/digits/`_` plus any non-ASCII byte, so UTF-8
/// names (`Pérsona`, `año`) lex as one identifier. The bytes are kept verbatim.
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentCont(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn add(tokens: *std.ArrayList(Token), allocator: Allocator, kind: TokenKind, text: []const u8, pos: usize) LexError!void {
    try tokens.append(allocator, .{ .kind = kind, .text = text, .pos = pos });
}

pub fn tokenize(allocator: Allocator, src: []const u8, diag: ?*Diagnostic) LexError!std.ArrayList(Token) {
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
                    if (diag) |d| d.set(.parse, start, "unterminated string literal", .{});
                    return error.UnexpectedEof;
                }
                try add(&tokens, allocator, .string, src[content_start..i], start);
                i += 1; // closing quote
            },
            '`' => {
                // Quoted identifier: any bytes up to the closing backtick.
                const start = i;
                const end = std.mem.indexOfScalarPos(u8, src, i + 1, '`') orelse {
                    if (diag) |d| d.set(.parse, start, "unterminated quoted identifier", .{});
                    return error.UnexpectedEof;
                };
                if (end == i + 1) {
                    if (diag) |d| d.set(.parse, start, "empty quoted identifier", .{});
                    return error.UnexpectedToken;
                }
                try tokens.append(allocator, .{ .kind = .ident, .text = src[i + 1 .. end], .pos = start, .quoted = true });
                i = end + 1;
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
                    if (diag) |d| d.set(.parse, i, "unexpected character 0x{x:0>2}", .{c});
                    return error.UnexpectedToken;
                }
            },
        }
    }
    try add(&tokens, allocator, .eof, src[src.len..], src.len);
    return tokens;
}

