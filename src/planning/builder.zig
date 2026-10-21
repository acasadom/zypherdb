//! Builds the plan of a checked query (see `Plan.zig`): each clause becomes
//! one or more operators of its query's chain, in order.
//!
//! - MATCH: per pattern, the operators of its plan (`patterns.zig`), then a
//!   filter for the WHERE;
//! - OPTIONAL MATCH, `CALL { }`, MERGE, FOREACH: an operator that runs a
//!   chain of its own for each row;
//! - UNWIND, LOAD CSV, CALL, WITH, RETURN and the writing clauses: one
//!   operator each;
//! - a query that writes gets an `eager` between its clauses, so each clause
//!   sees the effect of the one before it on every row;
//! - a pattern or subquery inside an expression gets a chain too, found by
//!   the expression's AST node (`Plan.expression_chains`).
//!
//! The planner follows the variables in scope (`scope.zig`): a pattern node
//! bound before its pattern is checked, not scanned.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const isSubquery = @import("../query/ast.zig").isSubquery;

const Plan = @import("Plan.zig");
const Operator = Plan.Operator;
const ChainIndex = Plan.ChainIndex;
const Scope = @import("scope.zig").Scope;
const patterns = @import("patterns.zig");

pub const Context = patterns.Context;

/// The plan of `root`: a query, or a UNION of queries.
pub fn build(context: Context, root: Index) Allocator.Error!Plan {
    var builder = Builder{ .context = context };
    const ast = context.ast;
    const queries: []const Index = if (ast.kind(root) == .union_query) ast.nodeChildren(root) else &.{root};
    const main_chains = try context.allocator.alloc(ChainIndex, queries.len);
    for (main_chains, queries) |*chain, query| chain.* = try builder.buildChain(query, .{}, .main);
    return .{
        .operators = builder.operators.items,
        .chains = builder.chains.items,
        .patterns = builder.patterns.items,
        .main_chains = main_chains,
        .expression_chains = builder.expression_chains,
        .node_count = builder.node_count,
        .edge_count = builder.edge_count,
    };
}

/// A main chain runs a query and ends with its RETURN (or nothing); an inner
/// one hands its rows back through `output`.
const ChainKind = enum { main, inner };

