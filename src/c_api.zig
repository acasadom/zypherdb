//! C ABI for embedding ZypherDB from C, C++ or any language with a C FFI. The
//! declarations are in include/zypherdb.h; keep the two in step.
//!
//! Every function is `export fn` (C calling convention). Strings are passed as
//! (pointer, length) pairs. Handles are opaque pointers (`*Context`, `*Result`);
//! the caller must release them with the matching close/free function.
//!
//! Results are fully self-contained: the returned `*Result` owns an arena that
//! holds all its string cells, freed by `zypherdb_result_free`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = @import("query/ast.zig").Ast;
const Graph = @import("storage/graph.zig").Graph;
const EntitySnapshot = @import("execution/entities.zig").EntitySnapshot;
const NodeData = @import("execution/entities.zig").NodeData;
const SnapshotProperty = @import("execution/entities.zig").Property;
const PropertyIterator = @import("storage/graph.zig").PropertyIterator;
const KeyValueStore = @import("storage/key_value_store.zig").KeyValueStore;
const replication_module = @import("replication/replication.zig");
const Replication = replication_module.Replication;
const StorageError = @import("storage/key_value_store.zig").StorageError;
const integrity = @import("storage/integrity.zig");
const isStorableName = @import("storage/layout.zig").isStorableName;
const Value = @import("value.zig").Value;
const MapEntry = @import("value.zig").MapEntry;
const formatFloat = @import("value.zig").formatFloat;
const mapOf = @import("value.zig").mapOf;
const Executor = @import("execution/Executor.zig");
const Row = Executor.Row;
const Diagnostic = @import("diagnostics.zig").Diagnostic;
const ErrorCode = @import("diagnostics.zig").ErrorCode;
const parser = @import("query/parser.zig");
const Statement = @import("statement/Statement.zig");
const StatementCache = @import("statement/Cache.zig");

pub const Context = struct {
    store: KeyValueStore,
    graph: Graph,
    allocator: Allocator,
    diagnostic: Diagnostic,
    /// The last `zypherdb_export_json` document, owned by the context.
    export_json: []u8 = &.{},
    /// The last `zypherdb_check` report, owned by the context.
    check_json: []u8 = &.{},
    /// The last `zypherdb_replication_status` report, owned by the context.
    status_json: []u8 = &.{},
    /// Replication, on a database opened with a role.
    replication: ?*Replication = null,
    /// The directory LOAD CSV reads from (owned); null: LOAD CSV is off.
    import_directory: ?[]u8 = null,
    /// The statements `zypherdb_query` prepared, by text.
    statements: StatementCache,
    /// The memory a query runs in, kept from one query to the next (up to
    /// `retained_scratch` bytes) instead of asked for again each time.
    scratch: std.heap.ArenaAllocator,
};

/// How much of a query's memory the next one reuses.
pub const retained_scratch = 1 << 20;

const Result = struct {
    arena: std.heap.ArenaAllocator,
    rows: []Row,
    json: []u8, // the whole result serialized to JSON (for the bulk reader)
};

const allocator: Allocator = std.heap.c_allocator;

// Cell type tags returned by zypherdb_result_type.
pub const TYPE_INT64: c_int = 0;
pub const TYPE_STRING: c_int = 1;
pub const TYPE_BOOLEAN: c_int = 2;
pub const TYPE_NULL: c_int = 3;
pub const TYPE_LIST: c_int = 4;
/// A node or relationship cell: read it through `zypherdb_result_to_json`.
pub const TYPE_NODE: c_int = 5;
pub const TYPE_RELATIONSHIP: c_int = 6;
/// A map cell: read it through `zypherdb_result_to_json`.
pub const TYPE_MAP: c_int = 7;
/// A path cell: read it through `zypherdb_result_to_json`.
pub const TYPE_PATH: c_int = 8;
pub const TYPE_FLOAT64: c_int = 9;
pub const TYPE_DATE: c_int = 10;
pub const TYPE_LOCAL_TIME: c_int = 11;
pub const TYPE_TIME: c_int = 12;
pub const TYPE_LOCAL_DATE_TIME: c_int = 13;
pub const TYPE_DATE_TIME: c_int = 14;
pub const TYPE_DURATION: c_int = 15;

pub const DURABILITY_FULL: c_int = 0;
pub const DURABILITY_RELAXED: c_int = 1;
pub const DURABILITY_DEFERRED: c_int = 2;

pub const ROLE_MASTER: c_int = 0;
pub const ROLE_REPLICA: c_int = 1;

pub export fn zypherdb_open(path_ptr: [*]const u8, path_len: usize) ?*Context {
    return zypherdb_open_with_durability(path_ptr, path_len, DURABILITY_FULL);
}

