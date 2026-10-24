//! Snapshot tests: the expected text lives in the test, as a multiline string
//! literal right after `snap(@src(), ...)`, and is compared with the text the
//! code under test produced. Run the tests with `SNAP_UPDATE=1` to rewrite
//! every literal that differs with what the code produces now, then review
//! the change with `git diff`. Idea from TigerBeetle's `snaptest.zig`.
//!
//!     try snap(@src(),
//!         \\Return m.title
//!         \\NodeByLabelScan (m:Movie)
//!     ).diff(plan_text);

const std = @import("std");
const testing = std.testing;

/// Where the test files are, relative to the directory the tests run in
/// (`@src().file` is relative to the root of the test module).
const tests_directory = "tests/";

pub const Snap = struct {
    location: std.lang.SourceLocation,
    text: []const u8,

    /// Checks `got` against the snapshot (a trailing newline of `got` is
    /// ignored: a literal cannot end with one).
    pub fn diff(snapshot: Snap, got_text: []const u8) !void {
        const got = std.mem.trimEnd(u8, got_text, "\n");
        if (std.mem.eql(u8, snapshot.text, got)) return;
        if (updateRequested()) return update(snapshot.location, snapshot.text, got);
        std.debug.print(
            \\
            \\snapshot differs at {s}:{d}
            \\--- expected
            \\{s}
            \\--- got
            \\{s}
            \\--- first difference on line {d}
            \\Run with SNAP_UPDATE=1 to accept the new text.
            \\
        , .{ snapshot.location.file, snapshot.location.line, snapshot.text, got, firstDifferentLine(snapshot.text, got) });
        return error.SnapshotDiffers;
    }

    /// Formats `args` with `format` and checks the text against the snapshot.
    pub fn diffFmt(snapshot: Snap, comptime format: []const u8, args: anytype) !void {
        const got = try std.fmt.allocPrint(testing.allocator, format, args);
        defer testing.allocator.free(got);
        try snapshot.diff(got);
    }
};

/// A snapshot at `location` (pass `@src()`) with the expected `text`.
pub fn snap(location: std.lang.SourceLocation, text: []const u8) Snap {
    return .{ .location = location, .text = text };
}

fn updateRequested() bool {
    return testing.environ.containsUnempty(testing.allocator, "SNAP_UPDATE") catch false;
}

/// The 1-based number of the first line where `a` and `b` differ.
fn firstDifferentLine(a: []const u8, b: []const u8) usize {
    var a_lines = std.mem.splitScalar(u8, a, '\n');
    var b_lines = std.mem.splitScalar(u8, b, '\n');
    var number: usize = 1;
    while (true) : (number += 1) {
        const x = a_lines.next();
        const y = b_lines.next();
        if (x == null and y == null) return number;
        if (x == null or y == null or !std.mem.eql(u8, x.?, y.?)) return number;
    }
}

/// Lines added (or removed, when negative) by the updates of this run, so a
/// later snapshot in the same file is still found after an earlier one
/// changed its line count. The test runner runs tests one at a time.
const Shift = struct { file: []const u8, line: u32, lines_added: i64 };
var shifts: [256]Shift = undefined;
var shift_count: usize = 0;

/// The line a snapshot written at `line` of `file` is at now.
fn currentLine(file: []const u8, line: u32) i64 {
    var current: i64 = line;
    for (shifts[0..shift_count]) |shift| {
        if (std.mem.eql(u8, shift.file, file) and shift.line < line) current += shift.lines_added;
    }
    return current;
}

