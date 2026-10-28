//! Random read queries for the query fuzzer (query.zig): one or two MATCH
//! clauses over the fuzzer's labels, types and properties, a WHERE built
//! from predicates that never fail (comparisons, IS NULL, IN, STARTS WITH,
//! label tests, EXISTS), and a RETURN that projects or aggregates, ordered
//! by every column when it has SKIP or LIMIT (so the rows are determined).
//!
//! A query is kept in parts, so that the fuzzer can add a predicate to the
//! first MATCH's WHERE (ternary logic partitioning).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const labels = [_][]const u8{ "A", "B", "C" };
pub const types = [_][]const u8{ "T", "U" };
pub const properties = [_][]const u8{ "p", "q" };
/// The parameters a query may read; the fuzzer gives each a value.
pub const parameter_names = [_][]const u8{ "v0", "v1", "v2" };

/// What a seed's queries use, and how often (swarm testing).
pub const Mix = struct {
    /// Out of 8: a second MATCH (or OPTIONAL MATCH) after the first.
    second_clause: u8,
    /// Out of 8: an aggregating RETURN.
    aggregates: u8,
    /// Out of 8: a variable-length relationship (at most one per query).
    variable_length: u8,
    /// Out of 8: a value is a parameter rather than a literal.
    parameters: u8,
    /// Out of 8: a WHERE on a MATCH.
    where: u8,
    /// The most nodes in a pattern.
    pattern_nodes: u8,
    /// Out of 8: a range count, `MATCH (n:L) WHERE <ranges> RETURN count(n)`,
    /// which an index may answer from its keys alone.
    range_counts: u8,

    pub fn choose(random: std.Random) Mix {
        return .{
            .second_clause = random.uintAtMost(u8, 6),
            .aggregates = random.uintAtMost(u8, 6),
            .variable_length = random.uintAtMost(u8, 3),
            .parameters = random.uintAtMost(u8, 6),
            .where = random.intRangeAtMost(u8, 2, 8),
            .pattern_nodes = random.intRangeAtMost(u8, 1, 4),
            .range_counts = random.uintAtMost(u8, 2),
        };
    }
};

pub const Query = struct {
    /// The first MATCH, without its WHERE.
    head: []const u8,
    /// The first MATCH's WHERE (null: none).
    where: ?[]const u8,
    /// The clauses after it, RETURN included.
    tail: []const u8,
    /// A predicate on the first MATCH's variables, for partitioning.
    partition: []const u8,
    /// ORDER BY sorts on every column: rows compare in order.
    ordered: bool,
    /// The rows are a union over the first MATCH's rows: no aggregates,
    /// DISTINCT, SKIP or LIMIT.
    partitionable: bool,

    /// The query's text, with `extra` added to the first MATCH's WHERE.
    pub fn text(self: Query, allocator: Allocator, extra: ?[]const u8) Allocator.Error![]const u8 {
        if (extra) |predicate| {
            if (self.where) |where| return std.fmt.allocPrint(allocator, "{s} WHERE ({s}) AND ({s}) {s}", .{ self.head, where, predicate, self.tail });
            return std.fmt.allocPrint(allocator, "{s} WHERE {s} {s}", .{ self.head, predicate, self.tail });
        }
        if (self.where) |where| return std.fmt.allocPrint(allocator, "{s} WHERE {s} {s}", .{ self.head, where, self.tail });
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ self.head, self.tail });
    }
};

pub fn generate(random: std.Random, mix: Mix, allocator: Allocator) Allocator.Error!Query {
    var generator = Generator{ .random = random, .mix = mix, .allocator = allocator };
    return generator.query();
}

