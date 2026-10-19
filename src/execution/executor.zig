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

const Group = @import("aggregation.zig").Group;
const ProjItem = @import("aggregation.zig").ProjItem;
const Bindings = @import("bindings.zig").Bindings;
const BindStep = @import("planner.zig").BindStep;
const ChainEdge = @import("planner.zig").ChainEdge;
const ChainNode = @import("planner.zig").ChainNode;

const planner = @import("planner.zig");
const pattern_matching = @import("pattern_matching.zig");
const expressions = @import("expressions.zig");
const aggregation = @import("aggregation.zig");
const projection = @import("projection.zig");
const writes = @import("writes.zig");

const Executor = @This();

pub const ExecError = StorageError || error{
    UnknownVar,
    MissingProp,
    InvalidExpr,
    TypeMismatch,
};

/// A projected row: one `Value` per RETURN item.
pub const Row = std.ArrayList(Value);

ast: *Ast,
graph: *Graph,
allocator: Allocator,
rows: std.ArrayList(Row),

// Match context.
patterns: []const Index, // the MATCH clause's patterns (one or more)
nodes: std.ArrayList(ChainNode),
edges: std.ArrayList(ChainEdge),
steps: std.ArrayList(BindStep),
where_expr: Index,
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

// Result post-processing.
row_keys: std.ArrayList([]const Value),

// Aggregation.
has_agg: bool,
proj_items: std.ArrayList(ProjItem),
groups: std.ArrayList(Group),

diag: ?*Diagnostic,

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
        .where_expr = 0,
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
        .row_keys = .empty,
        .has_agg = false,
        .proj_items = .empty,
        .groups = .empty,
        .diag = null,
    };
}

pub fn fail(self: *Executor, code: ErrorCode, comptime fmt: []const u8, args: anytype) void {
    if (self.diag) |d| d.set(code, 0, fmt, args);
}

pub fn run(self: *Executor, query: Index) ExecError![]const Row {
    self.rows.clearRetainingCapacity();
    self.row_keys = .empty;
    self.groups = .empty;
    self.has_agg = false;
    self.proj_items = .empty;
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
        try self.collectOptionalVars(om);
    }
    if (pre_match) |pm| {
        try self.collectClauseVars(pm, &self.main_vars);
    }

    // Detect aggregations in the projection (grouping).
    if (self.return_clause) |rc| {
        const info = self.returnInfo(rc);
        for (self.ast.nodeChildren(info.projection)) |item| {
            const expr = self.ast.nodeChildren(item)[0];
            if (self.ast.kind(expr) == .agg) {
                self.has_agg = true;
                const kind = self.ast.data(expr).agg;
                const kids = self.ast.nodeChildren(expr);
                const arg: ?Index = if (kids.len > 0) kids[0] else null;
                try self.proj_items.append(self.allocator, .{ .agg = .{ .kind = kind, .arg = arg } });
            } else {
                try self.proj_items.append(self.allocator, .{ .key = expr });
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
            try self.leaf(&start);
        }
        self.collecting = false;

        // Phase 2: project/aggregate/filter/sort/paginate with WITH.
        try self.applyWith(wc);

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
            try self.leaf(&bindings);
        }
    }

    if (has_writes) try self.graph.commitWrite() else self.graph.commitRead();

    if (self.return_clause) |rc| {
        try self.postProcess(rc);
    }

    return self.rows.items;
}

/// Runs one MATCH clause (its patterns + WHERE) from `bindings`, recursing
/// through `matchPatterns`/`execStep` down to `leaf`.
pub fn runMatch(self: *Executor, mc: Index, bindings: *Bindings) ExecError!void {
    const mc_children = self.ast.nodeChildren(mc);
    self.has_match = true;
    // children = [pattern0, ..., patternN, where_expr]
    self.patterns = mc_children[0 .. mc_children.len - 1];
    self.where_expr = mc_children[mc_children.len - 1];
    try self.matchPatterns(0, bindings);
}
















/// Leaf of a match: apply the MATCH `WHERE`, then either outer-join through
/// OPTIONAL MATCH, collect the bindings (WITH pipeline), or apply updates +
/// RETURN.
pub fn leaf(self: *Executor, bindings: *Bindings) ExecError!void {
    if (self.has_match and !try self.evalBool(self.where_expr, bindings)) return;
    if (self.in_optional) {
        self.optional_matched = true;
        return self.afterOptional(bindings);
    }
    if (self.optional_match != null) {
        return self.runOptional(bindings);
    }
    if (self.unwind != null) {
        return self.runUnwind(bindings);
    }
    return self.afterOptional(bindings);
}

