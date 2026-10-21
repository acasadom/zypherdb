//! Runs the chains of a plan (see planning/Plan.zig). `feed` hands one row
//! to an operator, which passes the rows it makes on to the next one in its
//! chain:
//!
//! - the pattern operators extend the row with each match as it is found
//!   (pattern_matching.zig), without copying it;
//! - UNWIND binds each element in turn, LOAD CSV each record;
//! - a streaming WITH passes each projected row on;
//! - an operator that needs every row first (a collecting WITH, `eager`)
//!   keeps copies, and its rows go on when the operators before it in the
//!   chain are done (`flush`);
//! - RETURN accumulates or projects each row. With a LIMIT and nothing that
//!   needs every row first, it stops the query once it has enough.
//!
//! A row passed to an operator is the caller's: an operator may extend it,
//! but must restore it before returning, and copies it to keep it.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const isSubquery = @import("../query/ast.zig").isSubquery;
const Plan = @import("../planning/Plan.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const Value = @import("../value.zig").Value;
const clauses = @import("clauses.zig");
const expressions = @import("expressions.zig");
const load_csv = @import("load_csv.zig");
const pattern_matching = @import("pattern_matching.zig");
const procedures = @import("procedures.zig");
const projection = @import("projection.zig");
const writes = @import("writes.zig");

/// Where the rows of a chain run by an operator or an expression go.
pub const Sink = struct {
    context: *anyopaque,
    take: *const fn (context: *anyopaque, row: *Bindings) ExecutionError!void,
};

/// What a run keeps for an operator besides the plan.
pub const OperatorState = union(enum) {
    none,
    with_streaming: struct { info: projection.WithClauseParts, items: []const projection.WithItem },
    /// The rows a collecting WITH or an `eager` keeps until its chain flushes.
    kept: std.ArrayList(Bindings),
};

/// The run state of every operator of the plan.
pub fn initialStates(executor: *Executor) ExecutionError![]OperatorState {
    const states = try executor.allocator.alloc(OperatorState, executor.plan.operators.len);
    for (states, executor.plan.operators) |*state, operator| {
        state.* = switch (operator) {
            .with_streaming => |clause| streaming: {
                const info = projection.withClauseParts(executor, clause);
                break :streaming .{ .with_streaming = .{ .info = info, .items = try projection.withItems(executor, info) } };
            },
            .with_collecting, .eager => .{ .kept = .empty },
            else => .none,
        };
    }
    return states;
}

/// Runs a query's main chain from one empty row; its RETURN rows go to
/// `executor.rows`.
pub fn runMain(executor: *Executor, chain: Plan.ChainIndex) ExecutionError!void {
    const plan = executor.plan;
    const range = plan.chains[chain];
    var return_info: ?projection.ReturnClauseParts = null;
    var rows_needed: ?usize = null;
    for (plan.operators[range.first..range.end]) |operator| switch (operator) {
        .return_ => |clause| {
            const info = try projection.beginReturn(executor, clause);
            return_info = info;
            rows_needed = try projection.returnRowsNeeded(executor, info);
        },
        else => {},
    };
    if (return_info) |info| executor.return_info = info;
    executor.rows_needed = rows_needed;

    var start = Bindings{ .entries = .empty };
    runOperators(executor, range, &start) catch |err| switch (err) {
        error.LimitReached => {}, // the RETURN has every row it keeps
        else => |other| return other,
    };
    if (return_info) |info| try projection.endReturn(executor, info);
}

/// Runs `chain` from `start`; each row its `output` gets goes to `sink`.
pub fn runChain(executor: *Executor, chain: Plan.ChainIndex, start: *Bindings, sink: Sink) ExecutionError!void {
    const saved = executor.chain_sinks[chain];
    executor.chain_sinks[chain] = sink;
    defer executor.chain_sinks[chain] = saved;
    try runOperators(executor, executor.plan.chains[chain], start);
}

/// Feeds the chain's first operator, then lets each operator that keeps its
/// rows pass them on, in order.
fn runOperators(executor: *Executor, range: Plan.Chain, start: *Bindings) ExecutionError!void {
    // A run that ended early (an error, LIMIT) may have left rows behind.
    for (executor.operator_states[range.first..range.end]) |*state| switch (state.*) {
        .kept => |*kept| kept.* = .empty,
        else => {},
    };
    if (range.first == range.end) return;
    try feed(executor, range.first, start);
    for (range.first..range.end) |index| {
        switch (executor.operator_states[index]) {
            .kept => |*state| {
                const kept = state.items;
                state.* = .empty;
                const rows = switch (executor.plan.operators[index]) {
                    .with_collecting => |clause| try projection.applyWith(executor, clause, kept),
                    else => kept,
                };
                for (rows) |*row| try feed(executor, @intCast(index + 1), row);
            },
            else => {},
        }
    }
}

/// Hands `row` to operator `index`.
pub fn feed(executor: *Executor, index: Plan.OperatorIndex, row: *Bindings) ExecutionError!void {
    const next = index + 1;
    switch (executor.plan.operators[index]) {
        .bound_node => |reference| try pattern_matching.checkBoundNode(executor, reference, next, row),
        .node_scan => |reference| try pattern_matching.scanNodes(executor, reference, next, row),
        .edge_index_scan => |reference| try pattern_matching.scanEdgeIndex(executor, reference, next, row),
        .expand => |expand| try pattern_matching.expand(executor, expand, next, row),
        .project_path => |pattern| try pattern_matching.projectPath(executor, pattern, next, row),
        .filter => |filter| {
            if (!try expressions.evaluateBool(executor, filter.predicate, row)) return;
            if (filter.counts_accepted) executor.accepted_matches += 1;
            try feed(executor, next, row);
        },
        .optional => |optional| try runOptional(executor, optional, next, row),
        .unwind => |clause| {
            const value = try expressions.evaluate(executor, executor.ast.nodeChildren(clause)[0], row);
            const items: []const Value = switch (value) {
                .list => |items| items,
                .null => &.{},
                else => &.{value},
            };
            try feedEach(executor, next, row, executor.ast.data(clause).unwind.variable_name, items);
        },
        .load_csv => |clause| try feedEach(executor, next, row, executor.ast.data(clause).load_csv.variable_name, try load_csv.records(executor, clause, row)),
        .procedure_call => |call| try runProcedure(executor, call, next, row),
        .call_subquery => |call| try runCallSubquery(executor, call, next, row),
        .with_streaming => {
            const state = executor.operator_states[index].with_streaming;
            var projected = try projection.withRow(executor, state.info, state.items, row) orelse return;
            try feed(executor, next, &projected);
        },
        .with_collecting, .eager => try executor.operator_states[index].kept.append(executor.allocator, try clauses.copyRow(executor, row.*)),
        .return_ => {
            try projection.returnRow(executor, executor.return_info, row);
            if (executor.rows_needed) |needed| if (executor.rows.items.len >= needed) return error.LimitReached;
        },
        .write => |clause| {
            const saved = row.mark();
            defer row.restore(saved);
            try clauses.applyWrite(executor, clause, row);
            try feed(executor, next, row);
        },
        .merge => |merge| try runMerge(executor, merge, next, row),
        .foreach => |foreach| try runForeach(executor, foreach, next, row),
        .output => |chain| {
            const sink = executor.chain_sinks[chain] orelse unreachable; // set by runChain
            try sink.take(sink.context, row);
        },
        .discard => {},
    }
}

/// Binds `variable_name` to each of `items` in turn, feeding `next`.
fn feedEach(executor: *Executor, next: Plan.OperatorIndex, row: *Bindings, variable_name: []const u8, items: []const Value) ExecutionError!void {
    for (items) |item| {
        const saved = row.mark();
        defer row.restore(saved);
        try row.put(executor.allocator, variable_name, item);
        try feed(executor, next, row);
    }
}

fn ignoreRow(_: *anyopaque, _: *Bindings) ExecutionError!void {}

/// A sink that feeds operator `next`, counting the rows.
const Continue = struct {
    executor: *Executor,
    next: Plan.OperatorIndex,
    count: usize = 0,

    fn sink(self: *Continue) Sink {
        return .{ .context = self, .take = take };
    }

    fn take(context: *anyopaque, row: *Bindings) ExecutionError!void {
        const self: *Continue = @ptrCast(@alignCast(context));
        self.count += 1;
        try feed(self.executor, self.next, row);
    }
};

/// A sink that keeps a copy of each row.
pub const Collect = struct {
    executor: *Executor,
    rows: std.ArrayList(Bindings) = .empty,

    pub fn sink(self: *Collect) Sink {
        return .{ .context = self, .take = take };
    }

    fn take(context: *anyopaque, row: *Bindings) ExecutionError!void {
        const self: *Collect = @ptrCast(@alignCast(context));
        try self.rows.append(self.executor.allocator, try clauses.copyRow(self.executor, row.*));
    }
};

/// OPTIONAL MATCH from `row`: each match goes on, or, when there is none,
/// the row with the clause's new variables null.
fn runOptional(executor: *Executor, optional: Plan.Optional, next: Plan.OperatorIndex, row: *Bindings) ExecutionError!void {
    var matches = Continue{ .executor = executor, .next = next };
    try runChain(executor, optional.chain, row, matches.sink());
    if (matches.count > 0) return;
    const saved = row.mark();
    defer row.restore(saved);
    const children = executor.ast.nodeChildren(optional.clause);
    try clauses.bindNewVariablesToNull(executor, children[0 .. children.len - 1], row);
    try feed(executor, next, row);
}

fn runProcedure(executor: *Executor, call: Plan.ProcedureCall, next: Plan.OperatorIndex, row: *Bindings) ExecutionError!void {
    const Next = struct {
        executor: *Executor,
        next: Plan.OperatorIndex,

        fn extended(context: *anyopaque, extended_row: *Bindings) ExecutionError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try feed(self.executor, self.next, extended_row);
        }

        fn result(context: *anyopaque, values: []const Value) ExecutionError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try procedures.appendResult(self.executor, values);
        }
    };
    var continuation = Next{ .executor = executor, .next = next };
    try procedures.callRow(executor, call.clause, row, call.ends_query, .{ .context = &continuation, .extended = Next.extended, .result = Next.result });
}

