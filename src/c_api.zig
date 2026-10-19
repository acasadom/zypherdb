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
const Ast = @import("query/ast.zig").Ast;
const Graph = @import("storage/graph.zig").Graph;
const PropertyIterator = @import("storage/graph.zig").PropertyIterator;
const KeyValueStore = @import("storage/key_value_store.zig").KeyValueStore;
const StorageError = @import("storage/key_value_store.zig").StorageError;
const Value = @import("value.zig").Value;
const Executor = @import("execution/Executor.zig");
const Row = Executor.Row;
const Diagnostic = @import("diagnostics.zig").Diagnostic;
const ErrorCode = @import("diagnostics.zig").ErrorCode;
const parser = @import("query/parser.zig");

pub const Context = struct {
    store: KeyValueStore,
    graph: Graph,
    allocator: Allocator,
    diagnostic: Diagnostic,
    /// The last `acmedb_export_json` document, owned by the context.
    export_json: []u8 = &.{},
};

const Result = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,
    json: []u8, // the whole result serialized to JSON (for the bulk reader)
};

const allocator: Allocator = std.heap.c_allocator;

// Cell type tags returned by acmedb_result_type.
pub const TYPE_INT64: c_int = 0;
pub const TYPE_STRING: c_int = 1;
pub const TYPE_BOOLEAN: c_int = 2;
pub const TYPE_NULL: c_int = 3;
pub const TYPE_LIST: c_int = 4;

pub export fn acmedb_open(path_ptr: [*]const u8, path_len: usize) ?*Context {
    const path = path_ptr[0..path_len];
    const context = allocator.create(Context) catch return null;
    context.store = KeyValueStore.open(allocator, path) catch {
        allocator.destroy(context);
        return null;
    };
    context.graph = Graph.init(&context.store, allocator);
    context.allocator = allocator;
    context.diagnostic = Diagnostic.init();
    context.export_json = &.{};
    return context;
}

pub export fn acmedb_close(context: *Context) void {
    allocator.free(context.export_json);
    context.store.deinit();
    allocator.destroy(context);
}

/// Returns the last error message (and its length), if the most recent
/// operation failed.
pub export fn acmedb_last_error(context: *Context, out_len: *usize) [*]const u8 {
    const m = context.diagnostic.message();
    out_len.* = m.len;
    return m.ptr;
}

/// Returns the last error code (see `ErrorCode` in `diagnostics.zig`), 0 if none.
pub export fn acmedb_error_code(context: *Context) c_int {
    return @intCast(@backingInt(context.diagnostic.code));
}

/// Begins an explicit write transaction. Until `acmedb_commit_write` (or
/// `acmedb_abort_write`), every mutator runs inside it and commits atomically at
/// the end — one fsync for the whole batch. Returns 0 on success.
pub export fn acmedb_begin_write(context: *Context) c_int {
    context.graph.beginWrite() catch return 1;
    return 0;
}

pub export fn acmedb_commit_write(context: *Context) c_int {
    context.graph.commitWrite() catch return 1;
    return 0;
}

pub export fn acmedb_abort_write(context: *Context) void {
    context.graph.abortWrite();
}

/// Allocates a fresh, never-used node id (atomically). Returns `maxInt(u64)` on
/// failure.
pub export fn acmedb_allocate_node_id(context: *Context) u64 {
    // Inside an explicit write txn the read-modify-write is already atomic;
    // standalone it needs its own transaction.
    if (context.graph.inWriteTransaction()) {
        return context.graph.allocateNodeId() catch std.math.maxInt(u64);
    }
    context.graph.beginWrite() catch return std.math.maxInt(u64);
    const id = context.graph.allocateNodeId() catch {
        context.graph.abortWrite();
        return std.math.maxInt(u64);
    };
    context.graph.commitWrite() catch return std.math.maxInt(u64);
    return id;
}

pub export fn acmedb_add_node(context: *Context, id: u64, label_ptr: [*]const u8, label_len: usize) c_int {
    context.graph.addNode(id, label_ptr[0..label_len]) catch return 1;
    return 0;
}

