//! The Snowball stemmers against Snowball's own test vocabularies (a sample
//! of them; see snowball/README.md): every word must stem exactly as the
//! reference implementation stems it.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");
const text = zypherdb.text;

fn codePoints(allocator: std.mem.Allocator, utf8: []const u8) ![]const u21 {
    var codes = std.ArrayList(u21).empty;
    var view = try std.unicode.Utf8View.init(utf8);
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |code| try codes.append(allocator, code);
    return codes.items;
}

fn expectVocabulary(comptime stem: anytype, vocabulary: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var mismatches: usize = 0;
    var words: usize = 0;
    var lines = std.mem.splitScalar(u8, vocabulary, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const space = std.mem.indexOfScalar(u8, line, ' ').?;
        const word = line[0..space];
        const expected = line[space + 1 ..];
        const got = try stem(a, try codePoints(a, word));
        var buffer = std.ArrayList(u8).empty;
        for (got) |code| {
            var bytes: [4]u8 = undefined;
            try buffer.appendSlice(a, bytes[0..try std.unicode.utf8Encode(code, &bytes)]);
        }
        words += 1;
        if (!std.mem.eql(u8, buffer.items, expected)) {
            if (mismatches < 20) std.debug.print("{s}: expected {s}, got {s}\n", .{ word, expected, buffer.items });
            mismatches += 1;
        }
    }
    if (mismatches > 0) std.debug.print("{d} of {d} words differ\n", .{ mismatches, words });
    try testing.expectEqual(@as(usize, 0), mismatches);
}

test "the English stemmer matches Snowball's vocabulary" {
    try expectVocabulary(text.stem_english.stem, @embedFile("snowball/english.txt"));
}

test "the Spanish stemmer matches Snowball's vocabulary" {
    try expectVocabulary(text.stem_spanish.stem, @embedFile("snowball/spanish.txt"));
}
