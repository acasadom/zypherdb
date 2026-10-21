//! Streaming execution of read-only queries: each row goes through the
//! clauses one at a time, instead of each clause producing all its rows
//! before the next starts (`Executor.runClauses`, which queries that write
//! keep: a writing clause must see the effect of the clauses before it on
//! every row first).
//!
//! A clause is a stage. `feed` hands one row to a stage, which passes the
//! rows it makes on to the next:
//!
//! - MATCH and OPTIONAL MATCH run the pattern from the row, and each match
//!   goes on as it is found (`Executor.matchFound`), without being copied;
//! - UNWIND binds each element in turn;
//! - a WITH that only projects and filters passes each projected row on;
//! - a WITH that groups, removes duplicates, sorts or pages needs every row
//!   first: it keeps copies, and its rows go on when the stages before it
//!   are done (`flush`);
//! - RETURN accumulates or projects each row. With a LIMIT and nothing that
//!   needs every row first, it stops the query once it has enough.
//!
//! A row passed to a stage is the caller's: a stage may extend it, but must
//! restore it before returning, and copies it to keep it.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const clauses = @import("clauses.zig");
const expressions = @import("expressions.zig");
const pattern_matching = @import("pattern_matching.zig");
const projection = @import("projection.zig");
const procedures = @import("procedures.zig");
const Value = @import("../value.zig").Value;

const Pipeline = @This();

executor: *Executor,
query_clauses: []const Index,
stages: []Stage,
/// The RETURN's SKIP + LIMIT, when it can stop the query early.
rows_needed: ?usize,

const Stage = union(enum) {
    match: struct { optional: bool },
    unwind,
    call,
    with_streaming: struct { info: projection.WithClauseParts, items: []const projection.WithItem },
    with_collecting: std.ArrayList(Bindings),
    return_: projection.ReturnClauseParts,
};

/// Runs one read-only query; its RETURN rows go to `executor.rows`.
pub fn run(executor: *Executor, query: Index) ExecutionError!void {
    const query_clauses = executor.ast.nodeChildren(query);
    var pipeline = Pipeline{
        .executor = executor,
        .query_clauses = query_clauses,
        .stages = try executor.allocator.alloc(Stage, query_clauses.len),
        .rows_needed = null,
    };
    var return_info: ?projection.ReturnClauseParts = null;
    for (query_clauses, pipeline.stages) |clause, *stage| {
        stage.* = switch (executor.ast.kind(clause)) {
            .match_clause => .{ .match = .{ .optional = false } },
            .optional_match_clause => .{ .match = .{ .optional = true } },
            .unwind_clause => .unwind,
            .call_clause => .call,
            .with_clause => if (try projection.withStreams(executor, clause)) with: {
                const info = projection.withClauseParts(executor, clause);
                break :with .{ .with_streaming = .{ .info = info, .items = try projection.withItems(executor, info) } };
            } else .{ .with_collecting = .empty },
            .return_clause => ret: {
                const info = try projection.beginReturn(executor, clause);
                return_info = info;
                pipeline.rows_needed = try projection.returnRowsNeeded(executor, info);
                break :ret .{ .return_ = info };
            },
            else => unreachable, // a writing clause: the query is not read-only
        };
    }

    const saved_pipeline = executor.pipeline;
    executor.pipeline = &pipeline;
    defer executor.pipeline = saved_pipeline;

    pipeline.runStages() catch |err| switch (err) {
        error.LimitReached => {}, // the RETURN has every row it keeps
        else => |other| return other,
    };
    if (return_info) |info| try projection.endReturn(executor, info);
}

/// Feeds the first stage its one empty row, then lets each collecting stage
/// pass its rows on, in order.
fn runStages(self: *Pipeline) ExecutionError!void {
    var start = Bindings{ .entries = .empty };
    try self.feed(0, &start);
    for (self.stages, 0..) |*stage, index| {
        switch (stage.*) {
            .with_collecting => |*kept| {
                const rows = try projection.applyWith(self.executor, self.query_clauses[index], kept.items);
                for (rows) |*row| try self.feed(index + 1, row);
            },
            else => {},
        }
    }
}

