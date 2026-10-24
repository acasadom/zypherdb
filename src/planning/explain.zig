//! EXPLAIN: a plan as lines to read, one per operator, from the query's
//! result down to where its rows start (the order Neo4j shows a plan in).
//! A chain an operator runs (an OPTIONAL MATCH's, a subquery's) follows the
//! operator, one level deeper; the chain of a pattern or subquery inside an
//! expression follows the operator that evaluates it, under a line that
//! names the expression.
//!
//! The estimated rows of an operator are how many rows it makes per run of
//! its chain, from the label and relationship-type counts. They are a
//! guess: a filter is not assumed to drop any row, and an estimate is null
//! when the counts say nothing (a scan of every node, a variable-length
//! expansion, the groups of an aggregation).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const printer = @import("../query/printer.zig");
const Printer = printer.Printer;

const Plan = @import("Plan.zig");
const Operator = Plan.Operator;
const OperatorIndex = Plan.OperatorIndex;
const Statistics = @import("statistics.zig").Statistics;
const unknown = @import("statistics.zig").unknown;
const containsAggregate = @import("builder.zig").containsAggregate;

pub const Line = struct {
    depth: u32,
    /// The line this one is part of: the operator it hands its rows to, the
    /// operator that runs its chain, the expression it is the chain of (or
    /// the UNION); null for the first line.
    parent: ?usize,
    /// The operator it shows; null on the line that names an expression
    /// whose chain follows.
    operator: ?OperatorIndex,
    name: []const u8,
    details: []const u8,
    estimated_rows: ?f64,
};

/// The lines of `plan`, the plan of `root` (a query or a UNION).
pub fn lines(ast: *const Ast, plan: *const Plan, root: Index, statistics: *Statistics, allocator: Allocator) Allocator.Error![]const Line {
    var explainer = Explainer{ .ast = ast, .plan = plan, .statistics = statistics, .allocator = allocator };
    explainer.estimates = try allocator.alloc(?f64, plan.operators.len);
    // Each chain's operators after the chains they run (as they are built).
    for (0..plan.chains.len) |chain| try explainer.estimateChain(@intCast(chain));
    explainer.shown = try allocator.alloc(bool, plan.chains.len);
    @memset(explainer.shown, false);

    if (plan.main_chains.len > 1) {
        const all = ast.data(root).boolean;
        try explainer.output.append(allocator, .{ .depth = 0, .parent = null, .operator = null, .name = if (all) "UnionAll" else "Union", .details = "", .estimated_rows = null });
        for (plan.main_chains) |chain| try explainer.chain(chain, 1, 0);
    } else try explainer.chain(plan.main_chains[0], 0, null);
    return explainer.output.items;
}

