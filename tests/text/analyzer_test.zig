//! Analyzers: words, search forms and positions.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");
const analyzer = zypherdb.text.analyzer;

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

fn expectAnalyzed(kind: analyzer.Analyzer, text: []const u8, expected: []const struct { []const u8, u32 }) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const terms = try analyzer.analyze(arena.allocator(), kind, text);
    try testing.expectEqual(expected.len, terms.len);
    for (terms, expected) |term, wanted| {
        try testing.expectEqualStrings(wanted[0], term.text);
        try testing.expectEqual(wanted[1], term.position);
    }
}

test "language analyzers drop stop words, keep their positions, and stem" {
    // Stop words leave gaps: the positions still count them.
    try expectAnalyzed(.spanish, "Las contenciones del laboratorio", &.{ .{ "contencion", 1 }, .{ "laboratori", 3 } });
    try expectAnalyzed(.spanish, "contención CONTENCIÓN contencion", &.{ .{ "contencion", 0 }, .{ "contencion", 1 }, .{ "contencion", 2 } });
    try expectAnalyzed(.spanish, "él está aquí", &.{.{ "aqu", 2 }});
    try expectAnalyzed(.english, "The running dogs of the lab", &.{ .{ "run", 1 }, .{ "dog", 2 }, .{ "lab", 5 } });
    try expectAnalyzed(.english, "Generously, O'Neill's", &.{ .{ "generous", 0 }, .{ "o'neil", 1 } });
    // The standard analyzer neither stems nor drops words.
    try expectAnalyzed(.standard, "the running", &.{ .{ "the", 0 }, .{ "running", 1 } });
}
