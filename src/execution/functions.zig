//! Built-in functions: `name(arguments...)` in expressions.
//!
//! Each function is a row in one table: its arity and its implementation,
//! which receives the evaluated arguments. Names are case-insensitive, as in
//! openCypher. `checkCalls` validates every call of a query (known name,
//! right number of arguments) before the query runs, so a misspelt function
//! fails even when no row would reach it.
//!
//! Unless stated otherwise a function returns null when its (first) argument
//! is null, and fails with TypeMismatch on an argument of the wrong type.
//! Text functions count Unicode code points, not bytes (`size('é')` is 1).

const std = @import("std");

const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;
const Value = @import("../value.zig").Value;
const unicode = @import("../text/unicode.zig");
const MapEntry = @import("../value.zig").MapEntry;
const formatFloat = @import("../value.zig").formatFloat;

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const expressions = @import("expressions.zig");
const temporal_functions = @import("temporal_functions.zig");
const Bindings = @import("bindings.zig").Bindings;

const Function = struct {
    min_arguments: usize,
    max_arguments: usize,
    implementation: *const fn (self: *Executor, arguments: []const Value) ExecutionError!Value,
};

const variadic = std.math.maxInt(usize);

fn fixed(comptime count: usize, comptime implementation: anytype) Function {
    return .{ .min_arguments = count, .max_arguments = count, .implementation = implementation };
}

const Entry = struct { []const u8, Function };

const table = std.StaticStringMapWithEql(Function, std.static_string_map.eqlAsciiIgnoreCase).initComptime(builtin_entries ++ temporal_table);

const builtin_entries = [_]Entry{
    // Lists and strings.
    .{ "size", fixed(1, size) },
    .{ "head", fixed(1, head) },
    .{ "last", fixed(1, last) },
    .{ "tail", fixed(1, tail) },
    .{ "reverse", fixed(1, reverse) },
    .{ "range", Function{ .min_arguments = 2, .max_arguments = 3, .implementation = range } },
    // Null handling.
    .{ "coalesce", Function{ .min_arguments = 1, .max_arguments = variadic, .implementation = coalesce } },
    // Graph entities.
    .{ "id", fixed(1, id) },
    .{ "labels", fixed(1, labels) },
    .{ "type", fixed(1, relationshipType) },
    .{ "keys", fixed(1, keys) },
    .{ "properties", fixed(1, properties) },
    .{ "startNode", fixed(1, startNode) },
    .{ "length", fixed(1, pathLength) },
    .{ "nodes", fixed(1, pathNodes) },
    .{ "relationships", fixed(1, pathRelationships) },
    .{ "endNode", fixed(1, endNode) },
    // Conversions.
    .{ "toString", fixed(1, toString) },
    .{ "toInteger", fixed(1, toInteger) },
    .{ "toFloat", fixed(1, toFloat) },
    .{ "toBoolean", fixed(1, toBoolean) },
    // Strings.
    .{ "toLower", fixed(1, toLower) },
    .{ "toUpper", fixed(1, toUpper) },
    .{ "trim", fixed(1, trim) },
    .{ "lTrim", fixed(1, leftTrim) },
    .{ "rTrim", fixed(1, rightTrim) },
    .{ "replace", fixed(3, replace) },
    .{ "substring", Function{ .min_arguments = 2, .max_arguments = 3, .implementation = substring } },
    .{ "split", fixed(2, split) },
    // Numbers.
    .{ "abs", fixed(1, abs) },
    .{ "sign", fixed(1, sign) },
    .{ "ceil", fixed(1, floatFunction("ceil", std.math.ceil)) },
    .{ "floor", fixed(1, floatFunction("floor", std.math.floor)) },
    .{ "round", fixed(1, floatFunction("round", roundHalfUp)) },
    .{ "sqrt", fixed(1, floatFunction("sqrt", std.math.sqrt)) },
    .{ "exp", fixed(1, floatFunction("exp", std.math.exp)) },
    .{ "log", fixed(1, floatFunction("log", naturalLog)) },
    .{ "log10", fixed(1, floatFunction("log10", std.math.log10)) },
    .{ "sin", fixed(1, floatFunction("sin", std.math.sin)) },
    .{ "cos", fixed(1, floatFunction("cos", std.math.cos)) },
    .{ "tan", fixed(1, floatFunction("tan", std.math.tan)) },
    .{ "cot", fixed(1, floatFunction("cot", cotangent)) },
    .{ "asin", fixed(1, floatFunction("asin", std.math.asin)) },
    .{ "acos", fixed(1, floatFunction("acos", std.math.acos)) },
    .{ "atan", fixed(1, floatFunction("atan", std.math.atan)) },
    .{ "atan2", fixed(2, atan2) },
    .{ "degrees", fixed(1, floatFunction("degrees", std.math.radiansToDegrees)) },
    .{ "radians", fixed(1, floatFunction("radians", std.math.degreesToRadians)) },
    .{ "haversin", fixed(1, floatFunction("haversin", haversine)) },
    .{ "pi", fixed(0, constant(std.math.pi)) },
    .{ "e", fixed(0, constant(std.math.e)) },
    .{ "rand", fixed(0, random) },
};

