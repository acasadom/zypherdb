//! Aggregations and implicit grouping.

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

test "aggregations: count, sum, min and max with grouping" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // Count movies per actor (implicit GROUP BY p.name).
    try expectQuery(&ast, &g, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN p.name, count(m)", &.{
        &.{ .{ .string = "Keanu Reeves" }, .{ .int = 3 } },
        &.{ .{ .string = "Carrie-Anne Moss" }, .{ .int = 1 } },
        &.{ .{ .string = "Laurence Fishburne" }, .{ .int = 1 } },
        &.{ .{ .string = "Tom Hanks" }, .{ .int = 1 } },
    });

    // count(*) over all persons.
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN count(p)", &.{
        &.{.{ .int = 5 }},
    });

    // min/max released year.
    try expectQuery(&ast, &g, "MATCH (m:Movie) RETURN min(m.released), max(m.released)", &.{
        &.{ .{ .int = 1994 }, .{ .int = 2014 } },
    });

    // sum of birth years.
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN sum(p.born)", &.{
        &.{.{ .int = 9813 }},
    });
}

test "ungrouped aggregation over zero rows yields one row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    try loadMoviesGraph(&g);

    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "MATCH (x:Nope) RETURN count(*), count(x), sum(x.v), min(x.v), max(x.v)", &.{
        &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 0 }, .{ .null = {} }, .{ .null = {} } },
    });
    try expectQuery(&ast, &g, "MATCH (x:Nope) WITH count(x) AS c RETURN c", &.{
        &.{.{ .int = 0 }},
    });
    // With a grouping key, zero rows still yield zero groups.
    try expectQuery(&ast, &g, "MATCH (x:Nope) RETURN x.name, count(*)", &.{});
    try expectQuery(&ast, &g, "MATCH (x:Nope) WITH x.name AS n, count(*) AS c RETURN n, c", &.{});
}

test "aggregates inside expressions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "UNWIND [1, 2, 2, 5] AS x CREATE (:N {x: x})", &.{});
    // An aggregate anywhere in an expression; a grouping key may appear next to it.
    try expectQuery(&ast, &g, "MATCH (n:N) RETURN count(*) + 1, sum(n.x) * 100 / count(*), max(n.x) - min(n.x)", &.{
        &.{ .{ .int = 5 }, .{ .int = 250 }, .{ .int = 4 } },
    });
    try expectQuery(&ast, &g, "MATCH (n:N) RETURN n.x, n.x * 10 + count(*)", &.{
        &.{ .{ .int = 1 }, .{ .int = 11 } },
        &.{ .{ .int = 2 }, .{ .int = 22 } },
        &.{ .{ .int = 5 }, .{ .int = 51 } },
    });
    try expectQuery(&ast, &g, "MATCH (n:N) WITH n.x AS x, count(*) * 2 AS twice WHERE twice > 2 RETURN x, twice", &.{
        &.{ .{ .int = 2 }, .{ .int = 4 } },
    });

    // openCypher's rules: outside its aggregates, an aggregating expression
    // uses only constants and grouping keys; aggregates do not nest.
    try expectQueryError(&ast, &g, "MATCH (n:N) RETURN n.x + count(*)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (n:N) RETURN count(count(*))", error.InvalidExpression);
    // ORDER BY may combine the projection's names with its aggregates...
    try support.expectOrdered(&ast, &g, "MATCH (n:N) RETURN n.x AS x, count(*) AS c ORDER BY x * 0 - count(*), x", &.{
        &.{ .{ .int = 2 }, .{ .int = 2 } },
        &.{ .{ .int = 1 }, .{ .int = 1 } },
        &.{ .{ .int = 5 }, .{ .int = 1 } },
    });
    // ...but not use an aggregate the projection does not compute, nor
    // aggregate when the projection does not; a complex key is not reusable
    // next to an aggregate, even if projected.
    try expectQueryError(&ast, &g, "MATCH (n:N) RETURN n.x AS x, count(*) AS c ORDER BY sum(n.x)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (n:N) RETURN n.x ORDER BY count(*)", error.InvalidExpression);
    try expectQueryError(&ast, &g, "MATCH (n:N) RETURN n.x + 1, n.x + 1 + count(*)", error.InvalidExpression);
}

test "WITH without aggregates keeps every row" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g, "UNWIND [1, 1, 2] AS x CREATE (:N {x: x})", &.{});
    // It used to group, which silently dropped the duplicate 1.
    try expectQuery(&ast, &g, "MATCH (n:N) WITH n.x AS x RETURN x", &.{
        &.{.{ .int = 1 }},
        &.{.{ .int = 1 }},
        &.{.{ .int = 2 }},
    });
}
