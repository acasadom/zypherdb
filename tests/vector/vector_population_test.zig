//! A vector index populated in the background: in batches, kept by writes
//! meanwhile, resumed after a reopen, failed by a bad vector, carried by a
//! copy to a replica, and populated by the builder thread.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const KeyValueStore = zypherdb.KeyValueStore;
const Value = zypherdb.Value;
const population = zypherdb.vector.population;
const vector_index = zypherdb.vector.index;

const support = @import("../support.zig");
const openStore = support.openStore;
const testPath = support.testPath;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

const node_index = "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v OPTIONS {indexConfig: {`vector.dimensions`: 4}}";

fn int(n: i64) Value {
    return .{ .int = n };
}

fn expectSound(g: *Graph) !void {
    var report = try zypherdb.integrity.check(g, testing.allocator);
    defer report.deinit();
    for (report.problems.items) |problem| std.debug.print("integrity: {s}\n", .{problem});
    try testing.expect(report.ok());
}

/// Index `name`'s state, in `arena`.
fn stateOf(g: *Graph, arena: std.mem.Allocator, name: []const u8) !vector_index.State {
    const definition = (try zypherdb.schema_definitions.find(g, name, arena)).?;
    return vector_index.state(g, arena, definition.index_id);
}

fn expectPopulating(g: *Graph, name: []const u8, next: u64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(next, (try stateOf(g, arena.allocator(), name)).populating.next);
}

fn expectOnline(g: *Graph, name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try stateOf(g, arena.allocator(), name) == .online);
}

fn createDocs(ast: *Ast, g: *Graph, count: usize) !void {
    var text: [160]u8 = undefined;
    const query = try std.fmt.bufPrint(&text, "UNWIND range(0, {d}) AS i CREATE (:Doc {{id: i, v: [toFloat(i), 1.0, 0.0, 0.0]}})", .{count - 1});
    try expectQuery(ast, g, query, &.{});
}

test "population goes in batches, kept by writes meanwhile, and resumes after a reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.population_budget = .{ .entities = 10 };
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 100);
    try expectQuery(&ast, &g, node_index, &.{});
    try expectPopulating(&g, "docs", 10);
    const config = [_]zypherdb.value.MapEntry{
        .{ .key = "vector.dimensions", .value = int(4) },
        .{ .key = "vector.similarity_function", .value = .{ .string = "cosine" } },
    };
    const options = [_]zypherdb.value.MapEntry{.{ .key = "indexConfig", .value = .{ .map = &config } }};
    try expectQuery(&ast, &g, "SHOW VECTOR INDEXES", &.{&.{
        .{ .string = "docs" },                 .{ .string = "VECTOR" },             .{ .string = "NODE" },
        .{ .list = &.{.{ .string = "Doc" }} }, .{ .list = &.{.{ .string = "v" }} }, .null,
        .{ .map = &options },                  .{ .string = "POPULATING" },         .{ .float = 10 },
        .null,
    }});
    try expectQueryError(&ast, &g, "CALL db.index.vector.queryNodes('docs', 5, [1, 0, 0, 0]) YIELD node RETURN node", error.IndexPopulating);
    try expectQueryError(&ast, &g, "CALL db.awaitIndexes(0)", error.IndexPopulating);
    try expectSound(&g);

    // Writes meanwhile, behind and ahead of the population; a bad vector is
    // still refused.
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 80}) SET d.v = [0.0, 0.0, 1.0, 0.0]", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 90}) DETACH DELETE d", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 3}) REMOVE d.v", &.{});
    try expectQuery(&ast, &g, "CREATE (:Doc {id: 100, v: [1.0, 1.0, 1.0, 1.0]})", &.{});
    try expectQueryError(&ast, &g, "CREATE (:Doc {v: [1.0]})", error.ConstraintViolation);
    try expectSound(&g);

    try testing.expect(try population.advanceAny(&store));
    try expectPopulating(&g, "docs", 20);
    try expectSound(&g);

    // Closed mid-population: it goes on from where it got to.
    store.deinit();
    store = try openStore(&tmp, &path_buffer);
    store.population_budget = .{ .entities = 10 };
    g = Graph.init(&store, testing.allocator);
    try expectPopulating(&g, "docs", 20);
    try population.finish(&store);
    try expectOnline(&g, "docs");
    try expectQuery(&ast, &g, "CALL db.awaitIndexes(0)", &.{});
    try testing.expect(!try population.advanceAny(&store));
    try expectQuery(&ast, &g, "CALL db.index.vector.queryNodes('docs', 200, [1, 0, 0, 0]) YIELD node RETURN count(node)", &.{&.{int(99)}});
    try expectSound(&g);
}

