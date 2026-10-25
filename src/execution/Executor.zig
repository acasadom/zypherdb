//! The query executor: plans a parsed query (src/planning/) and runs the
//! plan's chains of operators (`operators.zig`).
//!
//! A query is a sequence of clauses. Each one turns the rows (the variable
//! bindings) it receives into the rows the next clause receives, starting
//! from one empty row: MATCH and OPTIONAL MATCH extend each row with every
//! match (OPTIONAL keeps an unmatched row, with nulls), UNWIND with each list
//! element, WITH projects / groups / filters, the write clauses apply to
//! every row in turn, and RETURN projects the final result. Each clause sees
//! the effects of the clauses before it: in a query that writes, every row
//! goes through a clause before any goes on to the next one.
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
const procedure_signatures = @import("../query/procedures.zig");

const ValueGrouping = @import("aggregation.zig").ValueGrouping;
const AggregationPlan = @import("aggregation.zig").AggregationPlan;
const ProjectionItem = @import("aggregation.zig").ProjectionItem;
const EntitySnapshot = @import("entities.zig").EntitySnapshot;
const Bindings = @import("bindings.zig").Bindings;
const Slot = @import("bindings.zig").Slot;
const no_slot = @import("bindings.zig").no_slot;
const NodeId = @import("../storage/graph.zig").NodeId;
const Plan = @import("../planning/Plan.zig");
const builder = @import("../planning/builder.zig");
const Statistics = @import("../planning/statistics.zig").Statistics;
const ExpressionProgram = @import("../planning/expression_program.zig").Program;

const clauses = @import("clauses.zig");
const expressions = @import("expressions.zig");
const functions = @import("functions.zig");
const projection = @import("projection.zig");
const operators = @import("operators.zig");
const profiling = @import("profiling.zig");
const procedures = @import("procedures.zig");
const schema = @import("schema.zig");
const temporal_functions = @import("temporal_functions.zig");
const sequence_algorithms = @import("../sequence_algorithms.zig");

const Executor = @This();

pub const ExecutionError = StorageError || error{
    IntegerOverflow,
    DivisionByZero,
    ParameterMissing,
    UnsupportedPropertyType,
    UnknownVariable,
    InvalidExpression,
    TypeMismatch,
    /// Internal: a streamed RETURN has every row it keeps (see `operators.zig`).
    LimitReached,
    /// LOAD CSV could not read its file (load_csv.zig).
    ExternalResourceFailed,
};

/// A projected row: one `Value` per RETURN item.
pub const Row = std.ArrayList(Value);

/// Query parameters (`$name`), by name.
pub const Parameters = std.StringHashMapUnmanaged(Value);

/// A `where_expression` that keeps every row (a subquery's RETURN has no WHERE).
pub const no_where: Index = std.math.maxInt(Index);

pub const UsedEdge = struct { match: Plan.MatchIndex, relationship: Relationship };

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

/// The plan being run, and what the run keeps for it: each operator's state,
/// where the rows of each chain go, and what each pattern node and edge is
/// matched to on the current search branch (see operators.zig).
plan: *const Plan = undefined,
operator_states: []operators.OperatorState = &.{},
chain_sinks: []?operators.Sink = &.{},
node_ids: []NodeId = &.{},
/// The plan's `slot_of`, and how many slots its rows have.
slot_of: []const Slot = &.{},
/// The plan's compiled expressions, and the value of each of its
/// parameters (null: not given), found once per run.
expression_program: ExpressionProgram = .empty,
parameter_values: []const ?Value = &.{},
row_width: usize = 0,
matched_edges: [][]const Relationship = &.{},
single_matches: []Relationship = &.{},
/// The RETURN of the main chain being run, and how many rows it keeps if it
/// can stop early.
return_info: projection.ReturnClauseParts = undefined,
rows_needed: ?usize = null,
/// While PROFILE runs the query: what each operator does. The query's own
/// rows, which PROFILE returns the plan instead of, are kept here.
profile: ?*profiling.Profile = null,
profiled_rows: []const Row = &.{},
/// After EXPLAIN or PROFILE: the line each line of the plan is part of.
plan_parents: []const ?usize = &.{},
/// Procedures defined besides the built-in ones (the TCK's test procedures).
table_procedures: []const procedure_signatures.TableProcedure = &.{},
/// Relationship uniqueness: the relationships bound on the current search
/// branch, each with its MATCH (one MATCH never uses one twice).
used_edges: std.ArrayList(UsedEdge),
/// The directory LOAD CSV reads from; null: LOAD CSV is off.
import_directory: ?[]const u8 = null,
/// The patterns of `=~` compiled in this run, by their text: those that are
/// not constants (a constant one is compiled with the plan).
regexes: std.StringHashMapUnmanaged(@import("../text/regex.zig").Regex) = .empty,
/// How many matches have passed their MATCH's WHERE so far (a shortest-path
/// search that tests the WHERE stops at the length where one did).
accepted_matches: usize = 0,