/// `date`, `localtime`, `time`, `localdatetime`, `datetime` (with their
/// `.statement`, `.transaction`, `.realtime` and `.truncate` variants) and
/// `duration` (with `.between`, `.inMonths`, `.inDays`, `.inSeconds`).
const temporal_table = blk: {
    const kinds = [_]struct { []const u8, temporal_functions.Kind }{
        .{ "date", .date },                     .{ "localtime", .local_time }, .{ "time", .time },
        .{ "localdatetime", .local_date_time }, .{ "datetime", .date_time },
    };
    var entries: [kinds.len * 5 + 7]Entry = undefined;
    var count: usize = 0;
    for (kinds) |kind| {
        const optional_argument = Function{ .min_arguments = 0, .max_arguments = 1, .implementation = constructor(kind[1], false) };
        for ([_][]const u8{ "", ".statement", ".transaction" }) |suffix| {
            entries[count] = .{ kind[0] ++ suffix, optional_argument };
            count += 1;
        }
        entries[count] = .{ kind[0] ++ ".realtime", .{ .min_arguments = 0, .max_arguments = 1, .implementation = constructor(kind[1], true) } };
        entries[count + 1] = .{ kind[0] ++ ".truncate", .{ .min_arguments = 2, .max_arguments = 3, .implementation = truncation(kind[1]) } };
        count += 2;
    }
    entries[count] = .{ "datetime.fromepoch", fixed(2, temporal_functions.fromEpoch) };
    entries[count + 1] = .{ "datetime.fromepochmillis", fixed(1, temporal_functions.fromEpochMillis) };
    entries[count + 2] = .{ "duration", fixed(1, temporal_functions.duration) };
    entries[count + 3] = .{ "duration.between", fixed(2, durationBetween(.full)) };
    entries[count + 4] = .{ "duration.inMonths", fixed(2, durationBetween(.months)) };
    entries[count + 5] = .{ "duration.inDays", fixed(2, durationBetween(.days)) };
    entries[count + 6] = .{ "duration.inSeconds", fixed(2, durationBetween(.seconds)) };
    break :blk entries;
};

fn constructor(comptime kind: temporal_functions.Kind, comptime realtime: bool) fn (*Executor, []const Value) ExecutionError!Value {
    return struct {
        fn apply(self: *Executor, arguments: []const Value) ExecutionError!Value {
            return temporal_functions.construct(self, kind, arguments, realtime);
        }
    }.apply;
}

fn truncation(comptime kind: temporal_functions.Kind) fn (*Executor, []const Value) ExecutionError!Value {
    return struct {
        fn apply(self: *Executor, arguments: []const Value) ExecutionError!Value {
            return temporal_functions.truncate(self, kind, arguments);
        }
    }.apply;
}

