//! The printer: an expression parsed and printed again reads as canonical
//! Cypher (EXPLAIN shows operators' details this way).

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;

/// Parses `RETURN expression` and prints the expression back.
fn expectPrinted(expression: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ast = Ast.init(arena.allocator());
    const source = try std.fmt.allocPrint(arena.allocator(), "RETURN {s}", .{expression});
    const query = try acmedb.parser.parse(&ast, source, null);
    const return_clause = ast.nodeChildren(query)[0];
    const item = ast.nodeChildren(ast.nodeChildren(return_clause)[0])[0];
    const printed = try acmedb.printer.text(&ast, arena.allocator(), ast.nodeChildren(item)[0]);
    try testing.expectEqualStrings(expected, printed);
}

test "prints literals, parameters and property access" {
    try expectPrinted("1", "1");
    try expectPrinted("2.5", "2.5");
    try expectPrinted("'it\\'s'", "'it\\'s'");
    try expectPrinted("\"a\\\\b\"", "'a\\\\b'");
    try expectPrinted("true", "true");
    try expectPrinted("null", "null");
    try expectPrinted("$card", "$card");
    try expectPrinted("[1, 2, [3]]", "[1, 2, [3]]");
    try expectPrinted("{name: 'Ana', age: 30}", "{name: 'Ana', age: 30}");
}

test "prints operators with parentheses only where precedence needs them" {
    try expectPrinted("1 + 2 * 3", "1 + 2 * 3");
    try expectPrinted("(1 + 2) * 3", "(1 + 2) * 3");
    try expectPrinted("1 - (2 - 3)", "1 - (2 - 3)");
    try expectPrinted("$a.x > 1 AND $b.y < 2 OR NOT $c", "$a.x > 1 AND $b.y < 2 OR NOT $c");
    try expectPrinted("($a OR $b) AND $c", "($a OR $b) AND $c");
    try expectPrinted("$n.name STARTS WITH 'A'", "$n.name STARTS WITH 'A'");
    try expectPrinted("$x IS NOT NULL", "$x IS NOT NULL");
    try expectPrinted("-$x ^ 2", "-$x ^ 2");
    try expectPrinted("$s =~ 'a.*'", "$s =~ 'a.*'");
}

test "prints calls, aggregates, comprehensions and CASE" {
    try expectPrinted("toUpper('a')", "toUpper('a')");
    try expectPrinted("count(*)", "count(*)");
    try expectPrinted("count(DISTINCT $x)", "count(DISTINCT $x)");
    try expectPrinted("[x IN range(1, 10) WHERE x % 2 = 0 | x * x]", "[x IN range(1, 10) WHERE x % 2 = 0 | x * x]");
    try expectPrinted("[x IN [1, 2]]", "[x IN [1, 2]]");
    try expectPrinted("any(x IN [1, 2] WHERE x > 1)", "any(x IN [1, 2] WHERE x > 1)");
    try expectPrinted("CASE WHEN $a THEN 1 ELSE 2 END", "CASE WHEN $a THEN 1 ELSE 2 END");
    try expectPrinted("CASE $a WHEN 1 THEN 'one' END", "CASE $a WHEN 1 THEN 'one' END");
    try expectPrinted("[1, 2, 3][1..]", "[1, 2, 3][1..]");
    try expectPrinted("$list[0]", "$list[0]");
}

test "prints patterns, with quoted names where needed" {
    try expectPrinted("[(a:Person {id: 1})-[:KNOWS*1..3]->(b) WHERE b.age > 3 | b.name]", "[(a:Person {id: 1})-[:KNOWS*..3]->(b) WHERE b.age > 3 | b.name]");
    try expectPrinted("[(a)<-[r:`TYPE WITH SPACE`|OTHER]-() | r]", "[(a)<-[r:`TYPE WITH SPACE`|OTHER]-() | r]");
    try expectPrinted("[(a)-[*2]-(b) | b]", "[(a)-[*2]-(b) | b]");
    try expectPrinted("[(a)-->(b) | b]", "[(a)-->(b) | b]");
    try expectPrinted("EXISTS { MATCH (n) RETURN n }", "EXISTS {…}");
}
