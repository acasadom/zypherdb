//! A vector index rebuilt in the background, into the next generation of
//! its graph: in batches, kept by writes meanwhile, searched in the old
//! generation until the swap, resumed after a reopen, carried by a copy to
//! a replica. And the keys of dropped and failed indexes, cleared in the
//! background.

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

const node_index = "CREATE VECTOR INDEX docs FOR (d:Doc) ON d.v OPTIONS {indexConfig: {`vector.dimensions`: 4}}";
const count_docs = "CALL db.index.vector.queryNodes('docs', 500, [1, 0, 0, 0]) YIELD node RETURN count(node)";

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

/// Index `name`, online in `generation`, being rebuilt up to `rebuild` (null: not).
fn expectOnline(g: *Graph, name: []const u8, generation: u8, rebuild: ?u64) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const online = (try stateOf(g, arena.allocator(), name)).online;
    try testing.expectEqual(generation, online.generation);
    try testing.expectEqual(rebuild, online.rebuild);
}

/// How many keys index `index_id` has: in `generation`, or all of them.
fn keysOf(store: *KeyValueStore, index_id: u32, generation: ?u8) !usize {
    const index_prefix = vector_index.indexPrefix(index_id);
    const generation_prefix = vector_index.generationPrefix(index_id, generation orelse 0);
    return store.countPrefix(if (generation == null) &index_prefix else &generation_prefix);
}

fn createDocs(ast: *Ast, g: *Graph, count: usize) !void {
    var text: [160]u8 = undefined;
    const query = try std.fmt.bufPrint(&text, "UNWIND range(0, {d}) AS i CREATE (:Doc {{id: i, v: [toFloat(i) + 1.0, 1.0, 0.0, 0.0]}})", .{count - 1});
    try expectQuery(ast, g, query, &.{});
}

/// The id property of the doc nearest `vector`.
fn nearest(ast: *Ast, g: *Graph, vector: []const u8, id: i64) !void {
    var text: [160]u8 = undefined;
    const query = try std.fmt.bufPrint(&text, "CALL db.index.vector.queryNodes('docs', 1, {s}) YIELD node RETURN node.id", .{vector});
    try expectQuery(ast, g, query, &.{&.{int(id)}});
}

test "a rebuild goes in batches, searched in the old generation and kept by writes meanwhile" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.population_budget = .{ .entities = 10, .nanoseconds = std.math.maxInt(u64) };
    store.vector_rebuild_tombstones = 16;
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 100);
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&store);
    try expectOnline(&g, "docs", 0, null);

    // 70 tombstones, 30 alive: the delete only marks the index.
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id >= 30 DETACH DELETE d", &.{});
    try expectOnline(&g, "docs", 0, 0);
    try testing.expectEqual(@as(usize, 0), try keysOf(&store, 1, 1));
    try expectQuery(&ast, &g, count_docs, &.{&.{int(30)}});
    try expectSound(&g);

    // A batch: the first 10 are in generation 1.
    try testing.expect(try population.advanceAny(&store));
    try expectOnline(&g, "docs", 0, 10);
    try expectSound(&g);

    // Writes below where the rebuild got to and above it.
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 2}) SET d.v = [0.0, 0.0, 0.0, 1.0]", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 25}) SET d.v = [0.0, 0.0, 1.0, 0.0]", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id IN [1, 28] DETACH DELETE d", &.{});
    try expectQuery(&ast, &g, "UNWIND range(200, 204) AS i CREATE (:Doc {id: i, v: [1.0, toFloat(i), 0.0, 0.0]})", &.{});
    try expectSound(&g);
    try expectQuery(&ast, &g, count_docs, &.{&.{int(33)}});
    try nearest(&ast, &g, "[0, 0, 0, 1]", 2);

    try population.finish(&store);
    try expectOnline(&g, "docs", 1, null);
    try testing.expectEqual(@as(usize, 0), try keysOf(&store, 1, 0));
    try expectSound(&g);
    try expectQuery(&ast, &g, count_docs, &.{&.{int(33)}});
    try nearest(&ast, &g, "[0, 0, 0, 1]", 2);
    try nearest(&ast, &g, "[0, 0, 1, 0]", 25);

    // The next rebuild goes into generation 2, past the old one's keys.
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id >= 3 DETACH DELETE d", &.{});
    try expectQuery(&ast, &g, "UNWIND range(0, 39) AS i CREATE (:Doc {id: 1000 + i, v: [1.0, 1.0, toFloat(i), 0.0]})", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id >= 1000 DETACH DELETE d", &.{});
    try expectOnline(&g, "docs", 1, 0);
    try population.finish(&store);
    try expectOnline(&g, "docs", 2, null);
    try testing.expectEqual(@as(usize, 0), try keysOf(&store, 1, 1));
    try expectSound(&g);
    try expectQuery(&ast, &g, count_docs, &.{&.{int(2)}});
}

test "tombstones past the threshold while populating start a rebuild when population ends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.population_budget = .{ .entities = 60, .nanoseconds = std.math.maxInt(u64) };
    store.vector_rebuild_tombstones = 16;
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 100);
    try expectQuery(&ast, &g, node_index, &.{});
    // 55 of the 60 placed go while the index populates: then 55
    // tombstones, 45 alive.
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id >= 5 AND d.id < 60 DETACH DELETE d", &.{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try stateOf(&g, arena.allocator(), "docs") == .populating);
    try testing.expect(try population.advanceAny(&store));
    try expectOnline(&g, "docs", 0, 0);
    try population.finish(&store);
    try expectOnline(&g, "docs", 1, null);
    try expectSound(&g);
    try expectQuery(&ast, &g, count_docs, &.{&.{int(45)}});
}