fn durationBetween(comptime precision: @import("../temporal/durations.zig").Precision) fn (*Executor, []const Value) ExecutionError!Value {
    return struct {
        fn apply(self: *Executor, arguments: []const Value) ExecutionError!Value {
            return temporal_functions.between(self, precision, arguments);
        }
    }.apply;
}

/// Checks every function call under `index`: the function exists and gets
/// a number of arguments it accepts. O(size of the query).
pub fn checkCalls(ast: *const Ast, index: Index, diagnostic: ?*Diagnostic) error{InvalidExpression}!void {
    if (ast.kind(index) == .function_call) {
        const name = ast.data(index).text;
        const count = ast.nodeChildren(index).len;
        const function = table.get(name) orelse {
            if (diagnostic) |d| d.set(.invalid_expression, 0, "unknown function '{s}'", .{name});
            return error.InvalidExpression;
        };
        if (count < function.min_arguments or count > function.max_arguments) {
            if (diagnostic) |d| d.set(.invalid_expression, 0, "function '{s}' does not take {d} argument(s)", .{ name, count });
            return error.InvalidExpression;
        }
    }
    for (ast.nodeChildren(index)) |child| try checkCalls(ast, child, diagnostic);
}

/// Evaluates the call `expr` (already checked by `checkCalls`).
pub fn call(self: *Executor, expr: Index, bindings: *Bindings) ExecutionError!Value {
    const function = table.get(self.ast.data(expr).text) orelse return error.InvalidExpression;
    const argument_nodes = self.ast.nodeChildren(expr);
    const arguments = try self.allocator.alloc(Value, argument_nodes.len);
    for (arguments, argument_nodes) |*argument, node| argument.* = try expressions.evaluate(self, node, bindings);
    return function.implementation(self, arguments);
}

fn typeError(self: *Executor, comptime function: []const u8, comptime expected: []const u8) ExecutionError {
    self.fail(.type_mismatch, function ++ "() expects " ++ expected, .{});
    return error.TypeMismatch;
}

// --- Lists and strings -------------------------------------------------------

fn size(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .list => |items| .{ .int = @intCast(items.len) },
        .string => |s| .{ .int = @intCast(try codePointCount(self, s)) },
        else => typeError(self, "size", "a list or a string"),
    };
}

fn head(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .list => |items| if (items.len > 0) items[0] else .{ .null = {} },
        else => typeError(self, "head", "a list"),
    };
}

fn last(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .list => |items| if (items.len > 0) items[items.len - 1] else .{ .null = {} },
        else => typeError(self, "last", "a list"),
    };
}

fn tail(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .list => |items| .{ .list = if (items.len > 0) items[1..] else items },
        else => typeError(self, "tail", "a list"),
    };
}

fn reverse(self: *Executor, arguments: []const Value) ExecutionError!Value {
    switch (arguments[0]) {
        .null => return .{ .null = {} },
        .list => |items| {
            const reversed = try self.allocator.dupe(Value, items);
            std.mem.reverse(Value, reversed);
            return .{ .list = reversed };
        },
        .string => |s| {
            const points = try codePoints(self, s);
            std.mem.reverse(u21, points);
            return .{ .string = try encodeCodePoints(self, points) };
        },
        else => return typeError(self, "reverse", "a list or a string"),
    }
}

/// `range(start, end[, step])`: the integers from `start` to `end`
/// inclusive, `step` apart (1 by default; it may be negative, not 0).
fn range(self: *Executor, arguments: []const Value) ExecutionError!Value {
    for (arguments) |argument| {
        if (argument != .int) return typeError(self, "range", "integer arguments");
    }
    const start = arguments[0].int;
    const end = arguments[1].int;
    const step: i64 = if (arguments.len == 3) arguments[2].int else 1;
    if (step == 0) {
        self.fail(.type_mismatch, "range() step must not be 0", .{});
        return error.TypeMismatch;
    }
    var items = std.ArrayList(Value).empty;
    var n = start;
    while ((step > 0 and n <= end) or (step < 0 and n >= end)) {
        try items.append(self.allocator, .{ .int = n });
        n = std.math.add(i64, n, step) catch break;
    }
    return .{ .list = items.items };
}

