//! CALL ... YIELD and the schema commands (CREATE / DROP / SHOW INDEXES).

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

fn expectParseError(ast: *Ast, src: []const u8) !void {
    try testing.expectError(error.UnexpectedToken, acmedb.parser.parse(ast, src, null));
}

fn string(text: []const u8) Value {
    return .{ .string = text };
}

test "CALL yields a procedure's columns, as variables or as the result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (:Person)-[:KNOWS]->(:Person:Admin)-[:WORKS_IN]->(:Team)", &.{});

    // Without YIELD, the procedure's rows are the result.
    try expectOrdered(&ast, &g, "CALL db.labels()", &.{ &.{string("Admin")}, &.{string("Person")}, &.{string("Team")} });
    try expectOrdered(&ast, &g, "CALL db.relationshipTypes", &.{ &.{string("KNOWS")}, &.{string("WORKS_IN")} });
    // YIELD with an alias and a WHERE, then the rest of the query.
    try expectQuery(&ast, &g, "CALL db.labels() YIELD label AS name WHERE name STARTS WITH 'P' RETURN name", &.{&.{string("Person")}});
    try expectQuery(&ast, &g, "CALL db.labels() YIELD label MATCH (n) WHERE label IN labels(n) RETURN label, count(n)", &.{
        &.{ string("Admin"), .{ .int = 1 } },
        &.{ string("Person"), .{ .int = 2 } },
        &.{ string("Team"), .{ .int = 1 } },
    });
    try expectQuery(&ast, &g, "MATCH (t:Team) CALL db.relationshipTypes() YIELD relationshipType RETURN count(*)", &.{&.{.{ .int = 2 }}});
    // A label nobody carries any more is not listed.
    try expectQuery(&ast, &g, "MATCH (t:Team) REMOVE t:Team", &.{});
    try expectQuery(&ast, &g, "CALL db.labels() YIELD label RETURN collect(label)", &.{&.{.{ .list = &.{ string("Admin"), string("Person") } }}});
    // In a query that writes.
    try expectQuery(&ast, &g, "CALL db.labels() YIELD label CREATE (:Note {about: label})", &.{});
    try expectQuery(&ast, &g, "MATCH (n:Note) RETURN count(n)", &.{&.{.{ .int = 2 }}});
    try expectOrdered(&ast, &g, "CALL db.index.fulltext.listAvailableAnalyzers() YIELD analyzer", &.{
        &.{string("standard")}, &.{string("english")}, &.{string("spanish")},
    });

    // Checked before the query runs.
    try expectQueryError(&ast, &g, "CALL db.nothing()", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.labels(1)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.labels() YIELD name RETURN name", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.labels() MATCH (n) RETURN n", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.index.fulltext.queryNodes('x', 'y') YIELD score MATCH (score)-->() RETURN 1", error.InvalidExpression);
    try expectParseError(&ast, "MATCH (n) CALL db.labels() YIELD label");
    try expectParseError(&ast, "CALL { MATCH (n) RETURN n } RETURN 1");
}

test "schema commands create, list and drop full-text indexes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE FULLTEXT INDEX documents FOR (d:Document|Note) ON EACH [d.title, d.body] OPTIONS {indexConfig: {`fulltext.analyzer`: 'spanish'}}", &.{});
    try expectQuery(&ast, &g, "CREATE FULLTEXT INDEX remarks IF NOT EXISTS FOR ()-[r:REVIEWED]-() ON EACH [r.comment]", &.{});
    try expectQuery(&ast, &g, "CREATE FULLTEXT INDEX remarks IF NOT EXISTS FOR ()-[r:OTHER]-() ON EACH [r.x]", &.{});

    const spanish = Value{ .map = &.{.{ .key = "indexConfig", .value = .{ .map = &.{.{ .key = "fulltext.analyzer", .value = string("spanish") }} } }} };
    const standard = Value{ .map = &.{.{ .key = "indexConfig", .value = .{ .map = &.{.{ .key = "fulltext.analyzer", .value = string("standard") }} } }} };
    try expectOrdered(&ast, &g, "SHOW FULLTEXT INDEXES", &.{
        &.{ string("documents"), string("FULLTEXT"), string("NODE"), .{ .list = &.{ string("Document"), string("Note") } }, .{ .list = &.{ string("title"), string("body") } }, spanish },
        &.{ string("remarks"), string("FULLTEXT"), string("RELATIONSHIP"), .{ .list = &.{string("REVIEWED")} }, .{ .list = &.{string("comment")} }, standard },
    });

    try expectQueryError(&ast, &g, "CREATE FULLTEXT INDEX documents FOR (n:X) ON EACH [n.y]", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CREATE FULLTEXT INDEX other FOR (n:X) ON EACH [n.y] OPTIONS {indexConfig: {`fulltext.analyzer`: 'klingon'}}", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CREATE FULLTEXT INDEX other FOR (n:X) ON EACH [n.y] OPTIONS {size: 3}", error.InvalidExpression);
    try expectParseError(&ast, "CREATE FULLTEXT INDEX FOR (n:X) ON EACH [n.y]");
    try expectParseError(&ast, "CREATE FULLTEXT INDEX other FOR (n:X) ON EACH [m.y]");
    try expectParseError(&ast, "CREATE INDEX other FOR (n:X) ON (n.y)");
    try expectParseError(&ast, "SHOW INDEXES RETURN 1");

    try expectQuery(&ast, &g, "DROP INDEX remarks", &.{});
    try expectQuery(&ast, &g, "DROP INDEX remarks IF EXISTS", &.{});
    try expectQueryError(&ast, &g, "DROP INDEX remarks", error.InvalidExpression);
    try expectQuery(&ast, &g, "SHOW INDEXES", &.{
        &.{ string("documents"), string("FULLTEXT"), string("NODE"), .{ .list = &.{ string("Document"), string("Note") } }, .{ .list = &.{ string("title"), string("body") } }, spanish },
    });
}

