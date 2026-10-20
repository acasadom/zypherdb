//! Write clauses: CREATE, MERGE, SET, DELETE and REMOVE.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

test "write clauses: CREATE, SET and DELETE" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // CREATE a node, then read it back.
    try expectQuery(&ast, &g, "CREATE (n:Person {name: 'Neo', born: 1964})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) RETURN n.born", &.{
        &.{.{ .int = 1964 }},
    });

    // SET a property.
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) SET n.born = 1970", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) RETURN n.born", &.{
        &.{.{ .int = 1970 }},
    });

    // CREATE two nodes + an edge in one statement.
    try expectQuery(&ast, &g, "CREATE (a:Person {name: 'X'})-[:KNOWS]->(b:Person {name: 'Y'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'X'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .string = "Y" }},
    });

    // MATCH + CREATE: bind an existing node, create a new one + edge.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'X'}) CREATE (a)-[:KNOWS]->(b:Person {name: 'Z'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'X'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .string = "Y" }},
        &.{.{ .string = "Z" }},
    });

    // DELETE a node (detach).
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) DELETE n", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Neo'}) RETURN n.name", &.{});
}

test "MERGE gets-or-creates nodes and edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try g.addNode(1, "Person");
    try g.setProperty(1, "name", .{ .string = "Keanu Reeves" });
    try g.setProperty(1, "born", .{ .int = 1964 });

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // MERGE an existing node twice -> still exactly one.
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'Keanu Reeves'})", &.{});
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'Keanu Reeves'})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Keanu Reeves'}) RETURN n.name", &.{
        &.{.{ .string = "Keanu Reeves" }},
    });

    // MERGE a brand-new node -> created.
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'Zorg', born: 1900})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'Zorg'}) RETURN n.born", &.{
        &.{.{ .int = 1900 }},
    });

    // MERGE an edge (get-or-create), then again -> still one edge.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'}) MERGE (a)-[:KNOWS]->(b:Person {name: 'Zorg'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .string = "Zorg" }},
    });
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'}) MERGE (a)-[:KNOWS]->(b:Person {name: 'Zorg'})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'Keanu Reeves'})-[:KNOWS]->(b:Person) RETURN b.name", &.{
        &.{.{ .string = "Zorg" }},
    });
}

test "relationship properties: CREATE, MATCH, SET and WHERE" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // CREATE an edge with a property.
    try expectQuery(&ast, &g, "CREATE (a:Person {name: 'A'})-[:KNOWS {weight: 5}]->(b:Person {name: 'B'})", &.{});

    // Read the relationship property.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) RETURN r.weight", &.{
        &.{.{ .int = 5 }},
    });

    // WHERE on a relationship property.
    try expectQuery(&ast, &g, "MATCH (a:Person)-[r:KNOWS]->(b:Person) WHERE r.weight > 3 RETURN b.name", &.{
        &.{.{ .string = "B" }},
    });

    // SET a relationship property.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) SET r.weight = 10", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS]->(b:Person {name: 'B'}) RETURN r.weight", &.{
        &.{.{ .int = 10 }},
    });

    // Inline relationship property filter.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[r:KNOWS {weight: 10}]->(b:Person) RETURN b.name", &.{
        &.{.{ .string = "B" }},
    });
}

test "DELETE fails on connected nodes; DETACH DELETE removes edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:Person {name: 'A'})-[:KNOWS]->(b:Person {name: 'B'})", &.{});

    // Plain DELETE fails because 'A' still has a relationship.
    try expectQueryError(&ast, &g, "MATCH (a:Person {name: 'A'}) DELETE a", error.NodeStillConnected);
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}) RETURN a.name", &.{
        &.{.{ .string = "A" }},
    });

    // DETACH DELETE removes 'A' and its relationship.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}) DETACH DELETE a", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}) RETURN a.name", &.{});
    try expectQuery(&ast, &g, "MATCH (b:Person {name: 'B'}) RETURN b.name", &.{
        &.{.{ .string = "B" }},
    });
}