// RETURN aggregation.
has_aggregates: bool,
projection_items: std.ArrayList(ProjectionItem),
return_aggregation: AggregationPlan,
groups: ValueGrouping,
/// While evaluating an aggregating expression for one group: the values that
/// replace its aggregate calls and grouping-key sub-expressions.
expression_overrides: ?*const std.AutoHashMapUnmanaged(Index, Value),
/// The time the statement runs at (nanoseconds since the epoch), read from
/// the clock when first asked for, so `datetime()` is the same throughout.
statement_time: ?i128,
/// A fixed clock (nanoseconds since the epoch) for every reading of the time,
/// `realtime` ones too; null: the system clock. Fuzzers and tests set it so a
/// run repeats.
fixed_time: ?i128 = null,
/// The planner's options for the plans `run` builds; the defaults make the
/// fastest plan. Fuzzers turn optimizations off to compare results.
plan_options: builder.Options = .{},
/// The generator `rand()` draws from; null: the system's random source.
/// Fuzzers and tests set it so a run repeats.
random: ?std.Random = null,

pub fn init(ast: *Ast, graph: *Graph, allocator: Allocator) Executor {
    return .{
        .ast = ast,
        .graph = graph,
        .allocator = allocator,
        .diagnostic = null,
        .parameters = .empty,
        .rows = .empty,
        .entities = .{},
        .used_edges = .empty,
        .has_aggregates = false,
        .projection_items = .empty,
        .return_aggregation = no_aggregation,
        .groups = .{},
        .expression_overrides = null,
        .statement_time = null,
    };
}

pub fn fail(self: *Executor, code: ErrorCode, comptime fmt: []const u8, args: anytype) void {
    if (self.diagnostic) |d| d.set(code, 0, fmt, args);
}

/// Runs a parsed query (or a UNION of queries, one after the other) and
/// returns its RETURN rows (none without RETURN). All writes of the query
/// commit or abort together; a read-only query reads one consistent snapshot.
pub fn run(self: *Executor, root: Index) ExecutionError![]const Row {
    if (self.ast.kind(root) == .explain) return profiling.run(self, root);
    if (schema.isSchemaCommand(self, root)) return schema.run(self, root);
    try self.check(root);
    const has_writes = self.writes(root);
    if (has_writes) try self.graph.beginWrite() else try self.graph.beginRead();
    errdefer if (has_writes) self.graph.abortWrite() else self.graph.abortRead();

    var statistics = Statistics{ .graph = self.graph, .allocator = self.allocator };
    const plan = try builder.build(.{ .ast = self.ast, .statistics = &statistics, .allocator = self.allocator, .options = self.plan_options }, root);
    const result = try self.execute(&plan, root);

    if (has_writes) try self.graph.commitWrite() else self.graph.commitRead();
    return result;
}

/// The semantic checks of `root` (a query or a UNION), before it is planned.
pub fn check(self: *Executor, root: Index) ExecutionError!void {
    if (self.ast.kind(root) != .union_query) return self.checkQuery(root);
    for (self.ast.nodeChildren(root)) |query| try self.checkQuery(query);
}

fn checkQuery(self: *Executor, query: Index) ExecutionError!void {
    try semantics.check(self.ast, query, self.allocator, self.diagnostic, self.table_procedures);
    try functions.checkCalls(self.ast, query, self.diagnostic);
}

/// True if a part of `root` writes: it runs in a write transaction.
pub fn writes(self: *Executor, root: Index) bool {
    if (self.ast.kind(root) != .union_query) return self.ast.queryWrites(root);
    for (self.ast.nodeChildren(root)) |query| {
        if (self.ast.queryWrites(query)) return true;
    }
    return false;
}

