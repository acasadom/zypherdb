//! Vector indexes through Cypher: CREATE VECTOR INDEX, kept current by every
//! write, queried with db.index.vector.queryNodes / queryRelationships,
//! refusing what is not a vector, listed and dropped; and the
//! vector.similarity functions.

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

fn string(s: []const u8) Value {
    return .{ .string = s };
}

fn expectSound(g: *Graph) !void {
    var report = try zypherdb.integrity.check(g, testing.allocator);
    defer report.deinit();
    for (report.problems.items) |problem| std.debug.print("integrity: {s}\n", .{problem});
    try testing.expect(report.ok());
}

const Fixture = struct {
    tmp: testing.TmpDir,
    path_buffer: [256]u8 = undefined,
    store: zypherdb.KeyValueStore = undefined,
    graph: Graph = undefined,
    ast: Ast = undefined,

    fn init(self: *Fixture) !void {
        self.tmp = testing.tmpDir(.{});
        self.store = try openStore(&self.tmp, &self.path_buffer);
        self.graph = Graph.init(&self.store, testing.allocator);
        self.ast = Ast.init(testing.allocator);
    }

    fn deinit(self: *Fixture) void {
        self.ast.deinit();
        self.store.deinit();
        self.tmp.cleanup();
    }
};

test "a node index: built from what is there, kept current, queried best first" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try expectQuery(ast, g,
        \\CREATE (:Doc {name: 'east', v: [1.0, 0.0]}), (:Doc {name: 'north', v: [0, 1]}),
        \\       (:Doc {name: 'west', v: [-1.0, 0.0]}), (:Other {v: [1.0, 0.0]}), (:Doc {name: 'none'})
    , &.{});
    try expectQuery(ast, g,
        \\CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v
        \\OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'cosine'}}
    , &.{});
    try expectOrdered(ast, g, "CALL db.index.vector.queryNodes('docs', 3, [1.0, 0.1]) YIELD node, score RETURN node.name", &.{
        &.{string("east")}, &.{string("north")}, &.{string("west")},
    });
    try expectOrdered(ast, g, "CALL db.index.vector.queryNodes('docs', 1, [0, 3]) YIELD node, score RETURN node.name, score", &.{
        &.{ string("north"), float(1) },
    });

    // Moved, removed, added, relabelled: the index follows.
    try expectQuery(ast, g, "MATCH (d:Doc {name: 'west'}) SET d.v = [0.9, 0.0]", &.{});
    try expectQuery(ast, g, "MATCH (d:Doc {name: 'east'}) REMOVE d.v", &.{});
    try expectQuery(ast, g, "MATCH (o:Other) SET o:Doc, o.name = 'other'", &.{});
    try expectQuery(ast, g, "MATCH (d:Doc {name: 'north'}) DETACH DELETE d", &.{});
    try expectOrdered(ast, g, "CALL db.index.vector.queryNodes('docs', 5, [1, 0]) YIELD node RETURN node.name", &.{
        // Both point east: ties go by id.
        &.{string("west")}, &.{string("other")},
    });
    try expectSound(g);

    const config = [_]zypherdb.value.MapEntry{
        .{ .key = "vector.dimensions", .value = int(2) },
        .{ .key = "vector.similarity_function", .value = string("cosine") },
    };
    const options = [_]zypherdb.value.MapEntry{.{ .key = "indexConfig", .value = .{ .map = &config } }};
    try expectQuery(ast, g, "SHOW VECTOR INDEXES", &.{&.{
        string("docs"),                 string("VECTOR"),             string("NODE"),
        .{ .list = &.{string("Doc")} }, .{ .list = &.{string("v")} }, .null,
        .{ .map = &options },
    }});
    try expectQuery(ast, g, "SHOW RANGE INDEXES", &.{});
    try expectQuery(ast, g, "DROP INDEX docs", &.{});
    try testing.expectEqual(@as(usize, 0), try g.store.countPrefix(&.{zypherdb.vector.index.marker}));
    try expectSound(g);
}

