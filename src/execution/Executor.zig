//! Volcano-style executor for the openCypher subset, now with write clauses.
//!
//! A query is a list of clauses (`match`, `create`, `set`, `delete`, `return`).
//! The `MATCH` clause is planned as before (anchor selection, predicate
//! pushdown) and produces variable bindings; then each `CREATE`/`SET`/`DELETE`
//! clause is applied to every binding, and finally `RETURN` projects (if
//! present). A query with no `MATCH` is applied to a single empty binding, so a
//! standalone `CREATE ...` works.
//!
//! Bindings map variable names to node ids dynamically, since `CREATE`
//! introduces new variables at runtime.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const Graph = @import("../storage/graph.zig").Graph;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;
const ErrorCode = @import("../diagnostics.zig").ErrorCode;

const ValueGrouping = @import("aggregation.zig").ValueGrouping;
const AggregateKind = @import("../query/ast.zig").AggregateKind;
const ProjectionItem = @import("aggregation.zig").ProjectionItem;
const Bindings = @import("bindings.zig").Bindings;
const PlanStep = @import("planner.zig").PlanStep;
const PatternEdge = @import("planner.zig").PatternEdge;
const PatternNode = @import("planner.zig").PatternNode;

const pattern_matching = @import("pattern_matching.zig");
const expressions = @import("expressions.zig");
const aggregation = @import("aggregation.zig");
const projection = @import("projection.zig");
const writes = @import("writes.zig");

const Executor = @This();

pub const ExecutionError = StorageError || error{
    UnknownVariable,
    MissingProperty,
    InvalidExpression,
    TypeMismatch,
};

/// A projected row: one `Value` per RETURN item.
pub const Row = std.ArrayList(Value);

ast: *Ast,
graph: *Graph,
allocator: Allocator,
/// RETURN rows, each with its ORDER BY key.
rows: std.ArrayList(projection.Sortable(Row)),

// Match context.
patterns: []const Index, // the MATCH clause's patterns (one or more)
nodes: std.ArrayList(PatternNode),
edges: std.ArrayList(PatternEdge),
steps: std.ArrayList(PlanStep),
where_expression: Index,
has_match: bool,

// Write context.
update_clauses: std.ArrayList(Index),
return_clause: ?Index,

// WITH pipeline context.
with_clause: ?Index,
with_rows: std.ArrayList(Bindings),
collecting: bool,

// OPTIONAL MATCH context.
optional_match: ?Index,
optional_vars: std.ArrayList([]const u8),
main_vars: std.ArrayList([]const u8),
in_optional: bool,
optional_matched: bool,

// UNWIND context.
unwind: ?Index,

// Aggregation.
has_aggregates: bool,
projection_items: std.ArrayList(ProjectionItem),
/// The aggregate function of each `.aggregate` projection item, in order.
aggregate_kinds: std.ArrayList(AggregateKind),
groups: ValueGrouping,

diagnostic: ?*Diagnostic,

pub fn init(ast: *Ast, graph: *Graph, allocator: Allocator) Executor {
    return .{
        .ast = ast,
        .graph = graph,
        .allocator = allocator,
        .rows = .empty,
        .patterns = &.{},
        .nodes = .empty,
        .edges = .empty,
        .steps = .empty,
        .where_expression = 0,
        .has_match = false,
        .update_clauses = .empty,
        .return_clause = null,
        .with_clause = null,
        .with_rows = .empty,
        .collecting = false,
        .optional_match = null,
        .optional_vars = .empty,
        .main_vars = .empty,
        .in_optional = false,
        .optional_matched = false,
        .unwind = null,
        .has_aggregates = false,
        .projection_items = .empty,
        .aggregate_kinds = .empty,
        .groups = .{},
        .diagnostic = null,
    };
}

pub fn fail(self: *Executor, code: ErrorCode, comptime fmt: []const u8, args: anytype) void {
    if (self.diagnostic) |d| d.set(code, 0, fmt, args);
}