test "a bad vector met by population fails the index, which is dropped and made again once the data is corrected" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.population_budget = .{ .entities = 5 };
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try createDocs(&ast, &g, 20);
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 12}) SET d.v = 'bad'", &.{});
    try expectQuery(&ast, &g, node_index, &.{});
    try expectSound(&g);
    try population.finish(&store);
    const failure = (try stateOf(&g, arena.allocator(), "docs")).failed;
    try testing.expectEqual(@as(u64, 12), failure.entity);
    try testing.expectEqualStrings("is not a list of numbers", failure.reason);
    // Its keys are gone but its state.
    const definition = (try zypherdb.schema_definitions.find(&g, "docs", arena.allocator())).?;
    var prefix: [5]u8 = undefined;
    prefix[0] = vector_index.marker;
    std.mem.writeInt(u32, prefix[1..5], definition.index_id, .big);
    try testing.expectEqual(@as(usize, 1), try store.countPrefix(&prefix));
    try expectSound(&g);
    // Neither kept nor checked.
    try expectQuery(&ast, &g, "CREATE (:Doc {id: 20, v: [1.0]})", &.{});
    try expectSound(&g);
    try expectQueryError(&ast, &g, "CALL db.index.vector.queryNodes('docs', 5, [1, 0, 0, 0]) YIELD node RETURN node", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.awaitIndexes()", error.InvalidExpression);

    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id IN [12, 20] SET d.v = [1.0, 2.0, 3.0, 4.0]", &.{});
    try expectQuery(&ast, &g, "DROP INDEX docs", &.{});
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&store);
    try expectOnline(&g, "docs");
    try expectQuery(&ast, &g, "CALL db.index.vector.queryNodes('docs', 50, [1, 0, 0, 0]) YIELD node RETURN count(node)", &.{&.{int(21)}});
    try expectSound(&g);
}

test "a relationship index populates past many relationships of other types" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.population_budget = .{ .entities = 3 };
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "CREATE (a:A), (b:B) WITH a, b UNWIND range(1, 5000) AS i CREATE (a)-[:OTHER {v: 'not a vector'}]->(b)", &.{});
    try expectQuery(&ast, &g, "MATCH (a:A), (b:B) UNWIND range(1, 10) AS i CREATE (a)-[:LINK {v: [toFloat(i), 0.0]}]->(b)", &.{});
    try expectQuery(&ast, &g, "CREATE VECTOR INDEX links FOR ()-[r:LINK]-() ON r.v OPTIONS {indexConfig: {`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}", &.{});
    try expectSound(&g);
    try population.finish(&store);
    try expectOnline(&g, "links");
    try expectQuery(&ast, &g, "CALL db.index.vector.queryRelationships('links', 50, [0, 0]) YIELD relationship RETURN count(relationship)", &.{&.{int(10)}});
    try expectSound(&g);
}

/// The replica `target` applies `source`'s change sets from `next.*` on.
fn replay(source: *KeyValueStore, target: *KeyValueStore, next: *u64) !void {
    const end = (try source.changeLogState()).?.next_lsn;
    while (next.* < end) : (next.* += 1) {
        const bytes = (try source.changeSet(next.*)).?;
        defer testing.allocator.free(bytes);
        try testing.expectEqual(.applied, try target.applyChangeSet(next.*, bytes));
    }
}

fn openAt(tmp: *testing.TmpDir, name: []const u8, buffer: []u8) !KeyValueStore {
    var base_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(buffer, "{s}/{s}", .{ testPath(tmp, &base_buffer), name });
    try tmp.dir.createDirPath(testing.io, name);
    return KeyValueStore.open(testing.allocator, path);
}

