//! Runs on the master the writes its replicas forward: each request
//! (forwarding.zig) is a statement run in a transaction of its own on the
//! master's database, as an application's query would be, and its answer
//! is the rows (with the entities they refer to) or the error. Nothing of the replica's process is there: no
//! import directory (LOAD CSV fails), no procedures it defined.
//!
//! The rows are written before a write commits: a result too large to send
//! (or with values nested too deep) fails the statement and commits nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

const forwarding = @import("forwarding.zig");
const Graph = @import("../storage/graph.zig").Graph;
const Statement = @import("../statement/Statement.zig");
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
    var answer: std.ArrayList(u8) = .empty;
    errdefer answer.deinit(allocator);
    answerRequest(graph, arena.allocator(), allocator, request_bytes, &diagnostic, &answer) catch |err| {
        if (diagnostic.message().len == 0) switch (err) {
            error.MalformedMessage => diagnostic.set(.invalid_expression, 0, "the forwarded request is malformed", .{}),
            error.ValueTooDeep => diagnostic.set(.invalid_expression, 0, "a value of the result is nested too deep to send to the replica", .{}),
            error.TooLarge => diagnostic.set(.external_resource, 0, "the result is too large to send to the replica (more than {d} MiB)", .{forwarding.max_answer_bytes >> 20}),
            error.ParseFailed => diagnostic.set(.parse, 0, "parse failed", .{}),
            else => diagnostics.noteError(&diagnostic, err),
        };
        answer.clearRetainingCapacity();
        forwarding.encodeAnswer(&answer, allocator, .{ .failed = .{
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
/// error nothing is committed and `diagnostic` may tell why.
fn answerRequest(graph: *Graph, scratch: Allocator, allocator: Allocator, request_bytes: []const u8, diagnostic: *Diagnostic, answer: *std.ArrayList(u8)) !void {
    const request = try forwarding.decodeRequest(request_bytes, scratch);
    const statement = try Statement.prepare(scratch, request.text, .{ .graph = graph, .diagnostic = diagnostic });
    defer statement.destroy();
    var executor = statement.executorFor(graph, scratch);
    executor.diagnostic = diagnostic;
    for (request.parameters) |entry| try executor.parameters.put(scratch, entry.key, entry.value);
    if (!statement.is_query) {
        // A schema command, EXPLAIN, PROFILE: in its own transaction, with
        // a few rows.
        const rows = try statement.run(&executor);
        try encodeDone(answer, allocator, scratch, statement.columns, rows, &executor.entities, try lastLsn(graph));
        return;
    }
    const rows = try statement.runOpen(&executor);
    {
        errdefer statement.abort(graph);
        try encodeDone(answer, allocator, scratch, statement.columns, rows, &executor.entities, 0);
    }
    try statement.commit(graph);
    forwarding.setAnswerLsn(answer.items, try lastLsn(graph));
}

fn encodeDone(answer: *std.ArrayList(u8), allocator: Allocator, scratch: Allocator, columns: []const []const u8, rows: []const Executor.Row, entities: *const EntitySnapshot, lsn: u64) !void {
    // Without columns (no RETURN) the rows hold nothing to send.
    const row_values = try scratch.alloc([]const Value, if (columns.len == 0) 0 else rows.len);
    for (row_values, rows[0..row_values.len]) |*values, row| values.* = row.items;
    try forwarding.encodeAnswer(answer, allocator, .{ .done = .{
        .lsn = lsn,
        .columns = columns,
        .rows = row_values,
        .entities = if (columns.len == 0) .{} else entities.*,
    } });
}

/// The master's last LSN, outside any transaction.
fn lastLsn(graph: *Graph) !u64 {
    const state = try graph.store.changeLogState() orelse return error.NotMaster;
    return state.next_lsn - 1;
}
