//! Graph storage: nodes, labels, edges, properties and their indexes.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Graph = acmedb.Graph;
const KeyValueStore = acmedb.KeyValueStore;
const NodeId = acmedb.NodeId;
const NodeIdIterator = acmedb.NodeIdIterator;

const support = @import("../support.zig");
const testPath = support.testPath;
const openStore = support.openStore;

fn expectNext(iterator: *NodeIdIterator, expected: NodeId) !void {
    const got = try iterator.next();
    try testing.expect(got != null);
    try testing.expectEqual(expected, got.?);
}

test "neighbours scans outgoing, incoming and type-filtered edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    const keanu: NodeId = 1;
    const lana: NodeId = 2;
    const matrix: NodeId = 100;
    const reloaded: NodeId = 101;
    const wick: NodeId = 102;

    try g.addNode(keanu, "");
    try g.addNode(lana, "");
    try g.addNode(matrix, "");
    try g.addNode(reloaded, "");
    try g.addNode(wick, "");

    try g.addEdge(keanu, matrix, "ACTED_IN");
    try g.addEdge(keanu, reloaded, "ACTED_IN");
    try g.addEdge(keanu, wick, "ACTED_IN");
    try g.addEdge(lana, matrix, "DIRECTED");

    // Outgoing ACTED_IN of keanu, in ascending neighbour-id order.
    var iterator = try g.neighbours(keanu, .out, "ACTED_IN");
    defer iterator.deinit();
    try expectNext(&iterator, matrix);
    try expectNext(&iterator, reloaded);
    try expectNext(&iterator, wick);
    try testing.expect((try iterator.next()) == null);

    // Incoming ACTED_IN of matrix: only keanu.
    var it2 = try g.neighbours(matrix, .in, "ACTED_IN");
    defer it2.deinit();
    try expectNext(&it2, keanu);
    try testing.expect((try it2.next()) == null);

    // Incoming DIRECTED of matrix: only lana (type filter isolates it).
    var it3 = try g.neighbours(matrix, .in, "DIRECTED");
    defer it3.deinit();
    try expectNext(&it3, lana);
    try testing.expect((try it3.next()) == null);

    // A node with no edges of the requested type yields no neighbours.
    var it4 = try g.neighbours(lana, .in, "ACTED_IN");
    defer it4.deinit();
    try testing.expect((try it4.next()) == null);
}

test "addNode and hasNode track node existence" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try testing.expect(!try g.hasNode(7));
    try g.addNode(7, "");
    try testing.expect(try g.hasNode(7));
    try testing.expect(!try g.hasNode(8));
}

test "allNodes yields labeled and unlabeled nodes, skipping property keys" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(3, "");
    try g.addNode(1, "Person");
    try g.setProperty(1, "name", .{ .string = "A" });
    try g.setProperty(3, "v", .{ .int = 7 });

    var iterator = try g.allNodes();
    defer iterator.deinit();
    try expectNext(&iterator, 1);
    try expectNext(&iterator, 3);
    try testing.expect((try iterator.next()) == null);
}

test "labels, properties and value encoding" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "Person");
    try g.addNode(2, "Person");
    try g.addNode(100, "Movie");

    // label index
    var iterator = try g.nodesWithLabel("Person");
    defer iterator.deinit();
    try expectNext(&iterator, 1);
    try expectNext(&iterator, 2);
    try testing.expect((try iterator.next()) == null);

    try testing.expect(try g.hasLabel(100, "Movie"));
    try testing.expect(!try g.hasLabel(100, "Person"));

    // properties: string and int round-trip
    try g.setProperty(1, "name", .{ .string = "Keanu Reeves" });
    try g.setProperty(1, "born", .{ .int = 1964 });

    const name = (try g.getProperty(1, "name", testing.allocator)).?;
    defer testing.allocator.free(name.string);
    try testing.expectEqualStrings("Keanu Reeves", name.string);

    const born = (try g.getProperty(1, "born", testing.allocator)).?;
    try testing.expectEqual(@as(i64, 1964), born.int);

    // absent property -> null
    try testing.expect((try g.getProperty(1, "nope", testing.allocator)) == null);
}

test "allocNodeId and deleteNode detach edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    const a = try g.allocNodeId();
    const b = try g.allocNodeId();
    try testing.expect(a != b);

    try g.addNode(a, "Person");
    try g.setProperty(a, "name", .{ .string = "Neo" });
    try g.addNode(b, "Person");
    try g.addEdge(a, b, "KNOWS");

    try testing.expect(try g.hasLabel(a, "Person"));
    var iterator = try g.neighbours(a, .out, "KNOWS");
    defer iterator.deinit();
    try expectNext(&iterator, b);
    try testing.expect((try iterator.next()) == null);

    try g.deleteNodeDetach(a);

    try testing.expect(!try g.hasNode(a));
    try testing.expect(!try g.hasLabel(a, "Person"));
    try testing.expect(try g.hasNode(b));
    var it2 = try g.neighbours(b, .in, "KNOWS");
    defer it2.deinit();
    try testing.expect((try it2.next()) == null);
}