test "euclidean scores, relationships" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try expectQuery(ast, g, "CREATE VECTOR INDEX links FOR ()-[r:LINK]-() ON (r.v) OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'EUCLIDEAN'}}", &.{});
    try expectQuery(ast, g, "CREATE (a)-[:LINK {w: 1, v: [0, 0]}]->(b), (a)-[:LINK {w: 2, v: [0, 2]}]->(b), (a)-[:OTHER {v: [0, 0]}]->(b)", &.{});
    try expectOrdered(ast, g, "CALL db.index.vector.queryRelationships('links', 10, [0, 0]) YIELD relationship, score RETURN relationship.w, score", &.{
        &.{ int(1), float(1) }, &.{ int(2), float(0.2) },
    });
    try expectQuery(ast, g, "MATCH ()-[r:LINK {w: 1}]->() DELETE r", &.{});
    try expectOrdered(ast, g, "CALL db.index.vector.queryRelationships('links', 10, [0, 0]) YIELD relationship RETURN relationship.w", &.{&.{int(2)}});
    try expectSound(g);
    // Each procedure for its own kind of index.
    try expectQueryError(ast, g, "CALL db.index.vector.queryNodes('links', 1, [0, 0]) YIELD node RETURN node", error.InvalidExpression);
}

test "a relationship index built from what is there: its type only, and refused on a bad vector" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try expectQuery(ast, g, "CREATE (a)-[:LINK {w: 1, v: [0, 0]}]->(b), (a)-[:LINK {w: 2, v: [0, 2]}]->(b), (a)-[:LINK {w: 3}]->(b), (a)-[:OTHER {v: [0, 1]}]->(b), (a)-[:OTHER {v: 'not a vector'}]->(b)", &.{});
    try expectQuery(ast, g, "CREATE VECTOR INDEX links FOR ()-[r:LINK]-() ON r.v OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}", &.{});
    try expectOrdered(ast, g, "CALL db.index.vector.queryRelationships('links', 10, [0, 1]) YIELD relationship RETURN relationship.w", &.{ &.{int(1)}, &.{int(2)} });
    try expectSound(g);
    try expectQueryError(ast, g, "CREATE VECTOR INDEX others FOR ()-[r:OTHER]-() ON r.v OPTIONS {indexConfig: {`vector.dimensions`: 2}}", error.ConstraintViolation);
    try expectQueryError(ast, g, "CALL db.index.vector.queryRelationships('others', 1, [0, 0]) YIELD relationship RETURN relationship", error.InvalidExpression);
}

test "what is not a vector is refused, before anything is written" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try expectQuery(ast, g, "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v OPTIONS {indexConfig: {`vector.dimensions`: 3}}", &.{});
    for ([_][]const u8{
        "CREATE (:Doc {v: [1.0, 2.0]})",
        "CREATE (:Doc {v: 'text'})",
        "CREATE (:Doc {v: ['a', 'b', 'c']})",
        "CREATE (:Doc {v: [0.0, 0.0, 0.0]})",
        "CREATE (:Doc {v: [1.0, 0.0, 1e300 * 1e300]})",
    }) |query| try expectQueryError(ast, g, query, error.ConstraintViolation);
    // A label that brings a bad property into the index, too.
    try expectQuery(ast, g, "CREATE (:Note {v: [1, 2]})", &.{});
    try expectQueryError(ast, g, "MATCH (n:Note) SET n:Doc", error.ConstraintViolation);
    try expectQuery(ast, g, "MATCH (d:Doc) RETURN count(d)", &.{&.{int(0)}});
    try expectSound(g);

    // An index on data that breaks it is not made.
    try expectQueryError(ast, g, "CREATE VECTOR INDEX notes FOR (n:Note) ON n.v OPTIONS {indexConfig: {`vector.dimensions`: 3}}", error.ConstraintViolation);
    try testing.expectEqual(@as(usize, 1), (try zypherdb.schema_definitions.all(g, arena.allocator())).len);

    // Options and queries that make no sense.
    try expectQueryError(ast, g, "CREATE VECTOR INDEX a FOR (n:A) ON n.v", error.InvalidExpression);
    try expectQueryError(ast, g, "CREATE VECTOR INDEX a FOR (n:A) ON n.v OPTIONS {indexConfig: {`vector.dimensions`: 5000}}", error.InvalidExpression);
    try expectQueryError(ast, g, "CREATE VECTOR INDEX a FOR (n:A) ON n.v OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'dot'}}", error.InvalidExpression);
    try expectQueryError(ast, g, "CALL db.index.vector.queryNodes('docs', 1, [1, 2]) YIELD node RETURN node", error.InvalidExpression);
    try expectQueryError(ast, g, "CALL db.index.vector.queryNodes('docs', 0, [1, 2, 3]) YIELD node RETURN node", error.InvalidExpression);
    try expectQueryError(ast, g, "CALL db.index.vector.queryNodes('nothing', 1, [1, 2, 3]) YIELD node RETURN node", error.InvalidExpression);
}