const Generator = struct {
    random: std.Random,
    mix: Mix,
    allocator: Allocator,
    /// Variables bound so far, by kind.
    nodes: std.ArrayList([]const u8) = .empty,
    relationships: std.ArrayList([]const u8) = .empty,
    /// A query has at most one variable-length relationship: several, each
    /// up to 3 hops on a dense graph, multiply into billions of paths.
    variable_length_used: bool = false,

    fn query(self: *Generator) Allocator.Error!Query {
        if (self.chance(self.mix.range_counts)) return self.rangeCount();
        const head = try self.match("MATCH");
        const first_nodes = self.nodes.items.len;
        const first_relationships = self.relationships.items.len;
        const where = if (self.chance(self.mix.where)) try self.predicate(2) else null;
        // The partition predicate reads only the first MATCH's variables.
        const partition = try self.predicateOver(first_nodes, first_relationships, 2);

        var tail = std.ArrayList(u8).empty;
        if (self.chance(self.mix.second_clause)) {
            const keyword = if (self.random.boolean()) "OPTIONAL MATCH" else "MATCH";
            try tail.print(self.allocator, "{s} ", .{try self.joinedMatch(keyword)});
            if (self.chance(self.mix.where)) try tail.print(self.allocator, "WHERE {s} ", .{try self.predicate(1)});
        }
        const ret = try self.returnClause();
        try tail.appendSlice(self.allocator, ret.text);
        return .{
            .head = head,
            .where = where,
            .tail = tail.items,
            .partition = partition,
            .ordered = ret.ordered,
            .partitionable = ret.partitionable,
        };
    }

    /// `MATCH (n0:L) WHERE n0.p > v [AND n0.p < w] RETURN count(n0)`: one or
    /// two range comparisons, written either way round, on one property.
    fn rangeCount(self: *Generator) Allocator.Error!Query {
        try self.nodes.append(self.allocator, "n0");
        const property = self.pick(&properties);
        var where = std.ArrayList(u8).empty;
        var lower = self.random.boolean();
        for (0..self.random.intRangeAtMost(u8, 1, 2)) |position| {
            if (position > 0) {
                try where.appendSlice(self.allocator, " AND ");
                lower = !lower; // the other side
            }
            const strict = self.random.boolean();
            const operator: []const u8 = if (lower) (if (strict) ">" else ">=") else (if (strict) "<" else "<=");
            try where.print(self.allocator, "n0.{s} {s} {s}", .{ property, operator, try self.value() });
        }
        return .{
            .head = try std.fmt.allocPrint(self.allocator, "MATCH (n0:{s})", .{self.pick(&labels)}),
            .where = where.items,
            .tail = if (self.random.boolean()) "RETURN count(n0) AS c0" else "RETURN count(*) AS c0",
            .partition = try self.predicate(1),
            .ordered = false,
            .partitionable = false,
        };
    }

    // --- Patterns ------------------------------------------------------------------

    fn match(self: *Generator, keyword: []const u8) Allocator.Error![]const u8 {
        var text = std.ArrayList(u8).empty;
        try text.print(self.allocator, "{s} {s}", .{ keyword, try self.pattern(null) });
        // Sometimes a second pattern: a cartesian product, or joined by a variable.
        if (self.random.uintLessThan(u8, 5) == 0) {
            const start = if (self.random.boolean()) self.pickNode() else null;
            try text.print(self.allocator, ", {s}", .{try self.pattern(start)});
        }
        return text.items;
    }

    /// A MATCH whose pattern starts from a node bound before.
    fn joinedMatch(self: *Generator, keyword: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s} {s}", .{ keyword, try self.pattern(self.pickNode()) });
    }

    /// A chain of nodes and relationships; `start`: a bound node it starts at.
    fn pattern(self: *Generator, start: ?[]const u8) Allocator.Error![]const u8 {
        var text = std.ArrayList(u8).empty;
        const node_count = self.random.intRangeAtMost(u8, 1, self.mix.pattern_nodes);
        for (0..node_count) |position| {
            if (position > 0) try text.appendSlice(self.allocator, try self.relationship());
            if (position == 0 and start != null) {
                try text.print(self.allocator, "({s})", .{start.?});
            } else {
                try text.appendSlice(self.allocator, try self.node());
            }
        }
        return text.items;
    }

    fn node(self: *Generator) Allocator.Error![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "n{d}", .{self.nodes.items.len});
        try self.nodes.append(self.allocator, name);
        var text = std.ArrayList(u8).empty;
        try text.print(self.allocator, "({s}", .{name});
        if (self.random.uintLessThan(u8, 3) != 0) try text.print(self.allocator, ":{s}", .{self.pick(&labels)});
        if (self.random.uintLessThan(u8, 6) == 0) try text.print(self.allocator, ":{s}", .{self.pick(&labels)});
        if (self.random.uintLessThan(u8, 3) == 0) try text.print(self.allocator, " {{{s}: {s}}}", .{ self.pick(&properties), try self.value() });
        try text.append(self.allocator, ')');
        return text.items;
    }

    fn relationship(self: *Generator) Allocator.Error![]const u8 {
        var inside = std.ArrayList(u8).empty;
        const variable_length = self.chance(self.mix.variable_length) and !self.variable_length_used;
        if (variable_length) self.variable_length_used = true;
        // A variable-length relationship stays unnamed: its variable is a list.
        if (!variable_length) {
            const name = try std.fmt.allocPrint(self.allocator, "r{d}", .{self.relationships.items.len});
            try self.relationships.append(self.allocator, name);
            try inside.appendSlice(self.allocator, name);
        }
        switch (self.random.uintLessThan(u8, 4)) {
            0 => {},
            1 => try inside.print(self.allocator, ":{s}|{s}", .{ types[0], types[1] }),
            else => try inside.print(self.allocator, ":{s}", .{self.pick(&types)}),
        }
        if (variable_length) {
            const low = self.random.uintAtMost(u8, 1);
            try inside.print(self.allocator, "*{d}..{d}", .{ low, low + self.random.intRangeAtMost(u8, 1, 2) });
        } else if (self.random.uintLessThan(u8, 5) == 0) {
            try inside.print(self.allocator, " {{{s}: {s}}}", .{ self.pick(&properties), try self.value() });
        }
        return switch (self.random.uintLessThan(u8, 3)) {
            0 => std.fmt.allocPrint(self.allocator, "-[{s}]->", .{inside.items}),
            1 => std.fmt.allocPrint(self.allocator, "<-[{s}]-", .{inside.items}),
            else => std.fmt.allocPrint(self.allocator, "-[{s}]-", .{inside.items}),
        };
    }

    // --- Predicates ----------------------------------------------------------------

    fn predicate(self: *Generator, depth: u8) Allocator.Error![]const u8 {
        return self.predicateOver(self.nodes.items.len, self.relationships.items.len, depth);
    }

    /// A boolean (or null) over the first `node_count` nodes and
    /// `relationship_count` relationships bound.
    fn predicateOver(self: *Generator, node_count: usize, relationship_count: usize, depth: u8) Allocator.Error![]const u8 {
        if (depth > 0 and self.random.uintLessThan(u8, 3) == 0) {
            const left = try self.predicateOver(node_count, relationship_count, depth - 1);
            return switch (self.random.uintLessThan(u8, 4)) {
                0 => std.fmt.allocPrint(self.allocator, "NOT ({s})", .{left}),
                1 => std.fmt.allocPrint(self.allocator, "({s}) AND ({s})", .{ left, try self.predicateOver(node_count, relationship_count, depth - 1) }),
                2 => std.fmt.allocPrint(self.allocator, "({s}) OR ({s})", .{ left, try self.predicateOver(node_count, relationship_count, depth - 1) }),
                else => std.fmt.allocPrint(self.allocator, "({s}) XOR ({s})", .{ left, try self.predicateOver(node_count, relationship_count, depth - 1) }),
            };
        }
        const n = self.nodes.items[self.random.uintLessThan(usize, node_count)];
        const operand = if (relationship_count > 0 and self.random.uintLessThan(u8, 4) == 0)
            self.relationships.items[self.random.uintLessThan(usize, relationship_count)]
        else
            n;
        const property = self.pick(&properties);
        return switch (self.random.uintLessThan(u8, 10)) {
            0, 1, 2 => std.fmt.allocPrint(self.allocator, "{s}.{s} {s} {s}", .{ operand, property, self.pick(&comparisons), try self.value() }),
            3 => std.fmt.allocPrint(self.allocator, "{s} {s} {s}.{s}", .{ try self.value(), self.pick(&comparisons), operand, property }),
            4 => std.fmt.allocPrint(self.allocator, "{s}.{s} IS {s}NULL", .{ operand, property, if (self.random.boolean()) "NOT " else "" }),
            5 => std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ n, self.pick(&labels) }),
            6 => std.fmt.allocPrint(self.allocator, "{s}.{s} IN [{s}, {s}]", .{ operand, property, try self.value(), try self.value() }),
            7 => std.fmt.allocPrint(self.allocator, "{s}.{s} STARTS WITH 'a'", .{ operand, property }),
            8 => std.fmt.allocPrint(self.allocator, "{s}.{s} {s} {s}.{s}", .{ n, property, self.pick(&comparisons), self.nodes.items[self.random.uintLessThan(usize, node_count)], self.pick(&properties) }),
            else => std.fmt.allocPrint(self.allocator, "EXISTS {{ ({s})-[:{s}]->(:{s}) }}", .{ n, self.pick(&types), self.pick(&labels) }),
        };
    }

    const comparisons = [_][]const u8{ "=", "<>", "<", "<=", ">", ">=" };

    /// A literal from a small pool (equal values meet: 1 and 1.0), or a parameter.
    fn value(self: *Generator) Allocator.Error![]const u8 {
        if (self.chance(self.mix.parameters)) return std.fmt.allocPrint(self.allocator, "${s}", .{self.pick(&parameter_names)});
        const literals = [_][]const u8{ "0", "1", "2", "1.0", "2.5", "'a'", "'b'", "'ab'", "''", "true", "false", "null", "[1, 2]" };
        return self.pick(&literals);
    }

    // --- RETURN --------------------------------------------------------------------

    const Return = struct { text: []const u8, ordered: bool, partitionable: bool };

    fn returnClause(self: *Generator) Allocator.Error!Return {
        var items = std.ArrayList([]const u8).empty;
        const aggregates = self.chance(self.mix.aggregates);
        const keys: usize = if (aggregates) self.random.uintAtMost(usize, 2) else self.random.intRangeAtMost(usize, 1, 3);
        for (0..keys) |_| try items.append(self.allocator, try self.expression());
        if (aggregates) {
            for (0..self.random.intRangeAtMost(usize, 1, 2)) |_| try items.append(self.allocator, try self.aggregate());
        }
        const distinct = !aggregates and self.random.uintLessThan(u8, 4) == 0;

        var text = std.ArrayList(u8).empty;
        try text.appendSlice(self.allocator, if (distinct) "RETURN DISTINCT " else "RETURN ");
        for (items.items, 0..) |item, i| {
            if (i > 0) try text.appendSlice(self.allocator, ", ");
            try text.print(self.allocator, "{s} AS c{d}", .{ item, i });
        }
        const ordered = self.random.boolean();
        var limited = false;
        if (ordered) {
            try text.appendSlice(self.allocator, " ORDER BY ");
            for (0..items.items.len) |i| {
                if (i > 0) try text.appendSlice(self.allocator, ", ");
                try text.print(self.allocator, "c{d}{s}", .{ i, if (self.random.boolean()) " DESC" else "" });
            }
            if (self.random.boolean()) {
                try text.print(self.allocator, " SKIP {d}", .{self.random.uintAtMost(u8, 3)});
                limited = true;
            }
            if (self.random.boolean()) {
                try text.print(self.allocator, " LIMIT {d}", .{self.random.uintAtMost(u8, 5)});
                limited = true;
            }
        }
        return .{ .text = text.items, .ordered = ordered, .partitionable = !aggregates and !distinct and !limited };
    }

    fn expression(self: *Generator) Allocator.Error![]const u8 {
        if (self.relationships.items.len > 0 and self.random.uintLessThan(u8, 4) == 0) {
            const r = self.pick(self.relationships.items);
            return switch (self.random.uintLessThan(u8, 3)) {
                0 => std.fmt.allocPrint(self.allocator, "type({s})", .{r}),
                1 => std.fmt.allocPrint(self.allocator, "id({s})", .{r}),
                else => std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ r, self.pick(&properties) }),
            };
        }
        const n = self.pick(self.nodes.items);
        return switch (self.random.uintLessThan(u8, 4)) {
            0 => std.fmt.allocPrint(self.allocator, "id({s})", .{n}),
            1 => std.fmt.allocPrint(self.allocator, "labels({s})", .{n}),
            else => std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ n, self.pick(&properties) }),
        };
    }

    fn aggregate(self: *Generator) Allocator.Error![]const u8 {
        const n = self.pick(self.nodes.items);
        return switch (self.random.uintLessThan(u8, 7)) {
            0 => "count(*)",
            1 => std.fmt.allocPrint(self.allocator, "count({s})", .{try self.expression()}),
            2 => std.fmt.allocPrint(self.allocator, "count(DISTINCT {s})", .{try self.expression()}),
            3 => std.fmt.allocPrint(self.allocator, "min({s})", .{try self.expression()}),
            4 => std.fmt.allocPrint(self.allocator, "max({s})", .{try self.expression()}),
            5 => std.fmt.allocPrint(self.allocator, "sum(id({s}))", .{n}),
            else => std.fmt.allocPrint(self.allocator, "size(collect(DISTINCT {s}.{s}))", .{ n, self.pick(&properties) }),
        };
    }

    // --- Choices -------------------------------------------------------------------

    fn pickNode(self: *Generator) []const u8 {
        return self.pick(self.nodes.items);
    }

    fn pick(self: *Generator, items: []const []const u8) []const u8 {
        return items[self.random.uintLessThan(usize, items.len)];
    }

    /// True `eighths` times out of 8.
    fn chance(self: *Generator, eighths: u8) bool {
        return self.random.uintLessThan(u8, 8) < eighths;
    }
};
