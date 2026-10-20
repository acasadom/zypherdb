//! The procedures a CALL can name, and what each takes and yields: the
//! signatures that the semantic checks and the executor share. The
//! implementations are in `src/execution/procedures.zig`.

const std = @import("std");
const Value = @import("../value.zig").Value;

/// What a column holds, as the semantic checks track variables.
pub const ColumnKind = enum { node, relationship, value };

pub const Column = struct { name: []const u8, kind: ColumnKind };

/// The type an argument is declared with (`INTEGER?`); arguments of the
/// built-in procedures are checked when they run instead.
pub const ArgumentType = enum { any, boolean, integer, float, number, string, list, map, node, relationship, path };

pub const Argument = struct { name: []const u8, type: ArgumentType };

pub const Signature = struct {
    name: []const u8,
    min_arguments: usize,
    max_arguments: usize,
    columns: []const Column,
    /// The declared arguments, when known (a table procedure's).
    arguments: []const Argument = &.{},

    pub fn column(self: Signature, name: []const u8) ?Column {
        for (self.columns) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

pub const catalog = [_]Signature{
    .{ .name = "db.labels", .min_arguments = 0, .max_arguments = 0, .columns = &.{.{ .name = "label", .kind = .value }} },
    .{ .name = "db.relationshipTypes", .min_arguments = 0, .max_arguments = 0, .columns = &.{.{ .name = "relationshipType", .kind = .value }} },
    .{ .name = "db.index.fulltext.queryNodes", .min_arguments = 2, .max_arguments = 3, .columns = &.{
        .{ .name = "node", .kind = .node },
        .{ .name = "score", .kind = .value },
    } },
    .{ .name = "db.index.fulltext.queryRelationships", .min_arguments = 2, .max_arguments = 3, .columns = &.{
        .{ .name = "relationship", .kind = .relationship },
        .{ .name = "score", .kind = .value },
    } },
    .{ .name = "db.index.fulltext.listAvailableAnalyzers", .min_arguments = 0, .max_arguments = 0, .columns = &.{
        .{ .name = "analyzer", .kind = .value },
        .{ .name = "description", .kind = .value },
    } },
};

/// A procedure defined by a table, as the openCypher TCK defines its test
/// procedures: a call emits the rows whose arguments equal the call's.
pub const TableProcedure = struct {
    signature: Signature,
    /// Each row: a value per argument, then a value per column.
    rows: []const []const Value,
};

/// The signature of the procedure `name` (case-sensitive, as in Neo4j):
/// a built-in one, or one of `defined`.
pub fn find(name: []const u8, defined: []const TableProcedure) ?Signature {
    for (catalog) |signature| if (std.mem.eql(u8, signature.name, name)) return signature;
    if (findTable(name, defined)) |procedure| return procedure.signature;
    return null;
}

pub fn findTable(name: []const u8, defined: []const TableProcedure) ?*const TableProcedure {
    for (defined) |*procedure| if (std.mem.eql(u8, procedure.signature.name, name)) return procedure;
    return null;
}

/// The type a declared type name stands for (`INTEGER?`, `STRING`), or null.
pub fn argumentType(declared: []const u8) ?ArgumentType {
    const name = std.mem.trimEnd(u8, declared, "?");
    var lower: [16]u8 = undefined;
    if (name.len > lower.len) return null;
    return std.meta.stringToEnum(ArgumentType, std.ascii.lowerString(&lower, name));
}
