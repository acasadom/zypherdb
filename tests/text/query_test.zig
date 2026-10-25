//! Full-text query syntax.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");
const query = zypherdb.text.query;

fn parse(arena: std.mem.Allocator, text: []const u8) ![]const query.Clause {
    var message: []const u8 = "";
    return query.parse(arena, text, &message);
}

fn expectInvalid(text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var message: []const u8 = "";
    try testing.expectError(error.InvalidQuery, query.parse(arena.allocator(), text, &message));
    try testing.expect(message.len > 0);
}

test "queries parse into clauses with occurrence, field and boost" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain = try parse(a, "contención  biológica");
    try testing.expectEqual(@as(usize, 2), plain.len);
    try testing.expectEqualStrings("contención", plain[0].kind.term);
    try testing.expectEqual(query.Occur.should, plain[1].occur);

    const mixed = try parse(a, "+bsl -animal title:\"nivel 3\" conten* contencion~1 x^2.5");
    try testing.expectEqual(query.Occur.must, mixed[0].occur);
    try testing.expectEqual(query.Occur.must_not, mixed[1].occur);
    try testing.expectEqualStrings("title", mixed[2].field.?);
    try testing.expectEqualStrings("nivel 3", mixed[2].kind.phrase);
    try testing.expectEqualStrings("conten", mixed[3].kind.prefix);
    try testing.expectEqual(@as(u8, 1), mixed[4].kind.fuzzy.max_edits);
    try testing.expectEqual(@as(f64, 2.5), mixed[5].boost);

    // AND makes both neighbours required; NOT excludes the next clause.
    const words = try parse(a, "a AND b OR c NOT d");
    try testing.expectEqual(query.Occur.must, words[0].occur);
    try testing.expectEqual(query.Occur.must, words[1].occur);
    try testing.expectEqual(query.Occur.should, words[2].occur);
    try testing.expectEqual(query.Occur.must_not, words[3].occur);

    const grouped = try parse(a, "(a OR b) && c");
    try testing.expectEqual(@as(usize, 2), grouped[0].kind.group.len);
    try testing.expectEqual(query.Occur.must, grouped[0].occur);

    // An escaped special character is part of the term.
    try testing.expectEqualStrings("a:b", (try parse(a, "a\\:b"))[0].kind.term);
    try testing.expectEqual(@as(usize, 0), (try parse(a, "   ")).len);
}

test "malformed queries say what is wrong" {
    try expectInvalid("\"unclosed");
    try expectInvalid("(a OR b");
    try expectInvalid("a)");
    try expectInvalid("co*ten");
    try expectInvalid("cont?ncion");
    try expectInvalid("AND a");
    try expectInvalid("title:");
    try expectInvalid("a^x");
}
