//! Counting from an index: when a query only counts the nodes of one label
//! whose indexed property is in a range, the index's keys in that range are
//! the answer (`Plan.Operator.node_index_range_count`).

const std = @import("std");
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const property_indexes = @import("../storage/property_indexes.zig");
const Plan = @import("Plan.zig");

/// True if the query of `clauses`, whose one pattern is planned as
/// `pattern`, is `MATCH (n:Label) WHERE <ranges> RETURN count(n)` (or
/// `count(*)`, with any alias) where every comparison of the WHERE is a
/// range seek on the property its index covers, at most one from each side.
pub fn countsFromIndex(ast: *const Ast, clauses: []const Index, pattern: Plan.PatternPlan) bool {
    if (clauses.len != 2) return false;
    if (ast.kind(clauses[0]) != .match_clause or ast.kind(clauses[1]) != .return_clause) return false;
    const match_children = ast.nodeChildren(clauses[0]);
    if (match_children.len != 2) return false; // one pattern, and the WHERE
    if (pattern.nodes.len != 1 or pattern.path_variable.len > 0) return false;
    const node = pattern.nodes[0];
    if (node.bound or node.labels.len != 1 or node.seeks.len > 0) return false;
    const use = node.range_index orelse return false;
    if (!rangesOnOneProperty(node.ranges, node.ranges[use.position].property)) return false;
    const comparisons = comparisonCount(ast, match_children[1]) orelse return false;
    if (comparisons != node.ranges.len) return false;
    return countsNode(ast, clauses[1], node.variable_name);
}

/// The ranges are all on `property` (a name, not a document path: reading
/// a path can fail where the index has no entry), at most one per side.
fn rangesOnOneProperty(ranges: []const Plan.RangeSeek, property: []const u8) bool {
    if (std.mem.indexOfScalar(u8, property, property_indexes.path_separator) != null) return false;
    var lowers: usize = 0;
    var uppers: usize = 0;
    for (ranges) |range| {
        if (!std.mem.eql(u8, range.property, property)) return false;
        if (range.lower != null) lowers += 1;
        if (range.upper != null) uppers += 1;
    }
    return lowers <= 1 and uppers <= 1;
}

/// How many comparisons (`<`, `<=`, `>`, `>=`) the AND tree `expression`
/// joins, or null if it holds anything else.
fn comparisonCount(ast: *const Ast, expression: Index) ?usize {
    if (ast.kind(expression) != .binary_operation) return null;
    const children = ast.nodeChildren(expression);
    return switch (ast.data(expression).binary_operator) {
        .greater_than, .greater_or_equal, .less_than, .less_or_equal => 1,
        .and_ => (comparisonCount(ast, children[0]) orelse return null) + (comparisonCount(ast, children[1]) orelse return null),
        else => null,
    };
}

/// True if the RETURN `clause` is one `count(*)` or `count(variable)`, not
/// DISTINCT, without ORDER BY, SKIP or LIMIT.
fn countsNode(ast: *const Ast, clause: Index, variable: []const u8) bool {
    if (ast.data(clause).return_.distinct) return false;
    const children = ast.nodeChildren(clause);
    if (children.len != 1) return false;
    const items = ast.nodeChildren(children[0]);
    if (items.len != 1) return false;
    const expression = ast.nodeChildren(items[0])[0];
    if (ast.kind(expression) != .aggregate) return false;
    const call = ast.data(expression).aggregate;
    if (call.kind != .count or call.distinct) return false;
    const arguments = ast.nodeChildren(expression);
    if (arguments.len == 0) return true;
    return arguments.len == 1 and ast.kind(arguments[0]) == .variable and variable.len > 0 and
        std.mem.eql(u8, ast.data(arguments[0]).text, variable);
}
