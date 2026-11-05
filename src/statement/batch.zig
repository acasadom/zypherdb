//! A batch: several statements run one after another in one transaction
//! (`write_many` in the bindings). Each sees what the ones before it wrote;
//! they commit together, as one change set, or, if one fails, none does.
//!
//! A batch holds queries only, and none that needs what only this process
//! has, so that it runs the same on any database, and on a replica's
//! master when the replica forwards it: no schema command (it commits a
//! transaction of its own), no EXPLAIN or PROFILE, no LOAD CSV (it reads
//! this process's import directory) and no procedure the process defined.

const std = @import("std");

const Statement = @import("Statement.zig");
const Executor = @import("../execution/Executor.zig");
const Row = Executor.Row;
const ExecutionError = Executor.ExecutionError;
const Graph = @import("../storage/graph.zig").Graph;
const Index = @import("../query/ast.zig").Index;
const procedures = @import("../query/procedures.zig");
const Diagnostic = @import("../diagnostics.zig").Diagnostic;

/// Whether `statement` may go in a batch, given the procedures the process
/// `defined`; `error.InvalidExpression`, with `diagnostic` telling why, if
/// not.
pub fn check(statement: *const Statement, defined: []const procedures.TableProcedure, diagnostic: ?*Diagnostic) error{InvalidExpression}!void {
    if (!statement.is_query) return refuse(diagnostic, "a batch holds queries only: run schema commands, EXPLAIN and PROFILE on their own", .{});
    const ast = &statement.ast;
    for (0..ast.nodes.items.len) |node| {
        const index: Index = @intCast(node);
        switch (ast.kind(index)) {
            .load_csv_clause => return refuse(diagnostic, "LOAD CSV does not go in a batch: run it on its own", .{}),
            .call_clause => {
                const name = ast.data(index).call.procedure;
                if (procedures.findTable(name, defined) != null) {
                    return refuse(diagnostic, "procedure {s}, defined in this process, is not called in a batch: call it on its own", .{name});
                }
            },
            else => {},
        }
    }
}

/// Whether one of `statements` writes: the batch runs in a write
/// transaction, else in a read one.
pub fn writes(statements: []const *Statement) bool {
    for (statements) |statement| if (statement.writes) return true;
    return false;
}

/// Runs `statements` (each `check`ed), each with its executor (made for
/// it, `Statement.executorFor`), in one transaction on `graph`; the rows of
/// each go in `results`. On an error nothing is committed and `failed`
/// is the index of the statement that failed, or null if none did (the
/// commit failed).
pub fn run(graph: *Graph, statements: []const *Statement, executors: []Executor, results: [][]const Row, failed: *?usize) ExecutionError!void {
    try runOpen(graph, statements, executors, results, failed);
    try commit(graph, statements);
}

/// Runs the batch as `run` does, but leaves its transaction open: the
/// caller then `commit`s or `abort`s it.
pub fn runOpen(graph: *Graph, statements: []const *Statement, executors: []Executor, results: [][]const Row, failed: *?usize) ExecutionError!void {
    std.debug.assert(statements.len == executors.len and statements.len == results.len);
    failed.* = null;
    if (writes(statements)) try graph.beginWrite() else try graph.beginRead();
    errdefer abort(graph, statements);
    for (statements, executors, results, 0..) |statement, *executor, *rows, index| {
        failed.* = index;
        rows.* = try statement.runIn(executor);
    }
    failed.* = null;
}

/// Commits the transaction `runOpen` left open.
pub fn commit(graph: *Graph, statements: []const *Statement) ExecutionError!void {
    if (!writes(statements)) return graph.commitRead();
    graph.commitWrite() catch |err| {
        graph.abortWrite();
        return err;
    };
}

/// Aborts the transaction `runOpen` left open.
pub fn abort(graph: *Graph, statements: []const *Statement) void {
    if (writes(statements)) graph.abortWrite() else graph.abortRead();
}

fn refuse(diagnostic: ?*Diagnostic, comptime format: []const u8, arguments: anytype) error{InvalidExpression} {
    if (diagnostic) |d| d.set(.invalid_expression, 0, format, arguments);
    return error.InvalidExpression;
}
