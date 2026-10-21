//! CSV for LOAD CSV (RFC 4180, as Neo4j reads it): fields separated by a
//! one-byte terminator (`,` by default), records by `\n` or `\r\n`, a field
//! in double quotes may hold the terminator, line ends and `""` (one quote).
//! An empty field is null; a quoted empty field (`""`) is the empty string.
//! A UTF-8 byte order mark at the start is skipped, and so is a last empty
//! line.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One record: its fields, null for an empty unquoted one.
pub const Record = []const ?[]const u8;

pub const ParseError = error{ InvalidCsv, OutOfMemory };

/// Why the text did not parse, and on which line (1-based).
pub const Problem = struct { message: []const u8 = "", line: usize = 0 };

/// The records of `text`; the fields are views into it, except quoted ones
/// (copied, unescaped, with `allocator`).
pub fn parse(allocator: Allocator, text: []const u8, terminator: u8, problem: *Problem) ParseError![]const Record {
    var position: usize = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) 3 else 0;
    var line: usize = 1;
    var records = std.ArrayList(Record).empty;
    var fields = std.ArrayList(?[]const u8).empty;
    while (position < text.len) {
        // One field.
        if (text[position] == '"') {
            const start_line = line;
            position += 1;
            var value = std.ArrayList(u8).empty;
            var escaped = false;
            const start = position;
            while (true) {
                if (position >= text.len) {
                    problem.* = .{ .message = "a quoted field is not closed", .line = start_line };
                    return error.InvalidCsv;
                }
                const byte = text[position];
                if (byte == '"') {
                    if (position + 1 < text.len and text[position + 1] == '"') {
                        if (!escaped) try value.appendSlice(allocator, text[start..position]);
                        escaped = true;
                        try value.append(allocator, '"');
                        position += 2;
                        continue;
                    }
                    if (!escaped) try value.appendSlice(allocator, text[start..position]);
                    position += 1;
                    break;
                }
                if (byte == '\n') line += 1;
                if (escaped) try value.append(allocator, byte);
                position += 1;
            }
            try fields.append(allocator, value.items);
            if (position < text.len and text[position] != terminator and text[position] != '\n' and text[position] != '\r') {
                problem.* = .{ .message = "text after a quoted field's closing quote", .line = line };
                return error.InvalidCsv;
            }
        } else {
            const start = position;
            while (position < text.len and text[position] != terminator and text[position] != '\n' and text[position] != '\r') position += 1;
            try fields.append(allocator, if (position == start) null else text[start..position]);
        }
        // What ends it: a terminator (another field follows), or a line end.
        if (position < text.len and text[position] == terminator) {
            position += 1;
            if (position == text.len) try fields.append(allocator, null); // `a,` ends with an empty field
            continue;
        }
        if (position < text.len and text[position] == '\r') position += 1;
        if (position < text.len and text[position] == '\n') position += 1;
        line += 1;
        try records.append(allocator, try fields.toOwnedSlice(allocator));
    }
    if (fields.items.len > 0) try records.append(allocator, try fields.toOwnedSlice(allocator));
    return records.items;
}

/// A field terminator written as Neo4j allows: one character, or `\t`.
pub fn terminatorOf(text: []const u8) ?u8 {
    if (text.len == 1) return text[0];
    if (std.mem.eql(u8, text, "\\t")) return '\t';
    return null;
}

fn expectRecords(text: []const u8, terminator: u8, expected: []const []const ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem = Problem{};
    const records = try parse(arena.allocator(), text, terminator, &problem);
    try std.testing.expectEqual(expected.len, records.len);
    for (expected, records) |expected_record, record| {
        try std.testing.expectEqual(expected_record.len, record.len);
        for (expected_record, record) |expected_field, field| {
            if (expected_field) |value| {
                try std.testing.expectEqualStrings(value, field.?);
            } else try std.testing.expect(field == null);
        }
    }
}

test "fields, records and line ends" {
    try expectRecords("a,b,c\n1,2,3\n", ',', &.{ &.{ "a", "b", "c" }, &.{ "1", "2", "3" } });
    try expectRecords("a,b\r\n1,2", ',', &.{ &.{ "a", "b" }, &.{ "1", "2" } });
    try expectRecords("a;b\n", ';', &.{&.{ "a", "b" }});
    try expectRecords("a\tb", '\t', &.{&.{ "a", "b" }});
    try expectRecords("\xEF\xBB\xBFname\nAna\n", ',', &.{ &.{"name"}, &.{"Ana"} });
    try expectRecords("", ',', &.{});
}

test "empty and quoted fields" {
    try expectRecords("a,,c\n", ',', &.{&.{ "a", null, "c" }});
    try expectRecords("a,\n", ',', &.{&.{ "a", null }});
    try expectRecords("a,", ',', &.{&.{ "a", null }});
    try expectRecords("\"\",x\n", ',', &.{&.{ "", "x" }});
    try expectRecords("\"a,b\",c\n", ',', &.{&.{ "a,b", "c" }});
    try expectRecords("\"say \"\"hi\"\"\",x\n", ',', &.{&.{ "say \"hi\"", "x" }});
    try expectRecords("\"two\nlines\",x\n", ',', &.{&.{ "two\nlines", "x" }});
}

test "malformed quoting is an error with its line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem = Problem{};
    try std.testing.expectError(error.InvalidCsv, parse(arena.allocator(), "a\n\"open,b\n", ',', &problem));
    try std.testing.expectEqual(@as(usize, 2), problem.line);
    try std.testing.expectError(error.InvalidCsv, parse(arena.allocator(), "\"a\"b,c\n", ',', &problem));
}

test "terminators as Neo4j writes them" {
    try std.testing.expectEqual(@as(?u8, ';'), terminatorOf(";"));
    try std.testing.expectEqual(@as(?u8, '\t'), terminatorOf("\\t"));
    try std.testing.expectEqual(@as(?u8, null), terminatorOf(";;"));
}
