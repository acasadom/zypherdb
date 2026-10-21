//! Graph storage: nodes, labels, edges, properties and their indexes.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Graph = acmedb.Graph;
const NodeId = acmedb.NodeId;
const NodeIdIterator = acmedb.NodeIdIterator;

const support = @import("../support.zig");
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

    _ = try g.addEdge(keanu, matrix, "ACTED_IN");
    _ = try g.addEdge(keanu, reloaded, "ACTED_IN");
    _ = try g.addEdge(keanu, wick, "ACTED_IN");
    _ = try g.addEdge(lana, matrix, "DIRECTED");

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

test "allocateNodeId and deleteNode detach edges" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    const a = try g.allocateNodeId();
    const b = try g.allocateNodeId();
    try testing.expect(a != b);

    try g.addNode(a, "Person");
    try g.setProperty(a, "name", .{ .string = "Neo" });
    try g.addNode(b, "Person");
    _ = try g.addEdge(a, b, "KNOWS");

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
    const a = try g.allocateNodeId();
    const b = try g.allocateNodeId();
    try testing.expect(a != b);
    try g.addNode(a, "Person");
    try g.setProperty(a, "name", .{ .string = "A" });
    _ = try g.addEdge(a, b, "KNOWS");
    try g.commitWrite();

    try testing.expect(try g.hasNode(a));
    try testing.expect(try g.hasEdge(a, b, "KNOWS"));

    // Abort path: nothing is visible, and the counter increment is rolled back.
    try g.beginWrite();
    const c = try g.allocateNodeId();
    try g.addNode(c, "Person");
    g.abortWrite();

    try testing.expect(!try g.hasNode(c));
    try testing.expectEqual(c, try g.allocateNodeId()); // counter rolled back, so c is reused
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
    const knows = try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProperty(knows, "weight", .{ .int = 5 });

    const w = (try g.getEdgeProperty(knows, "weight", testing.allocator)).?;
    try testing.expectEqual(@as(i64, 5), w.int);
    try testing.expect((try g.getEdgeProperty(knows, "nope", testing.allocator)) == null);

    // Detach-deleting a node removes its edge properties too.
    try g.deleteNodeDetach(1);
    try testing.expect(!try g.hasEdge(1, 2, "KNOWS"));
    try testing.expect(!try g.hasRelationship(knows));
    try testing.expect((try g.getEdgeProperty(knows, "weight", testing.allocator)) == null);
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
    const first = try g.addEdge(1, 2, "KNOWS");
    try g.setEdgeProperty(first, "weight", .{ .int = 5 });
    const second = try g.addEdge(1, 3, "KNOWS");
    try g.setEdgeProperty(second, "weight", .{ .int = 9 });

    // Index lookup returns the matching relationship (id, src, dst, edge_type).
    var iterator = try g.edgesByProperty("weight", .{ .int = 5 });
    defer iterator.deinit();
    const e = (try iterator.next()).?;
    try testing.expectEqual(first, e.id);
    try testing.expectEqual(@as(NodeId, 1), e.src);
    try testing.expectEqual(@as(NodeId, 2), e.dst);
    try testing.expectEqualStrings("KNOWS", e.edge_type);
    try testing.expect((try iterator.next()) == null);

    // Updating a value moves the index entry.
    try g.setEdgeProperty(first, "weight", .{ .int = 9 });
    var it2 = try g.edgesByProperty("weight", .{ .int = 5 });
    defer it2.deinit();
    try testing.expect((try it2.next()) == null);
    var it3 = try g.edgesByProperty("weight", .{ .int = 9 });
    defer it3.deinit();
    _ = (try it3.next()).?;
    _ = (try it3.next()).?;
    try testing.expect((try it3.next()) == null);

    // Removing a property removes its index entry.
    try g.removeEdgeProperty(first, "weight");
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

    _ = try g.addEdge(1, 2, "KNOWS");
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("KNOWS"));

    // Adding it again adds a second, parallel relationship.
    _ = try g.addEdge(1, 2, "KNOWS");
    try testing.expectEqual(@as(usize, 2), try g.edgeTypeCount("KNOWS"));

    _ = try g.addEdge(1, 3, "KNOWS");
    _ = try g.addEdge(2, 3, "LIKES");
    try testing.expectEqual(@as(usize, 3), try g.edgeTypeCount("KNOWS"));
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("LIKES"));

    // Detach-deleting a node decrements its edge types.
    try g.deleteNodeDetach(1);
    try testing.expectEqual(@as(usize, 0), try g.edgeTypeCount("KNOWS"));
    try testing.expectEqual(@as(usize, 1), try g.edgeTypeCount("LIKES"));
}