test "a replica copied mid-population goes on with it; one applying a CREATE over a bad vector fails the index, not the change set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var master = try openAt(&tmp, "master", &master_path);
    defer master.deinit();
    try master.startChangeLog();
    master.population_budget = .{ .entities = 10 };
    var replica_path: [256]u8 = undefined;
    var replica = try openAt(&tmp, "replica", &replica_path);
    defer replica.deinit();
    replica.population_budget = master.population_budget;
    var g = Graph.init(&master, testing.allocator);
    var replica_graph = Graph.init(&replica, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 50);
    try expectQuery(&ast, &g, node_index, &.{});
    var copy: std.Io.Writer.Allocating = .init(testing.allocator);
    defer copy.deinit();
    var next = try master.writeCopy(&copy.writer) + 1;
    try testing.expect(try replica.applyCopyPart(copy.written(), false) == null);
    _ = (try replica.applyCopyPart("", true)).?;
    try expectPopulating(&replica_graph, "docs", 10);
    try expectSound(&replica_graph);

    // Writes the replica applies while it populates.
    try expectQuery(&ast, &g, "UNWIND range(50, 54) AS i CREATE (:Doc {id: i, v: [1.0, toFloat(i), 0.0, 0.0]})", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 40}) SET d.v = [0.0, 0.0, 0.0, 1.0]", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 5}) DETACH DELETE d", &.{});
    try replay(&master, &replica, &next);
    try expectSound(&replica_graph);
    try population.finish(&replica);
    try expectOnline(&replica_graph, "docs");
    try expectSound(&replica_graph);
    try population.finish(&master);
    try expectSound(&g);
    const count = "CALL db.index.vector.queryNodes('docs', 100, [1, 0, 0, 0]) YIELD node RETURN count(node)";
    try expectQuery(&ast, &replica_graph, count, &.{&.{int(54)}});

    try expectQuery(&ast, &g, "CREATE (:Note {v: [1, 2]})", &.{});
    try expectQuery(&ast, &g, "CREATE VECTOR INDEX notes FOR (n:Note) ON n.v OPTIONS {indexConfig: {`vector.dimensions`: 3}}", &.{});
    try replay(&master, &replica, &next);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try stateOf(&g, arena.allocator(), "notes") == .failed);
    try testing.expect(try stateOf(&replica_graph, arena.allocator(), "notes") == .failed);
    try expectSound(&replica_graph);
}

test "the builder thread populates in the background, and goes on after a reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    for (0..2) |round| {
        var store = try openStore(&tmp, &path_buffer);
        defer store.deinit();
        store.population_budget = .{ .entities = 20 };
        const builder = try population.Builder.start(testing.allocator, &store);
        defer builder.stop();
        var session = try store.share();
        defer session.deinit();
        var g = Graph.init(&session, testing.allocator);
        if (round == 0) {
            try createDocs(&ast, &g, 200);
            try expectQuery(&ast, &g, node_index, &.{});
            try expectQuery(&ast, &g, "CALL db.awaitIndexes()", &.{});
            try expectOnline(&g, "docs");
            try expectQuery(&ast, &g, "CALL db.index.vector.queryNodes('docs', 300, [1, 0, 0, 0]) YIELD node RETURN count(node)", &.{&.{int(200)}});
            try expectSound(&g);
            // Closed at once: some of it is likely left for the next open.
            try expectQuery(&ast, &g, "MATCH (d:Doc) SET d.w = [d.id + 1.0, 1.0]", &.{});
            try expectQuery(&ast, &g, "CREATE VECTOR INDEX others FOR (d:Doc) ON d.w OPTIONS {indexConfig: {`vector.dimensions`: 2}}", &.{});
        } else {
            try waitOnline(&g, "others");
            try expectSound(&g);
        }
    }
}

test "db.awaitIndexes() runs on its own, out of write transactions, with a number of seconds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // No vector index: nothing to wait for.
    try expectQuery(&ast, &g, "CALL db.awaitIndexes()", &.{});
    try expectQuery(&ast, &g, "CALL db.awaitIndexes", &.{});
    try support.expectQueryWithParameters(&ast, &g, "CALL db.awaitIndexes($seconds)", &.{.{ "seconds", int(1) }}, &.{});
    try expectQueryError(&ast, &g, "CALL db.awaitIndexes(-1)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.awaitIndexes(1.5)", error.TypeMismatch);
    try expectQueryError(&ast, &g, "CALL db.awaitIndexes(1, 2)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (d:Doc) CALL db.awaitIndexes() RETURN d", error.InvalidExpression);
    try expectQueryError(&ast, &g, "CALL db.awaitIndexes() RETURN 1", error.InvalidExpression);

    try g.beginWrite();
    defer g.abortWrite();
    const query = try zypherdb.parser.parse(&ast, "CALL db.awaitIndexes()", null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = zypherdb.Executor.init(&ast, &g, arena.allocator());
    try testing.expectError(error.InvalidExpression, executor.run(query));
}

fn waitOnline(g: *Graph, name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..6000) |_| {
        if (try stateOf(g, arena.allocator(), name) == .online) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.TestTimeout;
}
