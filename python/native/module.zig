//! `acmedb._native`: the Python extension module, written in Zig on the
//! Python limited C API (abi3, Python 3.10 and later), so one build works with
//! every Python version of a platform.
//!
//! Values cross between Python and the engine by direct conversion: no JSON,
//! no intermediate buffers. A query runs with the GIL released. The Python
//! package (`acmedb/db.py`) wraps these functions in the `Database` class and
//! registers, through `configure`, the Python classes results are built with
//! (`Node`, `Date`, ...) and the exceptions errors are raised as.
//!
//! Functions (`db` is the capsule `open` returns):
//!
//!     configure(classes: dict)            open(path, durability) -> db
//!     close(db)                           sync(db)
//!     query(db, text, parameters) -> rows export_graph(db) -> dict
//!     begin_write(db)  commit_write(db)   abort_write(db)
//!     allocate_node_id(db) -> int         add_node(db, id, label)
//!     add_edge(db, source, target, type)  set_property(db, id, name, value)

const std = @import("std");
const acmedb = @import("acmedb");

const py = @import("python"); // python.h, translated by the build

const Value = acmedb.Value;
const MapEntry = acmedb.value.MapEntry;
const Graph = acmedb.Graph;
const KeyValueStore = acmedb.KeyValueStore;
const Executor = acmedb.Executor;
const Diagnostic = acmedb.Diagnostic;
const EntitySnapshot = @FieldType(Executor, "entities");

const allocator = std.heap.c_allocator;

/// An open database: what the capsule holds.
const Database = struct {
    store: KeyValueStore,
    graph: Graph,
    diagnostic: Diagnostic,
};

const capsule_name = "acmedb.Database";

// --- Registered Python classes -------------------------------------------------

/// The Python classes and callables `configure` registers (new references,
/// kept for the life of the process).
const Classes = struct {
    node: ?*py.PyObject = null,
    relationship: ?*py.PyObject = null,
    path: ?*py.PyObject = null,
    date: ?*py.PyObject = null,
    local_time: ?*py.PyObject = null,
    time: ?*py.PyObject = null,
    local_date_time: ?*py.PyObject = null,
    date_time: ?*py.PyObject = null,
    duration: ?*py.PyObject = null,
    /// `encode_temporal(value) -> (tag, iso) | None`: a datetime-module or
    /// acmedb temporal value as its tag and ISO 8601 text.
    encode_temporal: ?*py.PyObject = null,
    /// `query_error(code, message) -> exception`.
    query_error: ?*py.PyObject = null,
    storage_error: ?*py.PyObject = null,
    node_not_found_error: ?*py.PyObject = null,
};

var classes = Classes{};

fn configure(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var table: ?*py.PyObject = null;
    if (py.PyArg_ParseTuple(args, "O", &table) == 0) return null;
    inline for (@typeInfo(Classes).@"struct".field_names) |name| {
        const entry = py.PyDict_GetItemString(table, name) orelse return raise(py.PyExc_KeyError, "configure: missing " ++ name, .{});
        py.Py_IncRef(entry);
        @field(classes, name) = entry;
    }
    object_new = py.PyObject_GetAttrString(@ptrCast(@alignCast(&py.PyBaseObject_Type)), "__new__") orelse return null;
    if (!internFields(&node_fields, &.{ "id", "labels", "properties" }) or
        !internFields(&relationship_fields, &.{ "source", "target", "type", "properties" }) or
        !internFields(&path_fields, &.{ "nodes", "relationships" })) return null;
    return none();
}

// --- Small helpers --------------------------------------------------------------

fn none() *py.PyObject {
    const object: *py.PyObject = @ptrCast(&py._Py_NoneStruct);
    py.Py_IncRef(object);
    return object;
}

fn databaseOf(capsule: ?*py.PyObject) ?*Database {
    const pointer = py.PyCapsule_GetPointer(capsule, capsule_name) orelse return null;
    return @ptrCast(@alignCast(pointer));
}