const Explainer = struct {
    ast: *const Ast,
    plan: *const Plan,
    statistics: *Statistics,
    allocator: Allocator,
    estimates: []?f64 = &.{},
    /// The expression chains shown already (an expression evaluated by two
    /// operators is shown under the first).
    shown: []bool = &.{},
    output: std.ArrayList(Line) = .empty,

    /// The lines of a chain, its last operator first, under line `parent`.
    fn chain(self: *Explainer, chain_index: Plan.ChainIndex, depth: u32, parent: ?usize) Allocator.Error!void {
        const range = self.plan.chains[chain_index];
        var index = range.end;
        var consumer = parent;
        while (index > range.first) {
            index -= 1;
            const operator = self.plan.operators[index];
            if (operator == .output) continue;
            const line = self.output.items.len;
            try self.output.append(self.allocator, .{
                .depth = depth,
                .parent = consumer,
                .operator = index,
                .name = self.name(index, operator),
                .details = try self.details(operator),
                .estimated_rows = self.estimates[index],
            });
            switch (operator) {
                .optional => |optional| try self.chain(optional.chain, depth + 1, line),
                .call_subquery => |call| try self.chain(call.chain, depth + 1, line),
                .merge => |merge| try self.chain(merge.chain, depth + 1, line),
                .foreach => |foreach| try self.chain(foreach.chain, depth + 1, line),
                else => {},
            }
            for (try self.evaluated(operator)) |root| try self.expressionChains(root, depth + 1, line);
            consumer = line;
        }
    }

    /// The chains of the patterns and subqueries inside `node`, each under a
    /// line naming its expression.
    fn expressionChains(self: *Explainer, node: Index, depth: u32, parent: usize) Allocator.Error!void {
        if (self.plan.expression_chains.get(node)) |chain_index| {
            if (self.shown[chain_index]) return;
            self.shown[chain_index] = true;
            const expression_name = switch (self.ast.kind(node)) {
                .pattern_predicate => "PatternPredicate",
                .pattern_comprehension => "PatternComprehension",
                .exists_subquery => "Exists",
                else => "Count",
            };
            const line = self.output.items.len;
            try self.output.append(self.allocator, .{ .depth = depth, .parent = parent, .operator = null, .name = expression_name, .details = try printer.text(self.ast, self.allocator, node), .estimated_rows = null });
            return self.chain(chain_index, depth + 1, line);
        }
        for (self.ast.nodeChildren(node)) |child| try self.expressionChains(child, depth, parent);
    }

    /// The AST parts `operator` evaluates itself (not through a chain it runs).
    fn evaluated(self: *Explainer, operator: Operator) Allocator.Error![]const Index {
        const ast = self.ast;
        var roots = std.ArrayList(Index).empty;
        switch (operator) {
            .bound_node, .node_scan => |reference| try self.nodeValues(&roots, self.plan.patterns[reference.pattern].nodes[reference.node]),
            .edge_index_scan => |reference| {
                const pattern = self.plan.patterns[reference.pattern];
                for (pattern.edges[reference.edge].seeks) |seek| try roots.append(self.allocator, seek.value);
                try self.nodeValues(&roots, pattern.nodes[reference.edge]);
                try self.nodeValues(&roots, pattern.nodes[reference.edge + 1]);
            },
            .expand => |expand| {
                const pattern = self.plan.patterns[expand.pattern];
                for (pattern.edges[@min(expand.from, expand.to)].seeks) |seek| try roots.append(self.allocator, seek.value);
                try self.nodeValues(&roots, pattern.nodes[expand.to]);
            },
            .filter => |filter| try roots.append(self.allocator, filter.predicate),
            .unwind, .load_csv, .with_streaming, .with_collecting, .return_, .write => |clause| try roots.appendSlice(self.allocator, ast.nodeChildren(clause)),
            .procedure_call => |call| try roots.appendSlice(self.allocator, ast.nodeChildren(call.clause)),
            .merge => |merge| try roots.appendSlice(self.allocator, ast.nodeChildren(merge.clause)),
            .foreach => |foreach| try roots.append(self.allocator, ast.nodeChildren(foreach.clause)[0]),
            else => {},
        }
        return roots.items;
    }

    fn nodeValues(self: *Explainer, roots: *std.ArrayList(Index), node: Plan.PatternNode) Allocator.Error!void {
        for (node.seeks) |seek| try roots.append(self.allocator, seek.value);
        for (node.ranges) |range| {
            if (range.lower) |lower| try roots.append(self.allocator, lower);
            if (range.upper) |upper| try roots.append(self.allocator, upper);
        }
    }

    fn name(self: *Explainer, index: OperatorIndex, operator: Operator) []const u8 {
        return switch (operator) {
            .bound_node => "BoundNode",
            .node_scan => |reference| scan: {
                const node = self.plan.patterns[reference.pattern].nodes[reference.node];
                if (node.seeks.len > 0 and self.plan.index_lookups) break :scan "NodeIndexSeek";
                if (node.ranges.len > 0 and self.plan.index_lookups) break :scan "NodeIndexRangeSeek";
                if (node.labels.len > 0) break :scan "NodeByLabelScan";
                break :scan "AllNodesScan";
            },
            .edge_index_scan => "RelationshipIndexSeek",
            .expand => |expand| expand_name: {
                const pattern = self.plan.patterns[expand.pattern];
                const edge = pattern.edges[@min(expand.from, expand.to)];
                const into = pattern.nodes[expand.to].bound;
                if (edge.shortest == .one) break :expand_name "ShortestPath";
                if (edge.shortest == .all) break :expand_name "AllShortestPaths";
                if (edge.variable_length) break :expand_name if (into) "VarLengthExpand(Into)" else "VarLengthExpand(All)";
                break :expand_name if (into) "Expand(Into)" else "Expand(All)";
            },
            .project_path => "ProjectPath",
            .filter => "Filter",
            .optional => "Optional",
            .unwind => "Unwind",
            .load_csv => "LoadCSV",
            .procedure_call => "ProcedureCall",
            .call_subquery => "Apply",
            .with_streaming => "Projection",
            .with_collecting => |clause| if (containsAggregates(self.ast, clause)) "Aggregation" else "Projection",
            .return_ => |clause| if (!self.hasStages(index)) "Return" else if (containsAggregates(self.ast, clause)) "Aggregation" else "Projection",
            .projection_stage => |stage| switch (stage.kind) {
                .distinct => "Distinct",
                .sort => "Sort",
                .top => "Top",
                .skip => "Skip",
                .limit => "Limit",
            },
            .produce_results => "Return",
            .eager => "Eager",
            .write => |clause| switch (self.ast.kind(clause)) {
                .create_clause => "Create",
                .set_clause => "Set",
                .delete_clause => if (self.ast.data(clause).delete.detach) "DetachDelete" else "Delete",
                else => "Remove",
            },
            .merge => "Merge",
            .foreach => "Foreach",
            .output => "Output",
            .discard => "EmptyResult",
        };
    }

    /// Whether stages (or the end of a RETURN) follow operator `index`.
    fn hasStages(self: *Explainer, index: OperatorIndex) bool {
        if (index + 1 >= self.plan.operators.len) return false;
        return switch (self.plan.operators[index + 1]) {
            .projection_stage, .produce_results => true,
            else => false,
        };
    }

    fn details(self: *Explainer, operator: Operator) Allocator.Error![]const u8 {
        const ast = self.ast;
        var text = Printer{ .ast = ast, .allocator = self.allocator };
        switch (operator) {
            .bound_node => |reference| try nodeText(&text, self.plan.patterns[reference.pattern].nodes[reference.node]),
            .node_scan => |reference| try scanDetails(&text, self.plan.patterns[reference.pattern].nodes[reference.node]),
            .edge_index_scan => |reference| try stepDetails(&text, self.plan.patterns[reference.pattern], reference.edge, reference.edge + 1),
            .expand => |expand| try stepDetails(&text, self.plan.patterns[expand.pattern], expand.from, expand.to),
            .project_path => |pattern| try text.name(self.plan.patterns[pattern].path_variable),
            .filter => |filter| try text.write(filter.predicate),
            .optional => |optional| {
                const children = ast.nodeChildren(optional.clause);
                try text.list(children[0 .. children.len - 1], ", ");
            },
            .unwind => |clause| {
                try text.write(ast.nodeChildren(clause)[0]);
                try text.append(" AS ");
                try text.name(ast.data(clause).unwind.variable_name);
            },
            .load_csv => |clause| {
                const load = ast.data(clause).load_csv;
                if (load.with_headers) try text.append("WITH HEADERS ");
                try text.append("FROM ");
                try text.write(ast.nodeChildren(clause)[0]);
                try text.append(" AS ");
                try text.name(load.variable_name);
            },
            .procedure_call => |call| {
                const data = ast.data(call.clause).call;
                const children = ast.nodeChildren(call.clause);
                try text.append(data.procedure);
                try text.append("(");
                try text.list(children[0..data.argument_count], ", ");
                try text.append(")");
                const yields = children[data.argument_count .. children.len - 1];
                for (yields, 0..) |item, position| {
                    try text.append(if (position == 0) " YIELD " else ", ");
                    const yielded = ast.data(item).yield_;
                    try text.name(yielded.column);
                    if (yielded.alias.len > 0) {
                        try text.append(" AS ");
                        try text.name(yielded.alias);
                    }
                }
            },
            .call_subquery => try text.append("CALL {…}"),
            .with_streaming, .with_collecting, .return_, .produce_results => |clause| try projectionDetails(&text, clause),
            .projection_stage => |stage| try stageDetails(&text, stage),
            .write => |clause| try text.list(ast.nodeChildren(clause), ", "),
            .merge => |merge| try text.write(ast.nodeChildren(merge.clause)[0]),
            .foreach => |foreach| {
                try text.name(ast.data(foreach.clause).text);
                try text.append(" IN ");
                try text.write(ast.nodeChildren(foreach.clause)[0]);
            },
            .eager, .output, .discard => {},
        }
        return text.output.items;
    }

    fn estimateChain(self: *Explainer, chain_index: Plan.ChainIndex) Allocator.Error!void {
        const range = self.plan.chains[chain_index];
        var rows: ?f64 = 1;
        for (range.first..range.end) |index| {
            rows = try self.estimate(self.plan.operators[index], rows);
            self.estimates[index] = rows;
        }
    }

    /// The rows of the chain's last operator, per run of the chain.
    fn chainRows(self: *Explainer, chain_index: Plan.ChainIndex) ?f64 {
        const range = self.plan.chains[chain_index];
        return if (range.end > range.first) self.estimates[range.end - 1] else 1;
    }

    fn estimate(self: *Explainer, operator: Operator, input: ?f64) Allocator.Error!?f64 {
        const ast = self.ast;
        return switch (operator) {
            .node_scan => |reference| times(input, try self.anchorRows(self.plan.patterns[reference.pattern].nodes[reference.node])),
            .expand => |expand| times(input, try self.degree(self.plan.patterns[expand.pattern], expand.from, expand.to)),
            .optional => |optional| if (times(input, self.chainRows(optional.chain))) |rows| @max(rows, input orelse rows) else input,
            .unwind => |clause| unwind: {
                const list = ast.nodeChildren(clause)[0];
                if (ast.kind(list) != .list_literal) break :unwind null;
                break :unwind times(input, @floatFromInt(ast.nodeChildren(list).len));
            },
            .load_csv, .procedure_call => null,
            .call_subquery => |call| if (call.returns) times(input, self.chainRows(call.chain)) else input,
            .with_collecting, .return_ => |clause| if (containsAggregates(ast, clause)) groupRows(ast, clause) else input,
            .projection_stage => |stage| stageRows(ast, stage, input),
            else => input,
        };
    }

    /// How many candidates the anchor scan of `node` gives.
    fn anchorRows(self: *Explainer, node: Plan.PatternNode) Allocator.Error!?f64 {
        if (node.seeks.len > 0) return 1;
        var smallest: ?f64 = null;
        for (node.labels) |label| {
            const count = try self.statistics.labelCount(label);
            if (count == unknown) continue;
            const rows: f64 = @floatFromInt(count);
            smallest = if (smallest) |known| @min(known, rows) else rows;
        }
        if (node.ranges.len > 0) if (smallest) |rows| return rows / 4;
        return smallest;
    }

    /// How many neighbours an expansion reaches from one node: the
    /// relationships of its type per node of the start's label.
    fn degree(self: *Explainer, pattern: Plan.PatternPlan, from: usize, to: usize) Allocator.Error!?f64 {
        const edge = pattern.edges[@min(from, to)];
        if (edge.variable_length) return if (edge.shortest != .none) 1 else null;
        const edge_type = edge.singleType() orelse return null;
        const relationships = try self.statistics.edgeTypeCount(edge_type);
        if (relationships == unknown) return null;
        const start = pattern.nodes[from];
        if (start.labels.len == 0) return null;
        const nodes = try self.statistics.labelCount(start.labels[0]);
        if (nodes == unknown or nodes == 0) return null;
        var per_node = @as(f64, @floatFromInt(relationships)) / @as(f64, @floatFromInt(nodes));
        if (edge.undirected) per_node *= 2;
        // Into a node bound already: at most the relationships to it.
        if (pattern.nodes[to].bound or pattern.nodes[to].seeks.len > 0) per_node = @min(per_node, 1);
        return per_node;
    }

};