/// Opens with a durability mode: `DURABILITY_FULL` (each commit is on disk
/// when it returns), `DURABILITY_RELAXED` (a power failure can lose the last
/// commit, never corrupt the database) or `DURABILITY_DEFERRED` (commits are
/// written by the operating system or `zypherdb_sync`; a power failure can
/// lose the recent ones). NULL on an unknown mode.
pub export fn zypherdb_open_with_durability(path_ptr: [*]const u8, path_len: usize, durability: c_int) ?*Context {
    const mode: KeyValueStore.Durability = switch (durability) {
        DURABILITY_FULL => .full,
        DURABILITY_RELAXED => .relaxed,
        DURABILITY_DEFERRED => .deferred,
        else => return null,
    };
    const path = path_ptr[0..path_len];
    const context = allocator.create(Context) catch return null;
    context.store = KeyValueStore.openWithOptions(allocator, path, .{ .durability = mode }) catch {
        allocator.destroy(context);
        return null;
    };
    context.graph = Graph.init(&context.store, allocator);
    context.graph.checkFormat() catch {
        context.store.deinit();
        allocator.destroy(context);
        return null;
    };
    context.allocator = allocator;
    context.diagnostic = Diagnostic.init();
    context.export_json = &.{};
    context.check_json = &.{};
    context.status_json = &.{};
    context.replication = null;
    context.import_directory = null;
    context.statements = StatementCache.init(allocator);
    context.scratch = std.heap.ArenaAllocator.init(allocator);
    return context;
}

/// Writes every commit so far to disk. RETURN_OK or RETURN_STORAGE_ERROR.
pub export fn zypherdb_sync(context: *Context) c_int {
    context.store.sync() catch return RETURN_STORAGE_ERROR;
    return RETURN_OK;
}

/// Opens with a replication role: `ROLE_MASTER` serves replicas at
/// `address` ("host:port"), `ROLE_REPLICA` follows the master at `address`
/// (and refuses writes). A replica must not have been a master. Both send
/// `token` in clear: run replication on a trusted network. A replica calls
/// itself `name` in its master's status (NULL: the host's name). NULL when
/// the database cannot be opened or replication cannot start.
pub export fn zypherdb_open_replicated(path_ptr: [*]const u8, path_len: usize, durability: c_int, role: c_int, address_ptr: [*]const u8, address_len: usize, token_ptr: [*]const u8, token_len: usize, name_ptr: ?[*]const u8, name_len: usize) ?*Context {
    const address = address_ptr[0..address_len];
    const token = token_ptr[0..token_len];
    const replication_role: replication_module.Role = switch (role) {
        ROLE_MASTER => .{ .master = .{ .address = address, .token = token } },
        ROLE_REPLICA => .{ .replica = .{
            .master_address = address,
            .token = token,
            .name = if (name_ptr) |name| name[0..name_len] else null,
        } },
        else => return null,
    };
    const context = zypherdb_open_with_durability(path_ptr, path_len, durability) orelse return null;
    context.replication = Replication.start(allocator, &context.store, path_ptr[0..path_len], replication_role) catch {
        zypherdb_close(context);
        return null;
    };
    return context;
}

/// The LSN of the last change set this database has: on a master the last
/// committed, on a replica the last applied, in any process (with a role or
/// without); 0 on a database that is neither.
pub export fn zypherdb_last_lsn(context: *Context) u64 {
    return replication_module.lastLsn(&context.store) catch 0;
}

/// Waits until change set `lsn` of the master is applied here, at most
/// `timeout_ms`; whether it is. Read on a replica after it to see a write
/// made on the master (`zypherdb_last_lsn` there after the write), also in a
/// process that opened the replica without a role. True at once on a
/// database that is no replica.
pub export fn zypherdb_wait_for(context: *Context, lsn: u64, timeout_ms: u64) bool {
    const timeout_ns = timeout_ms *| std.time.ns_per_ms;
    const replication = context.replication orelse return replication_module.waitApplied(&context.store, lsn, timeout_ns) catch false;
    return replication.waitFor(lsn, timeout_ns);
}

/// How replication goes, as JSON (see docs/guide/c-api.md); the buffer
/// belongs to the context. NULL without replication or out of memory.
pub export fn zypherdb_replication_status(context: *Context, out_len: *usize) ?[*]const u8 {
    const replication = context.replication orelse return null;
    const json = replication.statusJson(allocator) catch return null;
    allocator.free(context.status_json);
    context.status_json = json;
    out_len.* = json.len;
    return json.ptr;
}

pub export fn zypherdb_close(context: *Context) void {
    if (context.replication) |replication| replication.stop();
    allocator.free(context.status_json);
    context.statements.deinit();
    context.scratch.deinit();
    allocator.free(context.export_json);
    allocator.free(context.check_json);
    if (context.import_directory) |directory| allocator.free(directory);
    context.store.deinit();
    allocator.destroy(context);
}