test "many writes and deletes keep the index sound and its answers exact on few entities" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try expectQuery(ast, g, "CREATE VECTOR INDEX points FOR (p:Point) ON p.v OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}", &.{});
    try expectQuery(ast, g, "UNWIND range(0, 299) AS i CREATE (:Point {i: i, v: [toFloat(i), toFloat(i % 7)]})", &.{});
    try expectQuery(ast, g, "MATCH (p:Point) WHERE p.i % 3 = 0 DELETE p", &.{});
    try expectQuery(ast, g, "MATCH (p:Point) WHERE p.i % 3 = 1 SET p.v = [p.v[0] + 0.5, 0.0]", &.{});
    try expectSound(g);
    try expectOrdered(ast, g, "CALL db.index.vector.queryNodes('points', 3, [100.0, 0.0]) YIELD node RETURN node.i", &.{
        &.{int(100)}, &.{int(98)}, &.{int(97)},
    });
}

test "vector.similarity functions" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try expectQuery(ast, g, "RETURN vector.similarity.cosine([1, 0], [0, 2]) AS c, vector.similarity.euclidean([0, 0], [0, 2]) AS e", &.{
        &.{ float(0.5), float(0.2) },
    });
    try expectQuery(ast, g, "RETURN vector.similarity.cosine(null, [1]) AS a, vector.similarity.cosine([0, 0], [1, 1]) AS b", &.{
        &.{ .null, .null },
    });
    try expectQueryError(ast, g, "RETURN vector.similarity.euclidean([1, 2], [1])", error.InvalidExpression);
    try expectQueryError(ast, g, "RETURN vector.similarity.euclidean([1, 'a'], [1, 2])", error.TypeMismatch);
}

