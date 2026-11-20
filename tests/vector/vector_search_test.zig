//! The SEARCH clause: `MATCH ... SEARCH x IN (VECTOR INDEX name FOR vector
//! WHERE ... LIMIT k OPTIONS {ef}) SCORE AS s WHERE ...`. The k closest
//! among the entities the MATCH and the inner WHERE keep, exact or through
//! the HNSW, as the row asks.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;
const Executor = zypherdb.Executor;
const parser = zypherdb.parser;

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

/// Five docs pointing round the circle, 'a' east, 'e' west; 'b' and 'd' by
/// the same author, 'c' with no vector.
fn createDocs(ast: *Ast, g: *Graph) !void {
    try expectQuery(ast, g,
        \\CREATE (x:Author {name: 'x'}), (y:Author {name: 'y'}),
        \\       (a:Doc {name: 'a', year: 2001, v: [1.0, 0.0]}), (b:Doc {name: 'b', year: 2002, v: [1.0, 0.5]}),
        \\       (c:Doc {name: 'c', year: 2003}), (d:Doc {name: 'd', year: 2004, v: [0.0, 1.0]}),
        \\       (e:Doc {name: 'e', year: 2005, v: [-1.0, 0.0]}),
        \\       (x)-[:WROTE]->(a), (y)-[:WROTE]->(b), (y)-[:WROTE]->(d), (x)-[:WROTE]->(e), (x)-[:WROTE]->(c)
    , &.{});
    try expectQuery(ast, g,
        \\CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v
        \\OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}
    , &.{});
}

test "the k closest among those the MATCH and the inner WHERE keep, best first" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    try createDocs(ast, g);

    try expectOrdered(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 2) SCORE AS s RETURN d.name, s", &.{
        &.{ string("a"), float(1) }, &.{ string("b"), float(0.8) },
    });
    // The two closest by y: not the closest two, then filtered.
    try expectOrdered(ast, g, "MATCH (:Author {name: 'y'})-[:WROTE]->(d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 2) RETURN d.name", &.{
        &.{string("b")}, &.{string("d")},
    });
    // The inner WHERE and the MATCH's WHERE both choose before ranking.
    try expectOrdered(ast, g, "MATCH (d:Doc) WHERE d.year > 2001 SEARCH d IN (VECTOR INDEX docs FOR [1, 0] WHERE d.name <> 'b' LIMIT 2) RETURN d.name", &.{
        &.{string("d")}, &.{string("e")},
    });
    // The WHERE after SCORE AS filters what was found: fewer than k.
    try expectOrdered(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 3) SCORE AS s WHERE s > 0.5 RETURN d.name", &.{
        &.{string("a")}, &.{string("b")},
    });
    // More than there are: every doc with a vector, none without.
    try expectOrdered(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [-1, 0] LIMIT 10) RETURN d.name", &.{
        &.{string("e")}, &.{string("d")}, &.{string("a")}, &.{string("b")},
    });
    try expectQuery(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 0) RETURN d.name", &.{});
}

test "every row of a chosen entity goes on; the vector and k come from each row" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    try createDocs(ast, g);
    try expectQuery(ast, g, "MATCH (y:Author {name: 'y'}), (d:Doc {name: 'a'}) CREATE (y)-[:WROTE]->(d)", &.{});

    // 'a' has two authors: both rows, one entity of k.
    try expectQuery(ast, g, "MATCH (w:Author)-[:WROTE]->(d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 1) RETURN w.name, d.name", &.{
        &.{ string("x"), string("a") }, &.{ string("y"), string("a") },
    });
    try expectOrdered(ast, g,
        \\UNWIND [{v: [1, 0], k: 1}, {v: [-1, 0], k: 2}] AS q
        \\MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR q.v LIMIT q.k) RETURN q.k, d.name
    , &.{
        &.{ int(1), string("a") }, &.{ int(2), string("e") }, &.{ int(2), string("d") },
    });
    // The inner WHERE may read what came before.
    try expectOrdered(ast, g,
        \\MATCH (n:Doc {name: 'a'}) WITH n
        \\MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR n.v WHERE d <> n LIMIT 1) RETURN d.name
    , &.{&.{string("b")}});
}

