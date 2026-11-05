//! Minimal diagnostic for structured errors: a human-readable message, a byte
//! offset into the source (for parse errors), and a stable error code (for the
//! C ABI to map onto typed exceptions). Used by the parser, executor and C ABI.

const std = @import("std");

/// Stable error categories, surfaced through the C ABI (`zypherdb_error_code`).
/// Keep the numeric values stable — the Python wrapper maps them to exceptions.
pub const ErrorCode = enum(u32) {
    none = 0,
    parse = 1,
    unknown_variable = 2,
    reserved = 3, // formerly "missing property": a missing property now reads as null
    type_mismatch = 4,
    invalid_expression = 5,
    node_still_connected = 6,
    storage = 7,
    parameter_missing = 8,
    arithmetic = 9,
    constraint_violation = 10,
    external_resource = 11,
    /// A replica that forwards writes refused one it cannot forward.
    write_not_forwarded = 12,
    /// A forwarded write did not run: the master could not be reached, or
    /// turned it away.
    master_unreachable = 13,
    /// A forwarded write was sent, then the connection was lost or the
    /// time ran out: the master may have committed it or not.
    outcome_unknown = 14,
};

pub const Diagnostic = struct {
    buffer: [256]u8,
    len: usize,
    pos: usize, // byte offset in the source; 0 when not applicable
    code: ErrorCode,

    pub fn init() Diagnostic {
        return .{ .buffer = undefined, .len = 0, .pos = 0, .code = .none };
    }

    /// Formats a message (truncated to the buffer if necessary) and records the
    /// error code.
    pub fn set(self: *Diagnostic, code: ErrorCode, pos: usize, comptime fmt: []const u8, args: anytype) void {
        self.code = code;
        self.pos = pos;
        const written = std.fmt.bufPrint(&self.buffer, fmt, args) catch |err| switch (err) {
            // Too long for the buffer: keep the truncated prefix, marked with "...".
            error.NoSpaceLeft => {
                const ellipsis = "...";
                var w: std.Io.Writer = .fixed(self.buffer[0 .. self.buffer.len - ellipsis.len]);
                w.print(fmt, args) catch {};
                const n = w.end;
                @memcpy(self.buffer[n .. n + ellipsis.len], ellipsis);
                self.len = n + ellipsis.len;
                return;
            },
        };
        self.len = written.len;
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Resets the diagnostic (a new operation starts from "no error").
    pub fn clear(self: *Diagnostic) void {
        self.len = 0;
        self.pos = 0;
        self.code = .none;
    }
};

test "messages too long for the buffer are truncated, not dropped" {
    var d = Diagnostic.init();
    var long: [400]u8 = undefined;
    @memset(&long, 'x');
    d.set(.unknown_variable, 0, "unknown variable '{s}'", .{&long});
    try std.testing.expectEqual(d.buffer.len, d.message().len);
    try std.testing.expect(std.mem.startsWith(u8, d.message(), "unknown variable 'xxx"));
    try std.testing.expect(std.mem.endsWith(u8, d.message(), "..."));
}

/// Sets the message and code of an engine error that set no diagnostic.
pub fn noteError(diagnostic: *Diagnostic, err: anyerror) void {
    if (err == error.ReadOnlyReplica) return diagnostic.set(.storage, 0, "the database is a replica: it refuses writes, which go to its master", .{});
    diagnostic.set(codeOf(err), 0, "query failed: {s}", .{@errorName(err)});
}

/// The error code of an engine error, for one that set no diagnostic.
pub fn codeOf(err: anyerror) ErrorCode {
    return switch (err) {
        error.UnknownVariable => .unknown_variable,
        error.TypeMismatch, error.UnsupportedPropertyType => .type_mismatch,
        error.ParameterMissing => .parameter_missing,
        error.IntegerOverflow, error.DivisionByZero => .arithmetic,
        error.InvalidExpression, error.TooManyLabels, error.ValueTooLarge => .invalid_expression,
        error.NodeStillConnected => .node_still_connected,
        error.ConstraintViolation => .constraint_violation,
        error.ExternalResourceFailed => .external_resource,
        else => .storage,
    };
}
