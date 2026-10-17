//! Minimal diagnostic for structured errors: a human-readable message plus a
//! byte offset into the source (for parse errors). Used by the parser,
//! executor and C ABI so failures carry context instead of a bare error code.

const std = @import("std");

pub const Diagnostic = struct {
    buf: [256]u8,
    len: usize,
    pos: usize, // byte offset in the source; 0 when not applicable

    pub fn init() Diagnostic {
        return .{ .buf = undefined, .len = 0, .pos = 0 };
    }

    /// Formats a message (truncated to the buffer if necessary).
    pub fn set(self: *Diagnostic, pos: usize, comptime fmt: []const u8, args: anytype) void {
        self.pos = pos;
        const written = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.len = 0;
            return;
        };
        self.len = written.len;
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buf[0..self.len];
    }
};
