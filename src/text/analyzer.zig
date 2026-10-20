//! Analyzers: text to the terms a full-text index keeps.
//!
//! Every analyzer splits text into words (runs of letters, numbers and
//! marks; an apostrophe between letters stays inside a word, as in
//! "O'Neill") and gives each word its search form: case-folded, without
//! accents, compatibility forms decomposed (`unicode.searchForm`). So
//! "Contención", "CONTENCION" and "contencion" are one term.
//!
//! A term's position is its word's place in the text, counting from 0; the
//! positions say which terms follow which, for phrases.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");

pub const Analyzer = enum {
    standard,
    english,
    spanish,

    pub fn fromName(name: []const u8) ?Analyzer {
        return std.meta.stringToEnum(Analyzer, name);
    }
};

pub const Term = struct { text: []const u8, position: u32 };

/// Words longer than this (in bytes, folded) are dropped, as no one searches them.
pub const max_term_length = 255;

/// The terms of `text`, in order, allocated with `allocator`.
pub fn analyze(allocator: Allocator, analyzer: Analyzer, text: []const u8) Allocator.Error![]Term {
    _ = analyzer; // stop words and stemming: by analyzer
    var terms = std.ArrayList(Term).empty;
    var word = std.ArrayList(u8).empty;
    defer word.deinit(allocator);
    var position: u32 = 0;
    var pending_apostrophe = false;
    var code_points = unicode.CodePoints{ .bytes = text };
    while (true) {
        const code = code_points.next();
        if (code) |c| {
            if (unicode.isWordCharacter(c)) {
                if (pending_apostrophe) try word.append(allocator, '\'');
                pending_apostrophe = false;
                try appendSearchForm(allocator, &word, c);
                continue;
            }
            // An apostrophe joins two parts of a word; elsewhere it separates.
            if ((c == '\'' or c == 0x2019) and word.items.len > 0 and !pending_apostrophe) {
                pending_apostrophe = true;
                continue;
            }
        }
        pending_apostrophe = false;
        if (word.items.len > 0) {
            if (word.items.len <= max_term_length) {
                try terms.append(allocator, .{ .text = try allocator.dupe(u8, word.items), .position = position });
                position += 1;
            }
            word.clearRetainingCapacity();
        }
        if (code == null) break;
    }
    return terms.items;
}

fn appendSearchForm(allocator: Allocator, word: *std.ArrayList(u8), code: u21) Allocator.Error!void {
    var buffer: [4]u8 = undefined;
    if (unicode.searchForm(code)) |form| {
        for (form) |folded| {
            const length = std.unicode.utf8Encode(folded, &buffer) catch unreachable;
            try word.appendSlice(allocator, buffer[0..length]);
        }
    } else {
        const length = std.unicode.utf8Encode(code, &buffer) catch unreachable;
        try word.appendSlice(allocator, buffer[0..length]);
    }
}
