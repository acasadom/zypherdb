//! Analyzers: text to the terms a full-text index keeps.
//!
//! Every analyzer splits text into words (runs of letters, numbers and
//! marks; an apostrophe between letters stays inside a word, as in
//! "O'Neill") and gives each word its search form: case-folded, without
//! accents, compatibility forms decomposed (`unicode.searchForm`). So
//! "Contención", "CONTENCION" and "contencion" are one term.
//!
//! The `english` and `spanish` analyzers also drop stop words ("the", "de")
//! and reduce each word to its stem with Snowball's stemmer for the language
//! ("contenciones" and "contención" share one term), working on the
//! case-folded word with its accents, which the stemmers' rules need; the
//! accents go after.
//!
//! A term's position is its word's place in the text, counting from 0 (stop
//! words count, though dropped); the positions say which terms follow which,
//! for phrases.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const stop_words = @import("stop_words.zig");
const stem_english = @import("stem_english.zig");
const stem_spanish = @import("stem_spanish.zig");

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
    var terms = std.ArrayList(Term).empty;
    // The word being read, as code points, case-folded (accents kept).
    var word = std.ArrayList(u21).empty;
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
                if (unicode.caseFold(c)) |folded| try word.appendSlice(allocator, folded) else try word.append(allocator, c);
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
            if (try termOf(allocator, analyzer, word.items)) |term_text| {
                try terms.append(allocator, .{ .text = term_text, .position = position });
            }
            position += 1;
            word.clearRetainingCapacity();
        }
        if (code == null) break;
    }
    return terms.items;
}

/// A word's term (null: none, a stop word or too long).
fn termOf(allocator: Allocator, analyzer: Analyzer, folded: []const u21) Allocator.Error!?[]const u8 {
    const stemmed: []const u21 = switch (analyzer) {
        .standard => folded,
        .english, .spanish => stemmed: {
            const list: []const []const u8 = if (analyzer == .english) &stop_words.english else &stop_words.spanish;
            if (stop_words.isStopWord(list, try utf8(allocator, folded))) return null;
            break :stemmed if (analyzer == .english) try stem_english.stem(allocator, folded) else try stem_spanish.stem(allocator, folded);
        },
    };
    var term = std.ArrayList(u8).empty;
    for (stemmed) |code| try appendSearchForm(allocator, &term, code);
    if (term.items.len == 0 or term.items.len > max_term_length) return null;
    return term.items;
}

fn utf8(allocator: Allocator, codes: []const u21) Allocator.Error![]const u8 {
    var bytes = std.ArrayList(u8).empty;
    var buffer: [4]u8 = undefined;
    for (codes) |code| try bytes.appendSlice(allocator, buffer[0 .. std.unicode.utf8Encode(code, &buffer) catch unreachable]);
    return bytes.items;
}

/// One word in its search form, as written in a query (a prefix or a fuzzy
/// term): the folded word characters of `text`, without stemming.
pub fn normalize(allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var word = std.ArrayList(u8).empty;
    var code_points = unicode.CodePoints{ .bytes = text };
    while (code_points.next()) |code| {
        if (unicode.isWordCharacter(code)) try appendSearchForm(allocator, &word, code) else if (code == '\'' and word.items.len > 0) try word.append(allocator, '\'');
    }
    return word.items;
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
