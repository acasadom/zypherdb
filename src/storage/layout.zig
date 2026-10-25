//! The layout of stored bytes: what the encoders guarantee (node_record.zig,
//! value_encoding.zig, key_encoding.zig).

const std = @import("std");

/// True if `name` can be stored as a label, relationship type or property
/// name: not empty (records hold no empty names) and without 0x00, which ends
/// names inside index and edge keys (a label "A\x00B" would be found as "A").
pub fn isStorableName(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfScalar(u8, name, 0) == null;
}

test "a storable name is not empty and has no 0x00" {
    try std.testing.expect(isStorableName("Person"));
    try std.testing.expect(!isStorableName(""));
    try std.testing.expect(!isStorableName("A\x00B"));
}