const Builder = struct {
    context: Context,
    operators: std.ArrayList(Operator) = .empty,
    chains: std.ArrayList(Plan.Chain) = .empty,
    patterns: std.ArrayList(Plan.PatternPlan) = .empty,
    expression_chains: std.AutoHashMapUnmanaged(Index, ChainIndex) = .empty,
    match_count: u32 = 0,
    node_count: u32 = 0,
    edge_count: u32 = 0,

    /// The chain of the clauses of `query`, from the variables in `scope`.
    fn buildChain(self: *Builder, query: Index, initial_scope: Scope, kind: ChainKind) Allocator.Error!ChainIndex {
        const ast = self.context.ast;
        var scope = initial_scope;
        var operators = std.ArrayList(Operator).empty;
        const writes = ast.queryWrites(query);
        const clauses = ast.nodeChildren(query);
        for (clauses, 0..) |clause, position| {
            if (writes and position > 0) try operators.append(self.context.allocator, .eager);
            try self.planClause(clause, &scope, &operators, kind, position + 1 == clauses.len);
        }
        return self.finish(&operators, kind);
    }

    /// Adds the operators of a chain being built to the plan, after the
    /// chains they run, and returns its index.
    fn finish(self: *Builder, operators: *std.ArrayList(Operator), kind: ChainKind) Allocator.Error!ChainIndex {
        const allocator = self.context.allocator;
        const index: ChainIndex = @intCast(self.chains.items.len);
        switch (kind) {
            .inner => try operators.append(allocator, .{ .output = index }),
            .main => {
                const items = operators.items;
                if (items.len == 0 or items[items.len - 1] != .return_) try operators.append(allocator, .discard);
            },
        }
        const first: Plan.OperatorIndex = @intCast(self.operators.items.len);
        try self.operators.appendSlice(allocator, operators.items);
        try self.chains.append(allocator, .{ .first = first, .end = @intCast(self.operators.items.len) });
        return index;
    }

    fn planClause(self: *Builder, clause_index: Index, scope: *Scope, operators: *std.ArrayList(Operator), kind: ChainKind, last: bool) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        switch (ast.kind(clause_index)) {
            .match_clause => try self.planMatch(clause_index, scope, operators),
            .optional_match_clause => {
                const inner = try self.matchChain(clause_index, try scope.clone(allocator));
                try operators.append(allocator, .{ .optional = .{ .clause = clause_index, .chain = inner } });
                try addPatternVariables(ast, allocator, matchPatterns(ast, clause_index), scope);
            },
            .unwind_clause => {
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .unwind = clause_index });
                try scope.add(allocator, ast.data(clause_index).unwind.variable_name);
            },
            .load_csv_clause => {
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .load_csv = clause_index });
                try scope.add(allocator, ast.data(clause_index).load_csv.variable_name);
            },
            .with_clause => try self.planProjection(clause_index, scope, operators),
            .return_clause => if (kind == .main) {
                try self.projectionExpressions(clause_index, scope);
                try operators.append(allocator, .{ .return_ = clause_index });
            } else try self.planProjection(clause_index, scope, operators),
            .call_clause => {
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .procedure_call = .{ .clause = clause_index, .ends_query = kind == .main and last } });
                for (ast.nodeChildren(clause_index)) |child| {
                    if (ast.kind(child) != .yield_item) continue;
                    const yielded = ast.data(child).yield_;
                    try scope.add(allocator, if (yielded.alias.len > 0) yielded.alias else yielded.column);
                }
            },
            .call_subquery => try self.planCallSubquery(clause_index, scope, operators),
            .merge_clause => {
                const children = ast.nodeChildren(clause_index);
                const inner = try self.patternChain(children[0..1], null, try scope.clone(allocator));
                try operators.append(allocator, .{ .merge = .{ .clause = clause_index, .chain = inner } });
                try addPatternVariables(ast, allocator, children[0..1], scope);
                for (children[1..]) |set_clause| try self.planExpressions(set_clause, scope);
            },
            .foreach_clause => {
                const children = ast.nodeChildren(clause_index);
                try self.planExpressions(children[0], scope);
                var inner_scope = try scope.clone(allocator);
                try inner_scope.add(allocator, ast.data(clause_index).text);
                const inner = try self.buildChain(children[1], inner_scope, .inner);
                try operators.append(allocator, .{ .foreach = .{ .clause = clause_index, .chain = inner } });
            },
            .create_clause => {
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .write = clause_index });
                try addPatternVariables(ast, allocator, ast.nodeChildren(clause_index), scope);
            },
            else => { // SET, DELETE, REMOVE
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .write = clause_index });
            },
        }
    }

    /// MATCH: each pattern's operators, then the WHERE.
    fn planMatch(self: *Builder, clause_index: Index, scope: *Scope, operators: *std.ArrayList(Operator)) Allocator.Error!void {
        const ast = self.context.ast;
        const children = ast.nodeChildren(clause_index);
        try self.patternOperators(matchPatterns(ast, clause_index), whereOf(ast, children[children.len - 1]), scope, operators);
    }

    /// The operators of `pattern_list` (one MATCH), whose WHERE is `where`
    /// (null: none), bound from `scope`, which gains their variables.
    fn patternOperators(self: *Builder, pattern_list: []const Index, where: ?Index, scope: *Scope, operators: *std.ArrayList(Operator)) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const match_index = self.match_count;
        self.match_count += 1;
        for (pattern_list) |pattern| {
            // Its properties are read before its own variables are bound.
            try self.planExpressions(pattern, scope);
            const placement = patterns.Placement{
                .index = @intCast(self.patterns.items.len),
                .match = match_index,
                .first_node = self.node_count,
                .first_edge = self.edge_count,
            };
            const pattern_plan = try patterns.plan(self.context, pattern, where, scope, placement, operators);
            self.node_count += @intCast(pattern_plan.nodes.len);
            self.edge_count += @intCast(pattern_plan.edges.len);
            try self.patterns.append(allocator, pattern_plan);
            try addPatternVariables(ast, allocator, &.{pattern}, scope);
        }
        if (where) |predicate| {
            try self.planExpressions(predicate, scope);
            try operators.append(allocator, .{ .filter = .{ .predicate = predicate, .counts_accepted = true } });
        }
    }

    /// The chain of an OPTIONAL MATCH: its patterns and WHERE, run from a row.
    fn matchChain(self: *Builder, clause_index: Index, scope: Scope) Allocator.Error!ChainIndex {
        const ast = self.context.ast;
        const children = ast.nodeChildren(clause_index);
        return self.patternChain(matchPatterns(ast, clause_index), whereOf(ast, children[children.len - 1]), scope);
    }

    fn patternChain(self: *Builder, pattern_list: []const Index, where: ?Index, initial_scope: Scope) Allocator.Error!ChainIndex {
        var scope = initial_scope;
        var operators = std.ArrayList(Operator).empty;
        try self.patternOperators(pattern_list, where, &scope, &operators);
        return self.finish(&operators, .inner);
    }

    /// A WITH, or the RETURN of a subquery (which makes rows as a WITH does):
    /// one operator, and the scope becomes the projected names.
    fn planProjection(self: *Builder, clause_index: Index, scope: *Scope, operators: *std.ArrayList(Operator)) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        try self.projectionExpressions(clause_index, scope);
        const operator: Operator = if (projectionStreams(ast, clause_index)) .{ .with_streaming = clause_index } else .{ .with_collecting = clause_index };
        try operators.append(allocator, operator);
        scope.* = .{};
        for (ast.nodeChildren(ast.nodeChildren(clause_index)[0])) |item| try scope.add(allocator, projectedName(ast, item));
    }

    /// Plans the expressions of a WITH or RETURN. The projection sees the
    /// variables before it; ORDER BY and WHERE also see the projected names,
    /// and, unless the projection aggregates, the variables before it.
    fn projectionExpressions(self: *Builder, clause_index: Index, scope: *const Scope) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const children = ast.nodeChildren(clause_index);
        const items = ast.nodeChildren(children[0]);
        var aggregates = false;
        for (items) |item| {
            try self.planExpressions(item, scope);
            if (containsAggregate(ast, ast.nodeChildren(item)[0])) aggregates = true;
        }
        var after = if (aggregates) Scope{} else try scope.clone(allocator);
        for (items) |item| try after.add(allocator, projectedName(ast, item));
        for (children[1..]) |child| try self.planExpressions(child, &after);
    }

    fn planCallSubquery(self: *Builder, clause_index: Index, scope: *Scope, operators: *std.ArrayList(Operator)) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const query = ast.nodeChildren(clause_index)[0];
        const body = ast.nodeChildren(query);
        const imports = ast.importsVariables(query);
        const returns = ast.kind(body[body.len - 1]) == .return_clause;
        const inner = try self.buildChain(query, if (imports) try scope.clone(allocator) else .{}, .inner);
        try operators.append(allocator, .{ .call_subquery = .{ .clause = clause_index, .chain = inner, .imports = imports, .returns = returns } });
        if (returns) {
            for (ast.nodeChildren(ast.nodeChildren(body[body.len - 1])[0])) |item| try scope.add(allocator, projectedName(ast, item));
        }
    }

    /// Plans the patterns and subqueries inside the expressions under `node`,
    /// with `scope` the variables bound where they are evaluated.
    fn planExpressions(self: *Builder, node: Index, scope: *const Scope) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const children = ast.nodeChildren(node);
        switch (ast.kind(node)) {
            .pattern_predicate => {
                const inner = try self.patternChain(children[0..1], whereOf(ast, children[1]), try scope.clone(allocator));
                try self.expression_chains.put(allocator, node, inner);
            },
            .pattern_comprehension => {
                const inner = try self.patternChain(children[0..1], whereOf(ast, children[1]), try scope.clone(allocator));
                try self.expression_chains.put(allocator, node, inner);
                var inside = try scope.clone(allocator);
                try addPatternVariables(ast, allocator, children[0..1], &inside);
                try self.planExpressions(children[2], &inside);
            },
            .exists_subquery, .count_subquery => {
                const inner = try self.buildChain(children[0], try scope.clone(allocator), .inner);
                try self.expression_chains.put(allocator, node, inner);
            },
            .list_comprehension, .quantifier => {
                try self.planExpressions(children[0], scope);
                var inside = try scope.clone(allocator);
                try inside.add(allocator, if (ast.kind(node) == .quantifier) ast.data(node).quantifier.variable_name else ast.data(node).text);
                for (children[1..]) |child| try self.planExpressions(child, &inside);
            },
            else => for (children) |child| try self.planExpressions(child, scope),
        }
    }
};

