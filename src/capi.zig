//! C ABI for embedding acmedb (target: Python via ctypes, or any C FFI).
//!
//! Every function is `export fn` (C calling convention). Strings are passed as
//! (pointer, length) pairs. Handles are opaque pointers (`*Context`, `*Result`);
//! the caller must release them with the matching close/free function.
//!
//! Results are fully self-contained: the returned `*Result` owns an arena that
//! holds all its string cells, freed by `acmedb_result_free`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = @import("ast/ast.zig").Ast;
const Graph = @import("storage/graph.zig").Graph;
const KvStore = @import("storage/kv_store.zig").KvStore;
const Value = @import("storage/graph.zig").Value;
const Row = @import("exec/exec.zig").Row;
const Executor = @import("exec/exec.zig").Executor;
const Diagnostic = @import("diag.zig").Diagnostic;
const ErrorCode = @import("diag.zig").ErrorCode;
const parser = @import("parser/parser.zig");

const Context = struct {
    store: KvStore,
    graph: Graph,
    allocator: Allocator,
    diag: Diagnostic,
};

const Result = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,
    json: []u8, // the whole result serialized to JSON (for the bulk reader)
};

const allocator: Allocator = std.heap.c_allocator;

// Cell type tags returned by acmedb_result_type.
const TYPE_INT: c_int = 0;
const TYPE_STR: c_int = 1;
const TYPE_BOOL: c_int = 2;
const TYPE_NULL: c_int = 3;
const TYPE_LIST: c_int = 4;

export fn acmedb_open(path_ptr: [*]const u8, path_len: usize) ?*Context {
    const path = path_ptr[0..path_len];
    const ctx = allocator.create(Context) catch return null;
    ctx.store = KvStore.open(allocator, path) catch {
        allocator.destroy(ctx);
        return null;
    };
    ctx.graph = Graph.init(&ctx.store, allocator);
    ctx.allocator = allocator;
    ctx.diag = Diagnostic.init();
    return ctx;
}

export fn acmedb_close(ctx: *Context) void {
    ctx.store.deinit();
    allocator.destroy(ctx);
}

/// Returns the last error message (and its length), if the most recent
/// operation failed.
export fn acmedb_last_error(ctx: *Context, out_len: *usize) [*]const u8 {
    const m = ctx.diag.message();
    out_len.* = m.len;
    return m.ptr;
}

/// Returns the last error code (see `ErrorCode` in `diag.zig`), 0 if none.
export fn acmedb_error_code(ctx: *Context) c_int {
    return @intCast(@intFromEnum(ctx.diag.code));
}

/// Begins an explicit write transaction. Until `acmedb_commit_write` (or
/// `acmedb_abort_write`), every mutator runs inside it and commits atomically at
/// the end — one fsync for the whole batch. Returns 0 on success.
export fn acmedb_begin_write(ctx: *Context) c_int {
    ctx.graph.beginWrite() catch return 1;
    return 0;
}

export fn acmedb_commit_write(ctx: *Context) c_int {
    ctx.graph.commitWrite() catch return 1;
    return 0;
}

export fn acmedb_abort_write(ctx: *Context) void {
    ctx.graph.abortWrite();
}

/// Allocates a fresh, never-used node id (atomically). Returns `maxInt(u64)` on
/// failure.
export fn acmedb_alloc_node_id(ctx: *Context) u64 {
    // Inside an explicit write txn the read-modify-write is already atomic;
    // standalone it needs its own transaction.
    if (ctx.graph.inWriteTxn()) {
        return ctx.graph.allocNodeId() catch std.math.maxInt(u64);
    }
    ctx.graph.beginWrite() catch return std.math.maxInt(u64);
    const id = ctx.graph.allocNodeId() catch {
        ctx.graph.abortWrite();
        return std.math.maxInt(u64);
    };
    ctx.graph.commitWrite() catch return std.math.maxInt(u64);
    return id;
}

