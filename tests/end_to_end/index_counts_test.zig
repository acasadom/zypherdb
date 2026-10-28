//! Counting from an index (`NodeIndexRangeCount`): `MATCH (n:L) WHERE
//! <ranges on n.p> RETURN count(n)` counts the index's keys in range. Each
//! count must equal the one a scan makes, whatever the bounds: strict or
//! not, of other kinds than the values, or values the keys hold cut short.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;
const Executor = zypherdb.Executor;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;

const Parameters = []const struct { []const u8, Value };

/// The one value `query` returns, run with `options`.
fn countWith(ast: *Ast, g: *Graph, query: []const u8, parameters: Parameters, options: zypherdb.PlanOptions) !Value {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    executor.plan_options = options;
    for (parameters) |parameter| try executor.parameters.put(arena.allocator(), parameter[0], parameter[1]);
    const rows = try executor.run(try zypherdb.parser.parse(ast, query, null));
    try testing.expectEqual(@as(usize, 1), rows.len);
    return rows[0].items[0];
}

/// True if `query`'s plan counts from the index.
fn countsFromIndex(ast: *Ast, g: *Graph, query: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    const explain = try std.fmt.allocPrint(arena.allocator(), "EXPLAIN {s}", .{query});
    for (try executor.run(try zypherdb.parser.parse(ast, explain, null))) |row| {
        if (std.mem.eql(u8, row.items[1].string, "NodeIndexRangeCount")) return true;
    }
    return false;
}

/// Asserts that `query` counts from the index, and that its count is the
/// scan's (no index, no seeks).
fn expectScanCount(ast: *Ast, g: *Graph, query: []const u8, parameters: Parameters) !void {
    try testing.expect(try countsFromIndex(ast, g, query));
    const counted = try countWith(ast, g, query, parameters, .{});
    const scanned = try countWith(ast, g, query, parameters, .{ .where_seeks = false, .index_lookups = false });
    testing.expectEqual(scanned.int, counted.int) catch |err| {
        std.debug.print("{s}: counted {d}, scanned {d}\n", .{ query, counted.int, scanned.int });
        return err;
    };
}

/// Longer than an index key holds (`property_indexes.max_value_bytes`).
const long_name: [600]u8 = @splat('x');

fn loadPeople(ast: *Ast, g: *Graph) !void {
    try expectQuery(ast, g, "UNWIND range(0, 99) AS i CREATE (:Person {age: i, name: 'p' + i, born: date({year: 1950 + i})})", &.{});
    // Floats (60.0 is indexed as the integer 60), a NaN, values of other
    // kinds, extremes, and nodes of another label.
    try expectQuery(ast, g, "CREATE (:Person {age: 60.5}), (:Person {age: -0.5}), (:Person {age: 60.0}), (:Person {age: 0.0 / 0.0}), (:Person {age: 'sixty'}), (:Person {age: [60]}), (:Person {age: true})", &.{});
    try expectQuery(ast, g, "CREATE (:Person {age: 9223372036854775807}), (:Person {age: -9223372036854775807 - 1}), (:Person {age: 1.0e300}), (:Person {age: -1.0e300}), (:Person)", &.{});
    try expectQuery(ast, g, "CREATE (:Animal {age: 70, name: 'p70'}), (:Person:Animal {age: 61})", &.{});
    // Names past the longest an index key holds: their keys are cut short.
    try support.expectQueryWithParameters(ast, g, "CREATE (:Person {name: $long}), (:Person {name: $long + 'y'}), (:Person {name: 'x'})", &.{.{ "long", .{ .string = &long_name } }}, &.{});
    try expectQuery(ast, g, "CREATE INDEX FOR (p:Person) ON (p.age)", &.{});
    try expectQuery(ast, g, "CREATE INDEX FOR (p:Person) ON (p.name)", &.{});
    try expectQuery(ast, g, "CREATE INDEX FOR (p:Person) ON (p.born)", &.{});
}