/// Whether a WITH's or RETURN's items aggregate.
fn containsAggregates(ast: *const Ast, clause: Index) bool {
    for (ast.nodeChildren(ast.nodeChildren(clause)[0])) |item| {
        if (containsAggregate(ast, ast.nodeChildren(item)[0])) return true;
    }
    return false;
}

/// The groups of an aggregation: one without grouping keys, else unknown.
fn groupRows(ast: *const Ast, clause: Index) ?f64 {
    for (ast.nodeChildren(ast.nodeChildren(clause)[0])) |item| {
        if (!containsAggregate(ast, ast.nodeChildren(item)[0])) return null;
    }
    return 1;
}

/// The rows a stage keeps of `input`: at most its LIMIT (SKIP + LIMIT for
/// `top`), fewer by its SKIP. DISTINCT is not assumed to drop any.
fn stageRows(ast: *const Ast, stage: Plan.ProjectionStage, input: ?f64) ?f64 {
    const parts = clauseParts(ast, stage.clause);
    const kept: ?f64 = switch (stage.kind) {
        .distinct, .sort => return input,
        .top => top: {
            const limit = literalCount(ast, parts.limit.?) orelse break :top null;
            const skipped = if (parts.skip) |skip| literalCount(ast, skip) orelse break :top null else 0;
            break :top skipped + limit;
        },
        .limit => literalCount(ast, parts.limit.?),
        .skip => {
            const skipped = literalCount(ast, parts.skip.?) orelse return input;
            return if (input) |known| @max(known - skipped, 0) else null;
        },
    };
    const limit = kept orelse return input;
    return if (input) |known| @min(known, limit) else limit;
}