/// The patterns of a MATCH or OPTIONAL MATCH (its last child is the WHERE).
fn matchPatterns(ast: *const Ast, clause_index: Index) []const Index {
    const children = ast.nodeChildren(clause_index);
    return children[0 .. children.len - 1];
}

/// A WHERE, or null when it is the `true` of a clause without one.
fn whereOf(ast: *const Ast, where: Index) ?Index {
    if (ast.kind(where) == .boolean_literal and ast.data(where).boolean) return null;
    return where;
}

/// Adds the variables of `pattern_list` (path, node and edge variables) to `scope`.
fn addPatternVariables(ast: *const Ast, allocator: Allocator, pattern_list: []const Index, scope: *Scope) Allocator.Error!void {
    for (pattern_list) |pattern| {
        try scope.add(allocator, ast.data(pattern).text);
        for (ast.nodeChildren(pattern)) |element| switch (ast.kind(element)) {
            .node_pattern => try scope.add(allocator, ast.data(element).node_pattern.variable_name),
            .edge_pattern => try scope.add(allocator, ast.data(element).edge_pattern.variable_name),
            else => {},
        };
    }
}

/// The name a projection item binds: its alias, or the variable it projects.
fn projectedName(ast: *const Ast, item: Index) []const u8 {
    const alias = ast.data(item).text;
    if (alias.len > 0) return alias;
    const expression = ast.nodeChildren(item)[0];
    return if (ast.kind(expression) == .variable) ast.data(expression).text else "";
}

/// Whether a WITH (or a subquery's RETURN) can pass its rows on one at a
/// time: it neither groups, removes duplicates, sorts nor pages.
fn projectionStreams(ast: *const Ast, clause_index: Index) bool {
    const distinct = if (ast.kind(clause_index) == .return_clause) ast.data(clause_index).return_.distinct else ast.data(clause_index).with_.distinct;
    if (distinct) return false;
    const children = ast.nodeChildren(clause_index);
    for (children[1..]) |child| switch (ast.kind(child)) {
        .order_by, .skip, .limit => return false,
        else => {},
    };
    for (ast.nodeChildren(children[0])) |item| {
        if (containsAggregate(ast, ast.nodeChildren(item)[0])) return false;
    }
    return true;
}

/// True if `expression` contains an aggregate call (not one of a subquery's).
pub fn containsAggregate(ast: *const Ast, expression: Index) bool {
    if (ast.kind(expression) == .aggregate) return true;
    if (isSubquery(ast.kind(expression))) return false;
    for (ast.nodeChildren(expression)) |child| {
        if (containsAggregate(ast, child)) return true;
    }
    return false;
}