fn rangeIds(g: *Graph, name: []const u8, lower: ?acmedb.Value, upper: ?acmedb.Value) ![]NodeId {
    var iterator = (try g.nodesInRange(name, lower, upper)).?;
    defer iterator.deinit();
    var ids = std.ArrayList(NodeId).empty;
    while (try iterator.next()) |id| try ids.append(testing.allocator, id);
    std.mem.sort(NodeId, ids.items, {}, std.sort.asc(NodeId));
    return ids.toOwnedSlice(testing.allocator);
}

fn expectRange(g: *Graph, name: []const u8, lower: ?acmedb.Value, upper: ?acmedb.Value, expected: []const NodeId) !void {
    const ids = try rangeIds(g, name, lower, upper);
    defer testing.allocator.free(ids);
    try testing.expectEqualSlices(NodeId, expected, ids);
}

test "range lookups over the property index: numbers and dates in order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    // Integers of both signs and floats, integral or not, under one property.
    const values = [_]acmedb.Value{ .{ .int = -5 }, .{ .int = -1 }, .{ .int = 0 }, .{ .float = 0.5 }, .{ .int = 3 }, .{ .float = 3.0 }, .{ .float = -2.5 }, .{ .int = 100 }, .{ .float = std.math.nan(f64) }, .{ .string = "7" } };
    for (values, 1..) |value, id| {
        try g.addNode(id, "N");
        try g.setProperty(id, "x", value);
    }
    // x >= -2 and x <= 3: -1, 0, 0.5, 3, 3.0.
    try expectRange(&g, "x", .{ .int = -2 }, .{ .int = 3 }, &.{ 2, 3, 4, 5, 6 });
    // Fractional bounds round outwards: a superset, checked again by the caller.
    try expectRange(&g, "x", .{ .float = -2.5 }, .{ .float = 0.25 }, &.{ 2, 3, 7 });
    // One side open; NaN and the string are never in a numeric range.
    try expectRange(&g, "x", .{ .int = 4 }, null, &.{8});
    try expectRange(&g, "x", null, .{ .int = -2 }, &.{ 1, 7 });
    try expectRange(&g, "x", .{ .float = std.math.nan(f64) }, null, &.{});
    // A string bound has no range: the caller scans instead.
    try testing.expect((try g.nodesInRange("x", .{ .string = "a" }, null)) == null);

    // Dates, before and after 1970.
    for ([_]i64{ -400, -1, 0, 20000 }, 20..) |days, id| {
        try g.addNode(id, "D");
        try g.setProperty(id, "on", .{ .date = .{ .days = days } });
    }
    try expectRange(&g, "on", .{ .date = .{ .days = -1 } }, .{ .date = .{ .days = 0 } }, &.{ 21, 22 });
    try expectRange(&g, "on", null, .{ .date = .{ .days = -2 } }, &.{20});
    // A range finds what equality finds: the index stays canonical.
    var equal = try g.nodesByProperty("x", .{ .float = 3.0 });
    defer equal.deinit();
    try testing.expectEqual(@as(?NodeId, 5), try equal.next());
    try testing.expectEqual(@as(?NodeId, 6), try equal.next());
}