/// Raises `class(message)`.
fn raise(class: ?*py.PyObject, comptime fmt: []const u8, args: anytype) ?*py.PyObject {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(buffer[0 .. buffer.len - 1], fmt, args) catch buffer[0 .. buffer.len - 1];
    buffer[message.len] = 0;
    py.PyErr_SetString(class, &buffer);
    return null;
}

/// Raises the exception for the database's last error.
fn raiseQueryError(database: *Database) ?*py.PyObject {
    const message = database.diagnostic.message();
    const text = py.PyUnicode_FromStringAndSize(message.ptr, @intCast(message.len)) orelse return null;
    defer py.Py_DecRef(text);
    const code = py.PyLong_FromLong(@intCast(@backingInt(database.diagnostic.code))) orelse return null;
    defer py.Py_DecRef(code);
    const exception = py.PyObject_CallFunctionObjArgs(classes.query_error, code, text, @as(?*py.PyObject, null)) orelse return null;
    defer py.Py_DecRef(exception);
    const exception_type = py.PyObject_Type(exception) orelse return null;
    defer py.Py_DecRef(exception_type);
    py.PyErr_SetObject(exception_type, exception);
    return null;
}

/// A Python str as UTF-8 bytes copied into `arena`.
fn stringOf(object: *py.PyObject, arena: std.mem.Allocator) ?[]const u8 {
    const bytes = py.PyUnicode_AsUTF8String(object) orelse return null;
    defer py.Py_DecRef(bytes);
    var pointer: [*c]u8 = undefined;
    var length: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(bytes, &pointer, &length) != 0) return null;
    const copy = arena.dupe(u8, pointer[0..@intCast(length)]) catch {
        _ = py.PyErr_NoMemory();
        return null;
    };
    return copy;
}

fn string(text: []const u8) ?*py.PyObject {
    return py.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len));
}

/// The object's type. (`Py_TYPE` is a function only from Python 3.14 on; the
/// `ob_type` field is part of the stable ABI.)
fn typeOf(object: *py.PyObject) ?*py.PyTypeObject {
    return object.ob_type;
}

/// True if the type of `object` has `flag` (`Py_TPFLAGS_LONG_SUBCLASS`, ...):
/// how CPython's own `PyLong_Check` and friends test.
fn hasTypeFlag(object: *py.PyObject, flag: c_ulong) bool {
    return py.PyType_GetFlags(typeOf(object)) & flag != 0;
}

fn isSubtype(object: *py.PyObject, type_object: *py.PyTypeObject) bool {
    const actual = typeOf(object);
    return actual == type_object or py.PyType_IsSubtype(actual, type_object) != 0;
}

// --- Python -> Value ---------------------------------------------------------------

