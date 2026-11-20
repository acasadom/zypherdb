//! `MATCH <pattern> WHERE ... SEARCH x IN (VECTOR INDEX name FOR vector
//! WHERE ... LIMIT k OPTIONS {ef: n}) SCORE AS s WHERE ...`: from each row,
//! the rows of the k entities x closest to the vector among those the MATCH
//! (with its WHERE) and the SEARCH's WHERE keep, best first, each with its
//! score. Every row of the MATCH for a chosen x goes on. The WHERE after
//! SCORE AS then drops rows (it may leave fewer than k); an OPTIONAL MATCH
//! with no row left gives its row of nulls.
//!
//! The way to find them is chosen for each row, when it runs:
//! - exact: the MATCH's rows are enumerated (the `candidates` chain); when
//!   they have at most `exactLimit` entities, each one's distance is
//!   measured and the k closest kept. Recall is 100%.
//! - HNSW: past that limit the enumeration stops and the index is searched
//!   with a filter that runs the MATCH with x bound (the `rows_of` chain)
//!   on each entity that would enter the results. If it ends with fewer
//!   than k, the exact way runs over every candidate, so that k come out
//!   whenever k match.
//! PROFILE shows how many rows took each way.

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Plan = @import("../planning/Plan.zig");
const Value = @import("../value.zig").Value;
const fulltext = @import("../storage/fulltext.zig");
const vector_index = @import("../storage/vector_index.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Bindings = @import("bindings.zig").Bindings;
const no_slot = @import("bindings.zig").no_slot;
const clauses = @import("clauses.zig");
const expressions = @import("expressions.zig");
const operators = @import("operators.zig");
const procedures = @import("procedures.zig");

/// How the rows of one SEARCH operator were found, for PROFILE.
pub const Ways = struct {
    exact: u64 = 0,
    hnsw: u64 = 0,
    /// HNSW found fewer than k, and the exact way completed it.
    hnsw_then_exact: u64 = 0,
};

/// An entity found, its distance to the query and its rows of the MATCH.
const Found = struct {
    id: u64,
    distance: f32,
    rows: []Bindings,

    fn closerFirst(_: void, a: Found, b: Found) bool {
        if (a.distance != b.distance) return a.distance < b.distance;
        return a.id < b.id;
    }
};

/// What a SEARCH needs from its row: the index, the query vector, k, ef.
const Request = struct {
    definition: fulltext.Definition,
    query: []const f32,
    k: usize,
    ef: usize,
};

/// SEARCH operator `search`, for one incoming `row`: feeds `next`.
pub fn run(executor: *Executor, search: Plan.Search, next: Plan.OperatorIndex, row: *Bindings) ExecutionError!void {
    const request = try requestOf(executor, search, row);
    var searcher = try vector_index.Searcher.init(executor.graph, executor.allocator, request.definition);
    const found = if (request.k == 0) &.{} else try closest(executor, search, next - 1, &searcher, request, row);
    try emit(executor, search, next, found, &searcher, row);
}

/// The `k` entities closest to the query among the MATCH's, closest first.
fn closest(executor: *Executor, search: Plan.Search, index: Plan.OperatorIndex, searcher: *vector_index.Searcher, request: Request, row: *Bindings) ExecutionError![]Found {
    const ways: ?*Ways = if (executor.profile) |profile| &profile.search_ways[index] else null;
    if (try gather(executor, search, row, exactLimit(request, searcher.live))) |candidates| {
        if (ways) |counted| counted.exact += 1;
        return rank(searcher, request, candidates);
    }
    var filter = Filter{ .executor = executor, .search = search, .row = row };
    const hits = try searcher.search(executor.allocator, request.query, request.k, request.ef, &filter);
    if (hits.len == request.k) {
        if (ways) |counted| counted.hnsw += 1;
        const found = try executor.allocator.alloc(Found, hits.len);
        for (found, hits) |*entity, hit| entity.* = .{ .id = hit.id, .distance = hit.distance, .rows = filter.rows.get(hit.id).? };
        return found;
    }
    if (ways) |counted| counted.hnsw_then_exact += 1;
    return rank(searcher, request, (try gather(executor, search, row, null)).?);
}

/// The most entities the exact way measures: ten times ef, or more on a
/// large index, where the HNSW visits about ef x live / matches entities
/// to find those that match (the two costs meet at sqrt(ef x live)).
fn exactLimit(request: Request, live: u64) usize {
    const breadth: u64 = request.ef;
    return @intCast(@max(10 * breadth, std.math.sqrt(breadth *| live)));
}

/// The entities of the MATCH's rows from `row`, with their rows, or null
/// when they are more than `limit`.
fn gather(executor: *Executor, search: Plan.Search, row: *Bindings, limit: ?usize) ExecutionError!?std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(Bindings)) {
    const Gather = struct {
        executor: *Executor,
        slot: @TypeOf(search.entity_slot),
        limit: ?usize,
        entities: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(Bindings)) = .empty,

        fn take(context: *anyopaque, match: *Bindings) ExecutionError!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const allocator = self.executor.allocator;
            const slot = try self.entities.getOrPut(allocator, entityId(match.get(self.slot).?));
            if (!slot.found_existing) {
                slot.value_ptr.* = .empty;
                if (self.limit) |most| if (self.entities.count() > most) return error.SearchTooBroad;
            }
            try slot.value_ptr.append(allocator, try clauses.copyRow(self.executor, match.*));
        }
    };
    var gathered = Gather{ .executor = executor, .slot = search.entity_slot, .limit = limit };
    var start = try clauses.copyRow(executor, row.*);
    operators.runChain(executor, search.candidates, &start, .{ .context = &gathered, .take = Gather.take }) catch |err| switch (err) {
        error.SearchTooBroad => return null,
        else => |other| return other,
    };
    return gathered.entities;
}