/// Mutator return codes: success, storage failure, and a missing node.
pub const RETURN_OK: c_int = 0;
pub const RETURN_STORAGE_ERROR: c_int = 1;
pub const RETURN_NODE_NOT_FOUND: c_int = 2;

/// Returns `RETURN_NODE_NOT_FOUND` unless every id in `ids` is an existing node.
fn requireNodes(context: *Context, ids: []const u64) c_int {
    for (ids) |id| {
        const exists = context.graph.hasNode(id) catch return RETURN_STORAGE_ERROR;
        if (!exists) return RETURN_NODE_NOT_FOUND;
    }
    return RETURN_OK;
}

/// Adds a directed edge. Both endpoints must exist (`RETURN_NODE_NOT_FOUND` otherwise), so
/// the C ABI can never create a dangling edge.
pub export fn acmedb_add_edge(context: *Context, src: u64, dst: u64, edge_type_ptr: [*]const u8, edge_type_length: usize) c_int {
    const return_code = requireNodes(context, &.{ src, dst });
    if (return_code != RETURN_OK) return return_code;
    context.graph.addEdge(src, dst, edge_type_ptr[0..edge_type_length]) catch return RETURN_STORAGE_ERROR;
    return RETURN_OK;
}

/// Sets an int property on an existing node (`RETURN_NODE_NOT_FOUND` otherwise).
pub export fn acmedb_set_property_int64(context: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value: i64) c_int {
    const return_code = requireNodes(context, &.{id});
    if (return_code != RETURN_OK) return return_code;
    context.graph.setProperty(id, name_ptr[0..name_len], .{ .int = value }) catch return RETURN_STORAGE_ERROR;
    return RETURN_OK;
}

/// Sets a string property on an existing node (`RETURN_NODE_NOT_FOUND` otherwise).
pub export fn acmedb_set_property_string(context: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_length: usize) c_int {
    const return_code = requireNodes(context, &.{id});
    if (return_code != RETURN_OK) return return_code;
    context.graph.setProperty(id, name_ptr[0..name_len], .{ .string = value_ptr[0..value_length] }) catch return RETURN_STORAGE_ERROR;
    return RETURN_OK;
}

pub export fn acmedb_query(context: *Context, query_ptr: [*]const u8, query_len: usize) ?*Result {
    const query = query_ptr[0..query_len];

    context.diagnostic.clear();
    var scratch = std.heap.ArenaAllocator.init(context.allocator);
    defer scratch.deinit();
    var ast = Ast.init(scratch.allocator());
    const q = parser.parse(&ast, query, &context.diagnostic) catch |err| {
        if (context.diagnostic.message().len == 0) context.diagnostic.set(.parse, 0, "parse failed: {s}", .{@errorName(err)});
        return null;
    };
    var executor = Executor.init(&ast, &context.graph, scratch.allocator());
    executor.diagnostic = &context.diagnostic;
    const rows = executor.run(q) catch |err| {
        // A bare runtime error that didn't set a message gets a generic one.
        if (context.diagnostic.message().len == 0) noteError(&context.diagnostic, err);
        return null;
    };

    const result = context.allocator.create(Result) catch return null;
    result.arena = std.heap.ArenaAllocator.init(context.allocator);
    result.rows = copyRows(&result.arena, rows) catch {
        result.arena.deinit();
        context.allocator.destroy(result);
        return null;
    };
    result.json = rowsToJson(&result.arena, result.rows) catch {
        result.arena.deinit();
        context.allocator.destroy(result);
        return null;
    };
    return result;
}

/// Serializes the whole result to a JSON array of arrays (`[[…], […]]`), so a
/// caller can read a large result in one call instead of one per cell. The
/// returned pointer is owned by the Result (valid until `acmedb_result_free`).
pub export fn acmedb_result_to_json(result: *const Result, out_len: *usize) [*]const u8 {
    out_len.* = result.json.len;
    return result.json.ptr;
}

