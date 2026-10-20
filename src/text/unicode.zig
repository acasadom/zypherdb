//! What full-text search needs of Unicode: which code points make up words,
//! and each code point's search form (case-folded, without accents); and
//! the case mappings of toUpper() and toLower(). The tables are generated from the Unicode Character Database
//! (`unicode_tables.zig`, by tools/unicode_tables.py).

const std = @import("std");
const tables = @import("unicode_tables.zig");

/// True if `code` is a letter, a number or a mark.
pub fn isWordCharacter(code: u21) bool {
    var low: usize = 0;
    var high: usize = tables.word_ranges.len;
    while (low < high) {
        const middle = (low + high) / 2;
        const range = tables.word_ranges[middle];
        if (code < range[0]) high = middle else if (code > range[1]) low = middle + 1 else return true;
    }
    return false;
}

/// The search form of `code`: itself (null) or other code points, possibly
/// none (a mark: an accent folds away).
pub fn searchForm(code: u21) ?[]const u21 {
    return mapped(&tables.fold_keys, &tables.fold_starts, &tables.fold_data, code);
}

/// The full case folding of `code` (accents kept): itself (null) or other
/// code points ("ß" folds to "ss").
pub fn caseFold(code: u21) ?[]const u21 {
    return mapped(&tables.case_keys, &tables.case_starts, &tables.case_data, code);
}

/// The full upper case of `code`: itself (null) or other code points ("ß"
/// is "SS").
pub fn upperCase(code: u21) ?[]const u21 {
    return mapped(&tables.upper_keys, &tables.upper_starts, &tables.upper_data, code);
}

/// The full lower case of `code`: itself (null) or other code points.
pub fn lowerCase(code: u21) ?[]const u21 {
    return mapped(&tables.lower_keys, &tables.lower_starts, &tables.lower_data, code);
}

/// The code points a generated table maps `code` to (`data[starts[i]..starts[i + 1]]`
/// for `keys[i] == code`), or null if it maps it to itself. O(log keys).
fn mapped(keys: []const u21, starts: []const u32, data: []const u21, code: u21) ?[]const u21 {
    const position = std.sort.binarySearch(u21, keys, code, struct {
        fn order(key: u21, item: u21) std.math.Order {
            return std.math.order(key, item);
        }
    }.order) orelse return null;
    return data[starts[position]..starts[position + 1]];
}

pub const Case = enum { upper, lower };

/// `text` in upper or lower case, with Unicode's full case mappings. In
/// lower case, a capital sigma that ends a word is the final sigma "ς".
pub fn changeCase(allocator: std.mem.Allocator, text: []const u8, case: Case) std.mem.Allocator.Error![]u8 {
    var result = std.ArrayList(u8).empty;
    try result.ensureTotalCapacity(allocator, text.len);
    var codes = CodePoints{ .bytes = text };
    var previous: ?u21 = null;
    while (codes.next()) |code| {
        defer previous = code;
        if (code < 0x80) {
            const byte: u8 = @intCast(code);
            try result.append(allocator, if (case == .upper) std.ascii.toUpper(byte) else std.ascii.toLower(byte));
            continue;
        }
        var lookahead = codes;
        const following = lookahead.next();
        const final_sigma = case == .lower and code == 0x3A3 and
            previous != null and isWordCharacter(previous.?) and (following == null or !isWordCharacter(following.?));
        const single = [1]u21{if (final_sigma) 0x3C2 else code};
        const mapping = if (final_sigma) &single else (switch (case) {
            .upper => upperCase(code),
            .lower => lowerCase(code),
        }) orelse &single;
        for (mapping) |mapped_code| {
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(mapped_code, &buffer) catch unreachable; // table code points are valid
            try result.appendSlice(allocator, buffer[0..length]);
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Iterates the code points of UTF-8 text; an invalid byte is U+FFFD.
pub const CodePoints = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn next(self: *CodePoints) ?u21 {
        if (self.position >= self.bytes.len) return null;
        const length = std.unicode.utf8ByteSequenceLength(self.bytes[self.position]) catch {
            self.position += 1;
            return 0xFFFD;
        };
        if (self.position + length > self.bytes.len) {
            self.position = self.bytes.len;
            return 0xFFFD;
        }
        const code = std.unicode.utf8Decode(self.bytes[self.position..][0..length]) catch {
            self.position += 1;
            return 0xFFFD;
        };
        self.position += length;
        return code;
    }
};