/// The `k` of `candidates` closest to the query (those the index holds:
/// an entity without a vector is not one), closest first.
fn rank(searcher: *vector_index.Searcher, request: Request, candidates: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(Bindings))) ExecutionError![]Found {
    var measured = std.ArrayList(Found).empty;
    const allocator = searcher.storage.arena;
    var entries = candidates.iterator();
    while (entries.next()) |entry| {
        const distance = try searcher.distanceOf(request.query, entry.key_ptr.*) orelse continue;
        try measured.append(allocator, .{ .id = entry.key_ptr.*, .distance = distance, .rows = entry.value_ptr.items });
    }
    std.mem.sort(Found, measured.items, {}, Found.closerFirst);
    return measured.items[0..@min(request.k, measured.items.len)];
}

/// The HNSW's filter: an entity matches if the MATCH, run from the row with
/// it bound, has a row. Its rows are kept for the entities returned.
const Filter = struct {
    executor: *Executor,
    search: Plan.Search,
    row: *Bindings,
    rows: std.AutoHashMapUnmanaged(u64, []Bindings) = .empty,

    pub fn accepts(self: *Filter, id: u64) ExecutionError!bool {
        const executor = self.executor;
        const value = try entityValue(executor, self.search, id) orelse return false;
        var start = try clauses.copyRow(executor, self.row.*);
        try start.put(executor.allocator, self.search.entity_slot, value);
        var matches = operators.Collect{ .executor = executor };
        try operators.runChain(executor, self.search.rows_of, &start, matches.sink());
        if (matches.rows.items.len == 0) return false;
        try self.rows.put(executor.allocator, id, matches.rows.items);
        return true;
    }
};

/// Feeds `next` the rows of `found`, best first, each with its score,
/// that pass the WHERE after SCORE AS; or, for an OPTIONAL MATCH left
/// with none, `row` with the MATCH's new variables and the score null.
fn emit(executor: *Executor, search: Plan.Search, next: Plan.OperatorIndex, found: []const Found, searcher: *vector_index.Searcher, row: *Bindings) ExecutionError!void {
    const post_where = executor.ast.nodeChildren(search.clause)[4];
    var emitted = false;
    for (found) |entity| {
        const score: Value = .{ .float = searcher.score(entity.distance) };
        for (entity.rows) |*match| {
            if (search.score_slot != no_slot) try match.put(executor.allocator, search.score_slot, score);
            if (!try expressions.evaluateBool(executor, post_where, match)) continue;
            emitted = true;
            try operators.feed(executor, next, match);
        }
    }
    if (emitted or executor.ast.kind(search.match_clause) != .optional_match_clause) return;
    const saved = row.mark();
    defer row.restore(saved);
    const children = executor.ast.nodeChildren(search.match_clause);
    try clauses.bindNewVariablesToNull(executor, children[0 .. children.len - 1], row);
    if (search.score_slot != no_slot) try row.put(executor.allocator, search.score_slot, .null);
    try operators.feed(executor, next, row);
}