/// `CALL { }` for one row: its subquery runs from the row if it imports
/// variables, else from an empty one. With a RETURN, each row it returns
/// extends this one; without, this row goes on once.
fn runCallSubquery(executor: *Executor, call: Plan.CallSubquery, next: Plan.OperatorIndex, row: *Bindings) ExecutionError!void {
    const Extend = struct {
        executor: *Executor,
        next: Plan.OperatorIndex,
        row: *Bindings,

        fn take(context: *anyopaque, result: *Bindings) ExecutionError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const saved = self.row.mark();
            defer self.row.restore(saved);
            for (result.entries.items) |entry| try self.row.put(self.executor.allocator, entry.name, entry.value);
            try feed(self.executor, self.next, self.row);
        }

    };
    var start = if (call.imports) try clauses.copyRow(executor, row.*) else Bindings{ .entries = .empty };
    var extend = Extend{ .executor = executor, .next = next, .row = row };
    try runChain(executor, call.chain, &start, .{ .context = &extend, .take = if (call.returns) Extend.take else ignoreRow });
    if (!call.returns) try feed(executor, next, row);
}

/// MERGE for one row: every match of its pattern (each with ON MATCH SET
/// applied), or, when there is none, the pattern created, with ON CREATE SET.
fn runMerge(executor: *Executor, merge: Plan.Merge, next: Plan.OperatorIndex, row: *Bindings) ExecutionError!void {
    const children = executor.ast.nodeChildren(merge.clause);
    var scope = try clauses.copyRow(executor, row.*);
    try writes.rejectNullProperties(executor, children[0], &scope);
    var matches = Collect{ .executor = executor };
    var start = try clauses.copyRow(executor, row.*);
    try runChain(executor, merge.chain, &start, matches.sink());
    if (matches.rows.items.len > 0) {
        for (matches.rows.items) |*match| {
            try writes.applySet(executor, children[2], match);
            try feed(executor, next, match);
        }
        return;
    }
    try writes.createPattern(executor, children[0], &scope, .merge);
    try writes.applySet(executor, children[1], &scope);
    try feed(executor, next, &scope);
}

