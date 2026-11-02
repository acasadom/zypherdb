//! The statements that write on a replica that forwards them
//! (`Role.Replica.forward_writes`): each goes to the master as its text and
//! parameters (forwarding.zig), runs there, and its rows come back with
//! the entities they refer to. The replica then waits until it has applied
//! what the write committed, so a read after it sees it; if that takes
//! longer than the request's time, the rows still come back, marked as
//! not visible here yet. Reads, EXPLAIN and SHOW run here as ever.
//!
//! Some statements need what only the replica's process has, and are
//! refused instead: a write that reads a CSV file (LOAD CSV reads the
//! master's import directory, not the replica's), or that calls a
//! procedure the process defined; and PROFILE of a write, whose profile
//! would be the master's.

const std = @import("std");
const Allocator = std.mem.Allocator;

const forwarding = @import("forwarding.zig");
const Replication = @import("replication.zig").Replication;
const Statement = @import("../statement/Statement.zig");
const Executor = @import("../execution/Executor.zig");
const Row = Executor.Row;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const procedures = @import("../query/procedures.zig");
const MapEntry = @import("../value.zig").MapEntry;
const diagnostics = @import("../diagnostics.zig");
const Diagnostic = diagnostics.Diagnostic;
const ErrorCode = diagnostics.ErrorCode;

pub const Route = enum {
    /// Runs on the replica.
    local,
    /// Goes to the master.
    forward,
};

pub const Error = error{
    /// Refused on the replica: it cannot be forwarded.
    WriteNotForwarded,
    /// Not run: the master could not be reached, or turned it away.
    MasterUnreachable,
    /// Sent whole, then the connection was lost or the time ran out: the
    /// master may have run it.
    OutcomeUnknown,
    /// Run on the master, where it failed: nothing committed.
    ForwardedWriteFailed,
} || Allocator.Error;

/// Where `statement` runs on a replica that forwards writes, given the
/// procedures the process `defined`; `error.WriteNotForwarded`, with
/// `diagnostic` telling why, if it can run on neither.
pub fn route(statement: *const Statement, defined: []const procedures.TableProcedure, diagnostic: *Diagnostic) Error!Route {
    const ast = &statement.ast;
    const root = statement.root;
    switch (ast.kind(root)) {
        .explain => {
            if (ast.data(root).explain == .profile and writes(ast, ast.nodeChildren(root)[0])) {
                return refuse(diagnostic, "PROFILE of a statement that writes does not run on a replica: profile it on the master", .{});
            }
            return .local;
        },
        .create_fulltext_index, .create_index, .create_constraint, .drop_index, .drop_constraint => return .forward,
        else => {},
    }
    if (!statement.is_query or !statement.writes) return .local;
    for (0..ast.nodes.items.len) |node| {
        const index: Index = @intCast(node);
        switch (ast.kind(index)) {
            .load_csv_clause => return refuse(diagnostic, "a write with LOAD CSV is not forwarded to the master (it would read the master's import directory): run it on the master", .{}),
            .call_clause => {
                const name = ast.data(index).call.procedure;
                if (procedures.findTable(name, defined) != null) {
                    return refuse(diagnostic, "a write that calls procedure {s}, defined in this process, is not forwarded to the master: the master does not have it", .{name});
                }
            },
            else => {},
        }
    }
    return .forward;
}

/// Tells why a write block is refused (`db.write()`, the C API's `zypherdb_begin_write`)
/// on a replica that forwards writes: it holds a transaction, which the
/// master would keep open over the network.
pub fn refuseWriteBlock(diagnostic: *Diagnostic) void {
    diagnostic.set(.write_not_forwarded, 0, "write blocks are not forwarded to the master: write on a replica with Cypher statements", .{});
}

/// What a forwarded statement gave back.
pub const Forwarded = struct {
    rows: []const Row,
    /// Whether the replica has applied what the write committed: a read
    /// here sees it. False: the time ran out first.
    visible: bool,
};