const ClauseParts = struct { order_by: ?Index = null, skip: ?Index = null, limit: ?Index = null };

fn clauseParts(ast: *const Ast, clause: Index) ClauseParts {
    var parts = ClauseParts{};
    for (ast.nodeChildren(clause)[1..]) |child| switch (ast.kind(child)) {
        .order_by => parts.order_by = child,
        .skip => parts.skip = child,
        .limit => parts.limit = child,
        else => {},
    };
    return parts;
}

fn times(a: ?f64, b: ?f64) ?f64 {
    return (a orelse return null) * (b orelse return null);
}

/// The value of a SKIP or LIMIT written as an integer.
fn literalCount(ast: *const Ast, clause_part: Index) ?f64 {
    const value = ast.nodeChildren(clause_part)[0];
    if (ast.kind(value) != .integer_literal) return null;
    return @floatFromInt(@max(ast.data(value).int, 0));
}

/// `(a:L {k: v})`, with the property ranges the scan reads, if it reads
/// them (it seeks an equality first).
fn scanDetails(text: *Printer, node: Plan.PatternNode) Allocator.Error!void {
    try nodeText(text, node);
    if (node.seeks.len > 0) return;
    for (node.ranges, 0..) |range, range_position| {
        try text.append(if (range_position == 0) " WHERE " else " AND ");
        if (range.lower) |lower| {
            try text.write(lower);
            try text.append(" <= ");
        }
        try text.name(node.variable_name);
        try text.append(".");
        try text.name(range.property);
        if (range.upper) |upper| {
            try text.append(" <= ");
            try text.write(upper);
        }
    }
}