/// Converts a Python value into a `Value` allocated in `arena`; null with a
/// Python exception set if it cannot be one.
fn valueOf(object: *py.PyObject, arena: std.mem.Allocator, inside_map: bool) ?Value {
    if (object == @as(*py.PyObject, @ptrCast(&py._Py_NoneStruct))) return .{ .null = {} };
    if (typeOf(object) == &py.PyBool_Type) return .{ .boolean = py.PyObject_IsTrue(object) == 1 };
    if (hasTypeFlag(object, py.Py_TPFLAGS_LONG_SUBCLASS)) {
        var overflow: c_int = 0;
        const n = py.PyLong_AsLongLongAndOverflow(object, &overflow);
        if (overflow != 0) {
            _ = raise(py.PyExc_OverflowError, "integer does not fit in 64 bits", .{});
            return null;
        }
        if (n == -1 and py.PyErr_Occurred() != null) return null;
        return .{ .int = n };
    }
    if (isSubtype(object, &py.PyFloat_Type)) return .{ .float = py.PyFloat_AsDouble(object) };
    if (hasTypeFlag(object, py.Py_TPFLAGS_UNICODE_SUBCLASS)) return .{ .string = stringOf(object, arena) orelse return null };
    if (hasTypeFlag(object, py.Py_TPFLAGS_LIST_SUBCLASS | py.Py_TPFLAGS_TUPLE_SUBCLASS)) {
        const length: usize = @intCast(py.PySequence_Size(object));
        const items = arena.alloc(Value, length) catch return noMemory(Value);
        for (items, 0..) |*item, i| {
            const element = py.PySequence_GetItem(object, @intCast(i)) orelse return null;
            defer py.Py_DecRef(element);
            item.* = valueOf(element, arena, inside_map) orelse return null;
        }
        return .{ .list = items };
    }
    if (hasTypeFlag(object, py.Py_TPFLAGS_DICT_SUBCLASS)) {
        const entries = arena.alloc(MapEntry, @intCast(py.PyDict_Size(object))) catch return noMemory(Value);
        var position: py.Py_ssize_t = 0;
        var key: ?*py.PyObject = null;
        var entry_value: ?*py.PyObject = null;
        var i: usize = 0;
        while (py.PyDict_Next(object, &position, &key, &entry_value) != 0) : (i += 1) {
            if (!hasTypeFlag(key.?, py.Py_TPFLAGS_UNICODE_SUBCLASS)) {
                _ = raise(py.PyExc_TypeError, "map keys must be str", .{});
                return null;
            }
            entries[i] = .{ .key = stringOf(key.?, arena) orelse return null, .value = valueOf(entry_value.?, arena, true) orelse return null };
        }
        return acmedb.value.mapOf(entries);
    }
    return temporalValueOf(object, arena);
}

fn noMemory(comptime T: type) ?T {
    _ = py.PyErr_NoMemory();
    return null;
}

/// A temporal value, through the registered `encode_temporal`.
fn temporalValueOf(object: *py.PyObject, arena: std.mem.Allocator) ?Value {
    const encoded = py.PyObject_CallFunctionObjArgs(classes.encode_temporal, object, @as(?*py.PyObject, null)) orelse return null;
    defer py.Py_DecRef(encoded);
    if (encoded == @as(*py.PyObject, @ptrCast(&py._Py_NoneStruct))) {
        const type_object = py.PyObject_Type(object);
        defer py.Py_DecRef(type_object);
        const type_name = py.PyObject_GetAttrString(type_object, "__name__");
        defer py.Py_DecRef(type_name);
        const name = if (type_name) |n| stringOf(n, arena) orelse "?" else "?";
        _ = raise(py.PyExc_TypeError, "{s} values are not supported", .{name});
        return null;
    }
    const tag = stringOf(py.PyTuple_GetItem(encoded, 0) orelse return null, arena) orelse return null;
    const text = stringOf(py.PyTuple_GetItem(encoded, 1) orelse return null, arena) orelse return null;
    const parse = acmedb.temporal.parse;
    const parsed: anyerror!Value = if (std.mem.eql(u8, tag, "date"))
        if (parse.date(text)) |v| Value{ .date = v } else |e| e
    else if (std.mem.eql(u8, tag, "localtime"))
        if (parse.localTime(text)) |v| Value{ .local_time = v } else |e| e
    else if (std.mem.eql(u8, tag, "time"))
        if (parse.time(text)) |v| Value{ .time = v } else |e| e
    else if (std.mem.eql(u8, tag, "localdatetime"))
        if (parse.localDateTime(text)) |v| Value{ .local_date_time = v } else |e| e
    else if (std.mem.eql(u8, tag, "datetime"))
        if (parse.dateTime(text)) |v| Value{ .date_time = v } else |e| e
    else if (parse.duration(text)) |v| Value{ .duration = v } else |e| e;
    return parsed catch {
        _ = raise(py.PyExc_ValueError, "not a valid {s}: {s}", .{ tag, text });
        return null;
    };
}

// --- Value -> Python ---------------------------------------------------------------