test "multi-label, REMOVE, CASE and MERGE ON CREATE/MATCH" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Multi-label: a node carries both labels; matching requires all of them.
    try expectQuery(&ast, &g, "CREATE (n:Person:Employee {name: 'A'})", &.{});
    try expectQuery(&ast, &g, "CREATE (m:Person {name: 'B'})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person:Employee) RETURN n.name", &.{
        &.{.{ .string = "A" }},
    });
    try expectQuery(&ast, &g, "MATCH (n:Employee) RETURN n.name", &.{
        &.{.{ .string = "A" }},
    });
    try expectQuery(&ast, &g, "MATCH (n:Person) RETURN n.name", &.{
        &.{.{ .string = "A" }},
        &.{.{ .string = "B" }},
    });

    // REMOVE a label.
    try expectQuery(&ast, &g, "MATCH (n:Person:Employee) REMOVE n:Employee", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Employee) RETURN n.name", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person) RETURN n.name", &.{
        &.{.{ .string = "A" }},
        &.{.{ .string = "B" }},
    });

    // REMOVE a property (and its index entry).
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'A'}) REMOVE n.name", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'A'}) RETURN n.name", &.{});

    // CASE expression.
    try expectQuery(&ast, &g, "RETURN CASE WHEN 1 > 0 THEN 'yes' ELSE 'no' END", &.{
        &.{.{ .string = "yes" }},
    });

    // MERGE ON CREATE / ON MATCH SET.
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'X'}) ON CREATE SET n.c = 1 ON MATCH SET n.m = 1", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'X'}) RETURN n.c", &.{
        &.{.{ .int = 1 }},
    });
    try expectQuery(&ast, &g, "MERGE (n:Person {name: 'X'}) ON CREATE SET n.c = 2 ON MATCH SET n.m = 1", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Person {name: 'X'}) RETURN n.m", &.{
        &.{.{ .int = 1 }},
    });
}

test "CREATE and MERGE write anonymous nodes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // A node without a variable is still created.
    try expectQuery(&ast, &g, "CREATE (:Door {name: 'D1'})", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Door) RETURN d.name", &.{
        &.{.{ .string = "D1" }},
    });

    // Anonymous endpoints of a chain get their edges.
    try expectQuery(&ast, &g, "CREATE (:Zone {name: 'Z1'})-[:HAS]->(:Door {name: 'D2'})", &.{});
    try expectQuery(&ast, &g, "MATCH (z:Zone)-[:HAS]->(d:Door) RETURN z.name, d.name", &.{
        &.{ .{ .string = "Z1" }, .{ .string = "D2" } },
    });

    // An anonymous MERGE matches the existing node instead of duplicating it.
    try expectQuery(&ast, &g, "MERGE (:Door {name: 'D1'})", &.{});
    try expectQuery(&ast, &g, "MERGE (:Door {name: 'D3'})", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Door) RETURN count(*)", &.{
        &.{.{ .int = 3 }},
    });
}

test "boolean and list properties are stored, null removes, mixed lists are refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Booleans round-trip and are indexed (an inline property is a seek).
    try expectQuery(&ast, &g, "CREATE (:Card {active: true, code: 1})", &.{});
    try expectQuery(&ast, &g, "CREATE (:Card {active: false, code: 2})", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {active: true}) RETURN c.code, c.active", &.{
        &.{ .{ .int = 1 }, .{ .boolean = true } },
    });

    // Setting a property to null removes it.
    try expectQuery(&ast, &g, "MATCH (c:Card {code: 1}) SET c.active = null", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card) WHERE c.code = 1 RETURN count(*)", &.{
        &.{.{ .int = 1 }},
    });
    try expectQuery(&ast, &g, "MATCH (c:Card {active: true}) RETURN count(*)", &.{
        &.{.{ .int = 0 }},
    });

    // A list of one type is stored (and indexed); a mixed list is refused
    // with an error instead of aborting the process.
    try expectQuery(&ast, &g, "MATCH (c:Card {code: 2}) SET c.tags = [1, 2.5], c.names = ['a', 'b']", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card {tags: [1, 2.5]}) RETURN c.tags, c.names", &.{
        &.{ .{ .list = &.{ .{ .int = 1 }, .{ .float = 2.5 } } }, .{ .list = &.{ .{ .string = "a" }, .{ .string = "b" } } } },
    });
    try expectQueryError(&ast, &g, "MATCH (c:Card {code: 2}) SET c.tags = [1, 'a']", error.UnsupportedPropertyType);
}

