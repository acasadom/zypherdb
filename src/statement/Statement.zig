//! A prepared statement: a query parsed, checked and planned once, then run
//! again and again with new parameter values. The plan depends on what kind
//! each predicate's value is (a literal, a parameter), never on the values,
//! so parameters are bound when the statement runs.
//!
//! The plan was built on the graph's counts of the time (`Plan.statistics`).
//! Each run reads them again, in its own transaction, and plans again when
//! one has drifted: grown or shrunk to `drift_factor` times what it was, by
//! at least `drift_floor`.
//!
//! EXPLAIN, PROFILE and schema commands are parsed again on each run (they
//! have no plan to keep). A statement is not safe to run from two threads at
//! once; its database's are not either.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const parser = @import("../query/parser.zig");
const printer = @import("../query/printer.zig");
const signatures = @import("../query/procedures.zig");
const Diagnostic = @import("../diagnostics.zig").Diagnostic;
const Graph = @import("../storage/graph.zig").Graph;
const Plan = @import("../planning/Plan.zig");
const builder = @import("../planning/builder.zig");
const statistics = @import("../planning/statistics.zig");
const Executor = @import("../execution/Executor.zig");
const ExecutionError = Executor.ExecutionError;
const Row = Executor.Row;

const Statement = @This();

/// A count that changed to this many times what it was, or a fraction as
/// small, makes the plan stale ...
pub const drift_factor = 2;
/// ... if it changed by at least this many: small graphs do not replan
/// over a handful of nodes.
pub const drift_floor = 100;

pub const PrepareError = ExecutionError || error{ParseFailed};

allocator: Allocator,
/// Owns the text, the AST and what the statement says about itself.
arena: std.heap.ArenaAllocator,
/// Owns the current plan; reset when the statement plans again.
plan_arena: std.heap.ArenaAllocator,
text: []const u8,
ast: Ast,
root: Index,
/// A query or a UNION, which keeps a plan; else (EXPLAIN, PROFILE, a
/// schema command) parsed again on each run.
is_query: bool,
/// The plan of a query (null until planned, or if planning again failed).
plan: ?Plan,
writes: bool,
/// The `$name` parameters it reads, in the order they first appear.
parameter_names: []const []const u8,
/// The names of its result's columns (empty without RETURN).
columns: []const []const u8,
/// How many times it has planned (1 after `prepare`).
plans_made: usize = 0,

/// What preparing and running a statement takes besides its text.
pub const Environment = struct {
    graph: *Graph,
    diagnostic: ?*Diagnostic = null,
    table_procedures: []const signatures.TableProcedure = &.{},
};

/// Parses, checks and plans `text` (the plan in a read transaction of its
/// own). The statement is the caller's, to `destroy`.
pub fn prepare(allocator: Allocator, text: []const u8, environment: Environment) PrepareError!*Statement {
    const self = try allocator.create(Statement);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .plan_arena = std.heap.ArenaAllocator.init(allocator),
        .text = undefined,
        .ast = undefined,
        .root = undefined,
        .is_query = false,
        .plan = null,
        .writes = false,
        .parameter_names = &.{},
        .columns = &.{},
    };
    errdefer self.arena.deinit();
    errdefer self.plan_arena.deinit();
    const arena = self.arena.allocator();
    self.text = try arena.dupe(u8, text);
    self.ast = Ast.init(arena);
    self.root = parser.parse(&self.ast, self.text, environment.diagnostic) catch |err| {
        if (environment.diagnostic) |diagnostic| if (diagnostic.message().len == 0) diagnostic.set(.parse, 0, "parse failed: {s}", .{@errorName(err)});
        return error.ParseFailed;
    };
    self.parameter_names = try self.ast.parameterNames(arena, self.root);
    self.is_query = isQuery(&self.ast, self.root);
    if (!self.is_query) return self;

    var checker = Executor.init(&self.ast, environment.graph, arena);
    checker.diagnostic = environment.diagnostic;
    checker.table_procedures = environment.table_procedures;
    try checker.check(self.root);
    self.writes = checker.writes(self.root);
    self.columns = try columnNames(&self.ast, arena, self.root, environment.table_procedures);

    try environment.graph.beginRead();
    defer environment.graph.commitRead();
    try self.replan(environment.graph);
    return self;
}

