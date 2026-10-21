//! The plan of a query: the operators that run it, built once from the
//! checked AST (`builder.zig`) and run by `execution/operators.zig`.
//!
//! Operators live in one flat array, as the AST's nodes do, and are grouped
//! in chains: a chain is a run of consecutive operators, each handing the
//! rows it makes to the next one (the push model of a pipeline). A main
//! chain runs a query (one per part of a UNION); the other chains run inside
//! an operator, once for each of its rows: an OPTIONAL MATCH, a `CALL { }`
//! subquery, a MERGE's match, a FOREACH's clauses, and the patterns and
//! subqueries inside expressions. Each of those ends with `output`, which
//! hands its rows back to whoever runs the chain.
//!
//! A plan does not change once built. What a run needs besides it (the rows
//! an operator keeps, the nodes matched on the current search branch) is the
//! executor's, so one plan can run again and again (a prepared statement).

const std = @import("std");
const Index = @import("../query/ast.zig").Index;
const Shortest = @import("../query/ast.zig").EdgePatternData.Shortest;
const Direction = @import("../storage/graph.zig").Direction;

const Plan = @This();

pub const OperatorIndex = u32;
pub const ChainIndex = u32;
pub const PatternIndex = u32;
/// A MATCH (or OPTIONAL MATCH, MERGE, pattern in an expression): the unit of
/// relationship uniqueness.
pub const MatchIndex = u32;

operators: []const Operator,
chains: []const Chain,
patterns: []const PatternPlan,
/// The main chain of each query (several for a UNION), in order.
main_chains: []const ChainIndex,
/// The chain of each pattern or subquery inside an expression (a pattern
/// predicate, a pattern comprehension, `EXISTS { }`, `COUNT { }`), by its
/// AST node.
expression_chains: std.AutoHashMapUnmanaged(Index, ChainIndex),
/// How many pattern nodes and edges all the patterns have: the executor
/// keeps what each is matched to on the current branch.
node_count: u32,
edge_count: u32,

/// A run of consecutive operators: `first` up to, not including, `end`.
pub const Chain = struct {
    first: OperatorIndex,
    end: OperatorIndex,
};

pub const Operator = union(enum) {
    /// A node of the pattern bound before it (by an earlier pattern or
    /// clause): checks it against the pattern's labels and properties.
    bound_node: NodeReference,
    /// Binds the pattern's anchor node to each of its candidates.
    node_scan: NodeReference,
    /// Binds both ends of a single-edge pattern from the edge-property index.
    edge_index_scan: EdgeReference,
    /// Follows the edge between pattern nodes `from` (matched) and `to`.
    expand: Expand,
    /// Binds the pattern's path variable (`p = ...`).
    project_path: PatternIndex,
    /// Keeps the rows for which `predicate` is true.
    filter: Filter,
    /// OPTIONAL MATCH: the rows of `chain` run from each row, or the row
    /// with the clause's new variables null when there is none.
    optional: Optional,
    unwind: Index,
    load_csv: Index,
    procedure_call: ProcedureCall,
    /// `CALL { }`: `chain` run for each row.
    call_subquery: CallSubquery,
    /// A WITH (or a subquery's RETURN) that only projects and filters.
    with_streaming: Index,
    /// A WITH (or a subquery's RETURN) that groups, removes duplicates,
    /// sorts or pages: it keeps every row, and makes its own at the end.
    with_collecting: Index,
    /// The query's RETURN.
    return_: Index,
    /// Keeps every row before handing any on: each clause of a query that
    /// writes sees the effect of the clause before it on every row.
    eager,
    /// CREATE, SET, DELETE or REMOVE, applied to each row in turn.
    write: Index,
    /// MERGE: the matches of `chain` from each row, or the pattern created.
    merge: Merge,
    /// FOREACH: `chain` (its clauses) run once per element of the list.
    foreach: Foreach,
    /// The end of a chain run by an operator or an expression: hands each
    /// row back to it.
    output: ChainIndex,
    /// The end of a query without RETURN: its rows go no further.
    discard,
};

