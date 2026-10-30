//! The copies of a database replication sends and receives, each in
//! directory `copy-N` of a copies directory.

const std = @import("std");
const Io = std.Io;

pub fn directory(buffer: []u8, copies_directory: []const u8, number: u64) error{NoSpaceLeft}![]u8 {
    return std.fmt.bufPrint(buffer, "{s}/copy-{d}", .{ copies_directory, number });
}

/// Deletes copy `number`, if it is there.
pub fn delete(io: Io, copies_directory: []const u8, number: u64) void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = directory(&path_buffer, copies_directory, number) catch return;
    Io.Dir.cwd().deleteTree(io, path) catch {};
}