/// A new reference to the Python value of `value`; null with an exception set
/// on failure. Entities take their labels and properties from `entities`.
fn objectOf(value: Value, entities: ?*const EntitySnapshot) ?*py.PyObject {
    return switch (value) {
        .null => none(),
        .int => |n| py.PyLong_FromLongLong(n),
        .float => |x| py.PyFloat_FromDouble(x),
        .string => |s| string(s),
        .boolean => |b| py.PyBool_FromLong(@intFromBool(b)),
        .list => |items| list: {
            const result = py.PyList_New(@intCast(items.len)) orelse break :list null;
            for (items, 0..) |item, i| {
                const element = objectOf(item, entities) orelse {
                    py.Py_DecRef(result);
                    break :list null;
                };
                _ = py.PyList_SetItem(result, @intCast(i), element); // steals `element`
            }
            break :list result;
        },
        .map => |entries| mapObject(entries, entities),
        .node => |id| node: {
            const data = if (entities) |snapshot| snapshot.nodes.get(id) else null;
            const labels = py.PyTuple_New(@intCast(if (data) |d| d.labels.len else 0)) orelse break :node null;
            if (data) |d| for (d.labels, 0..) |label, i| {
                _ = py.PyTuple_SetItem(labels, @intCast(i), string(label) orelse {
                    py.Py_DecRef(labels);
                    break :node null;
                });
            };
            const properties = propertiesObject(if (data) |d| d.properties else &.{}, entities) orelse {
                py.Py_DecRef(labels);
                break :node null;
            };
            break :node newEntity(classes.node, &node_fields, &.{ py.PyLong_FromUnsignedLongLong(id), labels, properties });
        },
        .relationship => |r| relationship: {
            const stored = if (entities) |snapshot| snapshot.relationships.getContext(r, .{}) else null;
            const properties = propertiesObject(stored orelse &.{}, entities) orelse break :relationship null;
            break :relationship newEntity(classes.relationship, &relationship_fields, &.{ py.PyLong_FromUnsignedLongLong(r.src), py.PyLong_FromUnsignedLongLong(r.dst), string(r.edge_type), properties });
        },
        .path => |p| path: {
            const nodes = py.PyTuple_New(@intCast(p.nodes.len)) orelse break :path null;
            for (p.nodes, 0..) |id, i| {
                _ = py.PyTuple_SetItem(nodes, @intCast(i), objectOf(.{ .node = id }, entities) orelse {
                    py.Py_DecRef(nodes);
                    break :path null;
                });
            }
            const relationships = py.PyTuple_New(@intCast(p.relationships.len)) orelse {
                py.Py_DecRef(nodes);
                break :path null;
            };
            for (p.relationships, 0..) |r, i| {
                _ = py.PyTuple_SetItem(relationships, @intCast(i), objectOf(.{ .relationship = r }, entities) orelse {
                    py.Py_DecRef(nodes);
                    py.Py_DecRef(relationships);
                    break :path null;
                });
            }
            break :path newEntity(classes.path, &path_fields, &.{ nodes, relationships });
        },
        inline .date, .local_time, .time, .local_date_time, .date_time, .duration => |t, tag| temporal: {
            var buffer: [128]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            t.format(&writer) catch break :temporal raise(py.PyExc_ValueError, "temporal value too long", .{});
            const class = switch (tag) {
                .date => classes.date,
                .local_time => classes.local_time,
                .time => classes.time,
                .local_date_time => classes.local_date_time,
                .date_time => classes.date_time,
                .duration => classes.duration,
                else => unreachable,
            };
            break :temporal callClass(class, &.{string(writer.buffered())});
        },
    };
}

fn mapObject(entries: []const MapEntry, entities: ?*const EntitySnapshot) ?*py.PyObject {
    const result = py.PyDict_New() orelse return null;
    for (entries) |entry| {
        if (!setItem(result, entry.key, objectOf(entry.value, entities))) {
            py.Py_DecRef(result);
            return null;
        }
    }
    return result;
}

fn propertiesObject(properties: anytype, entities: ?*const EntitySnapshot) ?*py.PyObject {
    const result = py.PyDict_New() orelse return null;
    for (properties) |property| {
        if (!setItem(result, property.name, objectOf(property.value, entities))) {
            py.Py_DecRef(result);
            return null;
        }
    }
    return result;
}

