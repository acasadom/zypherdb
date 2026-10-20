//! Analyzers: words, search forms and positions.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");
const analyzer = acmedb.text.analyzer;

fn expectTerms(text: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const terms = try analyzer.analyze(arena.allocator(), .standard, text);
    try testing.expectEqual(expected.len, terms.len);
    for (terms, expected, 0..) |term, wanted, position| {
        try testing.expectEqualStrings(wanted, term.text);
        try testing.expectEqual(@as(u32, @intCast(position)), term.position);
    }
}

test "the standard analyzer folds case and accents, and splits on non-word characters" {
    try expectTerms("Contención BIOLÓGICA, nivel-3!", &.{ "contencion", "biologica", "nivel", "3" });
    try expectTerms("  Straße ﬁnal ²", &.{ "strasse", "final", "2" });
    // Decomposed accents (e + combining acute) fold like precomposed ones.
    try expectTerms("cafe\u{301} café", &.{ "cafe", "cafe" });
    // An apostrophe joins the parts of a word, and only there.
    try expectTerms("O'Neill's lab' 'x", &.{ "o'neill's", "lab", "x" });
    try expectTerms("Δοκιμή Испытание 試験", &.{ "δοκιμη", "испытание", "試験" });
    try expectTerms("", &.{});
    try expectTerms("¡¿...?!", &.{});
    // Invalid UTF-8 separates words.
    try expectTerms("ab\xffcd", &.{ "ab", "cd" });
}