// --- Null handling -------------------------------------------------------------

/// The first argument that is not null, or null.
fn coalesce(_: *Executor, arguments: []const Value) ExecutionError!Value {
    for (arguments) |argument| {
        if (!argument.isNull()) return argument;
    }
    return .{ .null = {} };
}

// --- Graph entities ------------------------------------------------------------

fn id(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .node => |node| .{ .int = @intCast(node) },
        .relationship => {
            self.fail(.type_mismatch, "id() of a relationship: acmedb identifies relationships by (source, target, type), not by an id", .{});
            return error.TypeMismatch;
        },
        else => typeError(self, "id", "a node"),
    };
}

fn labels(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const node = switch (arguments[0]) {
        .null => return .{ .null = {} },
        .node => |node| node,
        else => return typeError(self, "labels", "a node"),
    };
    try requireExisting(self, arguments[0], "labels");
    var names = std.ArrayList(Value).empty;
    var iterator = try self.graph.labelsOf(node);
    defer iterator.deinit();
    while (try iterator.next()) |label| try names.append(self.allocator, .{ .string = try self.allocator.dupe(u8, label) });
    return .{ .list = names.items };
}

fn relationshipType(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .relationship => |r| .{ .string = r.edge_type },
        else => typeError(self, "type", "a relationship"),
    };
}

/// The keys of a map, or the property names of a node or relationship, in
/// name order.
fn keys(self: *Executor, arguments: []const Value) ExecutionError!Value {
    if (arguments[0] == .map) {
        const names = try self.allocator.alloc(Value, arguments[0].map.len);
        for (names, arguments[0].map) |*name, entry| name.* = .{ .string = entry.key };
        return .{ .list = names };
    }
    if (arguments[0] != .null) try requireExisting(self, arguments[0], "keys");
    var iterator = switch (arguments[0]) {
        .null => return .{ .null = {} },
        .node => |node| try self.graph.propertiesOf(node),
        .relationship => |r| try self.graph.edgePropertiesOf(r.src, r.dst, r.edge_type),
        else => return typeError(self, "keys", "a map, a node or a relationship"),
    };
    defer iterator.deinit();
    var names = std.ArrayList(Value).empty;
    while (try iterator.next()) |property| try names.append(self.allocator, .{ .string = try self.allocator.dupe(u8, property.name) });
    return .{ .list = names.items };
}

/// The properties of a node or relationship as a map (a map is returned
/// as it is).
fn properties(self: *Executor, arguments: []const Value) ExecutionError!Value {
    if (arguments[0] == .map or arguments[0] == .null) return arguments[0];
    try requireExisting(self, arguments[0], "properties");
    return propertiesOf(self, arguments[0]);
}

/// The properties of an existing node or relationship as a map.
pub fn propertiesOf(self: *Executor, entity: Value) ExecutionError!Value {
    var iterator = switch (entity) {
        .node => |node| try self.graph.propertiesOf(node),
        .relationship => |r| try self.graph.edgePropertiesOf(r.src, r.dst, r.edge_type),
        else => return typeError(self, "properties", "a map, a node or a relationship"),
    };
    defer iterator.deinit();
    var entries = std.ArrayList(MapEntry).empty;
    while (try iterator.next()) |property| {
        try entries.append(self.allocator, .{ .key = try self.allocator.dupe(u8, property.name), .value = try property.value(self.allocator) });
    }
    return .{ .map = entries.items }; // stored in name order: already sorted
}

/// The number of relationships of a path.
fn pathLength(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .path => |p| .{ .int = @intCast(p.relationships.len) },
        else => typeError(self, "length", "a path"),
    };
}