/// Forwards `statement`, with the parameters of `executor` (made for it,
/// allocating in a scratch arena), to the master of `replication` and
/// waits for its rows; the entities they refer to go in
/// `executor.entities`, as a local run leaves them. On an error,
/// `executor.diagnostic` tells why.
pub fn forward(replication: *Replication, statement: *const Statement, executor: *Executor) Error!Forwarded {
    const scratch = executor.allocator;
    var unused: Diagnostic = .init();
    const diagnostic = executor.diagnostic orelse &unused;
    const since = replication.now();

    const parameters = try scratch.alloc(MapEntry, executor.parameters.count());
    var entries = executor.parameters.iterator();
    for (parameters) |*parameter| {
        const entry = entries.next().?;
        parameter.* = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.* };
    }
    std.mem.sort(MapEntry, parameters, {}, keyLessThan);
    var request: std.ArrayList(u8) = .empty;
    forwarding.encodeRequest(&request, scratch, .{ .text = statement.text, .parameters = parameters }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => fail(diagnostic, .invalid_expression, error.WriteNotForwarded, "the statement and its parameters are too large to forward to the master (more than {d} MiB)", .{forwarding.max_request_bytes >> 20}),
        error.ValueTooDeep => fail(diagnostic, .invalid_expression, error.WriteNotForwarded, "a parameter is nested too deep to forward to the master", .{}),
    };

    const outcome = replication.forward(request.items) catch |err| {
        return fail(diagnostic, .master_unreachable, error.MasterUnreachable, "the write could not be forwarded to the master: {t}; it did not run", .{err});
    };
    const answer_bytes = switch (outcome) {
        .answer => |bytes| bytes,
        .refused => |refusal| return fail(diagnostic, .master_unreachable, error.MasterUnreachable, "the master turned the forwarded write away ({t}); it did not run", .{refusal}),
        .master_unreachable => return fail(diagnostic, .master_unreachable, error.MasterUnreachable, "the master could not be reached in time; the write did not run", .{}),
        .unknown => return fail(diagnostic, .outcome_unknown, error.OutcomeUnknown, "the connection to the master was lost, or the time ran out, after the write was sent: it may have committed or not", .{}),
        .failed => |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NoCopy => fail(diagnostic, .master_unreachable, error.MasterUnreachable, "the replica holds no copy of its master yet; the write did not run", .{}),
            else => fail(diagnostic, .master_unreachable, error.MasterUnreachable, "the write could not be forwarded to the master: {t}; it did not run", .{err}),
        },
    };
    // The decoded answer holds views into its bytes: they live in the scratch.
    const bytes = scratch.dupe(u8, answer_bytes) catch |err| {
        replication.freeAnswer(answer_bytes);
        return err;
    };
    replication.freeAnswer(answer_bytes);
    const answer = forwarding.decodeAnswer(bytes, scratch) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail(diagnostic, .outcome_unknown, error.OutcomeUnknown, "the master's answer to the write is malformed: it may have committed or not", .{}),
    };
    const done = switch (answer) {
        .done => |done| done,
        .failed => |failure| {
            const code = std.enums.fromInt(ErrorCode, failure.code) orelse .storage;
            diagnostic.set(code, failure.position, "{s}", .{failure.message});
            return error.ForwardedWriteFailed;
        },
    };

    const rows = try scratch.alloc(Row, done.rows.len);
    for (rows, done.rows) |*row, values| {
        row.* = try .initCapacity(scratch, values.len);
        row.appendSliceAssumeCapacity(values);
    }
    executor.entities = done.entities;
    const timeout_ns = replication.requestTimeout() -| (replication.now() -| since);
    return .{ .rows = rows, .visible = replication.waitFor(done.lsn, timeout_ns) };
}

/// Whether query or UNION `root` writes.
fn writes(ast: *const Ast, root: Index) bool {
    if (ast.kind(root) != .union_query) return ast.queryWrites(root);
    for (ast.nodeChildren(root)) |query| if (ast.queryWrites(query)) return true;
    return false;
}

fn keyLessThan(_: void, a: MapEntry, b: MapEntry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn refuse(diagnostic: *Diagnostic, comptime format: []const u8, arguments: anytype) Error!Route {
    diagnostic.set(.write_not_forwarded, 0, format, arguments);
    return error.WriteNotForwarded;
}

fn fail(diagnostic: *Diagnostic, code: ErrorCode, err: Error, comptime format: []const u8, arguments: anytype) Error {
    diagnostic.set(code, 0, format, arguments);
    return err;
}