/// Sets the directory LOAD CSV reads files from (`path_len` 0: none, which
/// turns LOAD CSV off, as it is after opening). RETURN_OK, or
/// RETURN_STORAGE_ERROR when out of memory.
pub export fn zypherdb_set_import_directory(context: *Context, path_ptr: [*]const u8, path_len: usize) c_int {
    const directory: ?[]u8 = if (path_len == 0) null else allocator.dupe(u8, path_ptr[0..path_len]) catch return RETURN_STORAGE_ERROR;
    if (context.import_directory) |old| allocator.free(old);
    context.import_directory = directory;
    return RETURN_OK;
}

/// Returns the last error message (and its length), if the most recent
/// operation failed.
pub export fn zypherdb_last_error(context: *Context, out_len: *usize) [*]const u8 {
    const m = context.diagnostic.message();
    out_len.* = m.len;
    return m.ptr;
}

/// Returns the last error code (see `ErrorCode` in `diagnostics.zig`), 0 if none.
pub export fn zypherdb_error_code(context: *Context) c_int {
    return @intCast(@backingInt(context.diagnostic.code));
}

/// Begins an explicit write transaction. Until `zypherdb_commit_write` (or
/// `zypherdb_abort_write`), every mutator runs inside it and commits atomically at
/// the end — one fsync for the whole batch. Returns 0 on success.
pub export fn zypherdb_begin_write(context: *Context) c_int {
    context.graph.beginWrite() catch return 1;
    return 0;
}

pub export fn zypherdb_commit_write(context: *Context) c_int {
    context.graph.commitWrite() catch return 1;
    return 0;
}

pub export fn zypherdb_abort_write(context: *Context) void {
    context.graph.abortWrite();
}