/// `dict[key] = value`, taking ownership of `value` (null: an error is set).
fn setItem(dict: *py.PyObject, key: []const u8, value: ?*py.PyObject) bool {
    const item = value orelse return false;
    defer py.Py_DecRef(item);
    const key_object = string(key) orelse return false;
    defer py.Py_DecRef(key_object);
    return py.PyDict_SetItem(dict, key_object, item) == 0;
}

// The entity classes are built field by field, without their `__init__`
// (see acmedb/entities.py): `object.__new__(class)`, then each slot set with
// the generic setter, which bypasses the class's immutability guard.
var object_new: ?*py.PyObject = null;
var node_fields: [3]?*py.PyObject = @splat(null);
var relationship_fields: [4]?*py.PyObject = @splat(null);
var path_fields: [2]?*py.PyObject = @splat(null);

fn internFields(fields: []?*py.PyObject, names: []const [*:0]const u8) bool {
    for (fields, names) |*field, name| {
        field.* = py.PyUnicode_InternFromString(name) orelse return false;
    }
    return true;
}

/// A new entity of `class` with `fields` set to `values`, taking ownership
/// of the values (a null value: an error is already set).
fn newEntity(class: ?*py.PyObject, fields: []const ?*py.PyObject, values: []const ?*py.PyObject) ?*py.PyObject {
    var failed = false;
    for (values) |value| {
        if (value == null) failed = true;
    }
    const entity = if (failed) null else py.PyObject_CallFunctionObjArgs(object_new, class, @as(?*py.PyObject, null));
    for (fields, values) |field, value| {
        const v = value orelse continue;
        defer py.Py_DecRef(v);
        if (entity) |e| {
            if (py.PyObject_GenericSetAttr(e, field, v) != 0) failed = true;
        }
    }
    if (failed) {
        if (entity) |e| py.Py_DecRef(e);
        return null;
    }
    return entity;
}

/// `class(*arguments)`, taking ownership of the arguments (a null argument:
/// an error is already set).
fn callClass(class: ?*py.PyObject, arguments: []const ?*py.PyObject) ?*py.PyObject {
    const tuple = py.PyTuple_New(@intCast(arguments.len));
    var failed = tuple == null;
    for (arguments, 0..) |argument, i| {
        if (argument) |a| {
            if (tuple) |t| _ = py.PyTuple_SetItem(t, @intCast(i), a) else py.Py_DecRef(a);
        } else failed = true;
    }
    if (failed) {
        if (tuple) |t| py.Py_DecRef(t);
        return null;
    }
    defer py.Py_DecRef(tuple);
    return py.PyObject_Call(class, tuple, null);
}

// --- Opening and closing -----------------------------------------------------------

fn destroyCapsule(capsule: ?*py.PyObject) callconv(.c) void {
    const database = databaseOf(capsule) orelse return;
    database.store.deinit();
    allocator.destroy(database);
}

fn open(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var path_pointer: [*c]const u8 = undefined;
    var path_length: py.Py_ssize_t = 0;
    var durability: c_int = 0;
    if (py.PyArg_ParseTuple(args, "s#i", &path_pointer, &path_length, &durability) == 0) return null;
    const mode: KeyValueStore.Durability = switch (durability) {
        0 => .full,
        1 => .relaxed,
        2 => .deferred,
        else => return raise(py.PyExc_ValueError, "unknown durability {d}", .{durability}),
    };
    const database = allocator.create(Database) catch return py.PyErr_NoMemory();
    database.store = KeyValueStore.openWithOptions(allocator, path_pointer[0..@intCast(path_length)], .{ .durability = mode }) catch {
        allocator.destroy(database);
        return raise(classes.storage_error, "could not open the database at {s}", .{path_pointer[0..@intCast(path_length)]});
    };
    database.graph = Graph.init(&database.store, allocator);
    database.diagnostic = Diagnostic.init();
    return py.PyCapsule_New(database, capsule_name, destroyCapsule) orelse {
        database.store.deinit();
        allocator.destroy(database);
        return null;
    };
}