test "a dropped index and a failed one leave their keys to the builder" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    // Each CREATE populates its index whole.
    store.population_budget = .{ .nanoseconds = std.math.maxInt(u64) };
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 50);
    try expectQuery(&ast, &g, node_index, &.{});
    const kept = try keysOf(&store, 1, null);
    try expectQuery(&ast, &g, "DROP INDEX docs", &.{});
    try testing.expectEqual(kept, try keysOf(&store, 1, null));
    try expectSound(&g);
    // Created again meanwhile: a new id, its own keys.
    try expectQuery(&ast, &g, node_index, &.{});
    try expectQuery(&ast, &g, count_docs, &.{&.{int(50)}});
    try expectSound(&g);
    try population.finish(&store);
    try testing.expectEqual(@as(usize, 0), try keysOf(&store, 1, null));
    try testing.expectEqual(kept, try keysOf(&store, 2, null));
    try expectSound(&g);

    // Failed after a first batch placed some: all but its state goes.
    store.population_budget = .{ .entities = 5, .nanoseconds = std.math.maxInt(u64) };
    try expectQuery(&ast, &g, "UNWIND range(0, 19) AS i CREATE (:Note {id: i, v: [toFloat(i) + 1.0, 1.0, 0.0]})", &.{});
    try expectQuery(&ast, &g, "CREATE (:Note {id: 20, v: [1.0, 2.0]})", &.{});
    try expectQuery(&ast, &g, "CREATE VECTOR INDEX notes FOR (n:Note) ON n.v OPTIONS {indexConfig: {`vector.dimensions`: 3}}", &.{});
    try testing.expect(try keysOf(&store, 3, null) > 1);
    try population.finish(&store);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(try stateOf(&g, arena.allocator(), "notes") == .failed);
    try testing.expectEqual(@as(usize, 1), try keysOf(&store, 3, null));
    try expectSound(&g);
    try testing.expect(!try population.anyWork(&store));
}

test "the builder thread goes on with a rebuild after a reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    {
        // No builder: the rebuild waits for the next open.
        var store = try openStore(&tmp, &path_buffer);
        defer store.deinit();
        store.vector_rebuild_tombstones = 16;
        store.population_budget = .{ .nanoseconds = std.math.maxInt(u64) };
        var g = Graph.init(&store, testing.allocator);
        try createDocs(&ast, &g, 100);
        try expectQuery(&ast, &g, node_index, &.{});
        try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id >= 30 DETACH DELETE d", &.{});
        store.population_budget = .{ .entities = 10, .nanoseconds = std.math.maxInt(u64) };
        try testing.expect(try population.advanceAny(&store));
        try expectOnline(&g, "docs", 0, 10);
    }
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.population_budget = .{ .entities = 10, .nanoseconds = std.math.maxInt(u64) };
    const builder = try population.Builder.start(testing.allocator, &store);
    defer builder.stop();
    var session = try store.share();
    defer session.deinit();
    var g = Graph.init(&session, testing.allocator);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..6000) |_| {
        if (!try population.anyWork(&session)) break;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    } else return error.TestTimeout;
    try expectOnline(&g, "docs", 1, null);
    try expectSound(&g);
    try expectQuery(&ast, &g, count_docs, &.{&.{int(30)}});
}

test "a replica copied mid-rebuild goes on with it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var master = try openAt(&tmp, "master", &master_path);
    defer master.deinit();
    try master.startChangeLog();
    master.population_budget = .{ .entities = 10, .nanoseconds = std.math.maxInt(u64) };
    master.vector_rebuild_tombstones = 16;
    var replica_path: [256]u8 = undefined;
    var replica = try openAt(&tmp, "replica", &replica_path);
    defer replica.deinit();
    replica.population_budget = master.population_budget;
    replica.vector_rebuild_tombstones = master.vector_rebuild_tombstones;
    var g = Graph.init(&master, testing.allocator);
    var replica_graph = Graph.init(&replica, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 100);
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&master);
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id >= 30 DETACH DELETE d", &.{});
    try testing.expect(try population.advanceAny(&master));
    var copy: std.Io.Writer.Allocating = .init(testing.allocator);
    defer copy.deinit();
    var next = try master.writeCopy(&copy.writer) + 1;
    try testing.expect(try replica.applyCopyPart(copy.written(), false) == null);
    _ = (try replica.applyCopyPart("", true)).?;
    try expectOnline(&replica_graph, "docs", 0, 10);
    try expectSound(&replica_graph);

    // Writes the replica applies while it rebuilds.
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 2}) SET d.v = [0.0, 0.0, 0.0, 1.0]", &.{});
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id IN [1, 28] DETACH DELETE d", &.{});
    try replay(&master, &replica, &next);
    try expectSound(&replica_graph);
    try population.finish(&replica);
    try expectOnline(&replica_graph, "docs", 1, null);
    try expectSound(&replica_graph);
    try expectQuery(&ast, &replica_graph, count_docs, &.{&.{int(28)}});
    try nearest(&ast, &replica_graph, "[0, 0, 0, 1]", 2);
    // The master, its own rebuild left as it was, is sound too.
    try expectOnline(&g, "docs", 0, 10);
    try population.finish(&master);
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