/// FOREACH for one row: its clauses run once per element of the list, with
/// the variable bound to it (no element for `null`). The row goes on as it is.
fn runForeach(executor: *Executor, foreach: Plan.Foreach, next: Plan.OperatorIndex, row: *Bindings) ExecutionError!void {
    const children = executor.ast.nodeChildren(foreach.clause);
    const value = try expressions.evaluate(executor, children[0], row);
    const items: []const Value = switch (value) {
        .list => |items| items,
        .null => &.{},
        else => {
            executor.fail(.type_mismatch, "FOREACH needs a list, not {s}", .{@tagName(value)});
            return error.TypeMismatch;
        },
    };
    for (items) |item| {
        var scope = try clauses.copyRow(executor, row.*);
        try scope.put(executor.allocator, executor.ast.data(foreach.clause).text, item);
        try runChain(executor, foreach.chain, &scope, .{ .context = executor, .take = ignoreRow });
    }
    try feed(executor, next, row);
}

/// The rows of the chain of an expression's pattern or subquery, run from
/// `row` (a pattern predicate, a pattern comprehension, `EXISTS`, `COUNT`).
pub fn expressionRows(executor: *Executor, expression: Index, row: *const Bindings) ExecutionError![]Bindings {
    const chain = executor.plan.expression_chains.get(expression) orelse {
        executor.fail(.invalid_expression, "internal error: an expression's pattern was not planned", .{});
        return error.InvalidExpression;
    };
    // A subquery's expressions are its own: none stands for a group's value.
    const saved_overrides = executor.expression_overrides;
    defer executor.expression_overrides = saved_overrides;
    if (isSubquery(executor.ast.kind(expression))) executor.expression_overrides = null;
    var start = try clauses.copyRow(executor, row.*);
    var rows = Collect{ .executor = executor };
    try runChain(executor, chain, &start, rows.sink());
    return rows.rows.items;
}
