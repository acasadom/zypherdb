//! Pattern matching: node and edge patterns, WHERE, joins and anchors.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;

const support = @import("../support.zig");
const openStore = support.openStore;
const loadMoviesGraph = support.loadMoviesGraph;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

test "runs the vertical-slice queries end to end" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born", &.{
        &.{.{ .int = 1964 }},
    });
    try expectQuery(&ast, &g, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title", &.{
        &.{.{ .string = "The Matrix" }},
        &.{.{ .string = "The Matrix Reloaded" }},
        &.{.{ .string = "John Wick" }},
    });
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title AS movie", &.{
        &.{.{ .string = "The Matrix Reloaded" }},
        &.{.{ .string = "John Wick" }},
    });
    try expectQuery(&ast, &g, "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name", &.{
        &.{.{ .string = "Keanu Reeves" }},
        &.{.{ .string = "Carrie-Anne Moss" }},
        &.{.{ .string = "Laurence Fishburne" }},
    });
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE p.name = 'Keanu Reeves' AND m.released > 2000 RETURN p.name, m.title", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .string = "The Matrix Reloaded" } },
        &.{ .{ .string = "Keanu Reeves" }, .{ .string = "John Wick" } },
    });
}

test "MATCH multi-pattern: join and shared variables" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // People with a KNOWS chain: A -> B -> C.
    try g.addNode(1, "Person");
    try g.setProperty(1, "name", .{ .string = "A" });
    try g.addNode(2, "Person");
    try g.setProperty(2, "name", .{ .string = "B" });
    try g.addNode(3, "Person");
    try g.setProperty(3, "name", .{ .string = "C" });
    try g.addEdge(1, 2, "KNOWS");
    try g.addEdge(2, 3, "KNOWS");

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Shared variable across two patterns: a 2-hop path A -> ? -> ?.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[:KNOWS]->(b), (b)-[:KNOWS]->(c) RETURN c.name", &.{
        &.{.{ .string = "C" }},
    });

    // Join two independent matched nodes and connect them.
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'}), (c:Person {name: 'C'}) CREATE (a)-[:KNOWS]->(c)", &.{});
    try expectQuery(&ast, &g, "MATCH (a:Person {name: 'A'})-[:KNOWS]->(c:Person) RETURN c.name", &.{
        &.{.{ .string = "B" }},
        &.{.{ .string = "C" }},
    });
}

test "edge-property index anchors unlabeled edge patterns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // Unlabeled nodes connected by a typed edge carrying a property.
    try g.addNode(1, "");
    try g.setProperty(1, "name", .{ .string = "A" });
    try g.addNode(2, "");
    try g.setProperty(2, "name", .{ .string = "B" });
    try g.addNode(3, "");
    try g.setProperty(3, "name", .{ .string = "C" });
    try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProperty(1, 2, "KNOWS", "weight", .{ .int = 5 });
    try g.addEdge(1, 3, "KNOWS");
    try g.setEdgeProperty(1, 3, "KNOWS", "weight", .{ .int = 9 });

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // The edge-property index anchors the match: only weight=5 edges match.
    try expectQuery(&ast, &g, "MATCH (a)-[r:KNOWS {weight: 5}]->(b) RETURN a.name, b.name", &.{
        &.{ .{ .string = "A" }, .{ .string = "B" } },
    });
}

test "unlabeled node patterns scan every node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:P {v: 1})", &.{});
    try expectQuery(&ast, &g, "CREATE (b {v: 2})", &.{});

    // MATCH without a label sees labeled and unlabeled nodes alike.
    try expectQuery(&ast, &g, "MATCH (n) RETURN n.v", &.{
        &.{.{ .int = 1 }},
        &.{.{ .int = 2 }},
    });
    try expectQuery(&ast, &g, "MATCH (n) WHERE n.v > 1 RETURN n.v", &.{
        &.{.{ .int = 2 }},
    });

    // A bare MERGE matches an existing node instead of creating a new one.
    try expectQuery(&ast, &g, "MERGE (n)", &.{});
    try expectQuery(&ast, &g, "MATCH (n) RETURN count(*)", &.{
        &.{.{ .int = 2 }},
    });
}

test "UTF-8 and quoted names round-trip through labels and properties" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:Pérsona {año: 1990, nombre: 'Ñandú'})-[:`TRABAJA EN`]->(z:`Zona Norte`)", &.{});
    try expectQuery(&ast, &g, "MATCH (p:Pérsona)-[:`TRABAJA EN`]->(z:`Zona Norte`) RETURN p.año, p.`nombre`", &.{
        &.{ .{ .int = 1990 }, .{ .string = "Ñandú" } },
    });
    // A quoted keyword is a plain name.
    try expectQuery(&ast, &g, "CREATE (n:`MATCH` {`count`: 3})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:`MATCH`) RETURN n.`count`", &.{
        &.{.{ .int = 3 }},
    });
}

