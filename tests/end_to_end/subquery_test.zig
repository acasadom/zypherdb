//! Subqueries: `EXISTS { ... }` and `COUNT { ... }` with a pattern or a whole
//! read-only query inside (MATCH, OPTIONAL MATCH, UNWIND, WITH, RETURN), the
//! scope they see and keep, and aggregates that belong to them.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const Value = acmedb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

fn string(s: []const u8) Value {
    return .{ .string = s };
}

fn boolean(b: bool) Value {
    return .{ .boolean = b };
}

/// Ana is in two groups, Bo in one, Cy in none; engineering may enter floor 3.
fn createGroups(ast: *Ast, g: *Graph) !void {
    try expectQuery(ast, g,
        \\CREATE (ana:Person {name: 'Ana', age: 40})-[:MEMBER_OF]->(eng:Group {name: 'engineering'}),
        \\       (ana)-[:MEMBER_OF]->(:Group {name: 'security'}),
        \\       (bo:Person {name: 'Bo', age: 25})-[:MEMBER_OF]->(:Group {name: 'visitors'}),
        \\       (eng)-[:MAY_ENTER]->(:Zone {name: 'floor 3'}), (:Person {name: 'Cy', age: 31})
    , &.{});
}

test "EXISTS runs a whole read-only query from the outer row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createGroups(&ast, &g);

    // WITH aggregates per outer row, and its WHERE filters the groups.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS {
        \\  MATCH (p)-[:MEMBER_OF]->(g)
        \\  WITH p, count(g) AS groups WHERE groups >= 2
        \\  RETURN true
        \\}
        \\RETURN p.name
    , &.{&.{string("Ana")}});
    // A RETURN that aggregates always has a row, even from no match.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS { MATCH (p)-[:MEMBER_OF]->(g) RETURN count(g) AS n }
        \\RETURN p.name ORDER BY p.name
    , &.{ &.{string("Ana")}, &.{string("Bo")}, &.{string("Cy")} });
    // UNWIND, a WITH that filters, and a LIMIT that keeps no row.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS { UNWIND [30, 35] AS age WITH age WHERE p.age > age RETURN age }
        \\RETURN p.name ORDER BY p.name
    , &.{ &.{string("Ana")}, &.{string("Cy")} });
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE EXISTS { MATCH (p)-->(g) RETURN g LIMIT 0 } RETURN p.name", &.{});
    // OPTIONAL MATCH keeps the row; the WHERE after it decides.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS {
        \\  OPTIONAL MATCH (p)-[:MEMBER_OF]->(g)
        \\  WITH g WHERE g IS NULL
        \\  RETURN 1
        \\}
        \\RETURN p.name
    , &.{&.{string("Cy")}});
    // Two MATCHes, nested EXISTS, and EXISTS as a returned value.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE EXISTS {
        \\  MATCH (p)-->(g) WHERE EXISTS { MATCH (g)-[:MAY_ENTER]->(z) RETURN z }
        \\}
        \\RETURN p.name
    , &.{&.{string("Ana")}});
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\RETURN p.name, EXISTS { MATCH (p)-->(g) WITH count(*) AS n WHERE n > 1 RETURN n } AS busy
        \\ORDER BY p.name
    , &.{ &.{ string("Ana"), boolean(true) }, &.{ string("Bo"), boolean(false) }, &.{ string("Cy"), boolean(false) } });
}

test "an EXISTS subquery's aggregates and variables stay inside it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createGroups(&ast, &g);

    // The outer RETURN does not aggregate because the subquery does: one
    // row per person, not one group.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\RETURN count(*) AS people, sum(CASE WHEN EXISTS { MATCH (p)-->(g) RETURN count(g) AS n } THEN 1 ELSE 0 END) AS counted
    , &.{&.{ .{ .int = 3 }, .{ .int = 3 } }});
    // A variable the subquery binds is unknown after it.
    try expectQueryError(&ast, &g, "MATCH (p:Person) WHERE EXISTS { MATCH (p)-->(g) RETURN g } RETURN g", error.InvalidExpression);
    // A WITH inside it hides the outer variables it does not project.
    try expectQueryError(&ast, &g, "MATCH (p:Person) WHERE EXISTS { MATCH (p)-->(g) WITH g RETURN p } RETURN p", error.InvalidExpression);
    // Writing is not allowed in it.
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (p) WHERE EXISTS { MATCH (p)-->(g) SET g.seen = true } RETURN p", null));
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (p) WHERE EXISTS { CREATE (x) } RETURN p", null));
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (p) WHERE EXISTS { } RETURN p", null));
    // Nothing above wrote.
    try expectQuery(&ast, &g, "MATCH (n) WHERE n.seen IS NOT NULL RETURN n", &.{});
}