/// Exports the whole graph as one JSON document, read from storage (not
/// through the query engine):
///
///   {"nodes": [{"id": 1, "labels": ["A"], "properties": {"name": "x"}}, ...],
///    "relationships": [{"source": 1, "target": 2, "type": "R", "properties": {}}, ...]}
///
/// Nodes are in id order; relationships by source, then type and target. The
/// returned buffer belongs to the context and stays valid until the next
/// export or `acmedb_close`. Returns null on failure. O(N) in the store size.
pub export fn acmedb_export_json(context: *Context, out_len: *usize) ?[*]const u8 {
    const json = exportGraph(context) catch return null;
    allocator.free(context.export_json);
    context.export_json = json;
    out_len.* = json.len;
    return json.ptr;
}

fn exportGraph(context: *Context) (StorageError || Allocator.Error)![]u8 {
    const graph = &context.graph;
    // Reuse an explicit write transaction if one is open; otherwise read one
    // consistent snapshot.
    const own_transaction = !graph.inWriteTransaction();
    if (own_transaction) try graph.beginRead();
    defer if (own_transaction) graph.commitRead();

    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, "{\"nodes\":[");
    try appendNodesJson(graph, &buffer);
    try buffer.appendSlice(allocator, "],\"relationships\":[");
    try appendRelationshipsJson(graph, &buffer);
    try buffer.appendSlice(allocator, "]}");
    return buffer.toOwnedSlice(allocator);
}

fn appendNodesJson(graph: *Graph, buffer: *std.ArrayList(u8)) (StorageError || Allocator.Error)!void {
    var nodes = try graph.allNodes();
    defer nodes.deinit();
    var first = true;
    while (try nodes.next()) |id| {
        if (!first) try buffer.append(allocator, ',');
        first = false;
        try buffer.print(allocator, "{{\"id\":{d},\"labels\":[", .{id});
        var labels = try graph.labelsOf(id);
        defer labels.deinit();
        var first_label = true;
        while (try labels.next()) |label| {
            if (!first_label) try buffer.append(allocator, ',');
            first_label = false;
            try appendJsonString(buffer, allocator, label);
        }
        try buffer.appendSlice(allocator, "],\"properties\":");
        var properties = try graph.propertiesOf(id);
        defer properties.deinit();
        try appendPropertiesJson(&properties, buffer);
        try buffer.append(allocator, '}');
    }
}

fn appendRelationshipsJson(graph: *Graph, buffer: *std.ArrayList(u8)) (StorageError || Allocator.Error)!void {
    var nodes = try graph.allNodes();
    defer nodes.deinit();
    var first = true;
    while (try nodes.next()) |source| {
        var edges = try graph.edgesOf(source, .out);
        defer edges.deinit();
        while (try edges.next()) |edge| {
            if (!first) try buffer.append(allocator, ',');
            first = false;
            try buffer.print(allocator, "{{\"source\":{d},\"target\":{d},\"type\":", .{ source, edge.neighbour });
            try appendJsonString(buffer, allocator, edge.edge_type);
            try buffer.appendSlice(allocator, ",\"properties\":");
            var properties = try graph.edgePropertiesOf(source, edge.neighbour, edge.edge_type);
            defer properties.deinit();
            try appendPropertiesJson(&properties, buffer);
            try buffer.append(allocator, '}');
        }
    }
}

fn appendPropertiesJson(properties: *PropertyIterator, buffer: *std.ArrayList(u8)) (StorageError || Allocator.Error)!void {
    try buffer.append(allocator, '{');
    var first = true;
    while (try properties.next()) |property| {
        if (!first) try buffer.append(allocator, ',');
        first = false;
        try appendJsonString(buffer, allocator, property.name);
        try buffer.append(allocator, ':');
        try appendJsonValue(buffer, allocator, property.value);
    }
    try buffer.append(allocator, '}');
}

