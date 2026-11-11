//! The fault fuzzer's workload (tests/fuzz/faults.zig): random Cypher
//! statements of every kind that reaches the storage engine. Writes
//! (CREATE, MERGE, SET, REMOVE, DELETE), schema commands (uniqueness
//! constraints, full-text indexes), full-text searches, vector index work
//! (when a mix asks for it), and the query fuzzer's read queries
//! (query_generator.zig). Statements that fail (a
//! broken constraint, a connected node deleted) are part of the workload:
//! they must fail the same way with and without faults.

const std = @import("std");
const Allocator = std.mem.Allocator;
const generator = @import("query_generator.zig");

const labels = generator.labels;
const types = generator.types;
const properties = generator.properties;

/// Property values; the texts share words, for the full-text searches.
const literals = [_][]const u8{ "1", "2", "2.0", "'red'", "'red apples'", "'green tree'", "true", "[1, 2]" };

/// Full-text searches (stemmed: "apple" finds "apples").
const searches = [_][]const u8{ "red", "apple", "green OR red", "tre*" };

pub const Step = struct {
    text: []const u8,
    /// ORDER BY sorts on every column: rows compare in order.
    ordered: bool = false,
    /// Not a statement: one batch of a vector index's population, as the
    /// builder thread does (`text` only names it).
    populate: bool = false,
};

/// What a seed's workload is made of (swarm testing).
pub const Mix = struct {
    /// Out of 16: writes, schema commands and full-text searches; the rest
    /// are read queries.
    writes: u8,
    schema: u8,
    searches: u8,
    /// Vector indexes made, dropped, written, searched and populated (not
    /// drawn by `choose`: a fuzzer that wants them sets it).
    vector: u8 = 0,
    reads: generator.Mix,

    pub fn choose(random: std.Random) Mix {
        return .{
            .writes = random.intRangeAtMost(u8, 4, 10),
            .schema = random.uintAtMost(u8, 2),
            .searches = random.uintAtMost(u8, 2),
            .reads = generator.Mix.choose(random),
        };
    }

    pub fn format(self: Mix, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("writes {d}/16, schema {d}/16, searches {d}/16, vector {d}/16", .{ self.writes, self.schema, self.searches, self.vector });
    }
};

pub fn generate(random: std.Random, mix: Mix, allocator: Allocator) Allocator.Error!Step {
    const roll = random.uintLessThan(u8, 16);
    if (roll < mix.writes) return .{ .text = try write(random, allocator) };
    if (roll < mix.writes + mix.schema) return .{ .text = try schema(random, allocator) };
    if (roll < mix.writes + mix.schema + mix.searches) return .{ .text = try search(random, allocator) };
    if (roll < mix.writes + mix.schema + mix.searches + mix.vector) return vector(random, allocator);
    const query = try generator.generate(random, mix.reads, allocator);
    return .{ .text = try query.text(allocator, null), .ordered = query.ordered };
}

fn write(random: std.Random, allocator: Allocator) Allocator.Error![]const u8 {
    const a = pick(random, &labels);
    const b = pick(random, &labels);
    const p = pick(random, &properties);
    const q = pick(random, &properties);
    const v = pick(random, &literals);
    const w = pick(random, &literals);
    const t = pick(random, &types);
    const k = random.intRangeAtMost(u8, 1, 5);
    const print = std.fmt.allocPrint;
    return switch (random.uintLessThan(u8, 14)) {
        0 => print(allocator, "CREATE (:{s} {{{s}: {s}}})", .{ a, p, v }),
        1 => print(allocator, "CREATE (:{s}:{s} {{p: {s}, q: {s}}})", .{ a, b, v, w }),
        2 => print(allocator, "UNWIND range(1, {d}) AS i CREATE (:{s} {{{s}: i % 3}})", .{ k, a, p }),
        3 => print(allocator, "MATCH (a:{s}), (b:{s}) WITH a, b LIMIT {d} CREATE (a)-[:{s} {{{s}: {s}}}]->(b)", .{ a, b, k, t, p, v }),
        4 => print(allocator, "MATCH (n:{s}) WHERE n.{s} = {s} SET n.{s} = {s}", .{ a, p, v, q, w }),
        5 => print(allocator, "MATCH (n:{s}) SET n += {{{s}: {s}}}", .{ a, p, v }),
        6 => print(allocator, "MATCH (n:{s}) SET n:{s}", .{ a, b }),
        7 => print(allocator, "MATCH (n:{s}) REMOVE n:{s}", .{ a, b }),
        8 => print(allocator, "MATCH (n:{s}) REMOVE n.{s}", .{ a, p }),
        9 => print(allocator, "MATCH (n:{s}) WITH n LIMIT 1 DETACH DELETE n", .{a}),
        10 => print(allocator, "MATCH (n:{s}) WITH n LIMIT 1 DELETE n", .{a}),
        11 => print(allocator, "MATCH ()-[r:{s}]->() WITH r LIMIT 2 DELETE r", .{t}),
        12 => print(allocator, "MERGE (n:{s} {{{s}: {s}}}) ON CREATE SET n.created = true ON MATCH SET n.matched = true", .{ a, p, v }),
        else => print(allocator, "MATCH (a:{s}), (b:{s}) WHERE id(a) < id(b) WITH a, b LIMIT 1 MERGE (a)-[:{s}]->(b)", .{ a, b, t }),
    };
}