pub fn destroy(self: *Statement) void {
    self.plan_arena.deinit();
    self.arena.deinit();
    self.allocator.destroy(self);
}

/// Runs the statement with `executor`, which the caller made with the
/// statement's AST (`executorFor`), its parameters and a scratch allocator
/// the rows live in. One transaction, as `Executor.run`.
pub fn run(self: *Statement, executor: *Executor) ExecutionError![]const Row {
    if (!self.is_query) {
        // Parsed again, into the run's memory: running these rewrites nothing
        // the statement keeps.
        const ast = try executor.allocator.create(Ast);
        ast.* = Ast.init(executor.allocator);
        const root = parser.parse(ast, self.text, executor.diagnostic) catch return error.InvalidExpression;
        executor.ast = ast;
        return executor.run(root);
    }
    const graph = executor.graph;
    if (self.writes) try graph.beginWrite() else try graph.beginRead();
    errdefer if (self.writes) graph.abortWrite() else graph.abortRead();
    if (self.plan == null or stale(self.plan.?, graph)) try self.replan(graph);
    const rows = try executor.execute(&self.plan.?, self.root);
    if (self.writes) try graph.commitWrite() else graph.commitRead();
    return rows;
}

/// An executor for running the statement, allocating in `scratch`.
pub fn executorFor(self: *Statement, graph: *Graph, scratch: Allocator) Executor {
    return Executor.init(&self.ast, graph, scratch);
}

/// Plans the statement again, from the graph's counts now (in the caller's
/// transaction).
fn replan(self: *Statement, graph: *Graph) Allocator.Error!void {
    self.plan = null;
    _ = self.plan_arena.reset(.retain_capacity);
    const plan_allocator = self.plan_arena.allocator();
    var counts = statistics.Statistics{ .graph = graph, .allocator = plan_allocator };
    self.plan = try builder.build(.{ .ast = &self.ast, .statistics = &counts, .allocator = plan_allocator }, self.root);
    self.plans_made += 1;
}

/// True if a count the plan was built on has drifted (see `drift_factor`).
pub fn stale(plan: Plan, graph: *Graph) bool {
    for (plan.statistics) |count| {
        if (drifted(count.value, statistics.read(graph, count.kind, count.name))) return true;
    }
    return false;
}

fn drifted(then: usize, now: usize) bool {
    if (then == statistics.unknown or now == statistics.unknown) return false;
    const low = @min(then, now);
    const high = @max(then, now);
    return high - low >= drift_floor and high / drift_factor >= low;
}

/// A query or a UNION: what gets a plan to keep.
fn isQuery(ast: *const Ast, root: Index) bool {
    return switch (ast.kind(root)) {
        .query, .union_query => true,
        else => false,
    };
}

/// The result's column names: a RETURN's (its aliases, else the expressions
/// as Cypher), or those of a CALL that ends the query. A UNION's are its
/// first part's.
fn columnNames(ast: *const Ast, arena: Allocator, root: Index, table_procedures: []const signatures.TableProcedure) Allocator.Error![]const []const u8 {
    const query = if (ast.kind(root) == .union_query) ast.nodeChildren(root)[0] else root;
    const clauses = ast.nodeChildren(query);
    if (clauses.len == 0) return &.{};
    const last = clauses[clauses.len - 1];
    var names = std.ArrayList([]const u8).empty;
    switch (ast.kind(last)) {
        .return_clause => for (ast.nodeChildren(ast.nodeChildren(last)[0])) |item| {
            const alias = ast.data(item).text;
            try names.append(arena, if (alias.len > 0) alias else try printer.text(ast, arena, ast.nodeChildren(item)[0]));
        },
        .call_clause => {
            const call = ast.data(last).call;
            var yielded = false;
            for (ast.nodeChildren(last)) |child| {
                if (ast.kind(child) != .yield_item) continue;
                const item = ast.data(child).yield_;
                try names.append(arena, if (item.alias.len > 0) item.alias else item.column);
                yielded = true;
            }
            if (!yielded) if (signatures.find(call.procedure, table_procedures)) |signature| {
                for (signature.columns) |column| try names.append(arena, column.name);
            };
        },
        else => {},
    }
    return names.items;
}
