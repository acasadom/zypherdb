//! Minimal diagnostic for structured errors: a human-readable message, a byte
//! offset into the source (for parse errors), and a stable error code (for the
//! C ABI to map onto typed exceptions). Used by the parser, executor and C ABI.

const std = @import("std");

/// Stable error categories, surfaced through the C ABI (`acmedb_error_code`).
/// Keep the numeric values stable — the Python wrapper maps them to exceptions.
pub const ErrorCode = enum(u32) {
    none = 0,
    parse = 1,
    unknown_var = 2,
    missing_prop = 3,
    type_mismatch = 4,
    invalid_expr = 5,
    node_still_connected = 6,
    storage = 7,
};

pub const Diagnostic = struct {
    buf: [256]u8,
    len: usize,
    pos: usize, // byte offset in the source; 0 when not applicable
    code: ErrorCode,

    pub fn init() Diagnostic {
        return .{ .buf = undefined, .len = 0, .pos = 0, .code = .none };
    }

    /// Formats a message (truncated to the buffer if necessary) and records the
    /// error code.
    pub fn set(self: *Diagnostic, code: ErrorCode, pos: usize, comptime fmt: []const u8, args: anytype) void {
        self.code = code;
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

    /// Resets the diagnostic (a new operation starts from "no error").
    pub fn clear(self: *Diagnostic) void {
        self.len = 0;
        self.pos = 0;
        self.code = .none;
    }
};
