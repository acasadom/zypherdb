//! Maps, and the postfix operators on any value: `.key`, `[index]`, `[a..b]`.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn string(s: []const u8) Value {
    return .{ .string = s };
}

const null_value: Value = .{ .null = {} };

test "map literals, entries and equality" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Entries are kept sorted by key; a repeated key keeps its last value.
    try expectQuery(&ast, &g, "RETURN {b: 2, a: 1, b: 3}", &.{&.{.{ .map = &.{ .{ .key = "a", .value = int(1) }, .{ .key = "b", .value = int(3) } } }}});
    try expectQuery(&ast, &g, "WITH {zone: 'Z1', floors: [1, 2]} AS m RETURN m.zone, m.floors[1], m.missing, m['zone'], keys(m)", &.{
        &.{ string("Z1"), int(2), null_value, string("Z1"), .{ .list = &.{ string("floors"), string("zone") } } },
    });
    try expectQuery(&ast, &g, "RETURN {a: 1, b: 2} = {b: 2, a: 1}, {a: {b: 'x'}}.a.b", &.{&.{ .{ .boolean = true }, string("x") }});
}

test "list indexing and slicing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "WITH [10, 20, 30, 40] AS l RETURN l[0], l[-1], l[9], l[1..3], l[..2], l[-2..], l[3..1]", &.{&.{
        int(10),
        int(40),
        null_value,
        .{ .list = &.{ int(20), int(30) } },
        .{ .list = &.{ int(10), int(20) } },
        .{ .list = &.{ int(30), int(40) } },
        .{ .list = &.{} },
    }});
    try expectQueryError(&ast, &g, "RETURN [1, 2]['a']", error.TypeMismatch);
}

test "properties of entities as maps" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Door {name: 'D1', floor: 2})", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Door) RETURN properties(d), d['name'], properties(d).floor", &.{&.{
        .{ .map = &.{ .{ .key = "floor", .value = int(2) }, .{ .key = "name", .value = string("D1") } } },
        string("D1"),
        int(2),
    }});
    // A map holding an entity is not a storable property value (a map of
    // plain values is: see writing_test.zig).
    try expectQueryError(&ast, &g, "MATCH (d:Door) SET d.meta = {door: d}", error.UnsupportedPropertyType);
}

test "literal operands of the wrong type are compile-time errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQueryError(&ast, &g, "RETURN 123 AND true", error.InvalidExpression);
    try expectQueryError(&ast, &g, "RETURN NOT {}", error.InvalidExpression);
    try expectQueryError(&ast, &g, "RETURN 1 IN {a: 1}", error.InvalidExpression);
    try expectQueryError(&ast, &g, "RETURN properties('x')", error.InvalidExpression);
    // null is a valid (unknown) boolean.
    try expectQuery(&ast, &g, "RETURN null AND false, NOT null", &.{&.{ .{ .boolean = false }, null_value }});
}