export fn acmedb_add_node(ctx: *Context, id: u64, label_ptr: [*]const u8, label_len: usize) c_int {
    ctx.graph.addNode(id, label_ptr[0..label_len]) catch return 1;
    return 0;
}

/// Mutator return codes: success, storage failure, and a missing node.
const RC_OK: c_int = 0;
const RC_STORAGE: c_int = 1;
const RC_NO_NODE: c_int = 2;

/// Returns `RC_NO_NODE` unless every id in `ids` is an existing node.
fn requireNodes(ctx: *Context, ids: []const u64) c_int {
    for (ids) |id| {
        const exists = ctx.graph.hasNode(id) catch return RC_STORAGE;
        if (!exists) return RC_NO_NODE;
    }
    return RC_OK;
}

/// Adds a directed edge. Both endpoints must exist (`RC_NO_NODE` otherwise), so
/// the C ABI can never create a dangling edge.
export fn acmedb_add_edge(ctx: *Context, src: u64, dst: u64, etype_ptr: [*]const u8, etype_len: usize) c_int {
    const rc = requireNodes(ctx, &.{ src, dst });
    if (rc != RC_OK) return rc;
    ctx.graph.addEdge(src, dst, etype_ptr[0..etype_len]) catch return RC_STORAGE;
    return RC_OK;
}

/// Sets an int property on an existing node (`RC_NO_NODE` otherwise).
export fn acmedb_set_prop_i64(ctx: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value: i64) c_int {
    const rc = requireNodes(ctx, &.{id});
    if (rc != RC_OK) return rc;
    ctx.graph.setProp(id, name_ptr[0..name_len], .{ .int = value }) catch return RC_STORAGE;
    return RC_OK;
}

/// Sets a string property on an existing node (`RC_NO_NODE` otherwise).
export fn acmedb_set_prop_str(ctx: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize) c_int {
    const rc = requireNodes(ctx, &.{id});
    if (rc != RC_OK) return rc;
    ctx.graph.setProp(id, name_ptr[0..name_len], .{ .str = value_ptr[0..value_len] }) catch return RC_STORAGE;
    return RC_OK;
}

export fn acmedb_query(ctx: *Context, query_ptr: [*]const u8, query_len: usize) ?*Result {
    const query = query_ptr[0..query_len];

    ctx.diag.clear();
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    var ast = Ast.init(scratch.allocator());
    const q = parser.parse(&ast, query, &ctx.diag) catch |err| {
        if (ctx.diag.message().len == 0) ctx.diag.set(.parse, 0, "parse failed: {s}", .{@errorName(err)});
        return null;
    };
    var exec = Executor.init(&ast, &ctx.graph, scratch.allocator());
    exec.diag = &ctx.diag;
    const rows = exec.run(q) catch |err| {
        // A bare runtime error that didn't set a message gets a generic one.
        if (ctx.diag.message().len == 0) noteError(&ctx.diag, err);
        return null;
    };

    const result = ctx.allocator.create(Result) catch return null;
    result.arena = std.heap.ArenaAllocator.init(ctx.allocator);
    result.rows = copyRows(&result.arena, rows) catch {
        result.arena.deinit();
        ctx.allocator.destroy(result);
        return null;
    };
    result.json = rowsToJson(&result.arena, result.rows) catch {
        result.arena.deinit();
        ctx.allocator.destroy(result);
        return null;
    };
    return result;
}

/// Serializes the whole result to a JSON array of arrays (`[[…], […]]`), so a
/// caller can read a large result in one call instead of one per cell. The
/// returned pointer is owned by the Result (valid until `acmedb_result_free`).
export fn acmedb_result_to_json(result: *const Result, out_len: *usize) [*]const u8 {
    out_len.* = result.json.len;
    return result.json.ptr;
}

