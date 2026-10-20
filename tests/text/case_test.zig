//! toUpper() and toLower(): Unicode's full case mappings.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");
const unicode = acmedb.text.unicode;

fn expectCase(text: []const u8, case: unicode.Case, expected: []const u8) !void {
    const changed = try unicode.changeCase(testing.allocator, text, case);
    defer testing.allocator.free(changed);
    try testing.expectEqualStrings(expected, changed);
}

test "case changes cover every script, and one letter can become several" {
    try expectCase("Ana y Ñandú", .upper, "ANA Y ÑANDÚ");
    try expectCase("ÁRBOL Ελλάδα Москва", .lower, "árbol ελλάδα москва");
    try expectCase("straße", .upper, "STRASSE");
    try expectCase("ﬁ", .upper, "FI");
    // Not table data: the final sigma, chosen by the letters around it.
    try expectCase("ΟΔΥΣΣΕΥΣ ΣΑ", .lower, "οδυσσευς σα");
    try expectCase("", .upper, "");
}