test "map properties hold documents and filter by their fields (an extension)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\CREATE (:Card {id: 1, holder: {name: 'Ana', address: {city: 'Madrid'}, phones: ['600', null, 7]}}),
        \\       (:Card {id: 2, holder: {name: 'Bo', address: {city: 'Lugo'}}})
    , &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card) WHERE c.holder.address.city = 'Madrid' RETURN c.id, c.holder.phones[2], c.holder['name']", &.{
        &.{ .{ .int = 1 }, .{ .int = 7 }, .{ .string = "Ana" } },
    });
    // A whole document is found by equality, whatever order its keys are written in.
    try expectQuery(&ast, &g, "MATCH (c:Card {holder: {address: {city: 'Lugo'}, name: 'Bo'}}) RETURN c.id", &.{&.{.{ .int = 2 }}});
    try expectQuery(&ast, &g, "MATCH (c:Card {id: 2}) SET c.holder = {name: c.holder.name, badge: 42} RETURN c.holder", &.{
        &.{.{ .map = &.{ .{ .key = "badge", .value = .{ .int = 42 } }, .{ .key = "name", .value = .{ .string = "Bo" } } } }},
    });
    // Graph entities cannot be stored inside a document.
    try expectQueryError(&ast, &g, "MATCH (c:Card {id: 1}) SET c.holder = {card: c}", error.UnsupportedPropertyType);
}

test "null property values: MATCH finds nothing, MERGE is refused" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Door {num: 1})", &.{});
    // An inline null (an index lookup) and a list match nothing; neither aborts.
    try expectQuery(&ast, &g, "MATCH (d {num: null}) RETURN count(*)", &.{
        &.{.{ .int = 0 }},
    });
    try expectQuery(&ast, &g, "MATCH (d {num: [1]}) RETURN count(*)", &.{
        &.{.{ .int = 0 }},
    });
    try expectQueryError(&ast, &g, "MERGE ({num: null})", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (a:Door) MERGE (a)-[:R {since: null}]->(b:Door)", error.InvalidExpression);
}

test "CREATE with several patterns shares their variables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (z:Zone {name: 'Z'}), (d:Door {name: 'D'}), (z)-[:HAS]->(d), (:Door {name: 'E'})", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Door) RETURN count(*)", &.{
        &.{.{ .int = 2 }},
    });
    try expectQuery(&ast, &g, "MATCH (z:Zone)-[:HAS]->(d:Door) RETURN z.name, d.name", &.{
        &.{ .{ .string = "Z" }, .{ .string = "D" } },
    });
}

test "CREATE refuses to re-create a bound node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQueryError(&ast, &g, "CREATE (n:Foo)-[:T1]->(), (n:Bar)-[:T2]->()", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CREATE (n), (n {name: 'x'})-[:T]->()", error.InvalidExpression);
    try expectQuery(&ast, &g, "CREATE (n:Foo)", &.{});
    try expectQueryError(&ast, &g, "MATCH (a:Foo) CREATE (a)", error.InvalidExpression);
    // Reusing a bound node as an endpoint is fine.
    try expectQuery(&ast, &g, "MATCH (a:Foo) CREATE (a)-[:T]->(:Bar)", &.{});
    try expectQuery(&ast, &g, "MATCH (:Foo)-[:T]->(b:Bar) RETURN count(*)", &.{
        &.{.{ .int = 1 }},
    });
}

test "reading a property of an entity the query deleted is an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Door {num: 1})-[:IN {num: 2}]->(:Zone)", &.{});
    try expectQueryError(&ast, &g, "MATCH (d:Door) DETACH DELETE d RETURN d.num", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH ()-[r:IN]->() DELETE r RETURN r.num", error.InvalidExpression);
}