fn appendJsonString(buffer: *std.ArrayList(u8), result_allocator: Allocator, s: []const u8) Allocator.Error!void {
    try buffer.append(result_allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buffer.appendSlice(result_allocator, "\\\""),
            '\\' => try buffer.appendSlice(result_allocator, "\\\\"),
            0x00...0x1F => {
                // Every control char (including \n \r \t) as a \u00XX escape.
                const hex = "0123456789abcdef";
                var escape = [6]u8{ '\\', 'u', '0', '0', 0, 0 };
                escape[4] = hex[c >> 4];
                escape[5] = hex[c & 0xF];
                try buffer.appendSlice(result_allocator, &escape);
            },
            else => try buffer.append(result_allocator, c),
        }
    }
    try buffer.append(result_allocator, '"');
}

fn appendJsonValue(buffer: *std.ArrayList(u8), result_allocator: Allocator, v: Value) Allocator.Error!void {
    switch (v) {
        .int => |n| {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
            try buffer.appendSlice(result_allocator, s);
        },
        .string => |s| try appendJsonString(buffer, result_allocator, s),
        .boolean => |b| try buffer.appendSlice(result_allocator, if (b) "true" else "false"),
        .null => try buffer.appendSlice(result_allocator, "null"),
        .list => |items| {
            try buffer.append(result_allocator, '[');
            for (items, 0..) |e, i| {
                if (i > 0) try buffer.append(result_allocator, ',');
                try appendJsonValue(buffer, result_allocator, e);
            }
            try buffer.append(result_allocator, ']');
        },
    }
}

fn rowsToJson(arena: *std.heap.ArenaAllocator, rows: []const Row) Allocator.Error![]u8 {
    const result_allocator = arena.allocator();
    var buffer = std.ArrayList(u8).empty;
    try buffer.append(result_allocator, '[');
    for (rows, 0..) |r, i| {
        if (i > 0) try buffer.append(result_allocator, ',');
        try buffer.append(result_allocator, '[');
        for (r.items, 0..) |v, j| {
            if (j > 0) try buffer.append(result_allocator, ',');
            try appendJsonValue(&buffer, result_allocator, v);
        }
        try buffer.append(result_allocator, ']');
    }
    try buffer.append(result_allocator, ']');
    return buffer.items; // arena-owned
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
                            .string => |s| {
                                const copy = try arena.allocator().dupe(u8, s);
                                try list.append(arena.allocator(), .{ .string = copy });
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
                .string => |s| {
                    const copy = try arena.allocator().dupe(u8, s);
                    try row.append(arena.allocator(), .{ .string = copy });
                },
            }
        }
        try out.append(arena.allocator(), row);
    }
    return out.items;
}

pub export fn acmedb_result_free(result: *Result) void {
    result.arena.deinit();
    allocator.destroy(result);
}

pub export fn acmedb_result_row_count(result: *const Result) usize {
    return result.rows.len;
}

pub export fn acmedb_result_column_count(result: *const Result) usize {
    if (result.rows.len == 0) return 0;
    return result.rows[0].items.len;
}

pub export fn acmedb_result_type(result: *const Result, row: usize, col: usize) c_int {
    if (row >= result.rows.len) return -1;
    const r = result.rows[row];
    if (col >= r.items.len) return -1;
    return switch (r.items[col]) {
        .int => TYPE_INT64,
        .string => TYPE_STRING,
        .boolean => TYPE_BOOLEAN,
        .null => TYPE_NULL,
        .list => TYPE_LIST,
    };
}

pub export fn acmedb_result_int(result: *const Result, row: usize, col: usize) i64 {
    const r = result.rows[row];
    return switch (r.items[col]) {
        .int => |n| n,
        else => 0,
    };
}

pub export fn acmedb_result_bool(result: *const Result, row: usize, col: usize) bool {
    const r = result.rows[row];
    return switch (r.items[col]) {
        .boolean => |b| b,
        else => false,
    };
}

