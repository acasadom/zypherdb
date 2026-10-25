//! Floats: literals, mixed arithmetic, comparisons, functions, aggregates and
//! float properties.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectOrdered = support.expectOrdered;
const expectQueryError = support.expectQueryError;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn float(x: f64) Value {
    return .{ .float = x };
}

fn boolean(b: bool) Value {
    return .{ .boolean = b };
}

fn string(s: []const u8) Value {
    return .{ .string = s };
}

const null_value: Value = .{ .null = {} };

test "float literals and arithmetic" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN 1.5, .5, 1e3, 1.5e-3, -2.25, 1E2", &.{
        &.{ float(1.5), float(0.5), float(1000), float(0.0015), float(-2.25), float(100) },
    });
    // A float may start with its dot right after a keyword, too.
    try expectQuery(&ast, &g, "UNWIND [.25, 1] AS x WITH x WHERE x > .5 RETURN .5, CASE WHEN x < 1 THEN .1 ELSE .9 END", &.{
        &.{ float(0.5), float(0.9) },
    });
    // An integer with a float gives a float; two integers stay integers.
    try expectQuery(&ast, &g, "RETURN 1 + 0.5, 3 * 1.5, 7 / 2.0, 7 / 2, 7.5 % 2, -1.5 - 1", &.{
        &.{ float(1.5), float(4.5), float(3.5), int(3), float(1.5), float(-2.5) },
    });
    // `^` binds tighter than `*`, after the sign, and always gives a float.
    try expectQuery(&ast, &g, "RETURN 2 ^ 3, 2 * 3 ^ 2, -2 ^ 2, 2 ^ 3 ^ 2, 4 ^ 0.5", &.{
        &.{ float(8), float(18), float(4), float(64), float(2) },
    });
    // Float division by zero follows IEEE 754; integer division by zero fails.
    try expectQuery(&ast, &g, "RETURN 1.0 / 0, -1 / 0.0, toString(0.0 / 0.0)", &.{
        &.{ float(std.math.inf(f64)), float(-std.math.inf(f64)), string("NaN") },
    });
    try expectQueryError(&ast, &g, "RETURN 1 / 0", error.DivisionByZero);
    // A range is not a float: `1..3` stays a slice.
    try expectQuery(&ast, &g, "RETURN [1, 2, 3, 4][1..3], 'n' + 1.5", &.{
        &.{ .{ .list = &.{ int(2), int(3) } }, string("n1.5") },
    });
}

test "comparisons across numbers, strings, booleans and lists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN 1 = 1.0, 1 < 1.5, 2.0 >= 2, 9007199254740993 > 9007199254740992.0", &.{
        &.{ boolean(true), boolean(true), boolean(true), boolean(true) },
    });
    // NaN equals nothing and compares false with everything.
    try expectQuery(&ast, &g, "WITH 0.0 / 0.0 AS nan RETURN nan = nan, nan <> nan, nan < 1, nan >= 1", &.{
        &.{ boolean(false), boolean(true), boolean(false), boolean(false) },
    });
    try expectQuery(&ast, &g, "RETURN 'a' < 'b', false < true, [1, 2] < [1, 3], [1] < [1, 0], [1, 'a'] = [1.0, 'a']", &.{
        &.{ boolean(true), boolean(true), boolean(true), boolean(true), boolean(true) },
    });
    // Values that do not compare give null, not an error.
    try expectQuery(&ast, &g, "RETURN 1 < 'a', 'a' >= true, [1] < 1, {a: 1} < {a: 2}, 1 = 'a', [1, null] = [1, 2]", &.{
        &.{ null_value, null_value, null_value, null_value, boolean(false), null_value },
    });
    try expectQuery(&ast, &g, "RETURN 1.0 IN [1, 2], 3 IN [1, null]", &.{&.{ boolean(true), null_value }});
}

test "numeric functions and conversions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN round(2.5), round(-2.5), floor(-1.5), ceil(1.2), sqrt(16), abs(-1.5), sign(-0.5)", &.{
        &.{ float(3), float(-2), float(-2), float(2), float(4), float(1.5), int(-1) },
    });
    try expectQuery(&ast, &g, "RETURN toFloat(3), toFloat('2.5'), toFloat('x'), toInteger(2.9), toInteger(-2.9), toInteger('3.7')", &.{
        &.{ float(3), float(2.5), null_value, int(2), int(-2), int(3) },
    });
    try expectQuery(&ast, &g, "RETURN toString(1.0), toString(0.1), toString(1.5e20), exp(0), log(e()), log10(100), pi() > 3.14", &.{
        &.{ string("1.0"), string("0.1"), string("1.5e20"), float(1), float(1), float(2), boolean(true) },
    });
    try expectQuery(&ast, &g, "WITH rand() AS r RETURN r >= 0 AND r < 1", &.{&.{boolean(true)}});
}

test "aggregates over floats" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "UNWIND [1, 2, 3, 4] AS x RETURN sum(x), avg(x), stDevP(x), min(x), max(x)", &.{
        &.{ int(10), float(2.5), float(@sqrt(1.25)), int(1), int(4) },
    });
    try expectQuery(&ast, &g, "UNWIND [1, 2.5] AS x RETURN sum(x), avg(x), stDev(x)", &.{
        &.{ float(3.5), float(1.75), float(@sqrt(1.125)) },
    });
    try expectQuery(&ast, &g, "UNWIND [] AS x RETURN sum(x), avg(x)", &.{&.{ int(0), null_value }});
    try expectQueryError(&ast, &g, "UNWIND [9223372036854775807, 1] AS x RETURN sum(x)", error.IntegerOverflow);
    try expectQueryError(&ast, &g, "UNWIND ['a'] AS x RETURN avg(x)", error.TypeMismatch);
}

test "float properties are stored, indexed and ordered with integers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Reading {value: 1.0}), (:Reading {value: 2.5}), (:Reading {value: 2})", &.{});
    // An integral float is found by the integer it equals, and vice versa.
    try expectQuery(&ast, &g, "MATCH (r:Reading {value: 1}) RETURN r.value", &.{&.{float(1)}});
    try expectQuery(&ast, &g, "MATCH (r:Reading) WHERE r.value = 2.0 RETURN r.value", &.{&.{int(2)}});
    try expectOrdered(&ast, &g, "MATCH (r:Reading) RETURN r.value ORDER BY r.value DESC", &.{
        &.{float(2.5)}, &.{int(2)}, &.{float(1)},
    });
}

test "rand() draws from the executor's generator when it has one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    const query = try zypherdb.parser.parse(&ast, "UNWIND range(1, 3) AS i RETURN i, rand() ORDER BY i", null);
    var draws: [2][3]f64 = undefined;
    for (&draws) |*draw| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var prng = std.Random.DefaultPrng.init(42);
        var executor = zypherdb.Executor.init(&ast, &g, arena.allocator());
        executor.random = prng.random();
        const rows = try executor.run(query);
        try testing.expectEqual(@as(usize, 3), rows.len);
        for (rows, draw) |row, *value| value.* = row.items[1].float;
    }
    try testing.expectEqualSlices(f64, &draws[0], &draws[1]);
    try testing.expect(draws[0][0] != draws[0][1]);
}
