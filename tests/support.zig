//! Shared test support: temporary stores, the "people and movies" fixture
//! graph, and query assertions.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const KeyValueStore = acmedb.KeyValueStore;
const NodeId = acmedb.NodeId;
const Row = acmedb.Row;
const Value = acmedb.Value;
const Executor = acmedb.Executor;
const parser = acmedb.parser;
const eqlSequences = acmedb.eqlSequences;

/// Equal values of the same types, element by element: `Value.eql` holds
/// 1 and 1.0 equal (as grouping does), a test result must not.
fn identicalSequences(a: []const Value, b: []const Value) bool {
    if (!eqlSequences(a, b)) return false;
    for (a, b) |x, y| {
        if (!identicalTypes(x, y)) return false;
    }
    return true;
}

fn identicalTypes(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .list => |items| for (items, b.list) |x, y| {
            if (!identicalTypes(x, y)) break false;
        } else true,
        .map => |entries| for (entries, b.map) |x, y| {
            if (!identicalTypes(x.value, y.value)) break false;
        } else true,
        else => true,
    };
}

/// The path of a test's temporary directory, relative to the build root.
pub fn testPath(tmp: *testing.TmpDir, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
}

/// Opens a fresh store in the test's temporary directory.
pub fn openStore(tmp: *testing.TmpDir, buffer: []u8) !KeyValueStore {
    return KeyValueStore.open(testing.allocator, testPath(tmp, buffer));
}

/// Loads the "people and movies" fixture graph (see docs/tutorial).
pub fn loadMoviesGraph(g: *Graph) !void {
    const P = struct { id: NodeId, name: []const u8, born: i64 };
    const M = struct { id: NodeId, title: []const u8, released: i64 };
    const people = [_]P{
        .{ .id = 1, .name = "Keanu Reeves", .born = 1964 },
        .{ .id = 2, .name = "Carrie-Anne Moss", .born = 1967 },
        .{ .id = 3, .name = "Laurence Fishburne", .born = 1961 },
        .{ .id = 4, .name = "Lana Wachowski", .born = 1965 },
        .{ .id = 5, .name = "Tom Hanks", .born = 1956 },
    };
    const movies = [_]M{
        .{ .id = 100, .title = "The Matrix", .released = 1999 },
        .{ .id = 101, .title = "The Matrix Reloaded", .released = 2003 },
        .{ .id = 102, .title = "John Wick", .released = 2014 },
        .{ .id = 103, .title = "Forrest Gump", .released = 1994 },
    };
    for (people) |p| {
        try g.addNode(p.id, "Person");
        try g.setProperty(p.id, "name", .{ .string = p.name });
        try g.setProperty(p.id, "born", .{ .int = p.born });
    }
    for (movies) |m| {
        try g.addNode(m.id, "Movie");
        try g.setProperty(m.id, "title", .{ .string = m.title });
        try g.setProperty(m.id, "released", .{ .int = m.released });
    }
    const E = struct { a: NodeId, b: NodeId, t: []const u8 };
    const edges = [_]E{
        .{ .a = 1, .b = 100, .t = "ACTED_IN" },
        .{ .a = 1, .b = 101, .t = "ACTED_IN" },
        .{ .a = 1, .b = 102, .t = "ACTED_IN" },
        .{ .a = 2, .b = 100, .t = "ACTED_IN" },
        .{ .a = 3, .b = 100, .t = "ACTED_IN" },
        .{ .a = 5, .b = 103, .t = "ACTED_IN" },
        .{ .a = 4, .b = 100, .t = "DIRECTED" },
        .{ .a = 4, .b = 101, .t = "DIRECTED" },
    };
    for (edges) |e| _ = try g.addEdge(e.a, e.b, e.t);
}

/// Asserts that `rows` equals `expected` as an unordered set of rows.
pub fn expectRows(rows: []const Row, expected: []const []const Value) !void {
    try testing.expectEqual(expected.len, rows.len);
    const used = try testing.allocator.alloc(bool, rows.len);
    defer testing.allocator.free(used);
    @memset(used, false);

    for (expected) |expected_row| {
        var found = false;
        for (rows, 0..) |row, i| {
            if (used[i]) continue;
            if (identicalSequences(row.items, expected_row)) {
                used[i] = true;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

/// Parses `src`, runs it, and asserts the projected rows (as an unordered set).
pub fn expectQuery(ast: *Ast, g: *Graph, src: []const u8, expected: []const []const Value) !void {
    const query = try parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    try expectRows(try executor.run(query), expected);
}

/// Like `expectQuery`, with values for the query's `$name` parameters.
pub fn expectQueryWithParameters(ast: *Ast, g: *Graph, src: []const u8, parameters: []const struct { []const u8, Value }, expected: []const []const Value) !void {
    const query = try parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    for (parameters) |parameter| try executor.parameters.put(arena.allocator(), parameter[0], parameter[1]);
    try expectRows(try executor.run(query), expected);
}

/// Parses `src`, runs it, and asserts the projected rows in order.
pub fn expectOrdered(ast: *Ast, g: *Graph, src: []const u8, expected: []const []const Value) !void {
    const query = try parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    const rows = try executor.run(query);
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |expected_row, row| {
        try testing.expect(identicalSequences(row.items, expected_row));
    }
}

/// Parses `src`, runs it, and asserts that it fails with `expected_err`.
pub fn expectQueryError(ast: *Ast, g: *Graph, src: []const u8, expected_err: anyerror) !void {
    const query = try parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    try testing.expectError(expected_err, executor.run(query));
}
