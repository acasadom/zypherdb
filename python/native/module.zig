//! `zypherdb._native`: the Python extension module, written in Zig on the
//! Python limited C API (abi3, Python 3.10 and later), so one build works with
//! every Python version of a platform.
//!
//! Values cross between Python and the engine by direct conversion: no JSON,
//! no intermediate buffers. A query runs with the GIL released. The Python
//! package (`zypherdb/db.py`) wraps these functions in the `Database` class and
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
const zypherdb = @import("zypherdb");

const py = @import("python"); // python.h, translated by the build
const temporals = @import("temporals.zig");

// PyArg_ParseTuple with Py_ssize_t lengths for `#` formats. Before Python 3.13 C code
// gets this variant through the PY_SSIZE_T_CLEAN macro, which Zig code does not see;
// it is part of the stable ABI in every version, even where headers no longer declare it.
extern fn _PyArg_ParseTuple_SizeT(args: ?*py.PyObject, format: [*:0]const u8, ...) c_int;
const parseTuple = _PyArg_ParseTuple_SizeT;

const Value = zypherdb.Value;
const MapEntry = zypherdb.value.MapEntry;
const Graph = zypherdb.Graph;
const KeyValueStore = zypherdb.KeyValueStore;
const Executor = zypherdb.Executor;
const Diagnostic = zypherdb.Diagnostic;
const Statement = zypherdb.Statement;
const Replication = zypherdb.replication.Replication;
const EntitySnapshot = @FieldType(Executor, "entities");

const allocator = std.heap.c_allocator;

/// An open database: what the capsule holds.
const Database = struct {
    store: KeyValueStore,
    graph: Graph,
    diagnostic: Diagnostic,
    /// Return temporal values as their ISO 8601 text, not `datetime` objects.
    iso_temporals: bool,
    /// Procedures defined by `define_procedure` (the TCK's test procedures),
    /// with their values in `procedure_arena`.
    table_procedures: std.ArrayList(zypherdb.procedures.TableProcedure) = .empty,
    procedure_arena: std.heap.ArenaAllocator,
    /// The directory LOAD CSV reads from (owned); null: LOAD CSV is off.
    import_directory: ?[]u8 = null,
    /// The statements `query` prepared, by text.
    statements: zypherdb.StatementCache,
    /// The memory a query runs in, kept from one query to the next (up to
    /// `retained_scratch` bytes) instead of asked for again each time.
    scratch: std.heap.ArenaAllocator,
    /// Replication, on a database opened with a role.
    replication: ?*Replication = null,
};

const retained_scratch = 1 << 20;

/// The database's scratch memory for one call; `doneWith` gives it back.
fn scratchOf(args: ?*py.PyObject) ?*std.heap.ArenaAllocator {
    const database = parseDatabase(args) orelse return null;
    return &database.scratch;
}

fn doneWith(scratch: *std.heap.ArenaAllocator) void {
    _ = scratch.reset(.{ .retain_with_limit = retained_scratch });
}

/// Frees what an open database holds, and the database.
fn release(database: *Database) void {
    if (database.replication) |replication| replication.stop();
    database.statements.deinit();
    database.scratch.deinit();
    database.store.deinit();
    database.procedure_arena.deinit();
    if (database.import_directory) |directory| allocator.free(directory);
    allocator.destroy(database);
}

