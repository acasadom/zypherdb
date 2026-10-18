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

export fn acmedb_add_node(ctx: *Context, id: u64, label_ptr: [*]const u8, label_len: usize) c_int {
    ctx.graph.addNode(id, label_ptr[0..label_len]) catch return 1;
    return 0;
}

export fn acmedb_add_edge(ctx: *Context, src: u64, dst: u64, etype_ptr: [*]const u8, etype_len: usize) c_int {
    ctx.graph.addEdge(src, dst, etype_ptr[0..etype_len]) catch return 1;
    return 0;
}

export fn acmedb_set_prop_i64(ctx: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value: i64) c_int {
    ctx.graph.setProp(id, name_ptr[0..name_len], .{ .int = value }) catch return 1;
    return 0;
}

export fn acmedb_set_prop_str(ctx: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_len: usize) c_int {
    ctx.graph.setProp(id, name_ptr[0..name_len], .{ .str = value_ptr[0..value_len] }) catch return 1;
    return 0;
}

export fn acmedb_query(ctx: *Context, query_ptr: [*]const u8, query_len: usize) ?*Result {
    const query = query_ptr[0..query_len];

    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    var ast = Ast.init(scratch.allocator());
    const q = parser.parse(&ast, query, &ctx.diag) catch return null;
    var exec = Executor.init(&ast, &ctx.graph, scratch.allocator());
    exec.diag = &ctx.diag;
    const rows = exec.run(q) catch return null;

    const result = ctx.allocator.create(Result) catch return null;
    result.arena = std.heap.ArenaAllocator.init(ctx.allocator);
    result.rows = copyRows(&result.arena, rows) catch {
        result.arena.deinit();
        ctx.allocator.destroy(result);
        return null;
    };
    return result;
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

// Force the export functions to be analyzed/emitted even when the test blocks
// are not compiled (library builds).
comptime {
    _ = acmedb_open;
    _ = acmedb_close;
    _ = acmedb_add_node;
    _ = acmedb_add_edge;
    _ = acmedb_set_prop_i64;
    _ = acmedb_set_prop_str;
    _ = acmedb_query;
    _ = acmedb_result_free;
    _ = acmedb_result_rows;
    _ = acmedb_result_cols;
    _ = acmedb_result_type;
    _ = acmedb_result_int;
    _ = acmedb_result_bool;
    _ = acmedb_result_str;
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