test "DELETE removes relationships and ignores null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:Door)-[:IN {since: 1}]->(z:Zone), (a)-[:NEAR]->(z)", &.{});
    try expectQuery(&ast, &g, "MATCH ()-[r:IN]->() DELETE r", &.{});
    try expectQuery(&ast, &g, "MATCH ()-[r]->() RETURN count(*)", &.{&.{.{ .int = 1 }}});
    // The deleted relationship's property index entry is gone too.
    try expectQuery(&ast, &g, "MATCH ()-[r {since: 1}]->() RETURN count(*)", &.{&.{.{ .int = 0 }}});
    // The nodes are now deletable once their last relationship goes.
    try expectQuery(&ast, &g, "MATCH ()-[r:NEAR]->() DELETE r", &.{});
    try expectQuery(&ast, &g, "MATCH (n) DELETE n", &.{});
    try expectQuery(&ast, &g, "MATCH (n) RETURN count(*)", &.{&.{.{ .int = 0 }}});
    try expectQuery(&ast, &g, "OPTIONAL MATCH (n:Missing) DELETE n RETURN n", &.{&.{.{ .null = {} }}});
}

test "SET n = map, SET n += map and SET n:Label" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Card {id: 1, holder: 'Ana', pin: 1234})", &.{});
    // += merges: new keys added, existing ones overwritten, null removes.
    try expectQuery(&ast, &g, "MATCH (c:Card) SET c += {holder: 'Bo', active: true, pin: null}", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card) RETURN properties(c)", &.{&.{.{ .map = &.{
        .{ .key = "active", .value = .{ .boolean = true } },
        .{ .key = "holder", .value = .{ .string = "Bo" } },
        .{ .key = "id", .value = .{ .int = 1 } },
    } }}});
    // = replaces every property.
    try expectQuery(&ast, &g, "MATCH (c:Card) SET c = {id: 2}", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card) RETURN properties(c)", &.{&.{.{ .map = &.{.{ .key = "id", .value = .{ .int = 2 } }} }}});
    // Labels, and SET on null (from OPTIONAL MATCH) does nothing.
    try expectQuery(&ast, &g, "MATCH (c:Card) SET c:Blocked:Audited", &.{});
    try expectQuery(&ast, &g, "MATCH (c:Card:Blocked:Audited) RETURN c.id", &.{&.{.{ .int = 2 }}});
    try expectQuery(&ast, &g, "OPTIONAL MATCH (x:Missing) SET x += {a: 1}, x.b = 2", &.{});
}

test "write targets are expressions; nulls are ignored; MERGE takes its ON clauses in any order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:A:B:C {n: 1})-[:R]->(:A {n: 2})-[:R]->(:A {n: 3})", &.{});
    try expectQuery(&ast, &g, "MATCH (a:A {n: 1}) SET (a).name = 'one' REMOVE a:B:C RETURN a.name, labels(a)", &.{
        &.{ .{ .string = "one" }, .{ .list = &.{.{ .string = "A" }} } },
    });
    // On null (an OPTIONAL MATCH that found nothing), SET and REMOVE do nothing.
    try expectQuery(&ast, &g, "OPTIONAL MATCH (x:Nothing) SET x.n = 1, x:L REMOVE x.n, x:L RETURN x", &.{&.{.null}});
    // MERGE: ON MATCH and ON CREATE in any order.
    try expectQuery(&ast, &g, "MERGE (m:M) ON MATCH SET m.seen = true ON CREATE SET m.created = true RETURN m.created, m.seen", &.{&.{ .{ .boolean = true }, .null }});
    try expectQuery(&ast, &g, "MERGE (m:M) ON MATCH SET m.seen = true ON CREATE SET m.created = false RETURN m.created, m.seen", &.{&.{ .{ .boolean = true }, .{ .boolean = true } }});
    // DELETE takes expressions: list elements, map values, whole paths.
    try expectQuery(&ast, &g, "MATCH ()-[r:R]->() WITH collect(r) AS rs DELETE rs[0]", &.{});
    try expectQuery(&ast, &g, "MATCH ()-[r]->() RETURN count(r)", &.{&.{.{ .int = 1 }}});
    try expectQuery(&ast, &g, "MATCH p = (:A {n: 2})-[:R]->(:A {n: 3}) WITH {path: p} AS m DELETE m.path", &.{});
    try expectQuery(&ast, &g, "MATCH (a:A) RETURN collect(a.n)", &.{&.{.{ .list = &.{.{ .int = 1 }} }}});
    try expectQueryError(&ast, &g, "MATCH (a) DELETE a:A", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (a) DELETE 1 + 1", error.InvalidExpression);
}