fn entityId(value: Value) u64 {
    return switch (value) {
        .node => |id| id,
        .relationship => |relationship| relationship.id,
        else => unreachable, // the MATCH binds a node or a relationship
    };
}

/// The node or relationship `id` of the index, or null if it is gone.
fn entityValue(executor: *Executor, search: Plan.Search, id: u64) ExecutionError!?Value {
    if (!search.relationships) return .{ .node = id };
    const stored = try executor.graph.relationship(id, executor.allocator) orelse return null;
    return .{ .relationship = .{ .id = id, .src = stored.src, .dst = stored.dst, .edge_type = stored.edge_type } };
}

/// The index, query vector, k and ef of the SEARCH from `row`.
fn requestOf(executor: *Executor, search: Plan.Search, row: *Bindings) ExecutionError!Request {
    const ast = executor.ast;
    const names = ast.data(search.clause).search;
    const parts = ast.nodeChildren(search.clause);
    const found = try fulltext.find(executor.graph, names.index_name, executor.allocator);
    const definition = if (found != null and found.?.kind == .vector) found.? else {
        executor.fail(.invalid_expression, "there is no vector index named '{s}'", .{names.index_name});
        return error.InvalidExpression;
    };
    const wanted: fulltext.Entity = if (search.relationships) .relationships else .nodes;
    if (definition.entity != wanted) {
        executor.fail(.invalid_expression, "SEARCH '{s}' is a {s}, and vector index '{s}' indexes {s}", .{ names.variable_name, if (search.relationships) "relationship" else "node", names.index_name, @tagName(definition.entity) });
        return error.InvalidExpression;
    }
    try procedures.requireOnline(executor, definition);
    const query = switch (try vector_index.check(executor.allocator, definition, try expressions.evaluate(executor, parts[0], row))) {
        .vector => |vector| vector,
        .absent => {
            executor.fail(.type_mismatch, "SEARCH needs a vector, not null", .{});
            return error.TypeMismatch;
        },
        .invalid => |reason| {
            executor.fail(.invalid_expression, "SEARCH: index '{s}' takes a list of {d} numbers, and this vector {s}", .{ names.index_name, definition.dimensions, reason });
            return error.InvalidExpression;
        },
    };
    const k = try count(executor, try expressions.evaluate(executor, parts[2], row), "LIMIT", 0);
    var ef: ?usize = null;
    const options = try expressions.evaluate(executor, parts[3], row);
    switch (options) {
        .null => {},
        .map => |entries| for (entries) |option| {
            if (!std.mem.eql(u8, option.key, "ef")) {
                executor.fail(.invalid_expression, "SEARCH has no option '{s}' (expected ef)", .{option.key});
                return error.InvalidExpression;
            }
            ef = try count(executor, option.value, "option ef", 1);
        },
        else => {
            executor.fail(.type_mismatch, "SEARCH takes its OPTIONS as a map, such as {{ef: 200}}", .{});
            return error.TypeMismatch;
        },
    }
    const breadth = ef orelse definition.searchBreadth();
    return .{ .definition = definition, .query = query, .k = k, .ef = @max(k, breadth) };
}

/// `value` as a count of at least `least`, for the SEARCH's `what`.
fn count(executor: *Executor, value: Value, what: []const u8, least: i64) ExecutionError!usize {
    if (value != .int) {
        executor.fail(.type_mismatch, "the SEARCH {s} must be an integer, not {s}", .{ what, @tagName(value) });
        return error.TypeMismatch;
    }
    if (value.int < least) {
        executor.fail(.invalid_expression, "the SEARCH {s} must be at least {d}, not {d}", .{ what, least, value.int });
        return error.InvalidExpression;
    }
    return @intCast(value.int);
}