pub fn run(self: *Executor, query: Index) ExecutionError![]const Row {
    self.rows.clearRetainingCapacity();
    self.groups = .{};
    self.aggregate_kinds = .empty;
    self.has_aggregates = false;
    self.projection_items = .empty;
    self.with_rows = .empty;
    self.collecting = false;
    self.optional_match = null;
    self.optional_vars = .empty;
    self.main_vars = .empty;
    self.in_optional = false;
    self.optional_matched = false;
    self.unwind = null;

    var pre_match: ?Index = null;
    var post_match: ?Index = null;
    self.with_clause = null;
    self.update_clauses = .empty;
    self.return_clause = null;
    for (self.ast.nodeChildren(query)) |c| {
        switch (self.ast.kind(c)) {
            .match_clause => {
                if (self.with_clause == null) {
                    pre_match = c;
                } else {
                    post_match = c;
                }
            },
            .optional_match_clause => self.optional_match = c,
            .unwind_clause => self.unwind = c,
            .with_clause => self.with_clause = c,
            .create_clause, .merge_clause, .set_clause, .delete_clause, .remove_clause => try self.update_clauses.append(self.allocator, c),
            .return_clause => self.return_clause = c,
            else => {},
        }
    }
    if (self.optional_match) |om| {
        try pattern_matching.collectOptionalVars(self, om);
    }
    if (pre_match) |pm| {
        try pattern_matching.collectClauseVars(self, pm, &self.main_vars);
    }

    // Detect aggregations in the projection (grouping).
    if (self.return_clause) |rc| {
        const info = projection.returnClauseParts(self, rc);
        for (self.ast.nodeChildren(info.projection)) |item| {
            const expr = self.ast.nodeChildren(item)[0];
            if (self.ast.kind(expr) == .aggregate) {
                self.has_aggregates = true;
                const kind = self.ast.data(expr).aggregate;
                const children = self.ast.nodeChildren(expr);
                const arg: ?Index = if (children.len > 0) children[0] else null;
                try self.projection_items.append(self.allocator, .{ .aggregate = .{ .kind = kind, .arg = arg } });
                try self.aggregate_kinds.append(self.allocator, kind);
            } else {
                try self.projection_items.append(self.allocator, .{ .key = expr });
            }
        }
    }

    // All writes of this query commit (or abort) atomically; a read-only
    // query batches its reads into a single read transaction (snapshot),
    // avoiding one LMDB transaction per read (the #1 performance win).
    const has_writes = self.update_clauses.items.len > 0;
    if (has_writes) {
        try self.graph.beginWrite();
    } else {
        try self.graph.beginRead();
    }
    errdefer if (has_writes) self.graph.abortWrite() else self.graph.abortRead();

    if (self.with_clause) |wc| {
        // Phase 1: collect the pre-WITH match bindings.
        self.collecting = true;
        var start = Bindings{ .entries = .empty };
        if (pre_match) |pm| {
            try self.runMatch(pm, &start);
        } else {
            self.has_match = false;
            try self.matchFound(&start);
        }
        self.collecting = false;

        // Phase 2: project/aggregate/filter/sort/paginate with WITH.
        try projection.applyWith(self, wc);

        // Phase 3: run the post-WITH clauses against each projected row.
        for (self.with_rows.items) |row| {
            var bindings = Bindings{ .entries = .empty };
            try bindings.entries.appendSlice(self.allocator, row.entries.items);
            if (post_match) |pm| {
                try self.runMatch(pm, &bindings);
            } else {
                self.has_match = false;
                try self.finishBody(&bindings);
            }
        }
    } else {
        var bindings = Bindings{ .entries = .empty };
        if (pre_match) |pm| {
            try self.runMatch(pm, &bindings);
        } else {
            self.has_match = false;
            try self.matchFound(&bindings);
        }
    }

    if (has_writes) try self.graph.commitWrite() else self.graph.commitRead();

    if (self.return_clause) |rc| {
        try projection.postProcess(self, rc);
    }

    const result = try self.allocator.alloc(Row, self.rows.items.len);
    for (result, self.rows.items) |*row, sortable| row.* = sortable.item;
    return result;
}

/// Runs one MATCH clause (its patterns + WHERE) from `bindings`, recursing
/// through `matchPatterns`/`runStep` down to `matchFound`.
pub fn runMatch(self: *Executor, mc: Index, bindings: *Bindings) ExecutionError!void {
    const match_children = self.ast.nodeChildren(mc);
    self.has_match = true;
    // children = [pattern0, ..., patternN, where_expression]
    self.patterns = match_children[0 .. match_children.len - 1];
    self.where_expression = match_children[match_children.len - 1];
    try pattern_matching.matchPatterns(self, 0, bindings);
}

/// Leaf of a match: apply the MATCH `WHERE`, then either outer-join through
/// OPTIONAL MATCH, collect the bindings (WITH pipeline), or apply updates +
/// RETURN.
pub fn matchFound(self: *Executor, bindings: *Bindings) ExecutionError!void {
    if (self.has_match and !try expressions.evaluateBool(self, self.where_expression, bindings)) return;
    if (self.in_optional) {
        self.optional_matched = true;
        return self.afterOptional(bindings);
    }
    if (self.optional_match != null) {
        return pattern_matching.runOptional(self, bindings);
    }
    if (self.unwind != null) {
        return pattern_matching.runUnwind(self, bindings);
    }
    return self.afterOptional(bindings);
}

/// Continuation after (optional) matching: collect or finish.
pub fn afterOptional(self: *Executor, bindings: *Bindings) ExecutionError!void {
    if (self.collecting) {
        return projection.collect(self, bindings);
    }
    try self.finishBody(bindings);
}

pub fn finishBody(self: *Executor, bindings: *Bindings) ExecutionError!void {
    for (self.update_clauses.items) |clause| {
        switch (self.ast.kind(clause)) {
            .create_clause => try writes.applyCreate(self, self.ast.nodeChildren(clause)[0], bindings),
            .merge_clause => try writes.applyMerge(self, clause, bindings),
            .set_clause => try writes.applySet(self, clause, bindings),
            .delete_clause => try writes.applyDelete(self, clause, bindings),
            .remove_clause => try writes.applyRemove(self, clause, bindings),
            else => {},
        }
    }

    if (self.return_clause) |rc| {
        const info = projection.returnClauseParts(self, rc);

        if (self.has_aggregates) {
            try aggregation.accumulate(self, bindings);
            return;
        }

        var out = std.ArrayList(Value).empty;
        for (self.ast.nodeChildren(info.projection)) |item| {
            const v = try expressions.evaluate(self, self.ast.nodeChildren(item)[0], bindings);
            try out.append(self.allocator, v);
        }
        // The ORDER BY key is evaluated now, while the row's variables are
        // still bound: it may use variables that are not projected.
        const sort_key = try projection.returnSortKey(self, info, out.items, bindings);
        try self.rows.append(self.allocator, .{ .item = out, .sort_key = sort_key });
    }
}
