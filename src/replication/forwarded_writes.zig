//! Runs on the master the writes its replicas forward: each request
//! (forwarding.zig) is a statement, or a batch of them (statement/batch.zig),
//! run in a transaction of its own on the master's database, as an
//! application's would be, and its answer is the rows of each (with the
//! entities they refer to) or the error. Nothing of the replica's process is there: no
//! import directory (LOAD CSV fails), no procedures it defined.
//!
//! The rows are written before a write commits: a result too large to send
//! (or with values nested too deep) fails the statement and commits nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const forwarding = @import("forwarding.zig");
const Graph = @import("../storage/graph.zig").Graph;
const Statement = @import("../statement/Statement.zig");
const batch = @import("../statement/batch.zig");
const Executor = @import("../execution/Executor.zig");
const Value = @import("../value.zig").Value;
const EntitySnapshot = @import("../execution/entities.zig").EntitySnapshot;
const diagnostics = @import("../diagnostics.zig");
const Diagnostic = diagnostics.Diagnostic;

/// Runs the request in `request_bytes` on `graph`, the master's; returns
/// the bytes of its answer, allocated with `allocator`. Fails only when
/// not even an answer can be made.
pub fn run(graph: *Graph, allocator: Allocator, request_bytes: []const u8) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    var diagnostic: Diagnostic = .init();
    var failed: ?usize = null;
    var answer: std.ArrayList(u8) = .empty;
    errdefer answer.deinit(allocator);
    answerRequest(graph, arena.allocator(), allocator, request_bytes, &diagnostic, &failed, &answer) catch |err| {
        if (diagnostic.message().len == 0) switch (err) {
            error.MalformedMessage => diagnostic.set(.invalid_expression, 0, "the forwarded request is malformed", .{}),
            error.ValueTooDeep => diagnostic.set(.invalid_expression, 0, "a value of the result is nested too deep to send to the replica", .{}),
            error.TooLarge => diagnostic.set(.external_resource, 0, "the result is too large to send to the replica (more than {d} MiB)", .{forwarding.max_answer_bytes >> 20}),
            error.ParseFailed => diagnostic.set(.parse, 0, "parse failed", .{}),
            else => diagnostics.noteError(&diagnostic, err),
        };
        answer.clearRetainingCapacity();
        forwarding.encodeAnswer(&answer, allocator, .{ .failed = .{
            .statement = if (failed) |index| @intCast(index) else forwarding.no_statement,
            .code = @backingInt(diagnostic.code),
            .position = @intCast(diagnostic.pos),
            .message = diagnostic.message(),
        } }) catch |encode_err| switch (encode_err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A failure is a few hundred bytes, with no values.
            error.TooLarge, error.ValueTooDeep => unreachable,
        };
    };
    return answer.toOwnedSlice(allocator);
}

/// Runs the request and writes its `done` answer into `answer`; on an
/// error nothing is committed, `diagnostic` may tell why and `failed` is
/// the index of the statement that failed, if one did.
fn answerRequest(graph: *Graph, scratch: Allocator, allocator: Allocator, request_bytes: []const u8, diagnostic: *Diagnostic, failed: *?usize, answer: *std.ArrayList(u8)) !void {
    const requests = try forwarding.decodeRequests(request_bytes, scratch);
    if (requests.len > 1) return answerBatch(graph, scratch, allocator, requests, diagnostic, failed, answer);
    failed.* = 0;
    const request = requests[0];
    const statement = try Statement.prepare(scratch, request.text, .{ .graph = graph, .diagnostic = diagnostic });
    defer statement.destroy();
    var executor = statement.executorFor(graph, scratch);
    executor.diagnostic = diagnostic;
    for (request.parameters) |entry| try executor.parameters.put(scratch, entry.key, entry.value);
    if (!statement.is_query) {
        // A schema command, EXPLAIN, PROFILE: in its own transaction, with
        // a few rows.
        const rows = try statement.run(&executor);
        failed.* = null;
        try encodeDone(answer, allocator, &.{try resultOf(scratch, statement.columns, rows, &executor.entities)}, lastLsn(graph));
        return;
    }
    const rows = try statement.runOpen(&executor);
    {
        errdefer statement.abort(graph);
        try encodeDone(answer, allocator, &.{try resultOf(scratch, statement.columns, rows, &executor.entities)}, 0);
        // What failed now is the commit.
        failed.* = null;
    }
    try statement.commit(graph);
    forwarding.setAnswerLsn(answer.items, lastLsn(graph));
}

/// Runs a batch of `requests` in one transaction, as `answerRequest` runs
/// one statement.
fn answerBatch(graph: *Graph, scratch: Allocator, allocator: Allocator, requests: []const forwarding.Request, diagnostic: *Diagnostic, failed: *?usize, answer: *std.ArrayList(u8)) !void {
    const statements = try scratch.alloc(*Statement, requests.len);
    var prepared: usize = 0;
    defer for (statements[0..prepared]) |statement| statement.destroy();
    const executors = try scratch.alloc(Executor, requests.len);
    // A statement that cannot be prepared, or cannot go in a batch, fails it.
    for (requests, statements, executors, 0..) |request, *statement, *executor, index| {
        failed.* = index;
        statement.* = try Statement.prepare(scratch, request.text, .{ .graph = graph, .diagnostic = diagnostic });
        prepared += 1;
        try batch.check(statement.*, &.{}, diagnostic);
        executor.* = statement.*.executorFor(graph, scratch);
        executor.diagnostic = diagnostic;
        for (request.parameters) |entry| try executor.parameters.put(scratch, entry.key, entry.value);
    }
    const rows = try scratch.alloc([]const Executor.Row, requests.len);
    try batch.runOpen(graph, statements, executors, rows, failed);
    {
        errdefer batch.abort(graph, statements);
        const results = try scratch.alloc(forwarding.Result, requests.len);
        for (results, statements, rows, executors) |*result, statement, statement_rows, *executor| {
            result.* = try resultOf(scratch, statement.columns, statement_rows, &executor.entities);
        }
        try encodeDone(answer, allocator, results, 0);
    }
    try batch.commit(graph, statements);
    forwarding.setAnswerLsn(answer.items, lastLsn(graph));
}

fn resultOf(scratch: Allocator, columns: []const []const u8, rows: []const Executor.Row, entities: *const EntitySnapshot) !forwarding.Result {
    // Without columns (no RETURN) the rows hold nothing to send.
    const row_values = try scratch.alloc([]const Value, if (columns.len == 0) 0 else rows.len);
    for (row_values, rows[0..row_values.len]) |*values, row| values.* = row.items;
    return .{ .columns = columns, .rows = row_values, .entities = if (columns.len == 0) .{} else entities.* };
}

fn encodeDone(answer: *std.ArrayList(u8), allocator: Allocator, results: []const forwarding.Result, lsn: u64) !void {
    try forwarding.encodeAnswer(answer, allocator, .{ .done = .{ .lsn = lsn, .results = results } });
}

/// The master's last LSN, outside any transaction, once what ran committed: a
/// read that fails now must not answer that it failed. Then, the last LSN this
/// store committed.
fn lastLsn(graph: *Graph) u64 {
    const state = (graph.store.changeLogState() catch null) orelse return graph.store.last_committed_lsn orelse 0;
    return state.next_lsn - 1;
}