fn pathNodes(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const p = switch (arguments[0]) {
        .null => return .{ .null = {} },
        .path => |p| p,
        else => return typeError(self, "nodes", "a path"),
    };
    const values = try self.allocator.alloc(Value, p.nodes.len);
    for (values, p.nodes) |*value, node| value.* = .{ .node = node };
    return .{ .list = values };
}

fn pathRelationships(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const p = switch (arguments[0]) {
        .null => return .{ .null = {} },
        .path => |p| p,
        else => return typeError(self, "relationships", "a path"),
    };
    const values = try self.allocator.alloc(Value, p.relationships.len);
    for (values, p.relationships) |*value, relationship| value.* = .{ .relationship = relationship };
    return .{ .list = values };
}

fn startNode(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .relationship => |r| .{ .node = r.src },
        else => typeError(self, "startNode", "a relationship"),
    };
}

fn endNode(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .relationship => |r| .{ .node = r.dst },
        else => typeError(self, "endNode", "a relationship"),
    };
}

/// Fails if `entity` was deleted by this query (openCypher's EntityNotFound):
/// its data can no longer be read.
fn requireExisting(self: *Executor, entity: Value, comptime function: []const u8) ExecutionError!void {
    const exists = switch (entity) {
        .node => |node| try self.graph.hasNode(node),
        .relationship => |r| try self.graph.hasEdge(r.src, r.dst, r.edge_type),
        else => true,
    };
    if (!exists) {
        self.fail(.invalid_expression, function ++ "() of a deleted entity", .{});
        return error.InvalidExpression;
    }
}

// --- Conversions -----------------------------------------------------------------

fn toString(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .string => arguments[0],
        .int => |n| .{ .string = try std.fmt.allocPrint(self.allocator, "{d}", .{n}) },
        .float => |x| .{ .string = try formatFloat(self.allocator, x) },
        .boolean => |b| .{ .string = if (b) "true" else "false" },
        inline .date, .local_time, .time, .local_date_time, .date_time, .duration => |t| .{ .string = try std.fmt.allocPrint(self.allocator, "{f}", .{t}) },
        else => typeError(self, "toString", "a number, a string, a boolean or a temporal value"),
    };
}

/// An integer; a float truncated toward zero; or a string holding a number
/// (null if it does not, or if the number does not fit in 64 bits).
fn toInteger(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .int => arguments[0],
        .float => |x| truncateToInteger(x),
        .string => |s| blk: {
            const text = std.mem.trim(u8, s, " \t\r\n");
            if (std.fmt.parseInt(i64, text, 10)) |n| break :blk .{ .int = n } else |_| {}
            break :blk if (parseNumber(text)) |x| truncateToInteger(x) else .{ .null = {} };
        },
        else => typeError(self, "toInteger", "a number or a string"),
    };
}

fn truncateToInteger(x: f64) Value {
    const whole = @trunc(x);
    if (std.math.isNan(whole) or whole < -9.223372036854775808e18 or whole >= 9.223372036854775808e18) return .{ .null = {} };
    return .{ .int = @intFromFloat(whole) };
}

/// A decimal number as written in a query (`1.5`, `-2`, `1e3`), or null:
/// `std.fmt.parseFloat` also reads `inf`, `nan` and hexadecimal, which are
/// not numbers here.
fn parseNumber(text: []const u8) ?f64 {
    for (text) |c| {
        if (!std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, ".eE+-", c) == null) return null;
    }
    return std.fmt.parseFloat(f64, text) catch null;
}

/// A float; an integer converted; or a string holding a number (null if it
/// does not).
fn toFloat(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .float => arguments[0],
        .int => |n| .{ .float = @floatFromInt(n) },
        .string => |s| if (parseNumber(std.mem.trim(u8, s, " \t\r\n"))) |x| .{ .float = x } else .{ .null = {} },
        else => typeError(self, "toFloat", "a number or a string"),
    };
}