/// The indexes a workload starts with, as an application makes them before
/// its queries: one per label and property. (Without them, the queries the
/// generator makes can cost so much that running each again at every fault
/// point takes hours.) The schema steps add and drop others, never these.
pub fn initialIndexes(allocator: Allocator) Allocator.Error![]const Step {
    var steps = std.ArrayList(Step).empty;
    for (labels) |label| for (properties) |property| {
        try steps.append(allocator, .{ .text = try std.fmt.allocPrint(allocator, "CREATE INDEX node_{s}_{s} FOR (n:{s}) ON (n.{s})", .{ label, property, label, property }) });
    };
    return steps.items;
}

fn schema(random: std.Random, allocator: Allocator) Allocator.Error![]const u8 {
    const label = pick(random, &labels);
    const property = pick(random, &properties);
    const edge_type = pick(random, &types);
    const print = std.fmt.allocPrint;
    return switch (random.uintLessThan(u8, 9)) {
        5 => print(allocator, "CREATE INDEX extra_{s}_{s} IF NOT EXISTS FOR (n:{s}) ON (n.{s})", .{ label, property, label, property }),
        6 => print(allocator, "DROP INDEX extra_{s}_{s} IF EXISTS", .{ label, property }),
        7 => print(allocator, "CREATE INDEX edge_{s}_{s} IF NOT EXISTS FOR ()-[r:{s}]-() ON (r.{s})", .{ edge_type, property, edge_type, property }),
        8 => print(allocator, "DROP INDEX edge_{s}_{s} IF EXISTS", .{ edge_type, property }),
        0 => print(allocator, "CREATE CONSTRAINT unique_{s}_{s} IF NOT EXISTS FOR (n:{s}) REQUIRE n.{s} IS UNIQUE", .{ label, property, label, property }),
        1 => print(allocator, "CREATE CONSTRAINT unique_{s}_pq IF NOT EXISTS FOR (n:{s}) REQUIRE (n.p, n.q) IS UNIQUE", .{ label, label }),
        2 => print(allocator, "DROP CONSTRAINT unique_{s}_{s} IF EXISTS", .{ label, property }),
        3 => print(allocator, "CREATE FULLTEXT INDEX text_{s} IF NOT EXISTS FOR (n:{s}) ON EACH [n.p, n.q]", .{ label, label }),
        else => print(allocator, "DROP INDEX text_{s} IF EXISTS", .{label}),
    };
}

fn search(random: std.Random, allocator: Allocator) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "CALL db.index.fulltext.queryNodes('text_{s}', '{s}') YIELD node, score RETURN id(node), score", .{ pick(random, &labels), pick(random, &searches) });
}

/// Indexes on property `v` of a label or a relationship type, 2 numbers
/// long; a vector of 3 is a bad one (refused once indexed; before, it
/// fails the index that population meets it in).
fn vector(random: std.Random, allocator: Allocator) Allocator.Error!Step {
    const a = pick(random, &labels);
    const t = pick(random, &types);
    const k = random.intRangeAtMost(u8, 1, 5);
    const x = pick(random, &numbers);
    const options = "OPTIONS {{indexConfig: {{`vector.dimensions`: 2, `vector.similarity_function`: 'euclidean'}}}}";
    const print = std.fmt.allocPrint;
    const text = switch (random.uintLessThan(u8, 16)) {
        0...2 => try print(allocator, "CREATE VECTOR INDEX vector_{s} IF NOT EXISTS FOR (n:{s}) ON n.v " ++ options, .{ a, a }),
        3 => try print(allocator, "CREATE VECTOR INDEX vector_{s} IF NOT EXISTS FOR ()-[r:{s}]-() ON r.v " ++ options, .{ t, t }),
        4 => try print(allocator, "DROP INDEX vector_{s} IF EXISTS", .{if (random.boolean()) a else t}),
        5...7 => try print(allocator, "UNWIND range(1, {d}) AS i CREATE (:{s} {{v: [toFloat(i), {s}]}})", .{ 3 * k, a, x }),
        8 => try print(allocator, "MATCH (n:{s}) WITH n LIMIT {d} SET n.v = [{s}, toFloat(id(n))]", .{ a, k, x }),
        9 => try print(allocator, "MATCH ()-[r:{s}]->() WITH r LIMIT {d} SET r.v = [toFloat(id(r)), {s}]", .{ t, k, x }),
        10 => try print(allocator, "MATCH (n:{s}) WITH n LIMIT 1 SET n.v = [1.0, 2.0, 3.0]", .{a}),
        11 => try print(allocator, "MATCH (n:{s}) WITH n LIMIT 1 REMOVE n.v", .{a}),
        12 => try print(allocator, "CALL db.index.vector.queryNodes('vector_{s}', 3, [{s}, 1.0]) YIELD node, score RETURN id(node), score", .{ a, x }),
        else => return .{ .text = "populate one batch", .populate = true },
    };
    return .{ .text = text };
}

const numbers = [_][]const u8{ "0.0", "1.0", "2.5", "-3.0" };

fn pick(random: std.Random, choices: []const []const u8) []const u8 {
    return choices[random.uintLessThan(usize, choices.len)];
}