/// `(a)-[r:T]->(b)`, the step from pattern position `from` to `to`.
fn stepDetails(text: *Printer, pattern: Plan.PatternPlan, from: usize, to: usize) Allocator.Error!void {
    const edge = pattern.edges[@min(from, to)];
    try nodeText(text, pattern.nodes[from]);
    const points_right = !edge.undirected and ((from < to) == (edge.forward_direction == .out));
    const points_left = !edge.undirected and !points_right;
    try text.append(if (points_left) "<-[" else "-[");
    try text.name(edge.variable_name);
    for (edge.edge_types, 0..) |edge_type, position| {
        try text.append(if (position == 0) ":" else "|");
        try text.name(edge_type);
    }
    if (edge.variable_length) try text.hops(edge.min_hops, edge.max_hops);
    for (edge.seeks, 0..) |seek, position| {
        try text.append(if (position == 0) " {" else ", ");
        try text.name(seek.property);
        try text.append(": ");
        try text.write(seek.value);
    }
    if (edge.seeks.len > 0) try text.append("}");
    try text.append(if (points_right) "]->" else "]-");
    try nodeText(text, pattern.nodes[to]);
}

/// `(a:L {k: v})` for a planned node.
fn nodeText(text: *Printer, node: Plan.PatternNode) Allocator.Error!void {
    try text.append("(");
    try text.name(node.variable_name);
    for (node.labels) |label| {
        try text.append(":");
        try text.name(label);
    }
    for (node.seeks, 0..) |seek, position| {
        try text.append(if (position == 0) " {" else ", ");
        try text.name(seek.property);
        try text.append(": ");
        try text.write(seek.value);
    }
    if (node.seeks.len > 0) try text.append("}");
    try text.append(")");
}

/// `a, count(*) AS n WHERE n > 1`: the projection and a WITH's WHERE (its
/// DISTINCT, ORDER BY, SKIP and LIMIT are stages of their own).
fn projectionDetails(text: *Printer, clause: Index) Allocator.Error!void {
    const ast = text.ast;
    const children = ast.nodeChildren(clause);
    try text.write(children[0]);
    for (children[1..]) |child| switch (ast.kind(child)) {
        .order_by, .skip, .limit => {},
        .boolean_literal => if (!ast.data(child).boolean) try text.append(" WHERE false"),
        else => {
            // A WITH's WHERE (always its last child).
            try text.append(" WHERE ");
            try text.write(child);
        },
    };
}

/// `p.name, n` (DISTINCT: what rows are distinct by), `ORDER BY n DESC`,
/// `ORDER BY n DESC LIMIT 1 + 3` (`top`: SKIP + LIMIT rows), `SKIP 1`,
/// `LIMIT 3`.
fn stageDetails(text: *Printer, stage: Plan.ProjectionStage) Allocator.Error!void {
    const ast = text.ast;
    const parts = clauseParts(ast, stage.clause);
    switch (stage.kind) {
        .distinct => try text.write(ast.nodeChildren(stage.clause)[0]),
        .sort => try text.write(parts.order_by.?),
        .top => {
            try text.write(parts.order_by.?);
            try text.append(" LIMIT ");
            if (parts.skip) |skip| {
                try text.write(ast.nodeChildren(skip)[0]);
                try text.append(" + ");
            }
            try text.write(ast.nodeChildren(parts.limit.?)[0]);
        },
        .skip => try text.write(parts.skip.?),
        .limit => try text.write(parts.limit.?),
    }
}