pub const NodeReference = struct { pattern: PatternIndex, node: u32 };

pub const EdgeReference = struct { pattern: PatternIndex, edge: u32 };

pub const Expand = struct { pattern: PatternIndex, from: u32, to: u32 };

pub const Filter = struct {
    predicate: Index,
    /// The WHERE of a MATCH: the rows it keeps are counted (a shortest-path
    /// search that tests the WHERE stops at the length where one passed).
    counts_accepted: bool,
};

pub const Optional = struct { clause: Index, chain: ChainIndex };

pub const ProcedureCall = struct {
    clause: Index,
    /// The CALL ends the query: its rows are the query's result.
    ends_query: bool,
};

pub const CallSubquery = struct {
    clause: Index,
    chain: ChainIndex,
    /// The subquery starts from the row (it imports variables), else from
    /// an empty one.
    imports: bool,
    /// It has a RETURN, whose columns extend the row; else the row goes on.
    returns: bool,
};

pub const Merge = struct { clause: Index, chain: ChainIndex };

pub const Foreach = struct { clause: Index, chain: ChainIndex };

/// One pattern (`(a)-[r]->(b)...`) of a MATCH, planned: its nodes and edges
/// in written order, with the predicates pushed down to them.
pub const PatternPlan = struct {
    nodes: []const PatternNode,
    edges: []const PatternEdge,
    /// `p = ...`, or empty.
    path_variable: []const u8,
    /// The MATCH it is part of.
    match: MatchIndex,
    /// Where its nodes' and edges' run state starts in the executor's.
    first_node: u32,
    first_edge: u32,
};

/// An equality predicate `node.property = value` pushed down to a node.
pub const Seek = struct {
    property: []const u8,
    value: Index,
};

/// A comparison `node.property > value` (or `<`, `>=`, `<=`) pushed down to a
/// node: a bound for a range lookup (`Graph.nodesInRange`). The WHERE is still
/// evaluated on every match, so the bound need only include what it keeps.
pub const RangeSeek = struct {
    property: []const u8,
    lower: ?Index,
    upper: ?Index,
};

pub const PatternNode = struct {
    variable_name: []const u8,
    labels: []const []const u8,
    seeks: []const Seek,
    ranges: []const RangeSeek,
    /// Bound before the pattern (by an earlier pattern or clause).
    bound: bool,
};

pub const PatternEdge = struct {
    edge_types: []const []const u8, // empty: any type
    /// `*min..max`: a path of min..max edges (max null: unbounded).
    variable_length: bool,
    min_hops: u32,
    max_hops: ?u32,
    /// Only the shortest paths (`shortestPath`: one, `allShortestPaths`: all).
    shortest: Shortest = .none,
    /// A shortest path whose MATCH's WHERE reads the path or its
    /// relationships: searched by increasing length (shortest_paths.zig).
    where_reads_path: bool = false,
    forward_direction: Direction, // direction when traversing node_i -> node_{i+1}
    undirected: bool, // `-[...]-`: either direction (forward_direction unused)
    /// Bound before the pattern or not, the variable takes the edge only if
    /// it is not bound to another one (`Bindings.bindValue`).
    variable_name: []const u8,
    seeks: []const Seek, // inline property equality filters

    /// True if an edge of type `edge_type` fits the pattern.
    pub fn allowsType(self: PatternEdge, edge_type: []const u8) bool {
        if (self.edge_types.len == 0) return true;
        for (self.edge_types) |allowed| {
            if (std.mem.eql(u8, allowed, edge_type)) return true;
        }
        return false;
    }

    /// The one type the pattern requires, if it names exactly one.
    pub fn singleType(self: PatternEdge) ?[]const u8 {
        return if (self.edge_types.len == 1) self.edge_types[0] else null;
    }
};

/// The operators of `chain`.
pub fn chainOperators(self: *const Plan, chain: ChainIndex) []const Operator {
    const range = self.chains[chain];
    return self.operators[range.first..range.end];
}