test "OPTIONAL MATCH: a row of nulls when none is left" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    try createDocs(ast, g);

    try expectQuery(ast, g,
        \\MATCH (w:Author {name: 'y'})
        \\OPTIONAL MATCH (w)-[:WROTE]->(d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] WHERE d.year > 2010 LIMIT 2) SCORE AS s
        \\RETURN w.name, d, s
    , &.{&.{ string("y"), .null, .null }});
    try expectQuery(ast, g,
        \\MATCH (w:Author {name: 'y'})
        \\OPTIONAL MATCH (w)-[:WROTE]->(d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 2) SCORE AS s WHERE s > 0.99
        \\RETURN w.name, d, s
    , &.{&.{ string("y"), .null, .null }});
    try expectOrdered(ast, g,
        \\MATCH (w:Author {name: 'y'})
        \\OPTIONAL MATCH (w)-[:WROTE]->(d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [0, 1] LIMIT 1)
        \\RETURN d.name
    , &.{&.{string("d")}});
}

test "relationships" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;

    try expectQuery(ast, g, "CREATE VECTOR INDEX links FOR ()-[r:LINK]-() ON (r.v) OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}", &.{});
    try expectQuery(ast, g,
        \\CREATE (a:A {name: 'a'})-[:LINK {w: 1, v: [0, 0]}]->(b:B), (a)-[:LINK {w: 2, v: [0, 1]}]->(b),
        \\       (c:C {name: 'c'})-[:LINK {w: 3, v: [0, 0.5]}]->(b)
    , &.{});
    try expectOrdered(ast, g, "MATCH ()-[r:LINK]->() SEARCH r IN (VECTOR INDEX links FOR [0, 0] LIMIT 2) RETURN r.w", &.{
        &.{int(1)}, &.{int(3)},
    });
    try expectOrdered(ast, g, "MATCH (:A)-[r:LINK]->() SEARCH r IN (VECTOR INDEX links FOR [0, 1.5] LIMIT 1) SCORE AS s RETURN r.w, s", &.{
        &.{ int(2), float(0.8) },
    });
    // A node variable needs a node index, and the other way round.
    try expectQueryError(ast, g, "MATCH (n:A) SEARCH n IN (VECTOR INDEX links FOR [0, 0] LIMIT 1) RETURN n", error.InvalidExpression);
}

/// The names of the `k` docs closest to `query` among `docs`, by measuring
/// every one (vector.similarity.euclidean, ties by id).
fn exactNames(ast: *Ast, g: *Graph, arena: std.mem.Allocator, query: []const u8, where: []const u8, k: usize) ![]const []const u8 {
    const source = try std.fmt.allocPrint(arena, "MATCH (d:Doc) WHERE {s} RETURN d.name ORDER BY vector.similarity.euclidean(d.v, {s}) DESC, id(d) LIMIT {d}", .{ where, query, k });
    const parsed = try parser.parse(ast, source, null);
    var executor = Executor.init(ast, g, arena);
    const rows = try executor.run(parsed);
    const names = try arena.alloc([]const u8, rows.len);
    for (names, rows) |*name, row| name.* = row.items[0].string;
    return names;
}

/// What a query found, and PROFILE's line for its SEARCH.
fn searchNames(ast: *Ast, g: *Graph, arena: std.mem.Allocator, source: []const u8) !struct { names: []const []const u8, profile: []const u8 } {
    const parsed = try parser.parse(ast, try std.fmt.allocPrint(arena, "PROFILE {s}", .{source}), null);
    var executor = Executor.init(ast, g, arena);
    const lines = try executor.run(parsed);
    var details: []const u8 = "";
    for (lines) |line| if (std.mem.eql(u8, line.items[1].string, "VectorSearch")) {
        details = line.items[2].string;
    };
    const rows = executor.profiled_rows;
    const names = try arena.alloc([]const u8, rows.len);
    for (names, rows) |*name, row| name.* = row.items[0].string;
    return .{ .names = names, .profile = details };
}

test "many candidates: the HNSW with the filter, the same as measuring every one" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 1500 docs on a 2-D grid, a third of them blue.
    try expectQuery(ast, g,
        \\CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v
        \\OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}
    , &.{});
    try expectQuery(ast, g,
        \\UNWIND range(0, 1499) AS i
        \\CREATE (:Doc {name: 'd' + toString(i), blue: i % 3 = 0, v: [toFloat(i % 50), toFloat(i / 50)]})
    , &.{});

    const queries = [_][]const u8{ "[10.2, 7.7]", "[49.0, 0.0]", "[25.5, 29.1]" };
    for (queries) |query| {
        // Few blue ones near a corner: exact; all of them: the HNSW.
        const cases = [_]struct { where: []const u8, way: []const u8 }{
            .{ .where = "d.blue AND d.v[0] < 4 AND d.v[1] < 4", .way = "rows searched exactly: 1," },
            .{ .where = "d.blue", .way = "with the HNSW: 1," },
            .{ .where = "true", .way = "with the HNSW: 1," },
        };
        for (cases) |case| {
            const source = try std.fmt.allocPrint(arena, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR {s} WHERE {s} LIMIT 5 OPTIONS {{ef: 10}}) RETURN d.name", .{ query, case.where });
            const found = try searchNames(ast, g, arena, source);
            try testing.expect(std.mem.indexOf(u8, found.profile, case.way) != null);
            const expected = try exactNames(ast, g, arena, query, case.where, 5);
            try testing.expectEqual(expected.len, found.names.len);
            var same: usize = 0;
            for (found.names) |name| {
                for (expected) |wanted| if (std.mem.eql(u8, name, wanted)) {
                    same += 1;
                };
            }
            // A 2-D grid this small is searched without a miss.
            try testing.expectEqual(expected.len, same);
        }
    }
}

