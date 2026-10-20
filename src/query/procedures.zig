//! The procedures a CALL can name, and what each takes and yields: the
//! signatures that the semantic checks and the executor share. The
//! implementations are in `src/execution/procedures.zig`.

const std = @import("std");

/// What a column holds, as the semantic checks track variables.
pub const ColumnKind = enum { node, relationship, value };

pub const Column = struct { name: []const u8, kind: ColumnKind };

pub const Signature = struct {
    name: []const u8,
    min_arguments: usize,
    max_arguments: usize,
    columns: []const Column,

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

/// The signature of the procedure `name` (case-sensitive, as in Neo4j).
pub fn find(name: []const u8) ?Signature {
    for (catalog) |signature| if (std.mem.eql(u8, signature.name, name)) return signature;
    return null;
}
