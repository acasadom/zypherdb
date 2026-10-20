//! What full-text search needs of Unicode: which code points make up words,
//! and each code point's search form (case-folded, without accents). The
//! tables are generated from the Unicode Character Database
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
    const position = std.sort.binarySearch(u21, &tables.fold_keys, code, struct {
        fn order(key: u21, item: u21) std.math.Order {
            return std.math.order(key, item);
        }
    }.order) orelse return null;
    return tables.fold_data[tables.fold_starts[position]..tables.fold_starts[position + 1]];
}

/// The full case folding of `code` (accents kept): itself (null) or other
/// code points ("ß" folds to "ss").
pub fn caseFold(code: u21) ?[]const u21 {
    const position = std.sort.binarySearch(u21, &tables.case_keys, code, struct {
        fn order(key: u21, item: u21) std.math.Order {
            return std.math.order(key, item);
        }
    }.order) orelse return null;
    return tables.case_data[tables.case_starts[position]..tables.case_starts[position + 1]];
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
