//! Arithmetic: integer operators, precedence, signs, concatenation, errors.

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

test "integer arithmetic, precedence and signs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN 1 + 2 * 3, (1 + 2) * 3, 10 - 4 - 3, 7 / 2, -7 / 2, -7 % 3, 7 % -3", &.{
        &.{ int(7), int(9), int(3), int(3), int(-3), int(-1), int(1) },
    });
    try expectQuery(&ast, &g, "RETURN -3, - (2 + 1), +4, -9223372036854775808, 0x1F, 0o17, -0x10", &.{
        &.{ int(-3), int(-3), int(4), int(std.math.minInt(i64)), int(31), int(15), int(-16) },
    });
    // Comparisons bind looser than arithmetic; comments are ignored.
    try expectQuery(&ast, &g, "RETURN 1 + 1 = 2, 2 * 3 > 5 /* block */ // line", &.{
        &.{ .{ .boolean = true }, .{ .boolean = true } },
    });
    try expectQuery(&ast, &g, "RETURN 1 + null, null * 2", &.{&.{ .{ .null = {} }, .{ .null = {} } }});
}

test "+ concatenates strings and lists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN 'a' + 'b', 'n' + 1, 2 + 'x'", &.{&.{ string("ab"), string("n1"), string("2x") }});
    try expectQuery(&ast, &g, "RETURN [1] + [2, 3], [1] + 2, 0 + [1]", &.{&.{
        .{ .list = &.{ int(1), int(2), int(3) } },
        .{ .list = &.{ int(1), int(2) } },
        .{ .list = &.{ int(0), int(1) } },
    }});
}

test "overflow, division by zero and literal limits are errors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQueryError(&ast, &g, "RETURN 9223372036854775807 + 1", error.IntegerOverflow);
    try expectQueryError(&ast, &g, "RETURN -(-9223372036854775808)", error.IntegerOverflow);
    try expectQueryError(&ast, &g, "RETURN 1 / 0", error.DivisionByZero);
    try expectQueryError(&ast, &g, "RETURN 1 % 0", error.DivisionByZero);
    // A literal of the wrong type fails before running; a runtime value at run time.
    try expectQueryError(&ast, &g, "RETURN true + 1", error.InvalidExpression);
    try expectQueryError(&ast, &g, "WITH true AS t RETURN t + 1", error.TypeMismatch);
    try testing.expectError(error.UnexpectedToken, zypherdb.parser.parse(&ast, "RETURN 9223372036854775808", null));
    try testing.expectError(error.UnexpectedToken, zypherdb.parser.parse(&ast, "RETURN -9223372036854775809", null));
}