test "string predicates and IN membership" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // STARTS WITH.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WHERE m.title STARTS WITH 'The' RETURN m.title", &.{
        &.{.{ .string = "The Matrix" }},
        &.{.{ .string = "The Matrix Reloaded" }},
    });

    // ENDS WITH.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WHERE m.title ENDS WITH 'Wick' RETURN m.title", &.{
        &.{.{ .string = "John Wick" }},
    });

    // CONTAINS.
    try expectQuery(&ast, &g, "MATCH (m:Movie) WHERE m.title CONTAINS 'Matrix' RETURN m.title", &.{
        &.{.{ .string = "The Matrix" }},
        &.{.{ .string = "The Matrix Reloaded" }},
    });

    // IN with strings.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.name IN ['Keanu Reeves', 'Tom Hanks'] RETURN p.name", &.{
        &.{.{ .string = "Keanu Reeves" }},
        &.{.{ .string = "Tom Hanks" }},
    });

    // IN with ints.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.born IN [1961, 1964] RETURN p.name", &.{
        &.{.{ .string = "Keanu Reeves" }},
        &.{.{ .string = "Laurence Fishburne" }},
    });

    // IN with no match.
    try expectQuery(&ast, &g, "MATCH (p:Person) WHERE p.name IN ['Nobody'] RETURN p.name", &.{});
}

test "untyped and undirected relationship patterns" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:P {n: 'a'})-[:KNOWS {w: 1}]->(b:P {n: 'b'}), (a)-[:OWNS {w: 2}]->(c:P {n: 'c'}), (c)-[:SELF {w: 3}]->(c)", &.{});

    // `-[r]->` without a type follows every type and binds the real edge.
    try expectQuery(&ast, &g, "MATCH (x {n: 'a'})-[r]->(y) RETURN y.n, r.w", &.{
        &.{ .{ .string = "b" }, .{ .int = 1 } },
        &.{ .{ .string = "c" }, .{ .int = 2 } },
    });
    try expectQuery(&ast, &g, "MATCH (x)-->(y) RETURN count(*)", &.{&.{.{ .int = 3 }}});
    try expectQuery(&ast, &g, "MATCH (x)<--(y {n: 'a'}) RETURN x.n", &.{
        &.{.{ .string = "b" }},
        &.{.{ .string = "c" }},
    });

    // Undirected: each edge both ways, a self-loop once.
    try expectQuery(&ast, &g, "MATCH (x {n: 'b'})--(y) RETURN y.n", &.{&.{.{ .string = "a" }}});
    try expectQuery(&ast, &g, "MATCH (x)-[r]-(y) RETURN count(*)", &.{&.{.{ .int = 5 }}});
    try expectQuery(&ast, &g, "MATCH (x {n: 'a'})-[r:OWNS]-(y) RETURN y.n", &.{&.{.{ .string = "c" }}});

    // Relationship uniqueness: a path never reuses an edge, so b--a--b is
    // not a match, but b--a--c is.
    try expectQuery(&ast, &g, "MATCH (x {n: 'b'})--(y)--(z) RETURN z.n", &.{&.{.{ .string = "c" }}});

    // A created relationship needs one type and a direction.
    try expectQueryError(&ast, &g, "CREATE (:P)-[:R]-(:P)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CREATE (:P)-->(:P)", error.InvalidExpression);
    // An undirected MERGE finds the edge in either direction.
    try expectQuery(&ast, &g, "MATCH (x {n: 'b'}), (y {n: 'a'}) MERGE (x)-[:KNOWS]-(y)", &.{});
    try expectQuery(&ast, &g, "MATCH ()-[r:KNOWS]->() RETURN count(*)", &.{&.{.{ .int = 1 }}});
}

test "variables keep their kind and their binding across clauses" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Static checks: they fail even on an empty graph.
    try expectQueryError(&ast, &g, "MATCH ()-[r]-()-[r]-() RETURN count(*)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (r)-[r]->() RETURN count(*)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "WITH 1 AS r MATCH ()-[r]-() RETURN count(*)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (n) WITH [n] AS users MATCH (users)-->(m) RETURN count(*)", error.InvalidExpression);

    try expectQuery(&ast, &g, "CREATE (a:A)-[:T {w: 1}]->(b:B), (a)-[:T {w: 2}]->(c:B)", &.{});
    // A bound node is checked against the new pattern's labels.
    try expectQuery(&ast, &g, "MATCH (a)-[r]->() WITH r, a MATCH (a:X)-[r]->(b) RETURN count(*)", &.{&.{.{ .int = 0 }}});
    try expectQuery(&ast, &g, "MATCH (a)-[r]->() WITH r, a MATCH (a:A)-[r]->(b) RETURN count(*)", &.{&.{.{ .int = 2 }}});
    // A bound relationship only matches itself, not every edge of its shape.
    try expectQuery(&ast, &g, "MATCH ()-[r {w: 1}]->() WITH r MATCH (a)-[r]->(b) RETURN r.w", &.{&.{.{ .int = 1 }}});
}

test "a missing property reads as null" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Door {name: 'D1', floor: 2})-[:IN]->(:Zone), (:Door {name: 'D2'})", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Door) RETURN d.name, d.floor", &.{
        &.{ .{ .string = "D1" }, .{ .int = 2 } },
        &.{ .{ .string = "D2" }, .{ .null = {} } },
    });
    // In WHERE a null comparison filters the row out.
    try expectQuery(&ast, &g, "MATCH (d:Door) WHERE d.floor > 1 RETURN d.name", &.{&.{.{ .string = "D1" }}});
    try expectQuery(&ast, &g, "MATCH ()-[r:IN]->() RETURN r.since", &.{&.{.{ .null = {} }}});
}
