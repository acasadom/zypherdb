//! What the clauses do to one row, for the operators that run them
//! (operators.zig): the writing clauses, and the null bindings of an
//! OPTIONAL MATCH without matches. WITH and RETURN are in projection.zig.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const writes = @import("writes.zig");

/// A copy of a row whose entries the next clause may extend independently.
pub fn copyRow(self: *Executor, row: Bindings) ExecutionError!Bindings {
    var copy = Bindings{ .entries = .empty };
    try copy.entries.appendSlice(self.allocator, row.entries.items);
    return copy;
}

/// Binds every variable of `patterns` that `row` does not bind yet to null.
pub fn bindNewVariablesToNull(self: *Executor, patterns: []const Index, row: *Bindings) ExecutionError!void {
    for (patterns) |pattern| {
        // A named path (`p = (a)-->(b)`) is null as well.
        const path_name = self.ast.data(pattern).text;
        if (path_name.len > 0 and row.get(path_name) == null) try row.put(self.allocator, path_name, .null);
        for (self.ast.nodeChildren(pattern)) |element| {
            const name = switch (self.ast.kind(element)) {
                .node_pattern => self.ast.data(element).node_pattern.variable_name,
                .edge_pattern => self.ast.data(element).edge_pattern.variable_name,
                else => continue,
            };
            if (name.len > 0 and row.get(name) == null) try row.put(self.allocator, name, .null);
        }
    }
}

/// CREATE, SET, DELETE or REMOVE for one row (each row sees the writes made
/// for the rows before it). CREATE binds its new variables in the row.
pub fn applyWrite(self: *Executor, clause: Index, row: *Bindings) ExecutionError!void {
    switch (self.ast.kind(clause)) {
        .create_clause => for (self.ast.nodeChildren(clause)) |pattern| {
            try writes.applyCreate(self, pattern, row);
        },
        .set_clause => try writes.applySet(self, clause, row),
        .delete_clause => try writes.applyDelete(self, clause, row),
        .remove_clause => try writes.applyRemove(self, clause, row),
        else => unreachable,
    }
}