/// Continuation after (optional) matching: collect or finish.
pub fn afterOptional(self: *Executor, bindings: *Bindings) ExecError!void {
    if (self.collecting) {
        return self.collect(bindings);
    }
    try self.finishBody(bindings);
}








pub fn finishBody(self: *Executor, bindings: *Bindings) ExecError!void {
    for (self.update_clauses.items) |clause| {
        switch (self.ast.kind(clause)) {
            .create_clause => try self.applyCreate(self.ast.nodeChildren(clause)[0], bindings),
            .merge_clause => try self.applyMerge(clause, bindings),
            .set_clause => try self.applySet(clause, bindings),
            .delete_clause => try self.applyDelete(clause, bindings),
            .remove_clause => try self.applyRemove(clause, bindings),
            else => {},
        }
    }

    if (self.return_clause) |rc| {
        const info = self.returnInfo(rc);

        if (self.has_agg) {
            try self.accumulate(bindings);
            return;
        }

        var out = std.ArrayList(Value).empty;
        for (self.ast.nodeChildren(info.projection)) |item| {
            const v = try self.eval(self.ast.nodeChildren(item)[0], bindings);
            try out.append(self.allocator, v);
        }
        try self.rows.append(self.allocator, out);

        // Evaluate the ORDER BY keys alongside the row (they may reference
        // variables that aren't projected).
        var keys = std.ArrayList(Value).empty;
        if (info.order_by) |ob| {
            for (self.ast.nodeChildren(ob)) |item| {
                const v = try self.eval(self.ast.nodeChildren(item)[0], bindings);
                try keys.append(self.allocator, v);
            }
        }
        try self.row_keys.append(self.allocator, keys.items);
    }
}

// Clause and expression machinery, implemented by the files above; aliased
// here so the executor's steps call each other as methods.
pub const setupPattern = planner.setupPattern;
pub const shouldEdgeAnchor = planner.shouldEdgeAnchor;
pub const buildEdgeSteps = planner.buildEdgeSteps;
pub const nodeIndex = planner.nodeIndex;
pub const tryAddSeek = planner.tryAddSeek;
pub const collectWhereSeeks = planner.collectWhereSeeks;
pub const estimate = planner.estimate;
pub const seedNodes = pattern_matching.seedNodes;
pub const hasAllLabels = pattern_matching.hasAllLabels;
pub const chooseAnchor = planner.chooseAnchor;
pub const buildSteps = planner.buildSteps;
pub const matchPatterns = pattern_matching.matchPatterns;
pub const execStep = pattern_matching.execStep;
pub const runUnwind = pattern_matching.runUnwind;
pub const runOptional = pattern_matching.runOptional;
pub const collectOptionalVars = pattern_matching.collectOptionalVars;
pub const collectClauseVars = pattern_matching.collectClauseVars;
pub const isMainVar = pattern_matching.isMainVar;
pub const bindOptionalNulls = pattern_matching.bindOptionalNulls;
pub const collect = projection.collect;
pub const withInfo = projection.withInfo;
pub const applyWith = projection.applyWith;
pub const findOrCreateWithGroup = projection.findOrCreateWithGroup;
pub const dedupBindings = projection.dedupBindings;
pub const applyBindingsSkip = projection.applyBindingsSkip;
pub const applyBindingsLimit = projection.applyBindingsLimit;
pub const sortBindings = projection.sortBindings;
pub const evalCountExpr = expressions.evalCountExpr;
pub const accumulate = aggregation.accumulate;
pub const evalAggArg = aggregation.evalAggArg;
pub const evalCountArg = aggregation.evalCountArg;
pub const findOrCreateGroup = aggregation.findOrCreateGroup;
pub const updateAgg = aggregation.updateAgg;
pub const aggregate = aggregation.aggregate;
pub const returnInfo = projection.returnInfo;
pub const postProcess = projection.postProcess;
pub const dedup = projection.dedup;
pub const sortRows = projection.sortRows;
pub const applyCreate = writes.applyCreate;
pub const applyMerge = writes.applyMerge;
pub const createNode = writes.createNode;
pub const findMatchingNode = writes.findMatchingNode;
pub const nodePropsMatch = writes.nodePropsMatch;
pub const applyEdges = writes.applyEdges;
pub const applySet = writes.applySet;
pub const applyRemove = writes.applyRemove;
pub const applyDelete = writes.applyDelete;
pub const nodeSeeksMatch = pattern_matching.nodeSeeksMatch;
pub const edgeSeeksMatch = pattern_matching.edgeSeeksMatch;
pub const evalBool = expressions.evalBool;
pub const inList = expressions.inList;
pub const eval = expressions.eval;