test "write transactions commit and abort atomically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // Commit path: batched writes are all visible, and the id counter advances
    // within the transaction (read-modify-write on the write txn).
    try g.beginWrite();
    const a = try g.allocNodeId();
    const b = try g.allocNodeId();
    try testing.expect(a != b);
    try g.addNode(a, "Person");
    try g.setProperty(a, "name", .{ .string = "A" });
    try g.addEdge(a, b, "KNOWS");
    try g.commitWrite();

    try testing.expect(try g.hasNode(a));
    try testing.expect(try g.hasEdge(a, b, "KNOWS"));

    // Abort path: nothing is visible, and the counter increment is rolled back.
    try g.beginWrite();
    const c = try g.allocNodeId();
    try g.addNode(c, "Person");
    g.abortWrite();

    try testing.expect(!try g.hasNode(c));
    try testing.expectEqual(c, try g.allocNodeId()); // counter rolled back, so c is reused
}

test "property index: lookups, updates and deletes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "Person");
    try g.setProperty(1, "name", .{ .string = "Keanu Reeves" });
    try g.addNode(2, "Person");
    try g.setProperty(2, "name", .{ .string = "Carrie-Anne Moss" });
    try g.addNode(3, "Person");
    try g.setProperty(3, "name", .{ .string = "Keanu Reeves" });

    // Two nodes share the name "Keanu Reeves".
    var iterator = try g.nodesByProperty("name", .{ .string = "Keanu Reeves" });
    defer iterator.deinit();
    try expectNext(&iterator, 1);
    try expectNext(&iterator, 3);
    try testing.expect((try iterator.next()) == null);

    // Integer index lookup.
    try g.setProperty(1, "born", .{ .int = 1964 });
    var it2 = try g.nodesByProperty("born", .{ .int = 1964 });
    defer it2.deinit();
    try expectNext(&it2, 1);
    try testing.expect((try it2.next()) == null);

    // Updating a value moves the index entry.
    try g.setProperty(3, "name", .{ .string = "Laurence Fishburne" });
    var it3 = try g.nodesByProperty("name", .{ .string = "Keanu Reeves" });
    defer it3.deinit();
    try expectNext(&it3, 1);
    try testing.expect((try it3.next()) == null);

    // Deleting a node removes its index entries.
    try g.deleteNode(1);
    var it4 = try g.nodesByProperty("name", .{ .string = "Keanu Reeves" });
    defer it4.deinit();
    try testing.expect((try it4.next()) == null);
}

test "edge properties round-trip and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "Person");
    try g.addNode(2, "Person");
    try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProperty(1, 2, "KNOWS", "weight", .{ .int = 5 });

    const w = (try g.getEdgeProperty(1, 2, "KNOWS", "weight", testing.allocator)).?;
    try testing.expectEqual(@as(i64, 5), w.int);
    try testing.expect((try g.getEdgeProperty(1, 2, "KNOWS", "nope", testing.allocator)) == null);

    // Detach-deleting a node removes its edge properties too.
    try g.deleteNodeDetach(1);
    try testing.expect(!try g.hasEdge(1, 2, "KNOWS"));
    try testing.expect((try g.getEdgeProperty(1, 2, "KNOWS", "weight", testing.allocator)) == null);
}

test "edge-property index: seek, update and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "");
    try g.addNode(2, "");
    try g.addNode(3, "");
    try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProperty(1, 2, "KNOWS", "weight", .{ .int = 5 });
    try g.addEdge(1, 3, "KNOWS");
    try g.setEdgeProperty(1, 3, "KNOWS", "weight", .{ .int = 9 });

    // Index lookup returns the matching edge (src, dst, edge_type).
    var iterator = try g.edgesByProperty("weight", .{ .int = 5 });
    defer iterator.deinit();
    const e = (try iterator.next()).?;
    try testing.expectEqual(@as(NodeId, 1), e.src);
    try testing.expectEqual(@as(NodeId, 2), e.dst);
    try testing.expectEqualStrings("KNOWS", e.edge_type);
    try testing.expect((try iterator.next()) == null);

    // Updating a value moves the index entry.
    try g.setEdgeProperty(1, 2, "KNOWS", "weight", .{ .int = 9 });
    var it2 = try g.edgesByProperty("weight", .{ .int = 5 });
    defer it2.deinit();
    try testing.expect((try it2.next()) == null);
    var it3 = try g.edgesByProperty("weight", .{ .int = 9 });
    defer it3.deinit();
    _ = (try it3.next()).?;
    _ = (try it3.next()).?;
    try testing.expect((try it3.next()) == null);

    // Removing a property removes its index entry.
    try g.removeEdgeProperty(1, 2, "KNOWS", "weight");
    var it4 = try g.edgesByProperty("weight", .{ .int = 9 });
    defer it4.deinit();
    _ = (try it4.next()).?;
    try testing.expect((try it4.next()) == null);

    // Detach-delete removes remaining edge index entries.
    try g.deleteNodeDetach(1);
    var it5 = try g.edgesByProperty("weight", .{ .int = 9 });
    defer it5.deinit();
    try testing.expect((try it5.next()) == null);
}

test "edge-type cardinality tracks add and delete" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "");
    try g.addNode(2, "");
    try g.addNode(3, "");

    try testing.expectEqual(@as(usize, 0), try g.edgeTypeCount("KNOWS"));

    try g.addEdge(1, 2, "KNOWS");
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("KNOWS"));

    // Re-adding the same edge is idempotent.
    try g.addEdge(1, 2, "KNOWS");
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("KNOWS"));

    try g.addEdge(1, 3, "KNOWS");
    try g.addEdge(2, 3, "LIKES");
    try testing.expectEqual(@as(usize, 2), try g.edgeTypeCount("KNOWS"));
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("LIKES"));

    // Detach-deleting a node decrements its edge types.
    try g.deleteNodeDetach(1);
    try testing.expectEqual(@as(usize, 0), try g.edgeTypeCount("KNOWS"));
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("LIKES"));
}