fn appendJsonString(buf: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try buf.append(gpa, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            0x00...0x1F => {
                // Every control char (including \n \r \t) as a \u00XX escape.
                const hex = "0123456789abcdef";
                var esc = [6]u8{ '\\', 'u', '0', '0', 0, 0 };
                esc[4] = hex[c >> 4];
                esc[5] = hex[c & 0xF];
                try buf.appendSlice(gpa, &esc);
            },
            else => try buf.append(gpa, c),
        }
    }
    try buf.append(gpa, '"');
}

fn appendJsonValue(buf: *std.ArrayList(u8), gpa: Allocator, v: Value) Allocator.Error!void {
    switch (v) {
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(gpa, s);
        },
        .str => |s| try appendJsonString(buf, gpa, s),
        .boolean => |b| try buf.appendSlice(gpa, if (b) "true" else "false"),
        .null => try buf.appendSlice(gpa, "null"),
        .list => |items| {
            try buf.append(gpa, '[');
            for (items, 0..) |e, i| {
                if (i > 0) try buf.append(gpa, ',');
                try appendJsonValue(buf, gpa, e);
            }
            try buf.append(gpa, ']');
        },
    }
}

fn rowsToJson(arena: *std.heap.ArenaAllocator, rows: []const Row) Allocator.Error![]u8 {
    const gpa = arena.allocator();
    var buf = std.ArrayList(u8).empty;
    try buf.append(gpa, '[');
    for (rows, 0..) |r, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.append(gpa, '[');
        for (r.items, 0..) |v, j| {
            if (j > 0) try buf.append(gpa, ',');
            try appendJsonValue(&buf, gpa, v);
        }
        try buf.append(gpa, ']');
    }
    try buf.append(gpa, ']');
    return buf.items; // arena-owned
}

fn copyRows(arena: *std.heap.ArenaAllocator, rows: []const Row) Allocator.Error![]Row {
    var out = std.ArrayList(Row).empty;
    for (rows) |r| {
        var row = std.ArrayList(Value).empty;
        for (r.items) |v| {
            switch (v) {
                .int => |n| try row.append(arena.allocator(), .{ .int = n }),
                .boolean => |b| try row.append(arena.allocator(), .{ .boolean = b }),
                .null => try row.append(arena.allocator(), .{ .null = {} }),
                .list => |items| {
                    var list = std.ArrayList(Value).empty;
                    for (items) |e| {
                        switch (e) {
                            .int => |n| try list.append(arena.allocator(), .{ .int = n }),
                            .boolean => |b| try list.append(arena.allocator(), .{ .boolean = b }),
                            .null => try list.append(arena.allocator(), .{ .null = {} }),
                            .str => |s| {
                                const copy = try arena.allocator().dupe(u8, s);
                                try list.append(arena.allocator(), .{ .str = copy });
                            },
                            .list => |inner| {
                                // Lists of lists are not surfaced through the C ABI.
                                _ = inner;
                                return error.OutOfMemory;
                            },
                        }
                    }
                    try row.append(arena.allocator(), .{ .list = list.items });
                },
                .str => |s| {
                    const copy = try arena.allocator().dupe(u8, s);
                    try row.append(arena.allocator(), .{ .str = copy });
                },
            }
        }
        try out.append(arena.allocator(), row);
    }
    return out.items;
}

export fn acmedb_result_free(result: *Result) void {
    result.arena.deinit();
    allocator.destroy(result);
}

export fn acmedb_result_rows(result: *const Result) usize {
    return result.rows.len;
}

export fn acmedb_result_cols(result: *const Result) usize {
    if (result.rows.len == 0) return 0;
    return result.rows[0].items.len;
}

export fn acmedb_result_type(result: *const Result, row: usize, col: usize) c_int {
    if (row >= result.rows.len) return -1;
    const r = result.rows[row];
    if (col >= r.items.len) return -1;
    return switch (r.items[col]) {
        .int => TYPE_INT,
        .str => TYPE_STR,
        .boolean => TYPE_BOOL,
        .null => TYPE_NULL,
        .list => TYPE_LIST,
    };
}