/// `set_import_directory(db, path or None)`: where LOAD CSV reads files.
fn setImportDirectory(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var path_pointer: [*c]const u8 = null;
    var path_length: py.Py_ssize_t = 0;
    if (parseTuple(args, "Oz#", &capsule, &path_pointer, &path_length) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    const directory: ?[]u8 = if (path_pointer == null) null else allocator.dupe(u8, path_pointer[0..@intCast(path_length)]) catch return py.PyErr_NoMemory();
    if (database.import_directory) |old| allocator.free(old);
    database.import_directory = directory;
    return none();
}

/// How result values become Python objects: the entities the rows refer to,
/// and how temporal values are returned.
const Output = struct {
    entities: ?*const EntitySnapshot,
    iso_temporals: bool,
};

const capsule_name = "zypherdb.Database";

// --- Registered Python classes -------------------------------------------------

/// The Python classes and callables `configure` registers (new references,
/// kept for the life of the process).
const Classes = struct {
    node: ?*py.PyObject = null,
    relationship: ?*py.PyObject = null,
    path: ?*py.PyObject = null,
    /// `query_error(code, message) -> exception`.
    query_error: ?*py.PyObject = null,
    storage_error: ?*py.PyObject = null,
    node_not_found_error: ?*py.PyObject = null,
};

var classes = Classes{};

fn configure(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var table: ?*py.PyObject = null;
    if (parseTuple(args, "O", &table) == 0) return null;
    inline for (@typeInfo(Classes).@"struct".field_names) |name| {
        const entry = py.PyDict_GetItemString(table, name) orelse return raise(py.PyExc_KeyError, "configure: missing " ++ name, .{});
        py.Py_IncRef(entry);
        @field(classes, name) = entry;
    }
    if (!temporals.configure(table)) return null;
    object_new = py.PyObject_GetAttrString(@ptrCast(@alignCast(&py.PyBaseObject_Type)), "__new__") orelse return null;
    if (!internFields(&node_fields, &.{ "id", "labels", "properties" }) or
        !internFields(&relationship_fields, &.{ "id", "source", "target", "type", "properties" }) or
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
        return zypherdb.value.mapOf(entries);
    }
    return switch (temporals.fromPython(object)) {
        .value => |v| v,
        .failed => null,
        .not_temporal => unsupported(object),
    };
}

fn noMemory(comptime T: type) ?T {
    _ = py.PyErr_NoMemory();
    return null;
}

fn unsupported(object: *py.PyObject) ?Value {
    const type_object = py.PyObject_Type(object) orelse return null;
    defer py.Py_DecRef(type_object);
    const type_name = py.PyObject_GetAttrString(type_object, "__name__") orelse return null;
    defer py.Py_DecRef(type_name);
    const bytes = py.PyUnicode_AsUTF8String(type_name) orelse return null;
    defer py.Py_DecRef(bytes);
    var pointer: [*c]u8 = undefined;
    var length: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(bytes, &pointer, &length) != 0) return null;
    _ = raise(py.PyExc_TypeError, "{s} values are not supported", .{pointer[0..@intCast(length)]});
    return null;
}

// --- Value -> Python ---------------------------------------------------------------

/// A new reference to the Python value of `value`; null with an exception set
/// on failure. Entities take their labels and properties from `out.entities`.
fn objectOf(value: Value, out: Output) ?*py.PyObject {
    return switch (value) {
        .null => none(),
        .int => |n| py.PyLong_FromLongLong(n),
        .float => |x| py.PyFloat_FromDouble(x),
        .string => |s| string(s),
        .boolean => |b| py.PyBool_FromLong(@intFromBool(b)),
        .list => |items| list: {
            const result = py.PyList_New(@intCast(items.len)) orelse break :list null;
            for (items, 0..) |item, i| {
                const element = objectOf(item, out) orelse {
                    py.Py_DecRef(result);
                    break :list null;
                };
                _ = py.PyList_SetItem(result, @intCast(i), element); // steals `element`
            }
            break :list result;
        },
        .map => |entries| mapObject(entries, out),
        .node => |id| node: {
            const data = if (out.entities) |snapshot| snapshot.nodes.get(id) else null;
            const labels = py.PyTuple_New(@intCast(if (data) |d| d.labels.len else 0)) orelse break :node null;
            if (data) |d| for (d.labels, 0..) |label, i| {
                _ = py.PyTuple_SetItem(labels, @intCast(i), string(label) orelse {
                    py.Py_DecRef(labels);
                    break :node null;
                });
            };
            const properties = propertiesObject(if (data) |d| d.properties else &.{}, out) orelse {
                py.Py_DecRef(labels);
                break :node null;
            };
            break :node newEntity(classes.node, &node_fields, &.{ py.PyLong_FromUnsignedLongLong(id), labels, properties });
        },
        .relationship => |r| relationship: {
            const stored = if (out.entities) |snapshot| snapshot.relationships.getContext(r, .{}) else null;
            const properties = propertiesObject(stored orelse &.{}, out) orelse break :relationship null;
            break :relationship newEntity(classes.relationship, &relationship_fields, &.{ py.PyLong_FromUnsignedLongLong(r.id), py.PyLong_FromUnsignedLongLong(r.src), py.PyLong_FromUnsignedLongLong(r.dst), string(r.edge_type), properties });
        },
        .path => |p| path: {
            const nodes = py.PyTuple_New(@intCast(p.nodes.len)) orelse break :path null;
            for (p.nodes, 0..) |id, i| {
                _ = py.PyTuple_SetItem(nodes, @intCast(i), objectOf(.{ .node = id }, out) orelse {
                    py.Py_DecRef(nodes);
                    break :path null;
                });
            }
            const relationships = py.PyTuple_New(@intCast(p.relationships.len)) orelse {
                py.Py_DecRef(nodes);
                break :path null;
            };
            for (p.relationships, 0..) |r, i| {
                _ = py.PyTuple_SetItem(relationships, @intCast(i), objectOf(.{ .relationship = r }, out) orelse {
                    py.Py_DecRef(nodes);
                    py.Py_DecRef(relationships);
                    break :path null;
                });
            }
            break :path newEntity(classes.path, &path_fields, &.{ nodes, relationships });
        },
        .date, .local_time, .time, .local_date_time, .date_time, .duration => temporals.toPython(value, out.iso_temporals),
    };
}