/// A boolean, or the string 'true' / 'false' (any case; null otherwise).
fn toBoolean(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .boolean => arguments[0],
        .string => |s| blk: {
            const text = std.mem.trim(u8, s, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(text, "true")) break :blk .{ .boolean = true };
            if (std.ascii.eqlIgnoreCase(text, "false")) break :blk .{ .boolean = false };
            break :blk .{ .null = {} };
        },
        else => typeError(self, "toBoolean", "a boolean or a string"),
    };
}

// --- Strings -----------------------------------------------------------------------

fn stringArgument(self: *Executor, value: Value, comptime function: []const u8) ExecutionError!?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |s| s,
        else => typeError(self, function, "a string"),
    };
}

/// Lower case, with Unicode's full case mappings ("ÁRBOL" is "árbol").
fn toLower(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const s = try stringArgument(self, arguments[0], "toLower") orelse return .{ .null = {} };
    return .{ .string = try unicode.changeCase(self.allocator, s, .lower) };
}

/// Upper case, with Unicode's full case mappings ("straße" is "STRASSE").
fn toUpper(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const s = try stringArgument(self, arguments[0], "toUpper") orelse return .{ .null = {} };
    return .{ .string = try unicode.changeCase(self.allocator, s, .upper) };
}

const whitespace = " \t\r\n";

fn trim(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const s = try stringArgument(self, arguments[0], "trim") orelse return .{ .null = {} };
    return .{ .string = std.mem.trim(u8, s, whitespace) };
}

fn leftTrim(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const s = try stringArgument(self, arguments[0], "lTrim") orelse return .{ .null = {} };
    return .{ .string = std.mem.trimStart(u8, s, whitespace) };
}

fn rightTrim(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const s = try stringArgument(self, arguments[0], "rTrim") orelse return .{ .null = {} };
    return .{ .string = std.mem.trimEnd(u8, s, whitespace) };
}

/// `replace(text, search, replacement)`: every occurrence of `search`.
fn replace(self: *Executor, arguments: []const Value) ExecutionError!Value {
    var parts: [3][]const u8 = undefined;
    for (&parts, arguments) |*part, argument| {
        part.* = try stringArgument(self, argument, "replace") orelse return .{ .null = {} };
    }
    if (parts[1].len == 0) return .{ .string = parts[0] };
    return .{ .string = try std.mem.replaceOwned(u8, self.allocator, parts[0], parts[1], parts[2]) };
}

/// `substring(text, start[, length])`, in code points from 0.
fn substring(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const s = try stringArgument(self, arguments[0], "substring") orelse return .{ .null = {} };
    for (arguments[1..]) |argument| {
        if (argument != .int or argument.int < 0) return typeError(self, "substring", "non-negative integer positions");
    }
    const points = try codePoints(self, s);
    const start: usize = @min(@as(usize, @intCast(arguments[1].int)), points.len);
    const length: usize = if (arguments.len == 3) @intCast(arguments[2].int) else points.len;
    const end = start + @min(length, points.len - start);
    return .{ .string = try encodeCodePoints(self, points[start..end]) };
}

/// `split(text, delimiter)`: the pieces between occurrences of the delimiter.
fn split(self: *Executor, arguments: []const Value) ExecutionError!Value {
    const s = try stringArgument(self, arguments[0], "split") orelse return .{ .null = {} };
    const delimiter = try stringArgument(self, arguments[1], "split") orelse return .{ .null = {} };
    var pieces = std.ArrayList(Value).empty;
    if (delimiter.len == 0) {
        // An empty delimiter splits into single characters.
        for (try codePoints(self, s)) |point| try pieces.append(self.allocator, .{ .string = try encodeCodePoints(self, &.{point}) });
        return .{ .list = pieces.items };
    }
    var iterator = std.mem.splitSequence(u8, s, delimiter);
    while (iterator.next()) |piece| try pieces.append(self.allocator, .{ .string = piece });
    return .{ .list = pieces.items };
}

