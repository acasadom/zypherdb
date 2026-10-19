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
    UnsupportedPropertyType,
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
optional_variables: std.ArrayList([]const u8),
main_variables: std.ArrayList([]const u8),
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
        .optional_variables = .empty,
        .main_variables = .empty,
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

/// Runs a parsed query and returns its RETURN rows (none without RETURN).
/// All writes of the query commit or abort together; a read-only query reads
/// one consistent snapshot.
pub fn run(self: *Executor, query: Index) ExecutionError![]const Row {
    self.reset();
    const matches = try self.classifyClauses(query);
    try self.collectProjectionItems();

    // One transaction per query: a write transaction if anything writes, else
    // one read transaction, instead of one LMDB transaction per read.
    const has_writes = self.update_clauses.items.len > 0;
    if (has_writes) try self.graph.beginWrite() else try self.graph.beginRead();
    errdefer if (has_writes) self.graph.abortWrite() else self.graph.abortRead();

    if (self.with_clause) |with_clause| {
        try self.runWithPipeline(with_clause, matches);
    } else {
        var bindings = Bindings{ .entries = .empty };
        try self.runFrom(matches.before_with, &bindings, .match_found);
    }

    if (has_writes) try self.graph.commitWrite() else self.graph.commitRead();

    if (self.return_clause) |return_clause| try projection.postProcess(self, return_clause);

    const result = try self.allocator.alloc(Row, self.rows.items.len);
    for (result, self.rows.items) |*row, sortable| row.* = sortable.item;
    return result;
}

/// The MATCH clauses before and after the WITH clause (if any).
const MatchClauses = struct { before_with: ?Index, after_with: ?Index };

fn reset(self: *Executor) void {
    self.rows.clearRetainingCapacity();
    self.groups = .{};
    self.aggregate_kinds = .empty;
    self.has_aggregates = false;
    self.projection_items = .empty;
    self.with_rows = .empty;
    self.collecting = false;
    self.optional_match = null;
    self.optional_variables = .empty;
    self.main_variables = .empty;
    self.in_optional = false;
    self.optional_matched = false;
    self.unwind = null;
    self.with_clause = null;
    self.update_clauses = .empty;
    self.return_clause = null;
}

/// Sorts the query's clauses into the executor's slots and returns its MATCH
/// clauses; also records which variables MATCH and OPTIONAL MATCH introduce.
fn classifyClauses(self: *Executor, query: Index) ExecutionError!MatchClauses {
    var matches = MatchClauses{ .before_with = null, .after_with = null };
    for (self.ast.nodeChildren(query)) |clause| {
        switch (self.ast.kind(clause)) {
            .match_clause => {
                if (self.with_clause == null) matches.before_with = clause else matches.after_with = clause;
            },
            .optional_match_clause => self.optional_match = clause,
            .unwind_clause => self.unwind = clause,
            .with_clause => self.with_clause = clause,
            .create_clause, .merge_clause, .set_clause, .delete_clause, .remove_clause => try self.update_clauses.append(self.allocator, clause),
            .return_clause => self.return_clause = clause,
            else => {},
        }
    }
    if (self.optional_match) |optional_match| try pattern_matching.collectOptionalVariables(self, optional_match);
    if (matches.before_with) |match_clause| try pattern_matching.collectClauseVariables(self, match_clause, &self.main_variables);
    return matches;
}

/// Splits the RETURN projection into grouping keys and aggregates.
fn collectProjectionItems(self: *Executor) ExecutionError!void {
    const return_clause = self.return_clause orelse return;
    const parts = projection.returnClauseParts(self, return_clause);
    for (self.ast.nodeChildren(parts.projection)) |item| {
        const expression = self.ast.nodeChildren(item)[0];
        if (self.ast.kind(expression) != .aggregate) {
            try self.projection_items.append(self.allocator, .{ .key = expression });
            continue;
        }
        self.has_aggregates = true;
        const kind = self.ast.data(expression).aggregate;
        const children = self.ast.nodeChildren(expression);
        const argument: ?Index = if (children.len > 0) children[0] else null;
        try self.projection_items.append(self.allocator, .{ .aggregate = .{ .kind = kind, .arg = argument } });
        try self.aggregate_kinds.append(self.allocator, kind);
    }
}

/// A query with WITH runs in three phases: collect the bindings of the
/// clauses before WITH, project them through WITH, then run the clauses after
/// WITH once per projected row.
fn runWithPipeline(self: *Executor, with_clause: Index, matches: MatchClauses) ExecutionError!void {
    self.collecting = true;
    var start = Bindings{ .entries = .empty };
    try self.runFrom(matches.before_with, &start, .match_found);
    self.collecting = false;

    try projection.applyWith(self, with_clause);

    for (self.with_rows.items) |row| {
        var bindings = Bindings{ .entries = .empty };
        try bindings.entries.appendSlice(self.allocator, row.entries.items);
        try self.runFrom(matches.after_with, &bindings, .finish_body);
    }
}

/// Without a MATCH clause, where execution continues from.
const Continuation = enum { match_found, finish_body };

/// Runs `match_clause` from `bindings`, or (with no MATCH) continues straight
/// at `without_match`.
fn runFrom(self: *Executor, match_clause: ?Index, bindings: *Bindings, without_match: Continuation) ExecutionError!void {
    if (match_clause) |clause| return self.runMatch(clause, bindings);
    self.has_match = false;
    switch (without_match) {
        .match_found => try self.matchFound(bindings),
        .finish_body => try self.finishBody(bindings),
    }
}

/// Runs one MATCH clause (its patterns + WHERE) from `bindings`, recursing
/// through `matchPatterns`/`runStep` down to `matchFound`.
pub fn runMatch(self: *Executor, match_clause: Index, bindings: *Bindings) ExecutionError!void {
    const match_children = self.ast.nodeChildren(match_clause);
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

    if (self.return_clause) |return_clause| {
        const parts = projection.returnClauseParts(self, return_clause);

        if (self.has_aggregates) {
            try aggregation.accumulate(self, bindings);
            return;
        }

        var out = std.ArrayList(Value).empty;
        for (self.ast.nodeChildren(parts.projection)) |item| {
            const v = try expressions.evaluate(self, self.ast.nodeChildren(item)[0], bindings);
            try out.append(self.allocator, v);
        }
        // The ORDER BY key is evaluated now, while the row's variables are
        // still bound: it may use variables that are not projected.
        const sort_key = try projection.returnSortKey(self, parts, out.items, bindings);
        try self.rows.append(self.allocator, .{ .item = out, .sort_key = sort_key });
    }
}
