//! The query executor: runs a parsed query as a pipeline of clauses.
//!
//! A query is a sequence of clauses. Each one turns the list of rows (the
//! variable bindings) it receives into the list the next clause receives,
//! starting from one empty row: MATCH and OPTIONAL MATCH extend each row with
//! every match (OPTIONAL keeps an unmatched row, with nulls), UNWIND with each
//! list element, WITH projects / groups / filters, the write clauses apply to
//! every row in turn, and RETURN projects the final result. Each clause sees
//! the effects of the clauses before it (see `clauses.zig`, `projection.zig`).
//!
//! The whole query runs in one transaction: a write transaction if any clause
//! writes, else one consistent read snapshot.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const Graph = @import("../storage/graph.zig").Graph;
const StorageError = @import("../storage/key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const Relationship = @import("../value.zig").Relationship;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;
const ErrorCode = @import("../diagnostics.zig").ErrorCode;
const semantics = @import("../query/semantics.zig");

const ValueGrouping = @import("aggregation.zig").ValueGrouping;
const AggregationPlan = @import("aggregation.zig").AggregationPlan;
const ProjectionItem = @import("aggregation.zig").ProjectionItem;
const EntitySnapshot = @import("entities.zig").EntitySnapshot;
const Bindings = @import("bindings.zig").Bindings;
const PlanStep = @import("planner.zig").PlanStep;
const PatternEdge = @import("planner.zig").PatternEdge;
const PatternNode = @import("planner.zig").PatternNode;

const clauses = @import("clauses.zig");
const expressions = @import("expressions.zig");
const functions = @import("functions.zig");
const projection = @import("projection.zig");

const Executor = @This();

pub const ExecutionError = StorageError || error{
    IntegerOverflow,
    DivisionByZero,
    ParameterMissing,
    UnsupportedPropertyType,
    UnknownVariable,
    InvalidExpression,
    TypeMismatch,
};

/// A projected row: one `Value` per RETURN item.
pub const Row = std.ArrayList(Value);

/// Query parameters (`$name`), by name.
pub const Parameters = std.StringHashMapUnmanaged(Value);

pub const no_aggregation = AggregationPlan{ .keys = &.{}, .aggregates = &.{}, .kinds = &.{} };

ast: *Ast,
graph: *Graph,
allocator: Allocator,
diagnostic: ?*Diagnostic,
/// The values of the query's `$name` parameters (none by default).
parameters: Parameters,

/// RETURN rows, each with its ORDER BY key.
rows: std.ArrayList(projection.Sortable(Row)),
/// Labels and properties of the nodes and relationships in the result rows,
/// read before the query's transaction ends (see `entities.zig`).
entities: EntitySnapshot,

// The MATCH (or OPTIONAL MATCH) being run: its patterns, WHERE, the plan of
// the pattern being matched, and where complete matches go.
patterns: []const Index,
where_expression: Index,
nodes: std.ArrayList(PatternNode),
edges: std.ArrayList(PatternEdge),
steps: std.ArrayList(PlanStep),
matches: ?*std.ArrayList(Bindings),
/// The path variable of the pattern being matched (`p = ...`), or empty.
path_variable: []const u8,
/// Relationship uniqueness: the edges bound on the current search branch of
/// the MATCH being run.
used_edges: std.ArrayList(Relationship),

// RETURN aggregation.
has_aggregates: bool,
projection_items: std.ArrayList(ProjectionItem),
return_aggregation: AggregationPlan,
groups: ValueGrouping,
/// While evaluating an aggregating expression for one group: the values that
/// replace its aggregate calls and grouping-key sub-expressions.
expression_overrides: ?*const std.AutoHashMapUnmanaged(Index, Value),

pub fn init(ast: *Ast, graph: *Graph, allocator: Allocator) Executor {
    return .{
        .ast = ast,
        .graph = graph,
        .allocator = allocator,
        .diagnostic = null,
        .parameters = .empty,
        .rows = .empty,
        .entities = .{},
        .patterns = &.{},
        .where_expression = 0,
        .nodes = .empty,
        .edges = .empty,
        .steps = .empty,
        .matches = null,
        .path_variable = "",
        .used_edges = .empty,
        .has_aggregates = false,
        .projection_items = .empty,
        .return_aggregation = no_aggregation,
        .groups = .{},
        .expression_overrides = null,
    };
}

pub fn fail(self: *Executor, code: ErrorCode, comptime fmt: []const u8, args: anytype) void {
    if (self.diagnostic) |d| d.set(code, 0, fmt, args);
}

/// Runs a parsed query and returns its RETURN rows (none without RETURN).
/// All writes of the query commit or abort together; a read-only query reads
/// one consistent snapshot.
pub fn run(self: *Executor, query: Index) ExecutionError![]const Row {
    try semantics.check(self.ast, query, self.allocator, self.diagnostic);
    try functions.checkCalls(self.ast, query, self.diagnostic);
    self.reset();

    const query_clauses = self.ast.nodeChildren(query);
    const has_writes = for (query_clauses) |clause| {
        if (clauses.isWrite(self.ast.kind(clause))) break true;
    } else false;
    if (has_writes) try self.graph.beginWrite() else try self.graph.beginRead();
    errdefer if (has_writes) self.graph.abortWrite() else self.graph.abortRead();

    var rows: []Bindings = try self.allocator.alloc(Bindings, 1);
    rows[0] = .{ .entries = .empty };
    for (query_clauses) |clause| {
        rows = switch (self.ast.kind(clause)) {
            .match_clause => try clauses.runMatch(self, clause, rows, false),
            .optional_match_clause => try clauses.runMatch(self, clause, rows, true),
            .unwind_clause => try clauses.runUnwind(self, clause, rows),
            .with_clause => try projection.applyWith(self, clause, rows),
            .return_clause => {
                try projection.applyReturn(self, clause, rows);
                break;
            },
            else => try clauses.runWrite(self, clause, rows),
        };
    }
    // Read the entities the rows refer to while the transaction still holds.
    for (self.rows.items) |row| try self.entities.capture(self.graph, self.allocator, row.item.items);

    if (has_writes) try self.graph.commitWrite() else self.graph.commitRead();

    const result = try self.allocator.alloc(Row, self.rows.items.len);
    for (result, self.rows.items) |*row, sortable| row.* = sortable.item;
    return result;
}

fn reset(self: *Executor) void {
    self.rows = .empty;
    self.entities = .{};
    self.used_edges = .empty;
    self.has_aggregates = false;
    self.projection_items = .empty;
    self.return_aggregation = no_aggregation;
    self.groups = .{};
    self.expression_overrides = null;
}

/// The expression of each projection item.
pub fn projectedExpressions(self: *Executor, projection_node: Index) ExecutionError![]const Index {
    const items = self.ast.nodeChildren(projection_node);
    const expressions_list = try self.allocator.alloc(Index, items.len);
    for (expressions_list, items) |*expr, item| expr.* = self.ast.nodeChildren(item)[0];
    return expressions_list;
}

/// The edge type to bind for a matched edge: the pattern's own (owned by the
/// AST) when it names one, else a copy of the stored type (a view into the
/// store that does not outlive the scan).
pub fn ownedEdgeType(self: *Executor, edge: PatternEdge, stored: []const u8) ExecutionError![]const u8 {
    if (edge.singleType()) |edge_type| return edge_type;
    return self.allocator.dupe(u8, stored);
}

/// Called by pattern matching for every complete match of the MATCH being
/// run: keeps it, as a row of its own, if it passes the MATCH's WHERE.
pub fn matchFound(self: *Executor, bindings: *Bindings) ExecutionError!void {
    if (!try expressions.evaluateBool(self, self.where_expression, bindings)) return;
    const output = self.matches orelse return;
    try output.append(self.allocator, try clauses.copyRow(self, bindings.*));
}
