//! The reading and writing clauses of the pipeline (WITH and RETURN are in
//! projection.zig). Each takes the rows the previous clause produced and
//! returns the rows for the next one.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const NodeKind = @import("../query/ast.zig").NodeKind;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const expressions = @import("expressions.zig");
const pattern_matching = @import("pattern_matching.zig");
const writes = @import("writes.zig");

/// True for the clauses that write to the graph.
pub fn isWrite(kind: NodeKind) bool {
    return switch (kind) {
        .create_clause, .merge_clause, .set_clause, .delete_clause, .remove_clause => true,
        else => false,
    };
}

/// A copy of a row whose entries the next clause may extend independently.
pub fn copyRow(self: *Executor, row: Bindings) ExecutionError!Bindings {
    var copy = Bindings{ .entries = .empty };
    try copy.entries.appendSlice(self.allocator, row.entries.items);
    return copy;
}

/// MATCH: every input row, extended with each match of the patterns that
/// passes the WHERE. OPTIONAL MATCH keeps an input row that has no such
/// match, with the clause's new variables bound to null (an outer join).
pub fn runMatch(self: *Executor, clause: Index, input: []Bindings, optional: bool) ExecutionError![]Bindings {
    const children = self.ast.nodeChildren(clause);
    // children = [pattern0, ..., patternN, where_expression]
    self.patterns = children[0 .. children.len - 1];
    self.where_expression = children[children.len - 1];

    var output = std.ArrayList(Bindings).empty;
    self.matches = &output;
    for (input) |row| {
        const matched_before = output.items.len;
        var bindings = try copyRow(self, row);
        try pattern_matching.matchPatterns(self, 0, &bindings);
        if (optional and output.items.len == matched_before) {
            var unmatched = try copyRow(self, row);
            try bindNewVariablesToNull(self, self.patterns, &unmatched);
            try output.append(self.allocator, unmatched);
        }
    }
    return output.items;
}

/// The matches of `patterns` passing `where_expression`, each extending
/// `row`: a MATCH nested in an expression (a pattern predicate, a pattern
/// comprehension, EXISTS). The state of the MATCH being run around it is put
/// back afterwards, and the nested patterns have their own relationship
/// uniqueness.
pub fn nestedMatches(self: *Executor, patterns: []const Index, where_expression: Index, row: Bindings) ExecutionError![]Bindings {
    const saved_patterns = self.patterns;
    const saved_where = self.where_expression;
    const saved_matches = self.matches;
    const saved_used_edges = self.used_edges;
    defer {
        self.patterns = saved_patterns;
        self.where_expression = saved_where;
        self.matches = saved_matches;
        self.used_edges = saved_used_edges;
    }
    self.patterns = patterns;
    self.where_expression = where_expression;
    self.used_edges = .empty;
    var output = std.ArrayList(Bindings).empty;
    self.matches = &output;
    var bindings = try copyRow(self, row);
    try pattern_matching.matchPatterns(self, 0, &bindings);
    return output.items;
}

/// The rows of a chain of MATCH clauses (as in `EXISTS { MATCH ... MATCH
/// ... }`) starting from `row`.
pub fn nestedMatchClauses(self: *Executor, match_clauses: []const Index, row: Bindings) ExecutionError![]Bindings {
    var rows = try self.allocator.dupe(Bindings, &.{row});
    for (match_clauses) |clause| {
        const children = self.ast.nodeChildren(clause);
        var next = std.ArrayList(Bindings).empty;
        for (rows) |input| try next.appendSlice(self.allocator, try nestedMatches(self, children[0 .. children.len - 1], children[children.len - 1], input));
        rows = next.items;
    }
    return rows;
}

/// MERGE: for each input row, every match of the whole pattern (each one a
/// row, with ON MATCH SET applied), or, when there is none, the pattern
/// created — its unbound nodes and its relationships — with ON CREATE SET.
fn runMerge(self: *Executor, clause: Index, input: []Bindings) ExecutionError![]Bindings {
    const children = self.ast.nodeChildren(clause);
    const pattern = children[0];
    const on_create = children[1];
    const on_match = children[2];
    var output = std.ArrayList(Bindings).empty;
    for (input) |row| {
        var scope = try copyRow(self, row);
        try writes.rejectNullProperties(self, pattern, &scope);
        const matches = try nestedMatches(self, &.{pattern}, Executor.no_where, row);
        if (matches.len > 0) {
            for (matches) |*match| {
                try writes.applySet(self, on_match, match);
                try output.append(self.allocator, match.*);
            }
            continue;
        }
        try writes.createPattern(self, pattern, &scope, .merge);
        try writes.applySet(self, on_create, &scope);
        try output.append(self.allocator, scope);
    }
    return output.items;
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

/// UNWIND list AS x: one row per element of the list, for every input row.
/// A null list gives no row; any other non-list value gives one row with it.
pub fn runUnwind(self: *Executor, clause: Index, input: []Bindings) ExecutionError![]Bindings {
    const list_expression = self.ast.nodeChildren(clause)[0];
    const variable_name = self.ast.data(clause).unwind.variable_name;
    var output = std.ArrayList(Bindings).empty;
    for (input) |*row| {
        const value = try expressions.evaluate(self, list_expression, row);
        const items: []const @TypeOf(value) = switch (value) {
            .list => |items| items,
            .null => &.{},
            else => &.{value},
        };
        for (items) |item| {
            var extended = try copyRow(self, row.*);
            try extended.put(self.allocator, variable_name, item);
            try output.append(self.allocator, extended);
        }
    }
    return output.items;
}

/// CREATE, MERGE, SET, DELETE, REMOVE: applied to each row in turn (so a row
/// sees the writes made for the rows before it); the rows go on, with any
/// variables the clause bound.
pub fn runWrite(self: *Executor, clause: Index, input: []Bindings) ExecutionError![]Bindings {
    if (self.ast.kind(clause) == .merge_clause) return runMerge(self, clause, input);
    for (input) |*row| {
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
    return input;
}