/// Rewrites the literal of the snapshot at `location` with `got`.
fn update(location: std.lang.SourceLocation, old_text: []const u8, got: []const u8) !void {
    const allocator = testing.allocator;
    const io = testing.io;
    const path = try std.mem.concat(allocator, u8, &.{ tests_directory, location.file });
    defer allocator.free(path);
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 << 20));
    defer allocator.free(source);

    const literal = try findLiteral(source, currentLine(location.file, location.line));
    // The file may have changed since the tests were compiled (an earlier
    // update in a run that was restarted after a crash): rewrite only the
    // literal that still holds the text this test was compiled with.
    if (!literalHolds(source[literal.start..literal.end], literal.indentation, old_text)) {
        std.debug.print("snapshot at {s}:{d} not updated: the file changed since it was compiled; run again\n", .{ path, location.line });
        return error.SnapshotSourceChanged;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll(source[0..literal.start]);
    var lines = std.mem.splitScalar(u8, got, '\n');
    var line_count: i64 = 0;
    while (lines.next()) |line| : (line_count += 1) {
        try out.writer.print("{s}\\\\{s}\n", .{ literal.indentation, line });
    }
    try out.writer.writeAll(source[literal.end..]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });

    if (shift_count == shifts.len) return error.TooManySnapshotUpdates;
    shifts[shift_count] = .{ .file = location.file, .line = location.line, .lines_added = line_count - literal.line_count };
    shift_count += 1;
    std.debug.print("snapshot updated: {s}:{d}\n", .{ path, location.line });
}

/// The `\\` lines of the first multiline literal at or after `line`: from the
/// start of its first line to the end of its last line's newline.
const Literal = struct { start: usize, end: usize, indentation: []const u8, line_count: i64 };

fn findLiteral(source: []const u8, line: i64) !Literal {
    var offset: usize = 0;
    var number: i64 = 1;
    while (number < line) : (number += 1) {
        offset = 1 + (std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse return error.SnapshotNotFound);
    }
    var literal: ?Literal = null;
    while (offset < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
        const text = source[offset..line_end];
        const indentation = text[0 .. text.len - std.mem.trimStart(u8, text, " \t").len];
        const next = @min(line_end + 1, source.len);
        if (std.mem.startsWith(u8, text[indentation.len..], "\\\\")) {
            if (literal) |*found| {
                found.end = next;
                found.line_count += 1;
            } else literal = .{ .start = offset, .end = next, .indentation = indentation, .line_count = 1 };
        } else if (literal != null) break;
        offset = next;
    }
    return literal orelse error.SnapshotNotFound;
}

/// Whether the `\\` lines in `lines` (each after `indentation`) spell `text`.
fn literalHolds(lines: []const u8, indentation: []const u8, text: []const u8) bool {
    var rest = text;
    var iterator = std.mem.splitScalar(u8, std.mem.trimEnd(u8, lines, "\n"), '\n');
    var first = true;
    while (iterator.next()) |line| : (first = false) {
        if (line.len < indentation.len + 2) return false;
        const content = line[indentation.len + 2 ..];
        if (!first) {
            if (rest.len == 0 or rest[0] != '\n') return false;
            rest = rest[1..];
        }
        if (!std.mem.startsWith(u8, rest, content)) return false;
        rest = rest[content.len..];
    }
    return rest.len == 0;
}

test "a literal is found after the line of its snap call" {
    const source =
        "    try snap(@src(),\n" ++
        "        \\\\a\n" ++
        "        \\\\\n" ++
        "    ).diff(x);\n";
    const literal = try findLiteral(source, 1);
    try testing.expectEqualStrings("        \\\\a\n        \\\\\n", source[literal.start..literal.end]);
    try testing.expectEqualStrings("        ", literal.indentation);
    try testing.expectEqual(@as(i64, 2), literal.line_count);
    const lines = source[literal.start..literal.end];
    try testing.expect(literalHolds(lines, literal.indentation, "a\n"));
    try testing.expect(!literalHolds(lines, literal.indentation, "a"));
    try testing.expect(!literalHolds(lines, literal.indentation, "a\nb"));
}

test "the first different line is counted from 1" {
    try testing.expectEqual(@as(usize, 2), firstDifferentLine("a\nb", "a\nc"));
    try testing.expectEqual(@as(usize, 3), firstDifferentLine("a\nb", "a\nb\nc"));
}