/// Allocates a fresh, never-used node id (atomically). Returns `maxInt(u64)` on
/// failure.
pub export fn zypherdb_allocate_node_id(context: *Context) u64 {
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

pub export fn zypherdb_add_node(context: *Context, id: u64, label_ptr: [*]const u8, label_len: usize) c_int {
    if (label_len > 0 and !isStorableName(label_ptr[0..label_len])) return RETURN_INVALID_NAME;
    context.graph.addNode(id, label_ptr[0..label_len]) catch |err| return writeFailure(context, err);
    return 0;
}

/// Mutator return codes: success, storage failure, a missing node, a write
/// a uniqueness constraint refused (its message in zypherdb_last_error), a
/// label, type or property name that is empty, longer than 1024 bytes or
/// holds a 0x00 byte, and a write past a size limit (a value over 4 GiB
/// stored, a node's 65536th label).
pub const RETURN_OK: c_int = 0;
pub const RETURN_STORAGE_ERROR: c_int = 1;
pub const RETURN_NODE_NOT_FOUND: c_int = 2;
pub const RETURN_CONSTRAINT_VIOLATION: c_int = 3;
pub const RETURN_INVALID_NAME: c_int = 4;
pub const RETURN_TOO_LARGE: c_int = 5;

/// The return code of a failed write; a constraint violation's message
/// goes to the context's diagnostic.
fn writeFailure(context: *Context, err: anyerror) c_int {
    if (err == error.ValueTooLarge or err == error.TooManyLabels) return RETURN_TOO_LARGE;
    if (err != error.ConstraintViolation) return RETURN_STORAGE_ERROR;
    context.diagnostic.set(.constraint_violation, 0, "{s}", .{context.graph.violationMessage()});
    return RETURN_CONSTRAINT_VIOLATION;
}

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
pub export fn zypherdb_add_edge(context: *Context, src: u64, dst: u64, edge_type_ptr: [*]const u8, edge_type_length: usize) c_int {
    if (!isStorableName(edge_type_ptr[0..edge_type_length])) return RETURN_INVALID_NAME;
    const return_code = requireNodes(context, &.{ src, dst });
    if (return_code != RETURN_OK) return return_code;
    _ = context.graph.addEdge(src, dst, edge_type_ptr[0..edge_type_length]) catch return RETURN_STORAGE_ERROR;
    return RETURN_OK;
}

/// Sets an int property on an existing node (`RETURN_NODE_NOT_FOUND` otherwise).
pub export fn zypherdb_set_property_int64(context: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value: i64) c_int {
    if (!isStorableName(name_ptr[0..name_len])) return RETURN_INVALID_NAME;
    const return_code = requireNodes(context, &.{id});
    if (return_code != RETURN_OK) return return_code;
    context.graph.setProperty(id, name_ptr[0..name_len], .{ .int = value }) catch |err| return writeFailure(context, err);
    return RETURN_OK;
}

/// Sets a float property on an existing node (`RETURN_NODE_NOT_FOUND` otherwise).
pub export fn zypherdb_set_property_float64(context: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value: f64) c_int {
    if (!isStorableName(name_ptr[0..name_len])) return RETURN_INVALID_NAME;
    const return_code = requireNodes(context, &.{id});
    if (return_code != RETURN_OK) return return_code;
    context.graph.setProperty(id, name_ptr[0..name_len], .{ .float = value }) catch |err| return writeFailure(context, err);
    return RETURN_OK;
}

/// Sets a string property on an existing node (`RETURN_NODE_NOT_FOUND` otherwise).
pub export fn zypherdb_set_property_string(context: *Context, id: u64, name_ptr: [*]const u8, name_len: usize, value_ptr: [*]const u8, value_length: usize) c_int {
    if (!isStorableName(name_ptr[0..name_len])) return RETURN_INVALID_NAME;
    const return_code = requireNodes(context, &.{id});
    if (return_code != RETURN_OK) return return_code;
    context.graph.setProperty(id, name_ptr[0..name_len], .{ .string = value_ptr[0..value_length] }) catch |err| return writeFailure(context, err);
    return RETURN_OK;
}

pub export fn zypherdb_query(context: *Context, query_ptr: [*]const u8, query_len: usize) ?*Result {
    return runQuery(context, query_ptr[0..query_len], null);
}

/// Like `zypherdb_query`, with the values of the query's `$name` parameters as
/// a JSON object (`{"card": 123, "zones": ["A", "B"]}`). Parameter values may
/// be integers, floats, strings, booleans, null, lists and maps (JSON objects).
pub export fn zypherdb_query_with_parameters(context: *Context, query_ptr: [*]const u8, query_len: usize, parameters_ptr: [*]const u8, parameters_len: usize) ?*Result {
    return runQuery(context, query_ptr[0..query_len], parameters_ptr[0..parameters_len]);
}

fn runQuery(context: *Context, query: []const u8, parameters_json: ?[]const u8) ?*Result {
    context.diagnostic.clear();
    const statement = context.statements.get(query) orelse prepared: {
        const statement = Statement.prepare(allocator, query, .{ .graph = &context.graph, .diagnostic = &context.diagnostic }) catch |err| {
            noteFailure(&context.diagnostic, err);
            return null;
        };
        // Kept only if it has a plan to reuse; the rest are parsed per run.
        if (!statement.is_query) {
            defer statement.destroy();
            return runStatement(context, statement, parameters_json);
        }
        context.statements.put(statement);
        break :prepared statement;
    };
    return runStatement(context, statement, parameters_json);
}

/// Runs `statement` with the parameters in `parameters_json` (none: null),
/// into a self-contained result.
fn runStatement(context: *Context, statement: *Statement, parameters_json: ?[]const u8) ?*Result {
    context.diagnostic.clear();
    const scratch = context.scratch.allocator();
    defer _ = context.scratch.reset(.{ .retain_with_limit = retained_scratch });
    const parameters = if (parameters_json) |json|
        parseParameters(scratch, json, &context.diagnostic) catch return null
    else
        Executor.Parameters.empty;
    var executor = statement.executorFor(&context.graph, scratch);
    executor.diagnostic = &context.diagnostic;
    executor.parameters = parameters;
    executor.import_directory = context.import_directory;
    const rows = statement.run(&executor) catch |err| {
        noteFailure(&context.diagnostic, err);
        return null;
    };

    const result = context.allocator.create(Result) catch return null;
    result.arena = std.heap.ArenaAllocator.init(context.allocator);
    result.rows = copyRows(&result.arena, rows) catch {
        result.arena.deinit();
        context.allocator.destroy(result);
        return null;
    };
    result.json = rowsToJson(&result.arena, result.rows, &executor.entities) catch {
        result.arena.deinit();
        context.allocator.destroy(result);
        return null;
    };
    return result;
}

/// A failure that set no message gets a generic one.
fn noteFailure(diagnostic: *Diagnostic, err: anyerror) void {
    if (diagnostic.message().len > 0) return;
    if (err == error.ParseFailed) return diagnostic.set(.parse, 0, "parse failed", .{});
    noteError(diagnostic, err);
}

/// Prepares a query to run again and again (`zypherdb_statement_query`): it is
/// parsed, checked and planned once. NULL on failure (the error is the
/// context's, as for `zypherdb_query`). Free it with `zypherdb_statement_free`
/// before closing its context.
pub export fn zypherdb_prepare(context: *Context, query_ptr: [*]const u8, query_len: usize) ?*Statement {
    context.diagnostic.clear();
    return Statement.prepare(allocator, query_ptr[0..query_len], .{ .graph = &context.graph, .diagnostic = &context.diagnostic }) catch |err| {
        noteFailure(&context.diagnostic, err);
        return null;
    };
}

/// Runs a prepared statement, with its parameters as a JSON object
/// (`parameters_ptr` NULL: none), as `zypherdb_query_with_parameters` runs a query.
pub export fn zypherdb_statement_query(context: *Context, statement: *Statement, parameters_ptr: ?[*]const u8, parameters_len: usize) ?*Result {
    const json: ?[]const u8 = if (parameters_ptr) |pointer| pointer[0..parameters_len] else null;
    return runStatement(context, statement, json);
}

pub export fn zypherdb_statement_free(statement: *Statement) void {
    statement.destroy();
}

/// How many columns the statement's result has (0 without RETURN).
pub export fn zypherdb_statement_column_count(statement: *const Statement) usize {
    return statement.columns.len;
}

/// The name of column `column` (its alias, or the expression as Cypher).
pub export fn zypherdb_statement_column_name(statement: *const Statement, column: usize, out_len: *usize) [*]const u8 {
    const name = statement.columns[column];
    out_len.* = name.len;
    return name.ptr;
}

/// How many `$name` parameters the statement reads.
pub export fn zypherdb_statement_parameter_count(statement: *const Statement) usize {
    return statement.parameter_names.len;
}

/// The name of parameter `parameter` (without the `$`), in the order they appear.
pub export fn zypherdb_statement_parameter_name(statement: *const Statement, parameter: usize, out_len: *usize) [*]const u8 {
    const name = statement.parameter_names[parameter];
    out_len.* = name.len;
    return name.ptr;
}

/// Reads a JSON object of parameters into Values (allocated in `arena`).
fn parseParameters(arena: Allocator, json: []const u8, diagnostic: *Diagnostic) error{InvalidParameters}!Executor.Parameters {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch {
        diagnostic.set(.type_mismatch, 0, "parameters are not valid JSON", .{});
        return error.InvalidParameters;
    };
    if (parsed != .object) {
        diagnostic.set(.type_mismatch, 0, "parameters must be a JSON object", .{});
        return error.InvalidParameters;
    }
    var parameters = Executor.Parameters.empty;
    var entries = parsed.object.iterator();
    while (entries.next()) |entry| {
        const value = parameterValue(arena, entry.value_ptr.*) catch |err| {
            diagnostic.set(.type_mismatch, 0, "parameter '{s}': {s}", .{ entry.key_ptr.*, switch (err) {
                error.UnsupportedNumber => "integers must fit in 64 bits",
                error.InvalidTemporal => "not a valid temporal value",
                error.OutOfMemory => "out of memory",
            } });
            return error.InvalidParameters;
        };
        parameters.put(arena, entry.key_ptr.*, value) catch return error.InvalidParameters;
    }
    return parameters;
}

fn parameterValue(arena: Allocator, json: std.json.Value) error{ UnsupportedNumber, InvalidTemporal, OutOfMemory }!Value {
    return switch (json) {
        .null => .{ .null = {} },
        .bool => |b| .{ .boolean = b },
        .integer => |n| .{ .int = n },
        .float => |x| .{ .float = x },
        // An integer too large for 64 bits: not silently made a float.
        .number_string => error.UnsupportedNumber,
        .string => |text| .{ .string = text },
        .array => |items| blk: {
            const values = try arena.alloc(Value, items.items.len);
            for (values, items.items) |*value, item| value.* = try parameterValue(arena, item);
            break :blk .{ .list = values };
        },
        .object => |object| blk: {
            if (try temporalParameter(object)) |value| break :blk value;
            const entries = try arena.alloc(MapEntry, object.count());
            var iterator = object.iterator();
            var i: usize = 0;
            while (iterator.next()) |entry| : (i += 1) {
                entries[i] = .{ .key = entry.key_ptr.*, .value = try parameterValue(arena, entry.value_ptr.*) };
            }
            break :blk mapOf(entries);
        },
    };
}

/// A temporal parameter: an object with one key, the temporal tag of the
/// JSON results (`{"~date": "2024-05-01"}`), holding ISO 8601 text.
fn temporalParameter(object: std.json.ObjectMap) error{InvalidTemporal}!?Value {
    if (object.count() != 1) return null;
    var iterator = object.iterator();
    const entry = iterator.next().?;
    const tag = entry.key_ptr.*;
    if (tag.len < 2 or tag[0] != '~') return null;
    const text = switch (entry.value_ptr.*) {
        .string => |t| t,
        else => return error.InvalidTemporal,
    };
    const parse = @import("temporal/parse.zig");
    const kinds = .{ "date", "localtime", "time", "localdatetime", "datetime", "duration" };
    inline for (kinds) |kind| {
        if (std.mem.eql(u8, tag[1..], kind)) {
            const err = error.InvalidTemporal;
            return switch (comptime std.meta.stringToEnum(enum { date, localtime, time, localdatetime, datetime, duration }, kind).?) {
                .date => .{ .date = parse.date(text) catch return err },
                .localtime => .{ .local_time = parse.localTime(text) catch return err },
                .time => .{ .time = parse.time(text) catch return err },
                .localdatetime => .{ .local_date_time = parse.localDateTime(text) catch return err },
                .datetime => .{ .date_time = parse.dateTime(text) catch return err },
                .duration => .{ .duration = parse.duration(text) catch return err },
            };
        }
    }
    return null;
}

/// Serializes the whole result to a JSON array of arrays (`[[…], […]]`), so a
/// caller can read a large result in one call instead of one per cell. The
/// returned pointer is owned by the Result (valid until `zypherdb_result_free`).
pub export fn zypherdb_result_to_json(result: *const Result, out_len: *usize) [*]const u8 {
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
/// export or `zypherdb_close`. Returns null on failure. O(N) in the store size.
pub export fn zypherdb_export_json(context: *Context, out_len: *usize) ?[*]const u8 {
    const json = exportGraph(context) catch return null;
    allocator.free(context.export_json);
    context.export_json = json;
    out_len.* = json.len;
    return json.ptr;
}

/// Checks that every structure derived from the stored records agrees with
/// them (src/storage/integrity.zig), and returns the report as JSON:
///
///   {"ok": false, "problem_count": 2, "problems": ["missing key ...", ...]}
///
/// `problems` describes the first 32. A diagnostic for a suspected bug, not a
/// routine call: it reads the whole database and holds memory in proportion
/// to it. The buffer belongs to the context and stays valid until the next
/// check or `zypherdb_close`. Returns null on failure.
pub export fn zypherdb_check(context: *Context, out_len: *usize) ?[*]const u8 {
    const json = checkJson(context) catch return null;
    allocator.free(context.check_json);
    context.check_json = json;
    out_len.* = json.len;
    return json.ptr;
}

fn checkJson(context: *Context) (StorageError || Allocator.Error)![]u8 {
    var report = try integrity.check(&context.graph, allocator);
    defer report.deinit();
    var buffer = std.ArrayList(u8).empty;
    errdefer buffer.deinit(allocator);
    try buffer.print(allocator, "{{\"ok\":{},\"problem_count\":{d},\"problems\":[", .{ report.ok(), report.count });
    for (report.problems.items, 0..) |problem, i| {
        if (i > 0) try buffer.append(allocator, ',');
        try appendJsonString(&buffer, allocator, problem);
    }
    try buffer.appendSlice(allocator, "]}");
    return buffer.toOwnedSlice(allocator);
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
            try buffer.print(allocator, "{{\"id\":{d},\"source\":{d},\"target\":{d},\"type\":", .{ edge.relationship, source, edge.neighbour });
            try appendJsonString(buffer, allocator, edge.edge_type);
            try buffer.appendSlice(allocator, ",\"properties\":");
            var properties = try graph.edgePropertiesOf(edge.relationship);
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
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        try appendJsonValue(buffer, allocator, try property.value(scratch.allocator()), null);
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

/// The JSON tag of a temporal value: `~date`, `~localtime`, ...
fn temporalTag(comptime tag: std.meta.Tag(Value)) []const u8 {
    return switch (tag) {
        .local_time => "localtime",
        .local_date_time => "localdatetime",
        .date_time => "datetime",
        else => @tagName(tag),
    };
}

/// Appends `v` as JSON. Nodes and relationships become objects tagged
/// `"~node"` / `"~relationship"` carrying their labels/type and properties
/// from `entities` (a reference not in the snapshot shows no labels and no
/// properties).
fn appendJsonValue(buffer: *std.ArrayList(u8), result_allocator: Allocator, v: Value, entities: ?*const EntitySnapshot) Allocator.Error!void {
    switch (v) {
        .int => |n| try buffer.print(result_allocator, "{d}", .{n}),
        // NaN and ±Infinity are written as such (JavaScript-style JSON, which
        // Python's json module reads).
        .float => |x| try buffer.appendSlice(result_allocator, try formatFloat(result_allocator, x)),
        .string => |s| try appendJsonString(buffer, result_allocator, s),
        .boolean => |b| try buffer.appendSlice(result_allocator, if (b) "true" else "false"),
        .null => try buffer.appendSlice(result_allocator, "null"),
        .list => |items| {
            try buffer.append(result_allocator, '[');
            for (items, 0..) |e, i| {
                if (i > 0) try buffer.append(result_allocator, ',');
                try appendJsonValue(buffer, result_allocator, e, entities);
            }
            try buffer.append(result_allocator, ']');
        },
        .node => |id| {
            const data: ?NodeData = if (entities) |snapshot| snapshot.nodes.get(id) else null;
            try buffer.print(result_allocator, "{{\"~node\":{{\"id\":{d},\"labels\":[", .{id});
            if (data) |node| {
                for (node.labels, 0..) |label, i| {
                    if (i > 0) try buffer.append(result_allocator, ',');
                    try appendJsonString(buffer, result_allocator, label);
                }
            }
            try buffer.appendSlice(result_allocator, "],\"properties\":");
            try appendSnapshotProperties(buffer, result_allocator, if (data) |node| node.properties else &.{});
            try buffer.appendSlice(result_allocator, "}}");
        },
        .path => |p| {
            try buffer.appendSlice(result_allocator, "{\"~path\":{\"nodes\":[");
            for (p.nodes, 0..) |node, i| {
                if (i > 0) try buffer.append(result_allocator, ',');
                try appendJsonValue(buffer, result_allocator, .{ .node = node }, entities);
            }
            try buffer.appendSlice(result_allocator, "],\"relationships\":[");
            for (p.relationships, 0..) |relationship, i| {
                if (i > 0) try buffer.append(result_allocator, ',');
                try appendJsonValue(buffer, result_allocator, .{ .relationship = relationship }, entities);
            }
            try buffer.appendSlice(result_allocator, "]}}");
        },
        .map => |entries| {
            try buffer.append(result_allocator, '{');
            for (entries, 0..) |entry, i| {
                if (i > 0) try buffer.append(result_allocator, ',');
                try appendJsonString(buffer, result_allocator, entry.key);
                try buffer.append(result_allocator, ':');
                try appendJsonValue(buffer, result_allocator, entry.value, entities);
            }
            try buffer.append(result_allocator, '}');
        },
        // Temporal values: tagged ISO 8601 text, `{"~date":"2024-05-01"}`.
        inline .date, .local_time, .time, .local_date_time, .date_time, .duration => |t, tag| {
            try buffer.print(result_allocator, "{{\"~{s}\":\"{f}\"}}", .{ temporalTag(tag), t });
        },
        .relationship => |r| {
            const properties: []const SnapshotProperty = if (entities) |snapshot| snapshot.relationships.getContext(r, .{}) orelse &.{} else &.{};
            try buffer.print(result_allocator, "{{\"~relationship\":{{\"id\":{d},\"source\":{d},\"target\":{d},\"type\":", .{ r.id, r.src, r.dst });
            try appendJsonString(buffer, result_allocator, r.edge_type);
            try buffer.appendSlice(result_allocator, ",\"properties\":");
            try appendSnapshotProperties(buffer, result_allocator, properties);
            try buffer.appendSlice(result_allocator, "}}");
        },
    }
}

fn appendSnapshotProperties(buffer: *std.ArrayList(u8), result_allocator: Allocator, properties: []const SnapshotProperty) Allocator.Error!void {
    try buffer.append(result_allocator, '{');
    for (properties, 0..) |property, i| {
        if (i > 0) try buffer.append(result_allocator, ',');
        try appendJsonString(buffer, result_allocator, property.name);
        try buffer.append(result_allocator, ':');
        try appendJsonValue(buffer, result_allocator, property.value, null);
    }
    try buffer.append(result_allocator, '}');
}

fn rowsToJson(arena: *std.heap.ArenaAllocator, rows: []const Row, entities: *const EntitySnapshot) Allocator.Error![]u8 {
    const result_allocator = arena.allocator();
    var buffer = std.ArrayList(u8).empty;
    try buffer.append(result_allocator, '[');
    for (rows, 0..) |r, i| {
        if (i > 0) try buffer.append(result_allocator, ',');
        try buffer.append(result_allocator, '[');
        for (r.items, 0..) |v, j| {
            if (j > 0) try buffer.append(result_allocator, ',');
            try appendJsonValue(&buffer, result_allocator, v, entities);
        }
        try buffer.append(result_allocator, ']');
    }
    try buffer.append(result_allocator, ']');
    return buffer.items; // arena-owned
}

/// Deep-copies the rows into the result's arena (they outlive the query).
fn copyRows(arena: *std.heap.ArenaAllocator, rows: []const Row) Allocator.Error![]Row {
    const copies = try arena.allocator().alloc(Row, rows.len);
    for (copies, rows) |*copy, row| {
        copy.* = .empty;
        for (row.items) |value| try copy.append(arena.allocator(), try value.clone(arena.allocator()));
    }
    return copies;
}

pub export fn zypherdb_result_free(result: *Result) void {
    result.arena.deinit();
    allocator.destroy(result);
}

pub export fn zypherdb_result_row_count(result: *const Result) usize {
    return result.rows.len;
}

pub export fn zypherdb_result_column_count(result: *const Result) usize {
    if (result.rows.len == 0) return 0;
    return result.rows[0].items.len;
}

pub export fn zypherdb_result_type(result: *const Result, row: usize, col: usize) c_int {
    if (row >= result.rows.len) return -1;
    const r = result.rows[row];
    if (col >= r.items.len) return -1;
    return switch (r.items[col]) {
        .int => TYPE_INT64,
        .float => TYPE_FLOAT64,
        .string => TYPE_STRING,
        .boolean => TYPE_BOOLEAN,
        .null => TYPE_NULL,
        .list => TYPE_LIST,
        .node => TYPE_NODE,
        .relationship => TYPE_RELATIONSHIP,
        .map => TYPE_MAP,
        .path => TYPE_PATH,
        .date => TYPE_DATE,
        .local_time => TYPE_LOCAL_TIME,
        .time => TYPE_TIME,
        .local_date_time => TYPE_LOCAL_DATE_TIME,
        .date_time => TYPE_DATE_TIME,
        .duration => TYPE_DURATION,
    };
}

pub export fn zypherdb_result_int(result: *const Result, row: usize, col: usize) i64 {
    const r = result.rows[row];
    return switch (r.items[col]) {
        .int => |n| n,
        else => 0,
    };
}

pub export fn zypherdb_result_float(result: *const Result, row: usize, col: usize) f64 {
    const r = result.rows[row];
    return switch (r.items[col]) {
        .float => |x| x,
        else => 0,
    };
}

pub export fn zypherdb_result_bool(result: *const Result, row: usize, col: usize) bool {
    const r = result.rows[row];
    return switch (r.items[col]) {
        .boolean => |b| b,
        else => false,
    };
}

pub export fn zypherdb_result_string(result: *const Result, row: usize, col: usize, out_len: *usize) [*]const u8 {
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

pub export fn zypherdb_result_list_length(result: *const Result, row: usize, col: usize) usize {
    if (row >= result.rows.len) return 0;
    const r = result.rows[row];
    if (col >= r.items.len) return 0;
    return switch (r.items[col]) {
        .list => |items| items.len,
        else => 0,
    };
}

pub export fn zypherdb_result_list_item_type(result: *const Result, row: usize, col: usize, item_index: usize) c_int {
    const item = listItem(result, row, col, item_index) orelse return -1;
    return switch (item) {
        .int => TYPE_INT64,
        .float => TYPE_FLOAT64,
        .string => TYPE_STRING,
        .boolean => TYPE_BOOLEAN,
        .null => TYPE_NULL,
        .list => TYPE_LIST,
        .node => TYPE_NODE,
        .relationship => TYPE_RELATIONSHIP,
        .map => TYPE_MAP,
        .path => TYPE_PATH,
        .date => TYPE_DATE,
        .local_time => TYPE_LOCAL_TIME,
        .time => TYPE_TIME,
        .local_date_time => TYPE_LOCAL_DATE_TIME,
        .date_time => TYPE_DATE_TIME,
        .duration => TYPE_DURATION,
    };
}

pub export fn zypherdb_result_list_item_int(result: *const Result, row: usize, col: usize, item_index: usize) i64 {
    const item = listItem(result, row, col, item_index) orelse return 0;
    return switch (item) {
        .int => |n| n,
        else => 0,
    };
}

pub export fn zypherdb_result_list_item_float(result: *const Result, row: usize, col: usize, item_index: usize) f64 {
    const item = listItem(result, row, col, item_index) orelse return 0;
    return switch (item) {
        .float => |x| x,
        else => 0,
    };
}

pub export fn zypherdb_result_list_item_bool(result: *const Result, row: usize, col: usize, item_index: usize) bool {
    const item = listItem(result, row, col, item_index) orelse return false;
    return switch (item) {
        .boolean => |b| b,
        else => false,
    };
}

pub export fn zypherdb_result_list_item_string(result: *const Result, row: usize, col: usize, item_index: usize, out_len: *usize) [*]const u8 {
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
    @import("diagnostics.zig").noteError(diagnostic, err);
}

// Force the export functions to be analyzed/emitted even when the test blocks
// are not compiled (library builds).
comptime {
    _ = zypherdb_open;
    _ = zypherdb_close;
    _ = zypherdb_add_node;
    _ = zypherdb_add_edge;
    _ = zypherdb_set_property_int64;
    _ = zypherdb_set_property_string;
    _ = zypherdb_allocate_node_id;
    _ = zypherdb_begin_write;
    _ = zypherdb_commit_write;
    _ = zypherdb_abort_write;
    _ = zypherdb_query;
    _ = zypherdb_result_free;
    _ = zypherdb_result_row_count;
    _ = zypherdb_result_column_count;
    _ = zypherdb_result_type;
    _ = zypherdb_result_int;
    _ = zypherdb_result_bool;
    _ = zypherdb_result_string;
    _ = zypherdb_result_to_json;
    _ = zypherdb_last_error;
    _ = zypherdb_error_code;
    _ = zypherdb_result_list_length;
    _ = zypherdb_result_list_item_type;
    _ = zypherdb_result_list_item_int;
    _ = zypherdb_result_list_item_bool;
    _ = zypherdb_result_list_item_string;
    _ = zypherdb_export_json;
    _ = zypherdb_check;
    _ = zypherdb_query_with_parameters;
    _ = zypherdb_prepare;
    _ = zypherdb_statement_query;
    _ = zypherdb_statement_free;
    _ = zypherdb_statement_column_count;
    _ = zypherdb_statement_column_name;
    _ = zypherdb_statement_parameter_count;
    _ = zypherdb_statement_parameter_name;
}