/// Runs `plan`, the plan of `root`, in the transaction the caller opened:
/// its main chains one after the other, then a UNION's duplicates removed.
/// Reads the entities the rows refer to before returning them.
pub fn execute(self: *Executor, plan: *const Plan, root: Index) ExecutionError![]const Row {
    self.reset();
    self.entities = .{};
    self.statement_time = null;
    self.regexes = .empty;
    try self.start(plan);

    var result = std.ArrayList(Row).empty;
    for (plan.main_chains) |chain| {
        self.reset();
        operators.runMain(self, chain) catch |err| {
            if (err == error.ConstraintViolation) self.fail(.constraint_violation, "{s}", .{self.graph.violationMessage()});
            return err;
        };
        for (self.rows.items) |sortable| try result.append(self.allocator, sortable.item);
    }
    // UNION (not UNION ALL) keeps one of each row.
    if (self.ast.kind(root) == .union_query and !self.ast.data(root).boolean) {
        try sequence_algorithms.removeDuplicates(Row, self.allocator, &result, projection.RowContext{});
    }
    // Read the entities the rows refer to while the transaction still holds.
    for (result.items) |row| try self.entities.capture(self.graph, self.allocator, row.items);
    return result.items;
}

/// Prepares the run state of `plan`. A parameter the query reads but the
/// run was not given fails here, before anything runs, as in Neo4j: even
/// one that no row would reach.
fn start(self: *Executor, plan: *const Plan) ExecutionError!void {
    for (plan.parameter_names) |name| {
        if (!self.parameters.contains(name)) {
            self.fail(.parameter_missing, "missing parameter '${s}'", .{name});
            return error.ParameterMissing;
        }
    }
    self.plan = plan;
    self.slot_of = plan.slot_of;
    try self.useExpressions(plan.expressions);
    self.row_width = plan.slot_count;
    self.operator_states = try operators.initialStates(self);
    self.chain_sinks = try self.allocator.alloc(?operators.Sink, plan.chains.len);
    @memset(self.chain_sinks, null);
    self.node_ids = try self.allocator.alloc(NodeId, plan.node_count);
    self.matched_edges = try self.allocator.alloc([]const Relationship, plan.edge_count);
    self.single_matches = try self.allocator.alloc(Relationship, plan.edge_count);
}

/// Evaluates expressions with `program` (a plan's, or a schema command's),
/// looking up the values of its parameters once.
pub fn useExpressions(self: *Executor, program: ExpressionProgram) ExecutionError!void {
    self.expression_program = program;
    const values = try self.allocator.alloc(?Value, program.parameter_names.len);
    for (values, program.parameter_names) |*value, name| value.* = self.parameters.get(name);
    self.parameter_values = values;
}

/// Clears the state of the query part last run.
fn reset(self: *Executor) void {
    self.rows = .empty;
    self.used_edges = .empty;
    self.has_aggregates = false;
    self.projection_items = .empty;
    self.return_aggregation = no_aggregation;
    self.groups = .{};
    self.expression_overrides = null;
}

/// The slot of the AST node `node` (a variable or what binds one).
pub fn slotOf(self: *const Executor, node: Index) Slot {
    return if (node < self.slot_of.len) self.slot_of[node] else no_slot;
}

/// A row of the plan's width, nothing bound.
pub fn newRow(self: *const Executor) ExecutionError!Bindings {
    return Bindings.init(self.allocator, self.row_width);
}

/// The statement's time, in nanoseconds since the epoch.
pub fn statementTime(self: *Executor) i128 {
    if (self.statement_time == null) self.statement_time = self.clockNow();
    return self.statement_time.?;
}

/// The time now, in nanoseconds since the epoch: `fixed_time` if set.
pub fn clockNow(self: *const Executor) i128 {
    return self.fixed_time orelse temporal_functions.clockNow();
}

/// The expression of each projection item.
pub fn projectedExpressions(self: *Executor, projection_node: Index) ExecutionError![]const Index {
    const items = self.ast.nodeChildren(projection_node);
    const expressions_list = try self.allocator.alloc(Index, items.len);
    for (expressions_list, items) |*expr, item| expr.* = self.ast.nodeChildren(item)[0];
    return expressions_list;
}
