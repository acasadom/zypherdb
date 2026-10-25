//! List comprehensions and the quantifiers any / all / none / single.

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

fn boolean(b: bool) Value {
    return .{ .boolean = b };
}

const null_value: Value = .{ .null = {} };

test "list comprehensions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN [x IN [1, 2, 3, 4] WHERE x % 2 = 0 | x * 10], [x IN [1, 2] | x + 1], [x IN [1, 2, 3] WHERE x > 1], [x IN null | x]", &.{&.{
        .{ .list = &.{ int(20), int(40) } },
        .{ .list = &.{ int(2), int(3) } },
        .{ .list = &.{ int(2), int(3) } },
        null_value,
    }});
    // The variable is local: it shadows an outer x without changing it.
    try expectQuery(&ast, &g, "WITH 100 AS x RETURN [x IN [1, 2] | x], x", &.{&.{ .{ .list = &.{ int(1), int(2) } }, int(100) }});
    // It is not mistaken for a non-key variable next to an aggregate.
    try expectQuery(&ast, &g, "UNWIND [1, 2] AS v RETURN [x IN collect(v) | x * 2]", &.{&.{.{ .list = &.{ int(2), int(4) } }}});
}

test "quantifiers with three-valued logic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN any(x IN [1, 2] WHERE x > 1), all(x IN [1, 2] WHERE x > 1), none(x IN [1, 2] WHERE x > 5), single(x IN [1, 2] WHERE x > 1)", &.{
        &.{ boolean(true), boolean(false), boolean(true), boolean(true) },
    });
    // Null predicate results: unknown unless the other elements decide.
    try expectQuery(&ast, &g, "RETURN any(x IN [null, 2] WHERE x > 1), any(x IN [null] WHERE x > 1), ALL(x IN [null, 0] WHERE x > 1), all(x IN [] WHERE false)", &.{
        &.{ boolean(true), null_value, boolean(false), boolean(true) },
    });
    try expectQueryError(&ast, &g, "RETURN any(x IN 5 WHERE x > 1)", error.TypeMismatch);
}

test "static type checks inside comprehensions and quantifiers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // x is known to be a string: `%` on it fails before running.
    try expectQueryError(&ast, &g, "RETURN any(x IN ['Clara'] WHERE x % 2 = 0)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "RETURN [x IN [true] | x + 1]", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (n) RETURN [x IN [1, 2] | count(*)]", error.InvalidExpression);
    // `+` joins a string with a number, so this is fine.
    try expectQuery(&ast, &g, "RETURN [x IN ['a'] | x + 1]", &.{&.{.{ .list = &.{.{ .string = "a1" }} }}});
}