test "COUNT counts the rows of a pattern or a read-only subquery" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createGroups(&ast, &g);

    const int = struct {
        fn of(n: i64) Value {
            return .{ .int = n };
        }
    }.of;
    // The short form: a pattern, with an optional WHERE.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) RETURN p.name, COUNT { (p)-[:MEMBER_OF]->() } AS groups ORDER BY p.name
    , &.{ &.{ string("Ana"), int(2) }, &.{ string("Bo"), int(1) }, &.{ string("Cy"), int(0) } });
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) WHERE COUNT { (p)-->(g) WHERE g.name <> 'security' } = 1 RETURN p.name ORDER BY p.name
    , &.{ &.{string("Ana")}, &.{string("Bo")} });
    // A whole subquery: its rows after UNWIND, WITH DISTINCT and RETURN.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person {name: 'Ana'})
        \\RETURN COUNT { MATCH (p)-->(g) UNWIND [g.name, g.name] AS name RETURN DISTINCT name } AS names
    , &.{&.{int(2)}});
    // `count(...)` stays the aggregate; COUNT { } is per row, so it can be a grouping key.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person) RETURN COUNT { (p)-->() } AS groups, count(*) AS people ORDER BY groups
    , &.{ &.{ int(0), int(1) }, &.{ int(1), int(1) }, &.{ int(2), int(1) } });
}

test "CALL { } runs a subquery per row: imports, returned columns, writes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createGroups(&ast, &g);

    const int = struct {
        fn of(n: i64) Value {
            return .{ .int = n };
        }
    }.of;
    // An importing WITH brings the row's variables in; RETURN's columns
    // extend the row, one row per returned row (none: the row is gone).
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\CALL { WITH p MATCH (p)-[:MEMBER_OF]->(g) RETURN g.name AS group }
        \\RETURN p.name, group ORDER BY p.name, group
    , &.{ &.{ string("Ana"), string("engineering") }, &.{ string("Ana"), string("security") }, &.{ string("Bo"), string("visitors") } });
    // An aggregate per row, and the scope form CALL (p) { ... }.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\CALL (p) { MATCH (p)-[:MEMBER_OF]->(g) RETURN count(g) AS groups }
        \\RETURN p.name, groups ORDER BY p.name
    , &.{ &.{ string("Ana"), int(2) }, &.{ string("Bo"), int(1) }, &.{ string("Cy"), int(0) } });
    // Without an import it sees nothing from outside: it runs on its own,
    // once per row.
    try expectQuery(&ast, &g,
        \\UNWIND [1, 2] AS i
        \\CALL { MATCH (z:Zone) RETURN z.name AS zone }
        \\RETURN i, zone
    , &.{ &.{ int(1), string("floor 3") }, &.{ int(2), string("floor 3") } });
    // Its `p` is not the outer one: 3 people × the 4 relationships.
    try expectQuery(&ast, &g, "MATCH (p:Person) CALL { MATCH (p)-->(g) RETURN g AS x } RETURN count(x)", &.{&.{int(12)}});
    // A subquery without RETURN writes, and the row goes on once; each row
    // sees what the rows before it wrote.
    try expectQuery(&ast, &g,
        \\MATCH (p:Person)
        \\CALL { WITH p CREATE (:Badge {owner: p.name}) }
        \\RETURN count(*) AS people
    , &.{&.{int(3)}});
    try expectQuery(&ast, &g, "MATCH (b:Badge) RETURN count(b)", &.{&.{int(3)}});
    try expectQuery(&ast, &g,
        \\UNWIND [1, 2, 3] AS i
        \\CALL { MATCH (b:Badge) WITH count(b) AS badges CREATE (:Badge {owner: 'extra', seen: badges}) }
        \\WITH i MATCH (b:Badge {owner: 'extra'}) RETURN b.seen ORDER BY b.seen
    , &.{ &.{int(3)}, &.{int(4)}, &.{int(5)}, &.{int(3)}, &.{int(4)}, &.{int(5)}, &.{int(3)}, &.{int(4)}, &.{int(5)} });
    // A query may end with a CALL that writes.
    try expectQuery(&ast, &g, "MATCH (b:Badge {owner: 'extra'}) CALL { WITH b DETACH DELETE b }", &.{});
    try expectQuery(&ast, &g, "MATCH (b:Badge {owner: 'extra'}) RETURN count(b)", &.{&.{int(0)}});

    // What cannot be right fails before it runs.
    const invalid = [_][]const u8{
        "MATCH (p:Person) CALL { WITH p RETURN p } RETURN p", // p is already bound
        "CALL { MATCH (n) RETURN n.name } RETURN 1", // a returned expression needs an alias
        "CALL { MATCH (n) RETURN n AS m } RETURN n", // n stays inside
    };
    for (invalid) |query| try expectQueryError(&ast, &g, query, error.InvalidExpression);
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "CALL { MATCH (n) } RETURN 1", null));
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, "MATCH (n) WHERE EXISTS { CALL { CREATE (x) } } RETURN n", null));
}