fn codePointCount(self: *Executor, s: []const u8) ExecutionError!usize {
    return std.unicode.utf8CountCodepoints(s) catch {
        self.fail(.type_mismatch, "string is not valid UTF-8", .{});
        return error.TypeMismatch;
    };
}

fn codePoints(self: *Executor, s: []const u8) ExecutionError![]u21 {
    var points = std.ArrayList(u21).empty;
    var view = std.unicode.Utf8View.init(s) catch {
        self.fail(.type_mismatch, "string is not valid UTF-8", .{});
        return error.TypeMismatch;
    };
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |point| try points.append(self.allocator, point);
    return points.items;
}

fn encodeCodePoints(self: *Executor, points: []const u21) ExecutionError![]const u8 {
    var bytes = std.ArrayList(u8).empty;
    for (points) |point| {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(point, &buffer) catch unreachable; // decoded from valid UTF-8
        try bytes.appendSlice(self.allocator, buffer[0..length]);
    }
    return bytes.items;
}

// --- Numbers -------------------------------------------------------------------------

fn abs(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .int => |n| if (n == std.math.minInt(i64)) blk: {
            self.fail(.type_mismatch, "abs() overflows a 64-bit integer", .{});
            break :blk error.TypeMismatch;
        } else .{ .int = if (n < 0) -n else n },
        .float => |x| .{ .float = @abs(x) },
        else => typeError(self, "abs", "a number"),
    };
}

/// -1, 0 or 1, as an integer (0 for NaN).
fn sign(self: *Executor, arguments: []const Value) ExecutionError!Value {
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .int => |n| .{ .int = std.math.sign(n) },
        .float => |x| .{ .int = if (x > 0) 1 else if (x < 0) -1 else 0 },
        else => typeError(self, "sign", "a number"),
    };
}

/// A function of one number that returns a float, from `operation` on f64:
/// integer arguments are converted first.
fn floatFunction(comptime name: []const u8, comptime operation: anytype) fn (*Executor, []const Value) ExecutionError!Value {
    return struct {
        fn apply(self: *Executor, arguments: []const Value) ExecutionError!Value {
            return switch (arguments[0]) {
                .null => .{ .null = {} },
                .int, .float => .{ .float = @as(f64, operation(expressions.asFloat(arguments[0]))) },
                else => typeError(self, name, "a number"),
            };
        }
    }.apply;
}

fn constant(comptime x: f64) fn (*Executor, []const Value) ExecutionError!Value {
    return struct {
        fn apply(_: *Executor, _: []const Value) ExecutionError!Value {
            return .{ .float = x };
        }
    }.apply;
}

/// Halves round up (toward positive infinity): round(2.5) is 3.0, round(-2.5) is -2.0.
fn roundHalfUp(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x)) return x;
    return @floor(x + 0.5);
}

fn naturalLog(x: f64) f64 {
    return @log(x);
}

fn cotangent(x: f64) f64 {
    return 1.0 / std.math.tan(x);
}

fn haversine(x: f64) f64 {
    return (1.0 - std.math.cos(x)) / 2.0;
}

fn atan2(self: *Executor, arguments: []const Value) ExecutionError!Value {
    for (arguments) |argument| switch (argument) {
        .null => return .{ .null = {} },
        .int, .float => {},
        else => return typeError(self, "atan2", "numbers"),
    };
    return .{ .float = std.math.atan2(expressions.asFloat(arguments[0]), expressions.asFloat(arguments[1])) };
}

/// A random float in [0, 1).
fn random(_: *Executor, _: []const Value) ExecutionError!Value {
    var bytes: [8]u8 = undefined;
    std.Io.Threaded.global_single_threaded.io().random(&bytes);
    const bits = std.mem.readInt(u64, &bytes, .little) >> 11;
    return .{ .float = @as(f64, @floatFromInt(bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53)) };
}