test "label counts track labels added, removed and deleted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try testing.expectEqual(@as(usize, 0), try g.labelCount("Person"));
    try g.addNode(1, "Person");
    try g.addNode(2, "Person");
    try g.addNode(3, "Team");
    try testing.expectEqual(@as(usize, 2), try g.labelCount("Person"));
    try testing.expectEqual(@as(usize, 1), try g.labelCount("Team"));

    // Adding a label a node has, or removing one it lacks, changes nothing.
    try g.addLabel(1, "Person");
    try g.removeLabel(3, "Person");
    try testing.expectEqual(@as(usize, 2), try g.labelCount("Person"));

    try g.addLabel(3, "Person");
    try g.removeLabel(1, "Person");
    try testing.expectEqual(@as(usize, 2), try g.labelCount("Person"));

    // Deleting a node removes it from every label it carried.
    try g.deleteNodeDetach(3);
    try testing.expectEqual(@as(usize, 1), try g.labelCount("Person"));
    try testing.expectEqual(@as(usize, 0), try g.labelCount("Team"));
    try testing.expectEqual(@as(usize, 0), try g.labelCount("Unknown"));
}

test "labelsOf, propertiesOf, edgePropertiesOf and edgesOf enumerate a node" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.addNode(1, "Person");
    try g.addLabel(1, "Admin");
    try g.setProperty(1, "name", .{ .string = "Ana" });
    try g.setProperty(1, "age", .{ .int = 40 });
    try g.addNode(2, "");
    try g.addNode(3, "");
    const knows = try g.addEdge(1, 2, "KNOWS");
    _ = try g.addEdge(1, 3, "OWNS");
    try g.setEdgeProperty(knows, "since", .{ .int = 2020 });

    var labels = try g.labelsOf(1);
    defer labels.deinit();
    try testing.expectEqualStrings("Admin", (try labels.next()).?);
    try testing.expectEqualStrings("Person", (try labels.next()).?);
    try testing.expect((try labels.next()) == null);

    var properties = try g.propertiesOf(1);
    defer properties.deinit();
    const age = (try properties.next()).?;
    try testing.expectEqualStrings("age", age.name);
    try testing.expectEqual(@as(i64, 40), (try age.value(testing.allocator)).int);
    try testing.expectEqualStrings("name", (try properties.next()).?.name);
    try testing.expect((try properties.next()) == null);

    var edge_properties = try g.edgePropertiesOf(knows);
    defer edge_properties.deinit();
    try testing.expectEqualStrings("since", (try edge_properties.next()).?.name);
    try testing.expect((try edge_properties.next()) == null);

    // Every outgoing edge, whatever its type.
    var edges = try g.edgesOf(1, .out);
    defer edges.deinit();
    const first = (try edges.next()).?;
    try testing.expectEqualStrings("KNOWS", first.edge_type);
    try testing.expectEqual(@as(NodeId, 2), first.neighbour);
    try testing.expectEqualStrings("OWNS", (try edges.next()).?.edge_type);
    try testing.expect((try edges.next()) == null);

    var incoming = try g.edgesOf(2, .in);
    defer incoming.deinit();
    try testing.expectEqual(@as(NodeId, 1), (try incoming.next()).?.neighbour);
}

fn bigEndian(comptime T: type, n: T) [@sizeOf(T)]u8 {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, n, .big);
    return bytes;
}

/// The key holding the storage format (src/storage/key_encoding.zig).
const format_key = "!format";

test "checkFormat stamps a new database and refuses another format" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);

    try g.checkFormat();
    const stamped = (try store.get(format_key)).?;
    defer testing.allocator.free(stamped);
    try testing.expectEqualSlices(u8, &bigEndian(u32, Graph.format_version), stamped);
    try g.checkFormat(); // its own format: accepted, unchanged

    try store.put(format_key, &bigEndian(u32, Graph.format_version + 1));
    try testing.expectError(error.IncompatibleFormat, g.checkFormat());
}
