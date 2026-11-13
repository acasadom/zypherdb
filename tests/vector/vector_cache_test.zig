//! The cache of vector index entries a store keeps across transactions
//! (src/storage/vector_cache.zig): current after another store's write,
//! after an aborted write whose transaction id the engine hands out
//! again, after a rebuild and after a copy; within its limit between
//! transactions, by the clock.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const KeyValueStore = zypherdb.KeyValueStore;
const Value = zypherdb.Value;
const population = zypherdb.vector.population;
const vector_index = zypherdb.vector.index;
const VectorCache = zypherdb.vector.cache.VectorCache;

const support = @import("../support.zig");
const openStore = support.openStore;
const testPath = support.testPath;
const expectQuery = support.expectQuery;
const expectQueryError = support.expectQueryError;

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

test "a store reads the entries another store wrote, not those it kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var other = try store.share();
    defer other.deinit();
    var g = Graph.init(&store, testing.allocator);
    var other_graph = Graph.init(&other, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 50);
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&store);
    try nearest(&ast, &g, "[0, 0, 0, 1]", 0);
    try testing.expect(store.vector_cache.bytes > 0);

    try expectQuery(&ast, &other_graph, "MATCH (d:Doc {id: 7}) SET d.v = [0.0, 0.0, 0.0, 1.0]", &.{});
    try expectQuery(&ast, &other_graph, "MATCH (d:Doc) WHERE d.id >= 40 DETACH DELETE d", &.{});
    try nearest(&ast, &g, "[0, 0, 0, 1]", 7);
    try expectQuery(&ast, &g, count_docs, &.{&.{int(40)}});
    try expectSound(&g);

    // And the other way round, after this store's own writes.
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 7}) SET d.v = [0.0, 0.0, 1.0, 0.0]", &.{});
    try nearest(&ast, &other_graph, "[0, 0, 1, 0]", 7);
    try expectSound(&other_graph);
    try expectSound(&g);
}

test "an aborted write leaves nothing in the cache, though its transaction id comes again" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var other = try store.share();
    defer other.deinit();
    var g = Graph.init(&store, testing.allocator);
    var other_graph = Graph.init(&other, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 50);
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&store);

    // The SET places doc 3 in the index; the CREATE after it fails the
    // statement, and its transaction is aborted.
    try expectQueryError(&ast, &g, "MATCH (d:Doc {id: 3}) SET d.v = [0.0, 1.0, 0.0, 0.0] CREATE (:Doc {id: 99, v: [1.0, 2.0]})", error.ConstraintViolation);
    // The next write transaction, another store's, has the aborted one's id.
    try expectQuery(&ast, &other_graph, "MATCH (d:Doc {id: 5}) SET d.v = [0.0, 0.0, 1.0, 0.0]", &.{});
    try nearest(&ast, &g, "[0, 1, 0, 0]", 0);
    try nearest(&ast, &g, "[0, 0, 1, 0]", 5);
    try expectSound(&g);
}

test "a rebuild's generation is read from the store, the old one's entries left to the clock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.vector_rebuild_tombstones = 16;
    var other = try store.share();
    defer other.deinit();
    var g = Graph.init(&store, testing.allocator);
    var other_graph = Graph.init(&other, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 100);
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&store);
    try nearest(&ast, &other_graph, "[1, 0, 0, 0]", 99);
    try expectQuery(&ast, &g, "MATCH (d:Doc) WHERE d.id >= 30 DETACH DELETE d", &.{});
    try population.finish(&store);
    try nearest(&ast, &other_graph, "[1, 0, 0, 0]", 29);
    try expectQuery(&ast, &other_graph, count_docs, &.{&.{int(30)}});
    try expectSound(&other_graph);
}

test "a copy loaded gives each generation the loading transaction's version, not the master's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var master_path: [256]u8 = undefined;
    var master = try openStore(&tmp, &master_path);
    defer master.deinit();
    try master.startChangeLog();
    var g = Graph.init(&master, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try createDocs(&ast, &g, 20);
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&master);

    var replica_base: [128]u8 = undefined;
    var replica_path: [256]u8 = undefined;
    try tmp.dir.createDirPath(testing.io, "replica");
    var replica = try KeyValueStore.open(testing.allocator, try std.fmt.bufPrint(&replica_path, "{s}/replica", .{testPath(&tmp, &replica_base)}));
    defer replica.deinit();
    var copy: std.Io.Writer.Allocating = .init(testing.allocator);
    defer copy.deinit();
    _ = try master.writeCopy(&copy.writer);
    _ = try replica.applyCopyPart(copy.written(), true);

    var key: [7]u8 = undefined;
    key[0..6].* = vector_index.generationPrefix(1, 0);
    key[6] = 'V';
    try testing.expect(vector_index.isVersionKey(&key));
    const version = (try replica.get(&key)).?;
    defer testing.allocator.free(version);
    try replica.beginRead();
    const loaded = replica.transactionId().?;
    replica.abortRead();
    try testing.expectEqualSlices(u8, &vector_index.encodeVersion(loaded), version);
    var replica_graph = Graph.init(&replica, testing.allocator);
    try nearest(&ast, &replica_graph, "[1, 0, 0, 0]", 19);
    try expectSound(&replica_graph);
}

test "the cache stays within its limit between transactions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    store.vector_cache.limit = 4096;
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try createDocs(&ast, &g, 200);
    try expectQuery(&ast, &g, node_index, &.{});
    try population.finish(&store);
    try nearest(&ast, &g, "[1, 0, 0, 0]", 199);
    try expectQuery(&ast, &g, "MATCH (d:Doc {id: 50}) SET d.v = [0.0, 0.0, 0.0, 1.0]", &.{});
    try nearest(&ast, &g, "[0, 0, 0, 1]", 50);
    try store.beginRead();
    try testing.expect(store.vector_cache.bytes <= store.vector_cache.limit);
    store.abortRead();
    try expectSound(&g);
}

test "an entry read since the clock last passed it outlives one that was not" {
    var cache = VectorCache.init(testing.allocator);
    defer cache.deinit();
    const vector = [_]f32{ 1, 2, 3, 4 };
    const kept = try cache.generation(.{ .index_id = 1, .generation = 0 }, 7);
    _ = try cache.keepEntity(kept, 1, 0, true, &vector);
    _ = try cache.keepEntity(kept, 2, 0, true, &vector);
    cache.limit = cache.bytes;
    _ = try cache.keepEntity(kept, 3, 0, true, &vector);
    _ = try cache.keepEntity(kept, 4, 0, true, &vector);
    cache.evict();
    try testing.expectEqual(@as(usize, 2), kept.entities.count());

    // Both left are unmarked now; the one read is kept, with a new one.
    const read = kept.entities.keys()[0];
    const unread = kept.entities.keys()[1];
    try testing.expect(cache.findEntity(kept, read) != null);
    _ = try cache.keepEntity(kept, 5, 0, true, &vector);
    cache.evict();
    try testing.expect(cache.findEntity(kept, read) != null);
    try testing.expect(cache.findEntity(kept, 5) != null);
    try testing.expect(cache.findEntity(kept, unread) == null);

    // Another version drops them all.
    const again = try cache.generation(.{ .index_id = 1, .generation = 0 }, 8);
    try testing.expectEqual(kept, again);
    try testing.expectEqual(@as(usize, 0), again.entities.count());
    try testing.expectEqual(@as(usize, 0), cache.bytes);
}