test "a range count from an index equals the scan's" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try loadPeople(&ast, &g);

    const queries = [_][]const u8{
        "MATCH (p:Person) WHERE p.age > 60 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age >= 60 RETURN count(*)",
        "MATCH (p:Person) WHERE p.age < 10 RETURN count(p) AS young",
        "MATCH (p:Person) WHERE p.age <= 10 RETURN count(p)",
        "MATCH (p:Person) WHERE 60 < p.age RETURN count(p)",
        "MATCH (p:Person) WHERE 10 >= p.age RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 60 AND p.age < 70 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age >= 60 AND 70 >= p.age RETURN count(p)",
        // Float bounds against integer values, and the reverse.
        "MATCH (p:Person) WHERE p.age > 60.0 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age >= 60.5 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 60.5 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age < 61.5 AND p.age > -0.5 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age >= -0.5 AND p.age <= 0 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 9223372036854775806 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age >= 9.3e18 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > -1.0e300 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age < -9.3e18 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age >= 1.0e300 RETURN count(p)",
        // Strings, some cut short in the index.
        "MATCH (p:Person) WHERE p.name > 'p5' RETURN count(p)",
        "MATCH (p:Person) WHERE p.name >= 'p1' AND p.name < 'p2' RETURN count(p)",
        "MATCH (p:Person) WHERE p.name > 'x' RETURN count(p)",
        "MATCH (p:Person) WHERE p.name >= 'p' RETURN count(p)",
        // Bounds that compare with none of the values, or with some only.
        "MATCH (p:Person) WHERE p.age > 'a' RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 1 AND p.age < 'z' RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > true RETURN count(p)",
    };
    for (queries) |query| try expectScanCount(&ast, &g, query, &.{});

    // Parameters of every kind.
    const parameter_query = "MATCH (p:Person) WHERE p.age > $low AND p.age <= $high RETURN count(p)";
    const bounds = [_][2]Value{
        .{ .{ .int = 50 }, .{ .int = 60 } },
        .{ .{ .float = 49.5 }, .{ .float = 60.5 } },
        .{ .{ .float = std.math.nan(f64) }, .{ .int = 60 } },
        .{ .{ .float = -std.math.inf(f64) }, .{ .float = std.math.inf(f64) } },
        .{ .{ .null = {} }, .{ .int = 60 } },
        .{ .{ .string = "a" }, .{ .string = "z" } },
        .{ .{ .int = 1 }, .{ .string = "z" } },
        .{ .{ .boolean = false }, .{ .boolean = true } },
    };
    for (bounds) |bound| try expectScanCount(&ast, &g, parameter_query, &.{ .{ "low", bound[0] }, .{ "high", bound[1] } });
    const dates = [_][2]Value{
        .{ .{ .date = .{ .days = 0 } }, .{ .date = .{ .days = 10000 } } },
        .{ .{ .date = .{ .days = -7305 } }, .{ .date = .{ .days = 0 } } },
        .{ .{ .int = 0 }, .{ .date = .{ .days = 0 } } },
    };
    for (dates) |bound| try expectScanCount(&ast, &g, "MATCH (p:Person) WHERE p.born >= $low AND p.born < $high RETURN count(p)", &.{ .{ "low", bound[0] }, .{ "high", bound[1] } });
}

test "only a lone range count on an index counts from it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try loadPeople(&ast, &g);

    const others = [_][]const u8{
        "MATCH (p:Person) WHERE p.age > 60 RETURN count(DISTINCT p)",
        "MATCH (p:Person) WHERE p.age > 60 RETURN count(p.name)",
        "MATCH (p:Person) WHERE p.age > 60 RETURN count(p), count(*)",
        "MATCH (p:Person) WHERE p.age > 60 RETURN count(p) + 1",
        "MATCH (p:Person) WHERE p.age > 60 RETURN p.name, count(p)",
        "MATCH (p:Person) WHERE p.age > 60 AND p.name > 'a' RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 60 AND p.age > 70 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 60 OR p.age < 10 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age <> 60 RETURN count(p)",
        "MATCH (p:Person:Animal) WHERE p.age > 60 RETURN count(p)",
        "MATCH (p:Person {name: 'p61'}) WHERE p.age > 60 RETURN count(p)",
        "MATCH (p:Animal) WHERE p.age > 60 RETURN count(p)",
        "MATCH (p:Person)--() WHERE p.age > 60 RETURN count(p)",
        "MATCH (p:Person), (q) WHERE p.age > 60 RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 60 WITH p RETURN count(p)",
        "MATCH (p:Person) WHERE p.age > 60 RETURN count(p) ORDER BY count(p) LIMIT 1",
        "MATCH (p:Person) RETURN count(p)",
    };
    for (others) |query| {
        testing.expect(!try countsFromIndex(&ast, &g, query)) catch |err| {
            std.debug.print("counts from the index: {s}\n", .{query});
            return err;
        };
    }
}