/// Hands `row` to stage `index`.
pub fn feed(self: *Pipeline, index: usize, row: *Bindings) ExecutionError!void {
    const executor = self.executor;
    const clause = self.query_clauses[index];
    switch (self.stages[index]) {
        .match => |match| try self.runMatch(index, clause, match.optional, row),
        .unwind => {
            const value = try expressions.evaluate(executor, executor.ast.nodeChildren(clause)[0], row);
            const items: []const @TypeOf(value) = switch (value) {
                .list => |items| items,
                .null => &.{},
                else => &.{value},
            };
            const variable_name = executor.ast.data(clause).unwind.variable_name;
            for (items) |item| {
                const saved = row.mark();
                defer row.restore(saved);
                try row.put(executor.allocator, variable_name, item);
                try self.feed(index + 1, row);
            }
        },
        .call => {
            const Next = struct {
                pipeline: *Pipeline,
                index: usize,

                fn extended(context: *anyopaque, extended_row: *Bindings) ExecutionError!void {
                    const next: *@This() = @ptrCast(@alignCast(context));
                    try next.pipeline.feed(next.index, extended_row);
                }

                fn result(context: *anyopaque, values: []const Value) ExecutionError!void {
                    const next: *@This() = @ptrCast(@alignCast(context));
                    try procedures.appendResult(next.pipeline.executor, values);
                }
            };
            var next = Next{ .pipeline = self, .index = index + 1 };
            try procedures.callRow(executor, clause, row, index + 1 == self.query_clauses.len, .{ .context = &next, .extended = Next.extended, .result = Next.result });
        },
        .with_streaming => |with| {
            var projected = try projection.withRow(executor, with.info, with.items, row) orelse return;
            try self.feed(index + 1, &projected);
        },
        .with_collecting => |*kept| try kept.append(executor.allocator, try clauses.copyRow(executor, row.*)),
        .return_ => |info| {
            try projection.returnRow(executor, info, row);
            if (self.rows_needed) |needed| if (executor.rows.items.len >= needed) return error.LimitReached;
        },
    }
}

/// MATCH or OPTIONAL MATCH from `row`: each match goes on to the next stage
/// as `Executor.matchFound` finds it. The state of a MATCH running around
/// this one (an earlier stage, whose match this row is) is put back after.
fn runMatch(self: *Pipeline, index: usize, clause: Index, optional: bool, row: *Bindings) ExecutionError!void {
    const executor = self.executor;
    const children = executor.ast.nodeChildren(clause);
    const patterns = children[0 .. children.len - 1];

    const saved_patterns = executor.patterns;
    const saved_where = executor.where_expression;
    const saved_matches = executor.matches;
    const saved_used_edges = executor.used_edges;
    const saved_stage = executor.pipeline_stage;
    const saved_emitted = executor.stream_emitted;
    defer {
        executor.patterns = saved_patterns;
        executor.where_expression = saved_where;
        executor.matches = saved_matches;
        executor.used_edges = saved_used_edges;
        executor.pipeline_stage = saved_stage;
        executor.stream_emitted = saved_emitted;
    }
    executor.patterns = patterns;
    executor.where_expression = children[children.len - 1];
    executor.matches = null;
    executor.used_edges = .empty;
    executor.pipeline_stage = index + 1;
    executor.stream_emitted = 0;

    try pattern_matching.matchPatterns(executor, 0, row);
    if (optional and executor.stream_emitted == 0) {
        // No match: the row goes on with the clause's new variables null.
        const saved = row.mark();
        defer row.restore(saved);
        try clauses.bindNewVariablesToNull(executor, patterns, row);
        try self.feed(index + 1, row);
    }
}
