//! Built-in functions: lists, strings, conversions, graph entities, nulls.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const Value = acmedb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const loadMoviesGraph = support.loadMoviesGraph;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

fn string(s: []const u8) Value {
    return .{ .string = s };
}

fn int(n: i64) Value {
    return .{ .int = n };
}

const null_value: Value = .{ .null = {} };

test "list and string functions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN size([1, 2]), size('añu'), head([1, 2]), last([1, 2]), tail([1, 2, 3]), head([])", &.{
        &.{ int(2), int(3), int(1), int(2), .{ .list = &.{ int(2), int(3) } }, null_value },
    });
    try expectQuery(&ast, &g, "RETURN reverse('añb'), reverse([1, 2]), range(1, 3), range(5, 1, -2)", &.{
        &.{ string("bña"), .{ .list = &.{ int(2), int(1) } }, .{ .list = &.{ int(1), int(2), int(3) } }, .{ .list = &.{ int(5), int(3), int(1) } } },
    });
    try expectQuery(&ast, &g, "RETURN toUpper('aB'), toLower('aB'), trim('  x '), lTrim('  x '), rTrim('  x ')", &.{
        &.{ string("AB"), string("ab"), string("x"), string("x "), string("  x") },
    });
    try expectQuery(&ast, &g, "RETURN replace('a-b-c', '-', '+'), substring('ñandú', 1, 3), substring('abc', 1), split('a,b', ',')", &.{
        &.{ string("a+b+c"), string("and"), string("bc"), .{ .list = &.{ string("a"), string("b") } } },
    });
}

test "conversions, numbers and null handling" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "RETURN toString(42), toString(true), toInteger('17'), toInteger('x'), toBoolean('TRUE'), toBoolean('no')", &.{
        &.{ string("42"), string("true"), int(17), null_value, .{ .boolean = true }, null_value },
    });
    try expectQuery(&ast, &g, "RETURN abs(-3), sign(-3), coalesce(null, null, 2, 3), coalesce(null), toUpper(null)", &.{
        &.{ int(3), int(-1), int(2), null_value, null_value },
    });
    // exists(property): set or not; its argument must be a property.
    try expectQuery(&ast, &g, "CREATE (:Item {name: 'a'}), (:Item {name: 'b', price: 2})", &.{});
    try expectQuery(&ast, &g, "MATCH (i:Item) WHERE exists(i.price) RETURN i.name", &.{&.{string("b")}});
    try expectQuery(&ast, &g, "MATCH (i:Item) WHERE NOT EXISTS(i.price) RETURN i.name", &.{&.{string("a")}});
    try expectQuery(&ast, &g, "WITH {k: 1} AS m RETURN exists(m.k), exists(m.other)", &.{&.{ .{ .boolean = true }, .{ .boolean = false } }});
    try expectQueryError(&ast, &g, "MATCH (i:Item) RETURN exists(i)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "RETURN exists(1)", error.InvalidExpression);
    // Unknown functions and wrong arity fail before running; wrong types at run time.
    try expectQueryError(&ast, &g, "MATCH (n) RETURN nope(n)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (n) RETURN toUpper(n, n)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "RETURN toUpper(1)", error.TypeMismatch);
    try expectQueryError(&ast, &g, "RETURN range(1, 3, 0)", error.TypeMismatch);
}

test "graph entity functions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Lana Wachowski'})-[r:DIRECTED]->(m {title: 'The Matrix'}) RETURN id(p), labels(p), keys(p), type(r), startNode(r) = p, id(endNode(r))", &.{
        &.{ int(4), .{ .list = &.{string("Person")} }, .{ .list = &.{ string("born"), string("name") } }, string("DIRECTED"), .{ .boolean = true }, int(100) },
    });
    // Case-insensitive names, as in openCypher.
    try expectQuery(&ast, &g, "MATCH (m:Movie {title: 'John Wick'}) RETURN TOUPPER(m.title), Size(Labels(m))", &.{
        &.{ string("JOHN WICK"), int(1) },
    });
}

test "entity functions check their argument's kind and existence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Static: fails on an empty graph too.
    try expectQueryError(&ast, &g, "MATCH (r) RETURN type(r)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH ()-[r]->() RETURN labels(r)", error.InvalidExpression);

    try expectQuery(&ast, &g, "CREATE (:Door {num: 1})", &.{});
    try expectQueryError(&ast, &g, "MATCH (d:Door) DELETE d RETURN labels(d)", error.InvalidExpression);
}
