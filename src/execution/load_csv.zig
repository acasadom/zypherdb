//! LOAD CSV: the records of a CSV file as rows, read only from the import
//! directory the database was opened with (none: LOAD CSV is off).
//!
//! `file:///orders/2026.csv` is `orders/2026.csv` inside that directory. The
//! path is resolved (`..`, symbolic links) and must stay inside it; other
//! schemes (http, ...) are refused. Without headers a record is a list of
//! strings, with them a map from each header to its field; an empty field is
//! null in both.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const csv = @import("../text/csv.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const expressions = @import("expressions.zig");

/// The rows the clause makes from `row`: one value per record.
pub fn records(self: *Executor, clause: Index, row: *Bindings) ExecutionError![]const Value {
    const children = self.ast.nodeChildren(clause);
    const with_headers = self.ast.data(clause).load_csv.with_headers;
    const url = switch (try expressions.evaluate(self, children[0], row)) {
        .string => |text| text,
        else => {
            self.fail(.type_mismatch, "LOAD CSV FROM takes a URL string, as in 'file:///people.csv'", .{});
            return error.TypeMismatch;
        },
    };
    const terminator = switch (try expressions.evaluate(self, children[1], row)) {
        .null => ',',
        .string => |text| csv.terminatorOf(text) orelse {
            self.fail(.invalid_expression, "FIELDTERMINATOR is one character (or '\\t'), not '{s}'", .{text});
            return error.InvalidExpression;
        },
        else => {
            self.fail(.type_mismatch, "FIELDTERMINATOR takes a string", .{});
            return error.TypeMismatch;
        },
    };

    const text = try readFile(self, url);
    var problem = csv.Problem{};
    const parsed = csv.parse(self.allocator, text, terminator, &problem) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidCsv => return failed(self, "{s} is not valid CSV: {s} (line {d})", .{ url, problem.message, problem.line }),
    };

    var values = std.ArrayList(Value).empty;
    if (!with_headers) {
        for (parsed) |record| try values.append(self.allocator, .{ .list = try fieldValues(self, record) });
        return values.items;
    }
    if (parsed.len == 0) return &.{};
    const headers = parsed[0];
    for (parsed[1..]) |record| {
        const entries = try self.allocator.alloc(MapEntry, headers.len);
        for (entries, headers, 0..) |*entry, header, i| {
            const field: ?[]const u8 = if (i < record.len) record[i] else null;
            entry.* = .{ .key = header orelse "", .value = if (field) |value| .{ .string = value } else .{ .null = {} } };
        }
        try values.append(self.allocator, .{ .map = entries });
    }
    return values.items;
}

fn fieldValues(self: *Executor, record: csv.Record) ExecutionError![]const Value {
    const items = try self.allocator.alloc(Value, record.len);
    for (items, record) |*item, field| item.* = if (field) |value| .{ .string = value } else .{ .null = {} };
    return items;
}

fn failed(self: *Executor, comptime fmt: []const u8, args: anytype) ExecutionError {
    self.fail(.external_resource, fmt, args);
    return error.ExternalResourceFailed;
}

/// The bytes of the file `url` names in the import directory.
fn readFile(self: *Executor, url: []const u8) ExecutionError![]const u8 {
    const directory = self.import_directory orelse
        return failed(self, "LOAD CSV is off: it reads files only from an import directory given when the database is opened", .{});
    const relative = try relativePath(self, url);
    const io = std.Io.Threaded.global_single_threaded.io();
    const cwd = std.Io.Dir.cwd();

    const root = cwd.realPathFileAlloc(io, directory, self.allocator) catch
        return failed(self, "the import directory {s} cannot be read", .{directory});
    const joined = try std.fs.path.join(self.allocator, &.{ root, relative });
    const resolved = cwd.realPathFileAlloc(io, joined, self.allocator) catch
        return failed(self, "cannot read {s}: no such file in the import directory", .{url});
    // `..` or a symbolic link must not lead out of the directory.
    const inside = std.mem.startsWith(u8, resolved, root) and resolved.len > root.len and std.fs.path.isSep(resolved[root.len]);
    if (!inside) return failed(self, "cannot read {s}: it is outside the import directory", .{url});
    return cwd.readFileAlloc(io, resolved, self.allocator, .unlimited) catch
        return failed(self, "cannot read {s}", .{url});
}

/// The path inside the import directory of a `file:` URL (percent-decoded).
fn relativePath(self: *Executor, url: []const u8) ExecutionError![]const u8 {
    const prefix = "file:";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) {
        return failed(self, "LOAD CSV reads file: URLs from the import directory, not {s}", .{url});
    }
    var path = url[prefix.len..];
    while (path.len > 0 and path[0] == '/') path = path[1..];
    if (path.len == 0) return failed(self, "{s} names no file", .{url});
    var decoded = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '%' and i + 2 < path.len) {
            const byte = std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16) catch return failed(self, "{s} has a bad %-escape", .{url});
            try decoded.append(self.allocator, byte);
            i += 2;
        } else try decoded.append(self.allocator, path[i]);
    }
    if (std.mem.indexOfScalar(u8, decoded.items, 0) != null) return failed(self, "{s} has a NUL byte", .{url});
    return decoded.items;
}