test "full-text search finds, ranks and follows changes to nodes and relationships" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Nodes that exist before the index are indexed when it is created.
    try expectQuery(&ast, &g,
        \\CREATE (:Doc {title: 'Contención biológica', body: 'Procedimiento de contención en el laboratorio BSL-3'}),
        \\       (:Doc {title: 'Animales', body: 'Cuidado de los animales del vivario'}),
        \\       (:Doc {title: 'CONTENCION', body: 'contención contención contención'}),
        \\       (:Note {title: 'Contención', body: 'no indexed label'})
    , &.{});
    try expectQuery(&ast, &g, "CREATE FULLTEXT INDEX docs FOR (d:Doc) ON EACH [d.title, d.body]", &.{});

    // Case and accents fold; more occurrences in a shorter text rank higher.
    try expectOrdered(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'Contencion') YIELD node, score RETURN node.title", &.{
        &.{string("CONTENCION")}, &.{string("Contención biológica")},
    });
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'contención') YIELD node, score WHERE score > 0 RETURN count(*)", &.{&.{.{ .int = 2 }}});
    // OR of the terms, by default.
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'animales laboratorio') YIELD node RETURN count(*)", &.{&.{.{ .int = 2 }}});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'inexistente') YIELD node RETURN count(*)", &.{&.{.{ .int = 0 }}});
    // skip and limit; the rest of the query.
    try expectOrdered(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'contencion', {skip: 1, limit: 5}) YIELD node RETURN node.title", &.{&.{string("Contención biológica")}});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'vivario') YIELD node MATCH (n:Doc) WHERE n = node RETURN n.title", &.{&.{string("Animales")}});

    // Changes keep the index current: properties, labels, deletions.
    try expectQuery(&ast, &g, "MATCH (d:Doc {title: 'Animales'}) SET d.body = 'Ratones y contención'", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'vivario') YIELD node RETURN count(*)", &.{&.{.{ .int = 0 }}});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'ratones') YIELD node RETURN node.title", &.{&.{string("Animales")}});
    try expectQuery(&ast, &g, "MATCH (n:Note) SET n:Doc", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'indexed') YIELD node RETURN node.title", &.{&.{string("Contención")}});
    try expectQuery(&ast, &g, "MATCH (n:Note) REMOVE n:Doc REMOVE n.title", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'indexed') YIELD node RETURN count(*)", &.{&.{.{ .int = 0 }}});
    try expectQuery(&ast, &g, "MATCH (d:Doc {title: 'CONTENCION'}) DETACH DELETE d", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'contencion') YIELD node RETURN count(*)", &.{&.{.{ .int = 2 }}});
    // Lists of strings are indexed as text; other values are not.
    try expectQuery(&ast, &g, "CREATE (:Doc {title: ['primer', 'segundo'], body: 42})", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'segundo') YIELD node RETURN count(*)", &.{&.{.{ .int = 1 }}});

    // Relationships.
    try expectQuery(&ast, &g, "MATCH (a:Doc {title: 'Animales'}), (b:Doc {title: 'Contención biológica'}) CREATE (a)-[:CITES {note: 'ver el protocolo de contención'}]->(b)", &.{});
    try expectQuery(&ast, &g, "CREATE FULLTEXT INDEX citations FOR ()-[r:CITES]-() ON EACH [r.note]", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryRelationships('citations', 'protocolo') YIELD relationship RETURN startNode(relationship).title, endNode(relationship).title", &.{
        &.{ string("Animales"), string("Contención biológica") },
    });
    try expectQuery(&ast, &g, "MATCH ()-[r:CITES]->() SET r.note = 'sin texto útil'", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryRelationships('citations', 'protocolo') YIELD relationship RETURN count(*)", &.{&.{.{ .int = 0 }}});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryRelationships('citations', 'util') YIELD relationship RETURN count(*)", &.{&.{.{ .int = 1 }}});
    try expectQuery(&ast, &g, "MATCH ()-[r:CITES]->() DELETE r", &.{});
    try expectQuery(&ast, &g, "CALL db.index.fulltext.queryRelationships('citations', 'util') YIELD relationship RETURN count(*)", &.{&.{.{ .int = 0 }}});

    // Wrong uses.
    try expectQueryError(&ast, &g, "CALL db.index.fulltext.queryNodes('nothing', 'x') YIELD node RETURN node", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.index.fulltext.queryNodes('citations', 'x') YIELD node RETURN node", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 1) YIELD node RETURN node", error.TypeMismatch);
    try expectQueryError(&ast, &g, "CALL db.index.fulltext.queryNodes('docs', 'x', {top: 1}) YIELD node RETURN node", error.InvalidExpression);

    // Dropping an index removes every key it had.
    try expectQuery(&ast, &g, "DROP INDEX docs", &.{});
    try expectQuery(&ast, &g, "DROP INDEX citations", &.{});
    for ([_][]const u8{ "wdocs\x00", "Wdocs\x00", "vdocs\x00", "Vdocs\x00", "wcitations\x00", "vcitations\x00" }) |prefix| {
        try testing.expectEqual(@as(usize, 0), try store.countPrefix(prefix));
    }
}