export fn acmedb_result_int(result: *const Result, row: usize, col: usize) i64 {
    const r = result.rows[row];
    return switch (r.items[col]) {
        .int => |n| n,
        else => 0,
    };
}

export fn acmedb_result_bool(result: *const Result, row: usize, col: usize) bool {
    const r = result.rows[row];
    return switch (r.items[col]) {
        .boolean => |b| b,
        else => false,
    };
}

export fn acmedb_result_str(result: *const Result, row: usize, col: usize, out_len: *usize) [*]const u8 {
    const r = result.rows[row];
    const s: []const u8 = switch (r.items[col]) {
        .str => |s| s,
        else => "",
    };
    out_len.* = s.len;
    return s.ptr;
}

/// The `idx`-th element of a list cell, or `null` if the cell isn't a list or
/// the index is out of range.
fn listItem(result: *const Result, row: usize, col: usize, idx: usize) ?Value {
    if (row >= result.rows.len) return null;
    const r = result.rows[row];
    if (col >= r.items.len) return null;
    const items = switch (r.items[col]) {
        .list => |items| items,
        else => return null,
    };
    if (idx >= items.len) return null;
    return items[idx];
}

export fn acmedb_result_list_len(result: *const Result, row: usize, col: usize) usize {
    if (row >= result.rows.len) return 0;
    const r = result.rows[row];
    if (col >= r.items.len) return 0;
    return switch (r.items[col]) {
        .list => |items| items.len,
        else => 0,
    };
}

export fn acmedb_result_list_item_type(result: *const Result, row: usize, col: usize, idx: usize) c_int {
    const item = listItem(result, row, col, idx) orelse return -1;
    return switch (item) {
        .int => TYPE_INT,
        .str => TYPE_STR,
        .boolean => TYPE_BOOL,
        .null => TYPE_NULL,
        .list => TYPE_LIST,
    };
}

export fn acmedb_result_list_item_int(result: *const Result, row: usize, col: usize, idx: usize) i64 {
    const item = listItem(result, row, col, idx) orelse return 0;
    return switch (item) {
        .int => |n| n,
        else => 0,
    };
}

export fn acmedb_result_list_item_bool(result: *const Result, row: usize, col: usize, idx: usize) bool {
    const item = listItem(result, row, col, idx) orelse return false;
    return switch (item) {
        .boolean => |b| b,
        else => false,
    };
}

export fn acmedb_result_list_item_str(result: *const Result, row: usize, col: usize, idx: usize, out_len: *usize) [*]const u8 {
    const item = listItem(result, row, col, idx) orelse return "".ptr;
    const s: []const u8 = switch (item) {
        .str => |s| s,
        else => "",
    };
    out_len.* = s.len;
    return s.ptr;
}

/// Sets a generic message + code for a runtime error that never set one.
fn noteError(diag: *Diagnostic, err: anyerror) void {
    const code: ErrorCode = switch (err) {
        error.UnknownVar => .unknown_var,
        error.MissingProp => .missing_prop,
        error.TypeMismatch => .type_mismatch,
        error.InvalidExpr => .invalid_expr,
        error.NodeStillConnected => .node_still_connected,
        else => .storage,
    };
    diag.set(code, 0, "query failed: {s}", .{@errorName(err)});
}

