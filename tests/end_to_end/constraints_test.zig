//! Declared indexes (CREATE INDEX, which changes nothing: every property is
//! indexed) and uniqueness constraints.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const Value = acmedb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectOrdered = support.expectOrdered;
const expectQueryError = support.expectQueryError;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn string(s: []const u8) Value {
    return .{ .string = s };
}

const no_options = Value{ .map = &.{.{ .key = "indexConfig", .value = .{ .map = &.{} } }} };

test "CREATE INDEX is recorded and listed, and changes no result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Card {number: 1}), (:Card {number: 2})", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX card_numbers FOR (c:Card) ON (c.number)", &.{});
    try expectQuery(&ast, &g, "CREATE RANGE INDEX IF NOT EXISTS FOR ()-[r:HELD_BY]-() ON (r.since, r.until)", &.{});
    try expectQuery(&ast, &g, "CREATE INDEX card_numbers IF NOT EXISTS FOR (c:Card) ON (c.other)", &.{});
    try expectOrdered(&ast, &g, "SHOW INDEXES", &.{
        &.{ string("card_numbers"), string("RANGE"), string("NODE"), .{ .list = &.{string("Card")} }, .{ .list = &.{string("number")} }, no_options },
        &.{ string("index_HELD_BY_since_until"), string("RANGE"), string("RELATIONSHIP"), .{ .list = &.{string("HELD_BY")} }, .{ .list = &.{ string("since"), string("until") } }, no_options },
    });
    try expectQuery(&ast, &g, "SHOW FULLTEXT INDEXES", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 2}) RETURN c.number", &.{&.{int(2)}});
    try expectQueryError(&ast, &g, "CREATE INDEX card_numbers FOR (c:Card) ON (c.number)", error.InvalidExpression);
    try expectQuery(&ast, &g, "DROP INDEX card_numbers", &.{});
    try expectQuery(&ast, &g, "DROP INDEX index_HELD_BY_since_until", &.{});
    try expectQuery(&ast, &g, "SHOW INDEXES", &.{});
}

test "a uniqueness constraint refuses duplicate values" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Card {number: 1}), (:Card {number: 2}), (:Badge {number: 1})", &.{});
    try expectQuery(&ast, &g, "CREATE CONSTRAINT card_number FOR (c:Card) REQUIRE c.number IS UNIQUE", &.{});
    try expectOrdered(&ast, &g, "SHOW CONSTRAINTS", &.{
        &.{ string("card_number"), string("UNIQUENESS"), string("NODE"), .{ .list = &.{string("Card")} }, .{ .list = &.{string("number")} } },
    });
    // A constraint is not an index.
    try expectQuery(&ast, &g, "SHOW INDEXES", &.{});

    // A duplicate by CREATE, SET or a new label fails, and nothing of the
    // query is written.
    try expectQueryError(&ast, &g, "CREATE (:Card {number: 3}), (:Card {number: 1})", error.ConstraintViolation);
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 3}) RETURN c", &.{});
    try expectQueryError(&ast, &g, "MATCH (c:Card {number: 2}) SET c.number = 1", error.ConstraintViolation);
    try expectQueryError(&ast, &g, "MATCH (b:Badge) SET b:Card", error.ConstraintViolation);
    try expectQuery(&ast, &g, "MATCH (c:Card) RETURN c.number ORDER BY c.number", &.{ &.{int(1)}, &.{int(2)} });
    // Other labels, other values and missing values are not concerned; MERGE
    // finds the existing node instead of making a duplicate.
    try expectQuery(&ast, &g, "CREATE (:Badge {number: 2}), (:Card {number: 3}), (:Card), (:Card)", &.{});
    try expectQuery(&ast, &g, "MERGE (c:Card {number: 1}) RETURN count(*)", &.{&.{int(1)}});
    try expectQuery(&ast, &g, "MATCH (c:Card) RETURN count(c)", &.{&.{int(5)}});
    // Changing a node's own value to itself, or freeing a value first, works.
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 3}) SET c.number = 3", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 3}) REMOVE c.number", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {number: 2}) SET c.number = 3", &.{});

    // It cannot be dropped as an index; dropped, duplicates are allowed again.
    try expectQueryError(&ast, &g, "DROP INDEX card_number", error.InvalidExpression);
    try expectQuery(&ast, &g, "DROP CONSTRAINT card_number", &.{});
    try expectQuery(&ast, &g, "CREATE (:Card {number: 1})", &.{});
    // A constraint the data already breaks is refused.
    try expectQueryError(&ast, &g, "CREATE CONSTRAINT FOR (c:Card) REQUIRE c.number IS UNIQUE", error.ConstraintViolation);
    try expectQuery(&ast, &g, "SHOW CONSTRAINTS", &.{});
}

test "a constraint on several properties, Neo4j 4's syntax, and what is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE CONSTRAINT IF NOT EXISTS FOR (d:Door) REQUIRE (d.building, d.number) IS UNIQUE", &.{});
    try expectQuery(&ast, &g, "CREATE (:Door {building: 'A', number: 1}), (:Door {building: 'B', number: 1}), (:Door {building: 'A', number: 2})", &.{});
    try expectQueryError(&ast, &g, "CREATE (:Door {building: 'B', number: 1})", error.ConstraintViolation);
    // Values compare as `=` does, on every property: 1 is 1.0.
    try expectQueryError(&ast, &g, "CREATE (:Door {building: 'B', number: 1.0})", error.ConstraintViolation);
    try expectQuery(&ast, &g, "CREATE CONSTRAINT person_id ON (p:Person) ASSERT p.id IS UNIQUE", &.{});
    try expectQuery(&ast, &g, "MATCH (n) RETURN count(n)", &.{&.{int(3)}});
    try expectOrdered(&ast, &g, "SHOW CONSTRAINTS", &.{
        &.{ string("constraint_Door_building_number"), string("UNIQUENESS"), string("NODE"), .{ .list = &.{string("Door")} }, .{ .list = &.{ string("building"), string("number") } } },
        &.{ string("person_id"), string("UNIQUENESS"), string("NODE"), .{ .list = &.{string("Person")} }, .{ .list = &.{string("id")} } },
    });
    // The graph API is held to it as well.
    try g.addNode(100, "Person");
    try g.setProperty(100, "id", .{ .int = 7 });
    try g.addNode(101, "Person");
    try testing.expectError(error.ConstraintViolation, g.setProperty(101, "id", .{ .int = 7 }));
    try testing.expect(std.mem.indexOf(u8, g.violationMessage(), "person_id") != null);

    const invalid = [_][]const u8{
        "CREATE CONSTRAINT FOR (p:Person) REQUIRE p.id IS NOT NULL",
        "CREATE CONSTRAINT FOR (p:Person) REQUIRE (p.a, p.b) IS NODE KEY",
        "CREATE CONSTRAINT FOR ()-[r:R]-() REQUIRE r.id IS UNIQUE",
        "CREATE CONSTRAINT FOR (p:A|B) REQUIRE p.id IS UNIQUE",
        "CREATE CONSTRAINT FOR (p:Person) REQUIRE q.id IS UNIQUE",
    };
    for (invalid) |query| try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(&ast, query, null));
}