fn close(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    if (py.PyArg_ParseTuple(args, "O", &capsule) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    // The capsule is emptied so a later call fails cleanly, not on freed memory.
    _ = py.PyCapsule_SetDestructor(capsule, null);
    database.store.deinit();
    allocator.destroy(database);
    _ = py.PyCapsule_SetName(capsule, "acmedb.Database.closed");
    return none();
}

/// Parses `(db, ...)`: the database and the rest of the arguments.
fn parseDatabase(args: ?*py.PyObject) ?*Database {
    const capsule = py.PyTuple_GetItem(args, 0) orelse return null;
    return databaseOf(capsule);
}

// --- Queries -----------------------------------------------------------------------

fn query(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var text_pointer: [*c]const u8 = undefined;
    var text_length: py.Py_ssize_t = 0;
    var parameters_object: ?*py.PyObject = null;
    if (py.PyArg_ParseTuple(args, "Os#O", &capsule, &text_pointer, &text_length, &parameters_object) == 0) return null;
    const database = databaseOf(capsule) orelse return null;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parameters = Executor.Parameters.empty;
    if (parameters_object) |object| if (object != @as(*py.PyObject, @ptrCast(&py._Py_NoneStruct))) {
        var position: py.Py_ssize_t = 0;
        var key: ?*py.PyObject = null;
        var value: ?*py.PyObject = null;
        while (py.PyDict_Next(object, &position, &key, &value) != 0) {
            const name = stringOf(key.?, arena) orelse return null;
            const converted = valueOf(value.?, arena, false) orelse return null;
            parameters.put(arena, name, converted) catch return py.PyErr_NoMemory();
        }
    };
    const text = arena.dupe(u8, text_pointer[0..@intCast(text_length)]) catch return py.PyErr_NoMemory();

    // The engine runs without the GIL: other Python threads go on meanwhile.
    database.diagnostic.clear();
    var ast = acmedb.Ast.init(arena);
    var executor = Executor.init(&ast, &database.graph, arena);
    executor.diagnostic = &database.diagnostic;
    executor.parameters = parameters;
    const thread_state = py.PyEval_SaveThread();
    const outcome = run(&executor, &ast, text, &database.diagnostic);
    py.PyEval_RestoreThread(thread_state);
    const rows = outcome orelse return raiseQueryError(database);

    // Building a large result makes thousands of containers, which would set
    // off Python's cycle collector over and over; none of them can be part of
    // a cycle yet, so it is paused meanwhile.
    const collector_was_enabled = py.PyGC_Disable() != 0;
    defer if (collector_was_enabled) {
        _ = py.PyGC_Enable();
    };
    const result = py.PyList_New(@intCast(rows.len)) orelse return null;
    for (rows, 0..) |row, i| {
        const cells = py.PyList_New(@intCast(row.items.len)) orelse {
            py.Py_DecRef(result);
            return null;
        };
        _ = py.PyList_SetItem(result, @intCast(i), cells);
        for (row.items, 0..) |cell, j| {
            const object = objectOf(cell, &executor.entities) orelse {
                py.Py_DecRef(result);
                return null;
            };
            _ = py.PyList_SetItem(cells, @intCast(j), object);
        }
    }
    return result;
}

/// Parses and runs `text`; null on failure, with the diagnostic set.
fn run(executor: *Executor, ast: *acmedb.Ast, text: []const u8, diagnostic: *Diagnostic) ?[]const acmedb.Row {
    const parsed = acmedb.parser.parse(ast, text, diagnostic) catch |err| {
        if (diagnostic.message().len == 0) diagnostic.set(.parse, 0, "parse failed: {s}", .{@errorName(err)});
        return null;
    };
    return executor.run(parsed) catch |err| {
        if (diagnostic.message().len == 0) diagnostic.set(acmedb.diagnostics.codeOf(err), 0, "query failed: {s}", .{@errorName(err)});
        return null;
    };
}

// --- Writes ------------------------------------------------------------------------

fn storageFailure() ?*py.PyObject {
    return raise(classes.storage_error, "write failed", .{});
}

fn beginWrite(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    database.graph.beginWrite() catch return storageFailure();
    return none();
}

fn commitWrite(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    database.graph.commitWrite() catch return storageFailure();
    return none();
}

fn abortWrite(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    database.graph.abortWrite();
    return none();
}

fn sync(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    database.store.sync() catch return raise(classes.storage_error, "sync failed", .{});
    return none();
}

/// Runs `operation` in the open write transaction, or in one of its own.
fn writing(database: *Database, comptime operation: anytype, arguments: anytype) anyerror!void {
    if (database.graph.inWriteTransaction()) return @call(.auto, operation, arguments);
    try database.graph.beginWrite();
    errdefer database.graph.abortWrite();
    try @call(.auto, operation, arguments);
    try database.graph.commitWrite();
}

fn allocateNodeId(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    var id: u64 = 0;
    const Allocate = struct {
        fn apply(graph: *Graph, out: *u64) !void {
            out.* = try graph.allocateNodeId();
        }
    };
    writing(database, Allocate.apply, .{ &database.graph, &id }) catch return storageFailure();
    return py.PyLong_FromUnsignedLongLong(id);
}

fn addNode(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var id: c_ulonglong = 0;
    var label_pointer: [*c]const u8 = undefined;
    var label_length: py.Py_ssize_t = 0;
    if (py.PyArg_ParseTuple(args, "OKs#", &capsule, &id, &label_pointer, &label_length) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    writing(database, Graph.addNode, .{ &database.graph, id, label_pointer[0..@intCast(label_length)] }) catch return storageFailure();
    return none();
}

fn requireNodes(database: *Database, ids: []const u64) bool {
    for (ids) |id| {
        const exists = database.graph.hasNode(id) catch {
            _ = storageFailure();
            return false;
        };
        if (!exists) {
            _ = raise(classes.node_not_found_error, "node {d} does not exist", .{id});
            return false;
        }
    }
    return true;
}

fn addEdge(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var source: c_ulonglong = 0;
    var target: c_ulonglong = 0;
    var type_pointer: [*c]const u8 = undefined;
    var type_length: py.Py_ssize_t = 0;
    if (py.PyArg_ParseTuple(args, "OKKs#", &capsule, &source, &target, &type_pointer, &type_length) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    if (!requireNodes(database, &.{ source, target })) return null;
    writing(database, Graph.addEdge, .{ &database.graph, source, target, type_pointer[0..@intCast(type_length)] }) catch return storageFailure();
    return none();
}

fn setProperty(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var id: c_ulonglong = 0;
    var name_pointer: [*c]const u8 = undefined;
    var name_length: py.Py_ssize_t = 0;
    var value_object: ?*py.PyObject = null;
    if (py.PyArg_ParseTuple(args, "OKs#O", &capsule, &id, &name_pointer, &name_length, &value_object) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    if (!requireNodes(database, &.{id})) return null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const value = valueOf(value_object.?, arena_state.allocator(), false) orelse return null;
    writing(database, Graph.setProperty, .{ &database.graph, id, name_pointer[0..@intCast(name_length)], value }) catch |err| switch (err) {
        error.UnsupportedPropertyType => return raise(py.PyExc_TypeError, "this value cannot be stored as a property", .{}),
        else => return storageFailure(),
    };
    return none();
}

// --- Export ------------------------------------------------------------------------

/// `{"nodes": [{"id", "labels", "properties"}], "relationships": [{"source",
/// "target", "type", "properties"}]}`, read from storage in one snapshot.
fn exportGraph(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    const graph = &database.graph;
    const own_transaction = !graph.inWriteTransaction();
    if (own_transaction) graph.beginRead() catch return storageFailure();
    defer if (own_transaction) graph.commitRead();
    return exportIn(graph) catch |err| switch (err) {
        error.PythonError => null,
        else => storageFailure(),
    };
}

fn exportIn(graph: *Graph) !*py.PyObject {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = py.PyDict_New() orelse return error.PythonError;
    errdefer py.Py_DecRef(result);
    const nodes = py.PyList_New(0) orelse return error.PythonError;
    if (!setItem(result, "nodes", nodes)) return error.PythonError;
    const relationships = py.PyList_New(0) orelse return error.PythonError;
    if (!setItem(result, "relationships", relationships)) return error.PythonError;

    var node_ids = try graph.allNodes();
    defer node_ids.deinit();
    while (try node_ids.next()) |id| {
        const node = py.PyDict_New() orelse return error.PythonError;
        defer py.Py_DecRef(node);
        if (!setItem(node, "id", py.PyLong_FromUnsignedLongLong(id))) return error.PythonError;
        const labels = py.PyList_New(0) orelse return error.PythonError;
        if (!setItem(node, "labels", labels)) return error.PythonError;
        var label_iterator = try graph.labelsOf(id);
        defer label_iterator.deinit();
        while (try label_iterator.next()) |label| {
            const label_object = string(label) orelse return error.PythonError;
            defer py.Py_DecRef(label_object);
            if (py.PyList_Append(labels, label_object) != 0) return error.PythonError;
        }
        var properties = try graph.propertiesOf(id);
        defer properties.deinit();
        if (!setItem(node, "properties", try propertiesFrom(&properties, arena))) return error.PythonError;
        if (py.PyList_Append(nodes, node) != 0) return error.PythonError;

        var edges = try graph.edgesOf(id, .out);
        defer edges.deinit();
        while (try edges.next()) |edge| {
            const relationship = py.PyDict_New() orelse return error.PythonError;
            defer py.Py_DecRef(relationship);
            if (!setItem(relationship, "source", py.PyLong_FromUnsignedLongLong(id))) return error.PythonError;
            if (!setItem(relationship, "target", py.PyLong_FromUnsignedLongLong(edge.neighbour))) return error.PythonError;
            if (!setItem(relationship, "type", string(edge.edge_type))) return error.PythonError;
            var edge_properties = try graph.edgePropertiesOf(id, edge.neighbour, edge.edge_type);
            defer edge_properties.deinit();
            if (!setItem(relationship, "properties", try propertiesFrom(&edge_properties, arena))) return error.PythonError;
            if (py.PyList_Append(relationships, relationship) != 0) return error.PythonError;
        }
    }
    return result;
}

fn propertiesFrom(properties: *acmedb.graph.PropertyIterator, arena: std.mem.Allocator) !*py.PyObject {
    const result = py.PyDict_New() orelse return error.PythonError;
    errdefer py.Py_DecRef(result);
    while (try properties.next()) |property| {
        if (!setItem(result, property.name, objectOf(try property.value(arena), null))) return error.PythonError;
    }
    return result;
}

// --- The module --------------------------------------------------------------------

fn method(comptime name: [:0]const u8, comptime function: anytype) py.PyMethodDef {
    return .{ .ml_name = name.ptr, .ml_meth = @ptrCast(&function), .ml_flags = py.METH_VARARGS, .ml_doc = null };
}

var methods = [_]py.PyMethodDef{
    method("configure", configure),
    method("open", open),
    method("close", close),
    method("sync", sync),
    method("query", query),
    method("begin_write", beginWrite),
    method("commit_write", commitWrite),
    method("abort_write", abortWrite),
    method("allocate_node_id", allocateNodeId),
    method("add_node", addNode),
    method("add_edge", addEdge),
    method("set_property", setProperty),
    method("export_graph", exportGraph),
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var module_definition = py.PyModuleDef{
    .m_base = std.mem.zeroes(py.PyModuleDef_Base),
    .m_name = "acmedb._native",
    .m_doc = "The acmedb engine, for the acmedb package.",
    .m_size = -1,
    .m_methods = &methods,
    .m_slots = null,
    .m_traverse = null,
    .m_clear = null,
    .m_free = null,
};

export fn PyInit__native() ?*py.PyObject {
    return py.PyModule_Create2(&module_definition, py.PYTHON_ABI_VERSION);
}