// Force the export functions to be analyzed/emitted even when the test blocks
// are not compiled (library builds).
comptime {
    _ = acmedb_open;
    _ = acmedb_close;
    _ = acmedb_add_node;
    _ = acmedb_add_edge;
    _ = acmedb_set_prop_i64;
    _ = acmedb_set_prop_str;
    _ = acmedb_alloc_node_id;
    _ = acmedb_begin_write;
    _ = acmedb_commit_write;
    _ = acmedb_abort_write;
    _ = acmedb_query;
    _ = acmedb_result_free;
    _ = acmedb_result_rows;
    _ = acmedb_result_cols;
    _ = acmedb_result_type;
    _ = acmedb_result_int;
    _ = acmedb_result_bool;
    _ = acmedb_result_str;
    _ = acmedb_result_to_json;
    _ = acmedb_last_error;
    _ = acmedb_error_code;
    _ = acmedb_result_list_len;
    _ = acmedb_result_list_item_type;
    _ = acmedb_result_list_item_int;
    _ = acmedb_result_list_item_bool;
    _ = acmedb_result_list_item_str;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "C ABI: open, load, query and read results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const ctx = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(ctx);

    try testing.expectEqual(@as(c_int, 0), acmedb_add_node(ctx, 1, "Person".ptr, "Person".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_set_prop_str(ctx, 1, "name".ptr, "name".len, "Keanu Reeves".ptr, "Keanu Reeves".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_set_prop_i64(ctx, 1, "born".ptr, "born".len, 1964));
    try testing.expectEqual(@as(c_int, 0), acmedb_add_node(ctx, 100, "Movie".ptr, "Movie".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_set_prop_str(ctx, 100, "title".ptr, "title".len, "The Matrix".ptr, "The Matrix".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_add_edge(ctx, 1, 100, "ACTED_IN".ptr, "ACTED_IN".len));

    const q = "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title";
    const result = acmedb_query(ctx, q.ptr, q.len).?;
    defer acmedb_result_free(result);

    try testing.expectEqual(@as(usize, 1), acmedb_result_rows(result));
    try testing.expectEqual(@as(usize, 1), acmedb_result_cols(result));
    try testing.expectEqual(TYPE_STR, acmedb_result_type(result, 0, 0));

    var len: usize = 0;
    const s = acmedb_result_str(result, 0, 0, &len);
    try testing.expectEqualStrings("The Matrix", s[0..len]);
}

test "C ABI: node ids, list results and error codes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const ctx = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(ctx);

    // Node id allocation is monotonic.
    const a = acmedb_alloc_node_id(ctx);
    const b = acmedb_alloc_node_id(ctx);
    try testing.expect(a != b);
    try testing.expectEqual(a + 1, b);

    // A list result is readable.
    const q1 = "RETURN [1, 2, 3]";
    const r1 = acmedb_query(ctx, q1.ptr, q1.len).?;
    defer acmedb_result_free(r1);
    try testing.expectEqual(TYPE_LIST, acmedb_result_type(r1, 0, 0));
    try testing.expectEqual(@as(usize, 3), acmedb_result_list_len(r1, 0, 0));
    try testing.expectEqual(TYPE_INT, acmedb_result_list_item_type(r1, 0, 0, 0));
    try testing.expectEqual(@as(i64, 2), acmedb_result_list_item_int(r1, 0, 0, 1));

    // A parse error carries a code + message.
    const q2 = "MATCH (";
    try testing.expect(acmedb_query(ctx, q2.ptr, q2.len) == null);
    try testing.expectEqual(@as(c_int, 1), acmedb_error_code(ctx));

    // An unknown variable carries code 2.
    const q3 = "RETURN n.name";
    try testing.expect(acmedb_query(ctx, q3.ptr, q3.len) == null);
    try testing.expectEqual(@as(c_int, 2), acmedb_error_code(ctx));

    // A type mismatch carries code 4 (and a generic message).
    const q4 = "RETURN size(1)";
    try testing.expect(acmedb_query(ctx, q4.ptr, q4.len) == null);
    try testing.expectEqual(@as(c_int, 4), acmedb_error_code(ctx));
    var len: usize = 0;
    const msg = acmedb_last_error(ctx, &len);
    try testing.expect(len > 0);
    _ = msg;
}

test "C ABI: bulk JSON result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const ctx = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(ctx);

    // Scalars, a string and a list, in one JSON array-of-arrays.
    const q1 = "RETURN 1, 'x', [1, 2, 3]";
    const r1 = acmedb_query(ctx, q1.ptr, q1.len).?;
    defer acmedb_result_free(r1);
    var len1: usize = 0;
    const json1 = acmedb_result_to_json(r1, &len1);
    try testing.expectEqualStrings("[[1,\"x\",[1,2,3]]]", json1[0..len1]);

    // A double quote inside a string is escaped.
    const q2 = "RETURN 'say \"hi\"'";
    const r2 = acmedb_query(ctx, q2.ptr, q2.len).?;
    defer acmedb_result_free(r2);
    var len2: usize = 0;
    const json2 = acmedb_result_to_json(r2, &len2);
    try testing.expectEqualStrings("[[\"say \\\"hi\\\"\"]]", json2[0..len2]);
}

test "C ABI: batched write transaction commits atomically and aborts cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const ctx = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(ctx);

    // 100 nodes in one transaction.
    try testing.expectEqual(@as(c_int, 0), acmedb_begin_write(ctx));
    for (0..100) |i| {
        const id = acmedb_alloc_node_id(ctx);
        try testing.expect(id != std.math.maxInt(u64));
        try testing.expectEqual(@as(c_int, 0), acmedb_add_node(ctx, id, "Person".ptr, "Person".len));
        try testing.expectEqual(@as(c_int, 0), acmedb_set_prop_i64(ctx, id, "n".ptr, "n".len, @intCast(i)));
    }
    try testing.expectEqual(@as(c_int, 0), acmedb_commit_write(ctx));

    const q = "MATCH (n:Person) RETURN count(n)";
    const r = acmedb_query(ctx, q.ptr, q.len).?;
    defer acmedb_result_free(r);
    try testing.expectEqual(@as(i64, 100), acmedb_result_int(r, 0, 0));

    // An aborted transaction leaves nothing behind.
    try testing.expectEqual(@as(c_int, 0), acmedb_begin_write(ctx));
    const id = acmedb_alloc_node_id(ctx);
    try testing.expectEqual(@as(c_int, 0), acmedb_add_node(ctx, id, "Ghost".ptr, "Ghost".len));
    acmedb_abort_write(ctx);

    const q2 = "MATCH (n:Ghost) RETURN count(n)";
    const r2 = acmedb_query(ctx, q2.ptr, q2.len).?;
    defer acmedb_result_free(r2);
    // No Ghost nodes survive the abort: the count over zero matches is 0.
    try testing.expectEqual(@as(usize, 1), acmedb_result_rows(r2));
    try testing.expectEqual(@as(i64, 0), acmedb_result_int(r2, 0, 0));
}

test "C ABI: mutators reject nodes that do not exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const ctx = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(ctx);

    try testing.expectEqual(RC_OK, acmedb_add_node(ctx, 1, "P".ptr, "P".len));
    // A dangling edge and properties on a missing node are refused.
    try testing.expectEqual(RC_NO_NODE, acmedb_add_edge(ctx, 1, 999, "X".ptr, "X".len));
    try testing.expectEqual(RC_NO_NODE, acmedb_add_edge(ctx, 999, 1, "X".ptr, "X".len));
    try testing.expectEqual(RC_NO_NODE, acmedb_set_prop_i64(ctx, 999, "v".ptr, "v".len, 1));
    try testing.expectEqual(RC_NO_NODE, acmedb_set_prop_str(ctx, 999, "v".ptr, "v".len, "a".ptr, "a".len));
    try testing.expect(!try ctx.graph.hasNode(999));
    try testing.expect(!try ctx.graph.hasEdge(1, 999, "X"));

    try testing.expectEqual(RC_OK, acmedb_add_node(ctx, 2, "P".ptr, "P".len));
    try testing.expectEqual(RC_OK, acmedb_add_edge(ctx, 1, 2, "X".ptr, "X".len));
}