test "errors: the index, the vector, LIMIT and OPTIONS" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    try createDocs(ast, g);

    try expectQueryError(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX nothing FOR [1, 0] LIMIT 1) RETURN d", error.InvalidExpression);
    try expectQueryError(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0, 0] LIMIT 1) RETURN d", error.InvalidExpression);
    try expectQueryError(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR null LIMIT 1) RETURN d", error.TypeMismatch);
    try expectQueryError(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT -1) RETURN d", error.InvalidExpression);
    try expectQueryError(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 'two') RETURN d", error.TypeMismatch);
    try expectQueryError(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 1 OPTIONS {ef: 0}) RETURN d", error.InvalidExpression);
    try expectQueryError(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 1 OPTIONS {breadth: 4}) RETURN d", error.InvalidExpression);
    // Nothing to search: no error, no row.
    try expectQuery(ast, g, "MATCH (d:Nothing) SEARCH d IN (VECTOR INDEX docs FOR [1, 0] LIMIT 1) RETURN d", &.{});
}

test "the index's search breadth: given at creation, kept, shown, and refused when wrong" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    try expectQuery(ast, g,
        \\CREATE VECTOR INDEX wide FOR (d:Doc) ON (d.v)
        \\OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.hnsw.ef_search`: 400}}
    , &.{});
    try expectQueryError(ast, g, "CREATE VECTOR INDEX bad FOR (d:Doc) ON (d.w) OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.hnsw.ef_search`: 0}}", error.InvalidExpression);
    try expectQueryError(ast, g, "CREATE VECTOR INDEX bad FOR (d:Doc) ON (d.w) OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.hnsw.ef_search`: 'wide'}}", error.InvalidExpression);
    try expectQuery(ast, g, "CREATE (:Doc {v: [1.0, 0.0]}), (:Doc {v: [0.0, 1.0]})", &.{});

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = (try zypherdb.schema_definitions.find(g, "wide", arena.allocator())).?;
    try testing.expectEqual(@as(u32, 400), found.ef_search);
    try testing.expectEqual(@as(u32, 400), found.searchBreadth());
    // The index's breadth, or the query's.
    try expectQuery(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX wide FOR [1, 0] LIMIT 1) RETURN d.v", &.{&.{.{ .list = &.{ float(1.0), float(0.0) } }}});
    try expectQuery(ast, g, "MATCH (d:Doc) SEARCH d IN (VECTOR INDEX wide FOR [1, 0] LIMIT 1 OPTIONS {ef: 1}) RETURN d.v", &.{&.{.{ .list = &.{ float(1.0), float(0.0) } }}});
    try expectQuery(ast, g, "CALL db.index.vector.queryNodes('wide', 1, [0, 1]) YIELD node RETURN node.v", &.{&.{.{ .list = &.{ float(0.0), float(1.0) } }}});
}

test "EXPLAIN shows the SEARCH over its MATCH" {
    var fixture = Fixture{ .tmp = undefined };
    try fixture.init();
    defer fixture.deinit();
    const ast = &fixture.ast;
    const g = &fixture.graph;
    try createDocs(ast, g);

    const parsed = try parser.parse(ast, "EXPLAIN MATCH (d:Doc) SEARCH d IN (VECTOR INDEX docs FOR $v LIMIT 3) SCORE AS s RETURN d, s", null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    const lines = try executor.run(parsed);
    var names = std.ArrayList(u8).empty;
    for (lines) |line| {
        try names.appendSlice(arena.allocator(), line.items[1].string);
        try names.append(arena.allocator(), ' ');
        if (std.mem.eql(u8, line.items[1].string, "VectorSearch")) try testing.expectEqualStrings("d IN docs FOR $v LIMIT 3 SCORE AS s", line.items[2].string);
    }
    try testing.expectEqualStrings("Return VectorSearch NodeByLabelScan ", names.items);
}