fn mapObject(entries: []const MapEntry, out: Output) ?*py.PyObject {
    const result = py.PyDict_New() orelse return null;
    for (entries) |entry| {
        if (!setItem(result, entry.key, objectOf(entry.value, out))) {
            py.Py_DecRef(result);
            return null;
        }
    }
    return result;
}

fn propertiesObject(properties: anytype, out: Output) ?*py.PyObject {
    const result = py.PyDict_New() orelse return null;
    for (properties) |property| {
        if (!setItem(result, property.name, objectOf(property.value, out))) {
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
// (see zypherdb/entities.py): `object.__new__(class)`, then each slot set with
// the generic setter, which bypasses the class's immutability guard.
var object_new: ?*py.PyObject = null;
var node_fields: [3]?*py.PyObject = @splat(null);
var relationship_fields: [5]?*py.PyObject = @splat(null);
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

// --- Test procedures ---------------------------------------------------------------

/// `define_procedure(db, name, arguments, columns, rows)`: a procedure whose
/// rows are a table, as the openCypher TCK defines them. `arguments` and
/// `columns` are lists of `(name, type)` (types as declared: `INTEGER?`);
/// each row lists a value per argument, then per column.
fn defineProcedure(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var name_object: ?*py.PyObject = null;
    var arguments_object: ?*py.PyObject = null;
    var columns_object: ?*py.PyObject = null;
    var rows_object: ?*py.PyObject = null;
    if (parseTuple(args, "OUO!O!O!", &capsule, &name_object, &py.PyList_Type, &arguments_object, &py.PyList_Type, &columns_object, &py.PyList_Type, &rows_object) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    const arena = database.procedure_arena.allocator();

    const arguments = arena.alloc(zypherdb.procedures.Argument, @intCast(py.PyList_Size(arguments_object))) catch return py.PyErr_NoMemory();
    for (arguments, 0..) |*argument, i| {
        const declared = declaredPair(py.PyList_GetItem(arguments_object, @intCast(i)), arena) orelse return null;
        argument.* = .{ .name = declared[0], .type = zypherdb.procedures.argumentType(declared[1]) orelse return raise(py.PyExc_ValueError, "unknown type {s}", .{declared[1]}) };
    }
    const columns = arena.alloc(zypherdb.procedures.Column, @intCast(py.PyList_Size(columns_object))) catch return py.PyErr_NoMemory();
    for (columns, 0..) |*column, i| {
        const declared = declaredPair(py.PyList_GetItem(columns_object, @intCast(i)), arena) orelse return null;
        const column_type = zypherdb.procedures.argumentType(declared[1]) orelse return raise(py.PyExc_ValueError, "unknown type {s}", .{declared[1]});
        column.* = .{ .name = declared[0], .kind = switch (column_type) {
            .node => .node,
            .relationship => .relationship,
            else => .value,
        } };
    }
    const rows = arena.alloc([]const Value, @intCast(py.PyList_Size(rows_object))) catch return py.PyErr_NoMemory();
    for (rows, 0..) |*row, i| {
        const row_object = py.PyList_GetItem(rows_object, @intCast(i)) orelse return null;
        if (typeOf(row_object) != &py.PyList_Type) return raise(py.PyExc_TypeError, "each row must be a list", .{});
        const values = arena.alloc(Value, @intCast(py.PyList_Size(row_object))) catch return py.PyErr_NoMemory();
        if (values.len != arguments.len + columns.len) return raise(py.PyExc_ValueError, "a row needs a value per argument and per column", .{});
        for (values, 0..) |*value, j| value.* = valueOf(py.PyList_GetItem(row_object, @intCast(j)).?, arena, false) orelse return null;
        row.* = values;
    }
    const name = stringOf(name_object.?, arena) orelse return null;
    database.table_procedures.append(arena, .{
        .signature = .{ .name = name, .min_arguments = arguments.len, .max_arguments = arguments.len, .columns = columns, .arguments = arguments },
        .rows = rows,
    }) catch return py.PyErr_NoMemory();
    // The statements kept were checked without it.
    database.statements.clear();
    return none();
}

/// A `(name, type)` tuple's two strings.
fn declaredPair(object: ?*py.PyObject, arena: std.mem.Allocator) ?[2][]const u8 {
    const pair = object orelse return null;
    if (typeOf(pair) != &py.PyTuple_Type or py.PyTuple_Size(pair) != 2) {
        _ = raise(py.PyExc_TypeError, "expected a (name, type) tuple", .{});
        return null;
    }
    return .{ stringOf(py.PyTuple_GetItem(pair, 0).?, arena) orelse return null, stringOf(py.PyTuple_GetItem(pair, 1).?, arena) orelse return null };
}

// --- Opening and closing -----------------------------------------------------------

fn destroyCapsule(capsule: ?*py.PyObject) callconv(.c) void {
    const database = databaseOf(capsule) orelse return;
    release(database);
}

fn open(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var path_pointer: [*c]const u8 = undefined;
    var path_length: py.Py_ssize_t = 0;
    var durability: c_int = 0;
    var iso_temporals: c_int = 0;
    if (parseTuple(args, "s#ii", &path_pointer, &path_length, &durability, &iso_temporals) == 0) return null;
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
    database.graph.checkFormat() catch |err| {
        database.store.deinit();
        allocator.destroy(database);
        const path = path_pointer[0..@intCast(path_length)];
        if (err == error.IncompatibleFormat) return raise(classes.storage_error, "the database at {s} was written in another storage format", .{path});
        return raise(classes.storage_error, "could not open the database at {s}", .{path});
    };
    database.diagnostic = Diagnostic.init();
    database.iso_temporals = iso_temporals != 0;
    database.table_procedures = .empty;
    database.procedure_arena = std.heap.ArenaAllocator.init(allocator);
    database.import_directory = null;
    database.statements = zypherdb.StatementCache.init(allocator);
    database.scratch = std.heap.ArenaAllocator.init(allocator);
    database.replication = null;
    return py.PyCapsule_New(database, capsule_name, destroyCapsule) orelse {
        release(database);
        return null;
    };
}

fn close(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    if (parseTuple(args, "O", &capsule) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    // The capsule is emptied so a later call fails cleanly, not on freed memory.
    _ = py.PyCapsule_SetDestructor(capsule, null);
    release(database);
    _ = py.PyCapsule_SetName(capsule, "zypherdb.Database.closed");
    return none();
}

/// Parses `(db, ...)`: the database and the rest of the arguments.
fn parseDatabase(args: ?*py.PyObject) ?*Database {
    const capsule = py.PyTuple_GetItem(args, 0) orelse return null;
    return databaseOf(capsule);
}

// --- Queries -----------------------------------------------------------------------

/// What a query call takes: the database, the query's text and its parameters.
const QueryCall = struct { database: *Database, text: []const u8, parameters: Executor.Parameters };

/// The arguments `(db, text, parameters)`, converted into `arena`.
fn queryCall(args: ?*py.PyObject, arena: std.mem.Allocator) ?QueryCall {
    var capsule: ?*py.PyObject = null;
    var text_pointer: [*c]const u8 = undefined;
    var text_length: py.Py_ssize_t = 0;
    var parameters_object: ?*py.PyObject = null;
    if (parseTuple(args, "Os#O", &capsule, &text_pointer, &text_length, &parameters_object) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    const parameters = parametersOf(parameters_object, arena) orelse return null;
    const text = arena.dupe(u8, text_pointer[0..@intCast(text_length)]) catch return noMemory(QueryCall);
    return .{ .database = database, .text = text, .parameters = parameters };
}

/// A dict of parameters (or None: none) as Values, converted into `arena`.
fn parametersOf(parameters_object: ?*py.PyObject, arena: std.mem.Allocator) ?Executor.Parameters {
    var parameters = Executor.Parameters.empty;
    const object = parameters_object orelse return parameters;
    if (object == @as(*py.PyObject, @ptrCast(&py._Py_NoneStruct))) return parameters;
    var position: py.Py_ssize_t = 0;
    var key: ?*py.PyObject = null;
    var value: ?*py.PyObject = null;
    while (py.PyDict_Next(object, &position, &key, &value) != 0) {
        const name = stringOf(key.?, arena) orelse return null;
        const converted = valueOf(value.?, arena, false) orelse return null;
        parameters.put(arena, name, converted) catch return noMemory(Executor.Parameters);
    }
    return parameters;
}

/// The environment a database's statements are prepared in.
fn environmentOf(database: *Database) Statement.Environment {
    return .{ .graph = &database.graph, .diagnostic = &database.diagnostic, .table_procedures = database.table_procedures.items };
}

/// Runs `statement` with the call's parameters, with the GIL released
/// (other Python threads go on meanwhile); null on failure, with the
/// diagnostic set. `executor` is the statement's, allocating in the call's arena.
fn runStatement(call: QueryCall, statement: *Statement, executor: *Executor) ?[]const zypherdb.Row {
    const database = call.database;
    database.diagnostic.clear();
    executor.diagnostic = &database.diagnostic;
    executor.parameters = call.parameters;
    executor.table_procedures = database.table_procedures.items;
    executor.import_directory = database.import_directory;
    const thread_state = py.PyEval_SaveThread();
    defer py.PyEval_RestoreThread(thread_state);
    return statement.run(executor) catch |err| {
        noteFailure(&database.diagnostic, err);
        return null;
    };
}

fn noteFailure(diagnostic: *Diagnostic, err: anyerror) void {
    if (diagnostic.message().len == 0) zypherdb.diagnostics.noteError(diagnostic, err);
}

/// The statement prepared for the call's text: the cached one, or a new one
/// (cached if it has a plan to keep; else the caller's, in `owned`). Null on
/// failure, with the diagnostic set.
fn statementFor(call: QueryCall, owned: *?*Statement) ?*Statement {
    const database = call.database;
    if (database.statements.get(call.text)) |statement| return statement;
    database.diagnostic.clear();
    const thread_state = py.PyEval_SaveThread();
    const prepared = Statement.prepare(allocator, call.text, environmentOf(database));
    py.PyEval_RestoreThread(thread_state);
    const statement = prepared catch |err| {
        noteFailure(&database.diagnostic, if (err == error.ParseFailed) error.InvalidExpression else err);
        return null;
    };
    if (statement.is_query) database.statements.put(statement) else owned.* = statement;
    return statement;
}

/// `query(db, text, parameters)`: the rows of one query, as lists of cells.
fn query(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const scratch = scratchOf(args) orelse return null;
    defer doneWith(scratch);
    const arena = scratch.allocator();
    const call = queryCall(args, arena) orelse return null;
    var owned: ?*Statement = null;
    defer if (owned) |statement| statement.destroy();
    const statement = statementFor(call, &owned) orelse return raiseQueryError(call.database);
    var executor = statement.executorFor(&call.database.graph, arena);
    const rows = runStatement(call, statement, &executor) orelse return raiseQueryError(call.database);
    return rowsObject(rows, &executor, call.database);
}

/// `prepare(db, text)`: `(statement, parameters, columns)`: a prepared
/// statement (a capsule, freed with it) and the names of its parameters and
/// of its result's columns.
fn prepare(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var text_pointer: [*c]const u8 = undefined;
    var text_length: py.Py_ssize_t = 0;
    if (parseTuple(args, "Os#", &capsule, &text_pointer, &text_length) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    database.diagnostic.clear();
    const thread_state = py.PyEval_SaveThread();
    const prepared = Statement.prepare(allocator, text_pointer[0..@intCast(text_length)], environmentOf(database));
    py.PyEval_RestoreThread(thread_state);
    const statement = prepared catch |err| {
        noteFailure(&database.diagnostic, if (err == error.ParseFailed) error.InvalidExpression else err);
        return raiseQueryError(database);
    };
    const statement_capsule = py.PyCapsule_New(statement, statement_capsule_name, destroyStatementCapsule) orelse {
        statement.destroy();
        return null;
    };
    const parameters = stringTuple(statement.parameter_names) orelse {
        py.Py_DecRef(statement_capsule);
        return null;
    };
    const columns = stringTuple(statement.columns) orelse {
        py.Py_DecRef(statement_capsule);
        py.Py_DecRef(parameters);
        return null;
    };
    return py.Py_BuildValue("(NNN)", statement_capsule, parameters, columns);
}

/// `statement_query(db, statement, parameters)`: the rows of a prepared statement.
fn statementQuery(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var statement_capsule: ?*py.PyObject = null;
    var parameters_object: ?*py.PyObject = null;
    if (parseTuple(args, "OOO", &capsule, &statement_capsule, &parameters_object) == 0) return null;
    const pointer = py.PyCapsule_GetPointer(statement_capsule, statement_capsule_name) orelse return null;
    const statement: *Statement = @ptrCast(@alignCast(pointer));

    const database = databaseOf(capsule) orelse return null;
    const arena = database.scratch.allocator();
    defer doneWith(&database.scratch);
    const parameters = parametersOf(parameters_object, arena) orelse return null;
    const call = QueryCall{ .database = database, .text = statement.text, .parameters = parameters };
    var executor = statement.executorFor(&database.graph, arena);
    const rows = runStatement(call, statement, &executor) orelse return raiseQueryError(database);
    return rowsObject(rows, &executor, database);
}

const statement_capsule_name = "zypherdb.Statement";

fn destroyStatementCapsule(capsule: ?*py.PyObject) callconv(.c) void {
    const pointer = py.PyCapsule_GetPointer(capsule, statement_capsule_name) orelse return;
    const statement: *Statement = @ptrCast(@alignCast(pointer));
    statement.destroy();
}

/// `names` as a tuple of str.
fn stringTuple(names: []const []const u8) ?*py.PyObject {
    const tuple = py.PyTuple_New(@intCast(names.len)) orelse return null;
    for (names, 0..) |name, position| {
        const object = string(name) orelse {
            py.Py_DecRef(tuple);
            return null;
        };
        _ = py.PyTuple_SetItem(tuple, @intCast(position), object);
    }
    return tuple;
}

/// `plan(db, text, parameters)`: runs an EXPLAIN or PROFILE statement and
/// returns `(rows, lines, parents)`: the query's own rows (PROFILE runs it),
/// the plan's lines, and the index of each line's parent (None at the root).
fn plan(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const scratch = scratchOf(args) orelse return null;
    defer doneWith(scratch);
    const arena = scratch.allocator();
    const call = queryCall(args, arena) orelse return null;
    var owned: ?*Statement = null;
    defer if (owned) |statement| statement.destroy();
    const statement = statementFor(call, &owned) orelse return raiseQueryError(call.database);
    var executor = statement.executorFor(&call.database.graph, arena);
    const lines = runStatement(call, statement, &executor) orelse return raiseQueryError(call.database);

    const rows = rowsObject(executor.profiled_rows, &executor, call.database) orelse return null;
    const plan_lines = rowsObject(lines, &executor, call.database) orelse {
        py.Py_DecRef(rows);
        return null;
    };
    const parents = py.PyList_New(@intCast(executor.plan_parents.len)) orelse {
        py.Py_DecRef(rows);
        py.Py_DecRef(plan_lines);
        return null;
    };
    for (executor.plan_parents, 0..) |parent, position| {
        const object = if (parent) |index| py.PyLong_FromSsize_t(@intCast(index)) else none();
        _ = py.PyList_SetItem(parents, @intCast(position), object);
    }
    return py.Py_BuildValue("(NNN)", rows, plan_lines, parents);
}

/// `rows` as a list of lists of Python values.
fn rowsObject(rows: []const zypherdb.Row, executor: *Executor, database: *Database) ?*py.PyObject {
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
            const object = objectOf(cell, .{ .entities = &executor.entities, .iso_temporals = database.iso_temporals }) orelse {
                py.Py_DecRef(result);
                return null;
            };
            _ = py.PyList_SetItem(cells, @intCast(j), object);
        }
    }
    return result;
}

// --- Writes ------------------------------------------------------------------------

fn storageFailure() ?*py.PyObject {
    return raise(classes.storage_error, "write failed", .{});
}

/// The exception for a failed write: a constraint it would break
/// (ConstraintViolationError), a size limit (ValueError), or a storage
/// failure.
fn writeFailure(database: *Database, err: anyerror) ?*py.PyObject {
    if (err == error.ValueTooLarge) return raise(py.PyExc_ValueError, "this value is too large to store (at most {d} bytes)", .{zypherdb.layout.max_value_length});
    if (err == error.TooManyLabels) return raise(py.PyExc_ValueError, "a node cannot have more than {d} labels", .{zypherdb.layout.max_labels});
    if (err != error.ConstraintViolation) return storageFailure();
    database.diagnostic.set(.constraint_violation, 0, "{s}", .{database.graph.violationMessage()});
    return raiseQueryError(database);
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

// --- Replication -------------------------------------------------------------------

/// `start_replication(db, path, role, address, token)`: role 0 serves
/// replicas at `address`, role 1 follows the master at `address`.
fn startReplication(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var path_pointer: [*c]const u8 = undefined;
    var path_length: py.Py_ssize_t = 0;
    var role: c_int = 0;
    var address_pointer: [*c]const u8 = undefined;
    var address_length: py.Py_ssize_t = 0;
    var token_pointer: [*c]const u8 = undefined;
    var token_length: py.Py_ssize_t = 0;
    if (parseTuple(args, "Os#is#s#", &capsule, &path_pointer, &path_length, &role, &address_pointer, &address_length, &token_pointer, &token_length) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    const address = address_pointer[0..@intCast(address_length)];
    const token = token_pointer[0..@intCast(token_length)];
    const replication_role: zypherdb.replication.Role = switch (role) {
        0 => .{ .master = .{ .address = address, .token = token } },
        1 => .{ .replica = .{ .master_address = address, .token = token } },
        else => return raise(py.PyExc_ValueError, "unknown role {d}", .{role}),
    };
    database.replication = Replication.start(allocator, &database.store, path_pointer[0..@intCast(path_length)], replication_role) catch |err| return switch (err) {
        error.MasterDatabase => raise(classes.storage_error, "the database is a master: a replica must start from an empty database or a replica", .{}),
        error.ReadOnlyReplica => raise(classes.storage_error, "the database is a replica: it cannot serve replicas", .{}),
        else => raise(classes.storage_error, "replication could not start at {s}: {t}", .{ address, err }),
    };
    return none();
}

/// `last_lsn(db)`: the last change set the database has (a master's last
/// committed, a replica's last applied); 0 without replication.
fn lastLsn(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    const replication = database.replication orelse return py.PyLong_FromUnsignedLongLong(0);
    const status = replication.status(&.{}) catch return storageFailure();
    return py.PyLong_FromUnsignedLongLong(switch (status) {
        .master => |master| master.last_lsn,
        .replica => |replica| replica.applied_lsn,
    });
}

/// `wait_for(db, lsn, timeout_ms)`: whether the master's change set `lsn`
/// is applied here within the timeout (at once on a master).
fn waitFor(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var lsn: c_ulonglong = 0;
    var timeout_ms: c_ulonglong = 0;
    if (parseTuple(args, "OKK", &capsule, &lsn, &timeout_ms) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    const replication = database.replication orelse return py.PyBool_FromLong(1);
    const thread_state = py.PyEval_SaveThread();
    const applied = replication.waitFor(lsn, timeout_ms *| std.time.ns_per_ms);
    py.PyEval_RestoreThread(thread_state);
    return py.PyBool_FromLong(@intFromBool(applied));
}

/// `replication_status(db)`: how replication goes, as JSON text, or None
/// without replication.
fn replicationStatus(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    const replication = database.replication orelse return none();
    const json = replication.statusJson(allocator) catch return storageFailure();
    defer allocator.free(json);
    return string(json);
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
    if (parseTuple(args, "OKs#", &capsule, &id, &label_pointer, &label_length) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    if (label_length > 0 and !requireStorableName("label", label_pointer[0..@intCast(label_length)])) return null;
    writing(database, Graph.addNode, .{ &database.graph, id, label_pointer[0..@intCast(label_length)] }) catch |err| return writeFailure(database, err);
    return none();
}

/// Raises ValueError for a label, type or property name storage cannot keep.
fn requireStorableName(kind: []const u8, name: []const u8) bool {
    const problem = zypherdb.layout.nameProblem(name) orelse return true;
    _ = raise(py.PyExc_ValueError, "a {s} {s}", .{ kind, problem });
    return false;
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
    if (parseTuple(args, "OKKs#", &capsule, &source, &target, &type_pointer, &type_length) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    if (!requireStorableName("relationship type", type_pointer[0..@intCast(type_length)])) return null;
    if (!requireNodes(database, &.{ source, target })) return null;
    var id: u64 = 0;
    const Add = struct {
        fn apply(graph: *Graph, src: u64, dst: u64, edge_type: []const u8, out: *u64) !void {
            out.* = try graph.addEdge(src, dst, edge_type);
        }
    };
    writing(database, Add.apply, .{ &database.graph, source, target, type_pointer[0..@intCast(type_length)], &id }) catch return storageFailure();
    return py.PyLong_FromUnsignedLongLong(id);
}

fn setProperty(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var capsule: ?*py.PyObject = null;
    var id: c_ulonglong = 0;
    var name_pointer: [*c]const u8 = undefined;
    var name_length: py.Py_ssize_t = 0;
    var value_object: ?*py.PyObject = null;
    if (parseTuple(args, "OKs#O", &capsule, &id, &name_pointer, &name_length, &value_object) == 0) return null;
    const database = databaseOf(capsule) orelse return null;
    if (!requireNodes(database, &.{id})) return null;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const value = valueOf(value_object.?, arena_state.allocator(), false) orelse return null;
    if (value != .null and !requireStorableName("property name", name_pointer[0..@intCast(name_length)])) return null;
    writing(database, Graph.setProperty, .{ &database.graph, id, name_pointer[0..@intCast(name_length)], value }) catch |err| switch (err) {
        error.UnsupportedPropertyType => return raise(py.PyExc_TypeError, "this value cannot be stored as a property", .{}),
        else => return writeFailure(database, err),
    };
    return none();
}

// --- Export ------------------------------------------------------------------------

/// `{"nodes": [{"id", "labels", "properties"}], "relationships": [{"source",
/// "target", "type", "properties"}]}`, read from storage in one snapshot.
/// `{"ok": bool, "problem_count": int, "problems": [str]}` (see
/// `zypherdb.integrity.check`).
fn check(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    var report = zypherdb.integrity.check(&database.graph, allocator) catch return storageFailure();
    defer report.deinit();
    const result = py.PyDict_New() orelse return null;
    if (!fillReport(result, &report)) {
        py.Py_DecRef(result);
        return null;
    }
    return result;
}

fn fillReport(result: *py.PyObject, report: *const zypherdb.integrity.Report) bool {
    if (!setItem(result, "ok", py.PyBool_FromLong(@intFromBool(report.ok())))) return false;
    if (!setItem(result, "problem_count", py.PyLong_FromUnsignedLongLong(report.count))) return false;
    const problems = py.PyList_New(0) orelse return false;
    if (!setItem(result, "problems", problems)) return false;
    for (report.problems.items) |problem| {
        const text = string(problem) orelse return false;
        defer py.Py_DecRef(text);
        if (py.PyList_Append(problems, text) != 0) return false;
    }
    return true;
}

fn exportGraph(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    const database = parseDatabase(args) orelse return null;
    const graph = &database.graph;
    const own_transaction = !graph.inWriteTransaction();
    if (own_transaction) graph.beginRead() catch return storageFailure();
    defer if (own_transaction) graph.commitRead();
    return exportIn(graph, database.iso_temporals) catch |err| switch (err) {
        error.PythonError => null,
        else => storageFailure(),
    };
}

fn exportIn(graph: *Graph, iso_temporals: bool) !*py.PyObject {
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
        if (!setItem(node, "properties", try propertiesFrom(&properties, arena, iso_temporals))) return error.PythonError;
        if (py.PyList_Append(nodes, node) != 0) return error.PythonError;

        var edges = try graph.edgesOf(id, .out);
        defer edges.deinit();
        while (try edges.next()) |edge| {
            const relationship = py.PyDict_New() orelse return error.PythonError;
            defer py.Py_DecRef(relationship);
            if (!setItem(relationship, "id", py.PyLong_FromUnsignedLongLong(edge.relationship))) return error.PythonError;
            if (!setItem(relationship, "source", py.PyLong_FromUnsignedLongLong(id))) return error.PythonError;
            if (!setItem(relationship, "target", py.PyLong_FromUnsignedLongLong(edge.neighbour))) return error.PythonError;
            if (!setItem(relationship, "type", string(edge.edge_type))) return error.PythonError;
            var edge_properties = try graph.edgePropertiesOf(edge.relationship);
            defer edge_properties.deinit();
            if (!setItem(relationship, "properties", try propertiesFrom(&edge_properties, arena, iso_temporals))) return error.PythonError;
            if (py.PyList_Append(relationships, relationship) != 0) return error.PythonError;
        }
    }
    return result;
}

fn propertiesFrom(properties: *zypherdb.graph.PropertyIterator, arena: std.mem.Allocator, iso_temporals: bool) !*py.PyObject {
    const result = py.PyDict_New() orelse return error.PythonError;
    errdefer py.Py_DecRef(result);
    while (try properties.next()) |property| {
        if (!setItem(result, property.name, objectOf(try property.value(arena), .{ .entities = null, .iso_temporals = iso_temporals }))) return error.PythonError;
    }
    return result;
}

fn durationText(_: ?*py.PyObject, args: ?*py.PyObject) callconv(.c) ?*py.PyObject {
    var months: c_longlong = 0;
    var days: c_longlong = 0;
    var seconds: c_longlong = 0;
    var nanoseconds: c_uint = 0;
    if (parseTuple(args, "LLLI", &months, &days, &seconds, &nanoseconds) == 0) return null;
    return temporals.durationText(months, days, seconds, nanoseconds);
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
    method("start_replication", startReplication),
    method("last_lsn", lastLsn),
    method("wait_for", waitFor),
    method("replication_status", replicationStatus),
    method("query", query),
    method("plan", plan),
    method("prepare", prepare),
    method("statement_query", statementQuery),
    method("begin_write", beginWrite),
    method("commit_write", commitWrite),
    method("abort_write", abortWrite),
    method("allocate_node_id", allocateNodeId),
    method("add_node", addNode),
    method("add_edge", addEdge),
    method("set_property", setProperty),
    method("export_graph", exportGraph),
    method("check", check),
    method("define_procedure", defineProcedure),
    method("set_import_directory", setImportDirectory),
    method("duration_text", durationText),
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

var module_definition = py.PyModuleDef{
    .m_base = std.mem.zeroes(py.PyModuleDef_Base),
    .m_name = "zypherdb._native",
    .m_doc = "The ZypherDB engine, for the zypherdb package.",
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