pub export fn acmedb_result_string(result: *const Result, row: usize, col: usize, out_len: *usize) [*]const u8 {
    const r = result.rows[row];
    const s: []const u8 = switch (r.items[col]) {
        .string => |s| s,
        else => "",
    };
    out_len.* = s.len;
    return s.ptr;
}

/// The `item_index`-th element of a list cell, or `null` if the cell isn't a list or
/// the index is out of range.
fn listItem(result: *const Result, row: usize, col: usize, item_index: usize) ?Value {
    if (row >= result.rows.len) return null;
    const r = result.rows[row];
    if (col >= r.items.len) return null;
    const items = switch (r.items[col]) {
        .list => |items| items,
        else => return null,
    };
    if (item_index >= items.len) return null;
    return items[item_index];
}

pub export fn acmedb_result_list_length(result: *const Result, row: usize, col: usize) usize {
    if (row >= result.rows.len) return 0;
    const r = result.rows[row];
    if (col >= r.items.len) return 0;
    return switch (r.items[col]) {
        .list => |items| items.len,
        else => 0,
    };
}

pub export fn acmedb_result_list_item_type(result: *const Result, row: usize, col: usize, item_index: usize) c_int {
    const item = listItem(result, row, col, item_index) orelse return -1;
    return switch (item) {
        .int => TYPE_INT64,
        .string => TYPE_STRING,
        .boolean => TYPE_BOOLEAN,
        .null => TYPE_NULL,
        .list => TYPE_LIST,
    };
}

pub export fn acmedb_result_list_item_int(result: *const Result, row: usize, col: usize, item_index: usize) i64 {
    const item = listItem(result, row, col, item_index) orelse return 0;
    return switch (item) {
        .int => |n| n,
        else => 0,
    };
}

pub export fn acmedb_result_list_item_bool(result: *const Result, row: usize, col: usize, item_index: usize) bool {
    const item = listItem(result, row, col, item_index) orelse return false;
    return switch (item) {
        .boolean => |b| b,
        else => false,
    };
}

pub export fn acmedb_result_list_item_string(result: *const Result, row: usize, col: usize, item_index: usize, out_len: *usize) [*]const u8 {
    const item = listItem(result, row, col, item_index) orelse return "".ptr;
    const s: []const u8 = switch (item) {
        .string => |s| s,
        else => "",
    };
    out_len.* = s.len;
    return s.ptr;
}

/// Sets a generic message + code for a runtime error that never set one.
fn noteError(diagnostic: *Diagnostic, err: anyerror) void {
    const code: ErrorCode = switch (err) {
        error.UnknownVariable => .unknown_variable,
        error.MissingProperty => .missing_property,
        error.TypeMismatch, error.UnsupportedPropertyType => .type_mismatch,
        error.InvalidExpression => .invalid_expression,
        error.NodeStillConnected => .node_still_connected,
        else => .storage,
    };
    diagnostic.set(code, 0, "query failed: {s}", .{@errorName(err)});
}

// Force the export functions to be analyzed/emitted even when the test blocks
// are not compiled (library builds).
comptime {
    _ = acmedb_open;
    _ = acmedb_close;
    _ = acmedb_add_node;
    _ = acmedb_add_edge;
    _ = acmedb_set_property_int64;
    _ = acmedb_set_property_string;
    _ = acmedb_allocate_node_id;
    _ = acmedb_begin_write;
    _ = acmedb_commit_write;
    _ = acmedb_abort_write;
    _ = acmedb_query;
    _ = acmedb_result_free;
    _ = acmedb_result_row_count;
    _ = acmedb_result_column_count;
    _ = acmedb_result_type;
    _ = acmedb_result_int;
    _ = acmedb_result_bool;
    _ = acmedb_result_string;
    _ = acmedb_result_to_json;
    _ = acmedb_last_error;
    _ = acmedb_error_code;
    _ = acmedb_result_list_length;
    _ = acmedb_result_list_item_type;
    _ = acmedb_result_list_item_int;
    _ = acmedb_result_list_item_bool;
    _ = acmedb_result_list_item_string;
    _ = acmedb_export_json;
}