test "random writes, label changes and deletes, past a rebuild: sound, and recall holds" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    var data = std.heap.ArenaAllocator.init(testing.allocator);
    defer data.deinit();
    const allocator = data.allocator();

    try expectQuery(ast, g, "CREATE VECTOR INDEX points FOR (p:P) ON p.v OPTIONS {indexConfig: {`vector.dimensions`: 8}}", &.{});
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const node_count = 1600;
    const vectors = try allocator.alloc(?[]Value, node_count);
    const labelled = try allocator.alloc(bool, node_count);
    const randomVector = struct {
        fn make(r: std.Random, a: std.mem.Allocator) ![]Value {
            const items = try a.alloc(Value, 8);
            for (items) |*item| item.* = .{ .float = r.floatNorm(f64) };
            return items;
        }
    }.make;
    try g.beginWrite();
    for (0..node_count) |id| {
        try g.addNode(id, "P");
        vectors[id] = try randomVector(random, allocator);
        labelled[id] = true;
        try g.setProperty(id, "v", .{ .list = vectors[id].? });
    }
    try g.commitWrite();
    try expectSound(g);

    // Random changes, then most nodes gone: tombstones outnumber the living.
    try g.beginWrite();
    for (0..2000) |_| {
        const id = random.uintLessThan(usize, node_count);
        switch (random.uintLessThan(u8, 4)) {
            0 => {
                vectors[id] = try randomVector(random, allocator);
                try g.setProperty(id, "v", .{ .list = vectors[id].? });
            },
            1 => {
                vectors[id] = null;
                try g.removeProperty(id, "v");
            },
            2 => {
                labelled[id] = !labelled[id];
                if (labelled[id]) try g.addLabel(id, "P") else try g.removeLabel(id, "P");
            },
            else => if (vectors[id] == null) {
                vectors[id] = try randomVector(random, allocator);
                try g.setProperty(id, "v", .{ .list = vectors[id].? });
            },
        }
    }
    try g.commitWrite();
    try expectSound(g);
    try g.beginWrite();
    for (0..node_count) |id| if (id % 4 != 0) {
        try g.deleteNodeDetach(id);
        vectors[id] = null;
    };
    try g.commitWrite();
    try expectSound(g);
    // The rebuild dropped the tombstones of before (index 1's records).
    const records = try g.store.countPrefix(&.{ zypherdb.vector.index.marker, 0, 0, 0, 1, 'E' });
    try testing.expect(records < node_count * 3 / 4);

    // Recall of the 10 nearest, against every live node scored by the function.
    var found_total: usize = 0;
    var wanted_total: usize = 0;
    for (0..20) |_| {
        const query = try randomVector(random, allocator);
        const Scored = struct { id: usize, score: f64 };
        var exact = std.ArrayList(Scored).empty;
        for (vectors, labelled, 0..) |vector, is_labelled, id| {
            const items = vector orelse continue;
            if (!is_labelled) continue;
            var a: [8]f64 = undefined;
            var b: [8]f64 = undefined;
            for (&a, &b, items, query) |*x, *y, item, q| {
                x.* = item.float;
                y.* = q.float;
            }
            try exact.append(allocator, .{ .id = id, .score = zypherdb.vector.similarity.scoreOfNumbers(.cosine, &a, &b).? });
        }
        std.mem.sort(Scored, exact.items, {}, struct {
            fn moreThan(_: void, x: Scored, y: Scored) bool {
                return x.score > y.score;
            }
        }.moreThan);
        const parser = zypherdb.parser;
        const statement = try parser.parse(ast, "CALL db.index.vector.queryNodes('points', 10, $q) YIELD node RETURN id(node)", null);
        var run_arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer run_arena.deinit();
        var executor = zypherdb.Executor.init(ast, g, run_arena.allocator());
        try executor.parameters.put(run_arena.allocator(), "q", .{ .list = query });
        const rows = try executor.run(statement);
        try testing.expectEqual(@as(usize, 10), rows.len);
        for (exact.items[0..10]) |want| {
            for (rows) |row| if (row.items[0].int == want.id) {
                found_total += 1;
                break;
            };
        }
        wanted_total += 10;
    }
    const recall = @as(f64, @floatFromInt(found_total)) / @as(f64, @floatFromInt(wanted_total));
    if (recall < 0.95) std.debug.print("recall {d:.3}\n", .{recall});
    try testing.expect(recall >= 0.95);
}

test "the first vector index stamps the vector format, which stays after it is dropped" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try g.checkFormat();
    try expectQuery(ast, g, "CREATE INDEX names FOR (d:Doc) ON (d.name)", &.{});
    try expectQuery(ast, g, "CREATE FULLTEXT INDEX texts FOR (d:Doc) ON EACH [d.text]", &.{});
    try testing.expectEqual(@as(?u32, Graph.first_format), try g.storedFormat());

    // A vector index that is not made stamps nothing.
    try expectQuery(ast, g, "CREATE (:Doc {v: [1, 2]})", &.{});
    try expectQueryError(ast, g, "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v OPTIONS {indexConfig: {`vector.dimensions`: 3}}", error.ConstraintViolation);
    try testing.expectEqual(@as(?u32, Graph.first_format), try g.storedFormat());

    try expectQuery(ast, g, "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v OPTIONS {indexConfig: {`vector.dimensions`: 2}}", &.{});
    try testing.expectEqual(@as(?u32, Graph.vector_format), try g.storedFormat());
    try expectSound(g);
    try expectQuery(ast, g, "DROP INDEX docs", &.{});
    try testing.expectEqual(@as(?u32, Graph.vector_format), try g.storedFormat());
    try g.checkFormat();
    try expectSound(g);
}

test "the integrity checker reports a vector index in a database not stamped with the vector format" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const g = &fixture.graph;

    try g.checkFormat();
    try expectQuery(&fixture.ast, g, "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v OPTIONS {indexConfig: {`vector.dimensions`: 2}}", &.{});
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, Graph.first_format, .big);
    try g.store.put("!format", &bytes);
    var report = try zypherdb.integrity.check(g, testing.allocator);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.problems.items.len);
    try testing.expectEqualStrings("vector index docs in a database of format 1", report.problems.items[0]);
}
