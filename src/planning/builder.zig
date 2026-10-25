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
//! The planner follows the variables in scope (`scope.zig`) and gives each
//! a slot of the row (`Plan.slot_of`); a pattern node bound before its
//! pattern is checked, not scanned.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = @import("../query/ast.zig").Ast;
const Index = @import("../query/ast.zig").Index;
const isSubquery = @import("../query/ast.zig").isSubquery;

const Plan = @import("Plan.zig");
const ExpressionProgram = @import("expression_program.zig").Program;
const Operator = Plan.Operator;
const ChainIndex = Plan.ChainIndex;
const Scope = @import("scope.zig").Scope;
const Slot = @import("../execution/bindings.zig").Slot;
const no_slot = @import("../execution/bindings.zig").no_slot;
const patterns = @import("patterns.zig");

pub const Context = patterns.Context;
pub const Options = patterns.Options;

/// The plan of `root`: a query, or a UNION of queries.
pub fn build(context: Context, root: Index) Allocator.Error!Plan {
    const ast = context.ast;
    const slot_of = try context.allocator.alloc(Slot, ast.nodes.items.len);
    @memset(slot_of, no_slot);
    var builder = Builder{ .context = context, .slot_of = slot_of };
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
        .statistics = context.statistics.used.items,
        .slot_count = builder.slot_count,
        .slot_of = slot_of,
        .expressions = try ExpressionProgram.compile(context.allocator, ast, slot_of, &builder.expression_chains),
        .parameter_names = try ast.parameterNames(context.allocator, root),
        .index_lookups = context.options.index_lookups,
    };
}

/// A main chain runs a query and ends with its RETURN (or nothing); an inner
/// one hands its rows back through `output`.
const ChainKind = enum { main, inner };

/// What a projection's items bind: a WITH (and a subquery's RETURN, which
/// makes rows as a WITH does) binds every item in a new scope; the query's
/// RETURN binds its aliases, for its ORDER BY.
const ProjectionKind = enum { with, query_return };

const Builder = struct {
    context: Context,
    operators: std.ArrayList(Operator) = .empty,
    chains: std.ArrayList(Plan.Chain) = .empty,
    patterns: std.ArrayList(Plan.PatternPlan) = .empty,
    expression_chains: std.AutoHashMapUnmanaged(Index, ChainIndex) = .empty,
    match_count: u32 = 0,
    node_count: u32 = 0,
    edge_count: u32 = 0,
    slot_count: u32 = 0,
    slot_of: []Slot,

    /// A new slot for `name`, bound in `scope`, and recorded as `node`'s.
    fn declare(self: *Builder, scope: *Scope, name: []const u8, node: Index) Allocator.Error!Slot {
        const slot = self.slot_count;
        self.slot_count += 1;
        try scope.bind(self.context.allocator, name, slot);
        self.slot_of[node] = slot;
        return slot;
    }

    /// The slot of each variable of `pattern` (path, nodes, edges): the one
    /// in scope, or a new one. A path variable is always new.
    fn declarePattern(self: *Builder, pattern: Index, scope: *Scope) Allocator.Error!void {
        const ast = self.context.ast;
        const path_variable = ast.data(pattern).text;
        if (path_variable.len > 0) _ = try self.declare(scope, path_variable, pattern);
        for (ast.nodeChildren(pattern)) |element| {
            const name = switch (ast.kind(element)) {
                .node_pattern => ast.data(element).node_pattern.variable_name,
                .edge_pattern => ast.data(element).edge_pattern.variable_name,
                else => continue,
            };
            if (name.len == 0) continue;
            if (scope.slotOf(name)) |slot| {
                self.slot_of[element] = slot;
            } else _ = try self.declare(scope, name, element);
        }
    }

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
                const returns = items.len > 0 and (items[items.len - 1] == .return_ or items[items.len - 1] == .produce_results);
                if (!returns) try operators.append(allocator, .discard);
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
        const children = ast.nodeChildren(clause_index);
        switch (ast.kind(clause_index)) {
            .match_clause => try self.patternOperators(matchPatterns(ast, clause_index), whereOf(ast, children[children.len - 1]), scope, operators),
            .optional_match_clause => {
                // Its chain binds the clause's variables, in the slots the
                // rest of the query reads.
                var inner_scope = try scope.clone(allocator);
                const inner = try self.patternChain(matchPatterns(ast, clause_index), whereOf(ast, children[children.len - 1]), &inner_scope);
                try operators.append(allocator, .{ .optional = .{ .clause = clause_index, .chain = inner } });
                scope.* = inner_scope;
            },
            .unwind_clause => {
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .unwind = clause_index });
                _ = try self.declare(scope, ast.data(clause_index).unwind.variable_name, clause_index);
            },
            .load_csv_clause => {
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .load_csv = clause_index });
                _ = try self.declare(scope, ast.data(clause_index).load_csv.variable_name, clause_index);
            },
            .with_clause => try self.planProjection(clause_index, scope, operators),
            .return_clause => if (kind == .main) {
                _ = try self.projectionExpressions(clause_index, scope, .query_return);
                try operators.append(allocator, .{ .return_ = clause_index });
                const staged = try appendStages(allocator, ast, clause_index, self.context.options.top, operators);
                if (staged or projectionAggregates(ast, clause_index)) try operators.append(allocator, .{ .produce_results = clause_index });
            } else try self.planProjection(clause_index, scope, operators),
            .call_clause => {
                const call = ast.data(clause_index).call;
                for (children[0..call.argument_count]) |argument| try self.planExpressions(argument, scope);
                try operators.append(allocator, .{ .procedure_call = .{ .clause = clause_index, .ends_query = kind == .main and last } });
                for (children[call.argument_count .. children.len - 1]) |item| {
                    const yielded = ast.data(item).yield_;
                    _ = try self.declare(scope, if (yielded.alias.len > 0) yielded.alias else yielded.column, item);
                }
                try self.planExpressions(children[children.len - 1], scope);
            },
            .call_subquery => try self.planCallSubquery(clause_index, scope, operators),
            .merge_clause => {
                var inner_scope = try scope.clone(allocator);
                const inner = try self.patternChain(children[0..1], null, &inner_scope);
                try operators.append(allocator, .{ .merge = .{ .clause = clause_index, .chain = inner } });
                scope.* = inner_scope;
                for (children[1..]) |set_clause| try self.planExpressions(set_clause, scope);
            },
            .foreach_clause => {
                try self.planExpressions(children[0], scope);
                var inner_scope = try scope.clone(allocator);
                _ = try self.declare(&inner_scope, ast.data(clause_index).text, clause_index);
                const inner = try self.buildChain(children[1], inner_scope, .inner);
                try operators.append(allocator, .{ .foreach = .{ .clause = clause_index, .chain = inner } });
            },
            .create_clause => {
                // A pattern's properties may read what an earlier element of it created.
                for (children) |pattern| try self.declarePattern(pattern, scope);
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .write = clause_index });
            },
            else => { // SET, DELETE, REMOVE
                try self.planExpressions(clause_index, scope);
                try operators.append(allocator, .{ .write = clause_index });
            },
        }
    }

    /// The operators of `pattern_list` (one MATCH), whose WHERE is `where`
    /// (null: none), bound from `scope`, which gains their variables.
    fn patternOperators(self: *Builder, pattern_list: []const Index, where: ?Index, scope: *Scope, operators: *std.ArrayList(Operator)) Allocator.Error!void {
        const allocator = self.context.allocator;
        const match_index = self.match_count;
        self.match_count += 1;
        for (pattern_list) |pattern| {
            const before = try scope.clone(allocator);
            try self.declarePattern(pattern, scope);
            // Its properties may read its own earlier elements.
            try self.planExpressions(pattern, scope);
            const placement = patterns.Placement{
                .index = @intCast(self.patterns.items.len),
                .match = match_index,
                .first_node = self.node_count,
                .first_edge = self.edge_count,
            };
            const pattern_plan = try patterns.plan(self.context, pattern, where, &before, scope, placement, operators);
            self.node_count += @intCast(pattern_plan.nodes.len);
            self.edge_count += @intCast(pattern_plan.edges.len);
            try self.patterns.append(allocator, pattern_plan);
        }
        if (where) |predicate| {
            try self.planExpressions(predicate, scope);
            try operators.append(allocator, .{ .filter = .{ .predicate = predicate, .counts_accepted = true } });
        }
    }

    /// An inner chain of `pattern_list` and its WHERE, run from a row; `scope`
    /// gains the patterns' variables.
    fn patternChain(self: *Builder, pattern_list: []const Index, where: ?Index, scope: *Scope) Allocator.Error!ChainIndex {
        var operators = std.ArrayList(Operator).empty;
        try self.patternOperators(pattern_list, where, scope, &operators);
        return self.finish(&operators, .inner);
    }

    /// A WITH, or the RETURN of a subquery (which makes rows as a WITH does):
    /// one operator, and the scope becomes the projected names.
    fn planProjection(self: *Builder, clause_index: Index, scope: *Scope, operators: *std.ArrayList(Operator)) Allocator.Error!void {
        const ast = self.context.ast;
        const projected = try self.projectionExpressions(clause_index, scope, .with);
        if (projectionStreams(ast, clause_index)) {
            try operators.append(self.context.allocator, .{ .with_streaming = clause_index });
        } else {
            try operators.append(self.context.allocator, .{ .with_collecting = clause_index });
            _ = try appendStages(self.context.allocator, ast, clause_index, self.context.options.top, operators);
        }
        scope.* = projected;
    }

    /// Plans the expressions of a WITH or RETURN, gives its items their
    /// slots, and returns the scope of the projected names. The projection
    /// sees the variables before it; ORDER BY and WHERE also see the
    /// projected names, and, unless the projection aggregates, the
    /// variables before it.
    fn projectionExpressions(self: *Builder, clause_index: Index, scope: *const Scope, kind: ProjectionKind) Allocator.Error!Scope {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const children = ast.nodeChildren(clause_index);
        const items = ast.nodeChildren(children[0]);
        var aggregates = false;
        for (items) |item| {
            try self.planExpressions(item, scope);
            if (containsAggregate(ast, ast.nodeChildren(item)[0])) aggregates = true;
        }
        var projected = Scope{};
        for (items) |item| {
            const named = switch (kind) {
                .with => true,
                .query_return => ast.data(item).text.len > 0,
            };
            if (named) _ = try self.declare(&projected, projectedName(ast, item), item);
        }
        var after = if (aggregates) Scope{} else try scope.clone(allocator);
        var names = projected.names.iterator();
        while (names.next()) |entry| try after.bind(allocator, entry.key_ptr.*, entry.value_ptr.*);
        for (children[1..]) |child| try self.planExpressions(child, &after);
        return projected;
    }

    fn planCallSubquery(self: *Builder, clause_index: Index, scope: *Scope, operators: *std.ArrayList(Operator)) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const query = ast.nodeChildren(clause_index)[0];
        const body = ast.nodeChildren(query);
        const imports = ast.importsVariables(query);
        const returns = ast.kind(body[body.len - 1]) == .return_clause;
        const inner = try self.buildChain(query, if (imports) try scope.clone(allocator) else .{}, .inner);
        // The row takes the slots the subquery's RETURN binds.
        var returned_slots = std.ArrayList(Slot).empty;
        if (returns) {
            for (ast.nodeChildren(ast.nodeChildren(body[body.len - 1])[0])) |item| {
                const slot = self.slot_of[item];
                try returned_slots.append(allocator, slot);
                try scope.bind(allocator, projectedName(ast, item), slot);
            }
        }
        try operators.append(allocator, .{ .call_subquery = .{ .clause = clause_index, .chain = inner, .imports = imports, .returns = returns, .returned_slots = returned_slots.items } });
    }

    /// Resolves the variables under `node` to their slots, and plans the
    /// patterns and subqueries inside its expressions, with `scope` the
    /// variables bound where they are evaluated.
    fn planExpressions(self: *Builder, node: Index, scope: *const Scope) Allocator.Error!void {
        const ast = self.context.ast;
        const allocator = self.context.allocator;
        const children = ast.nodeChildren(node);
        switch (ast.kind(node)) {
            .variable => self.slot_of[node] = scope.slotOf(ast.data(node).text) orelse no_slot,
            .pattern_predicate => {
                var inside = try scope.clone(allocator);
                const inner = try self.patternChain(children[0..1], whereOf(ast, children[1]), &inside);
                try self.expression_chains.put(allocator, node, inner);
            },
            .pattern_comprehension => {
                var inside = try scope.clone(allocator);
                const inner = try self.patternChain(children[0..1], whereOf(ast, children[1]), &inside);
                try self.expression_chains.put(allocator, node, inner);
                try self.planExpressions(children[2], &inside);
            },
            .exists_subquery, .count_subquery => {
                const inner = try self.buildChain(children[0], try scope.clone(allocator), .inner);
                try self.expression_chains.put(allocator, node, inner);
            },
            .list_comprehension, .quantifier => {
                try self.planExpressions(children[0], scope);
                var inside = try scope.clone(allocator);
                _ = try self.declare(&inside, if (ast.kind(node) == .quantifier) ast.data(node).quantifier.variable_name else ast.data(node).text, node);
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
    const parts = projectionParts(ast, clause_index);
    return !parts.distinct and parts.order_by == null and parts.skip == null and parts.limit == null and !projectionAggregates(ast, clause_index);
}

/// Whether a WITH's or RETURN's items aggregate.
fn projectionAggregates(ast: *const Ast, clause_index: Index) bool {
    for (ast.nodeChildren(ast.nodeChildren(clause_index)[0])) |item| {
        if (containsAggregate(ast, ast.nodeChildren(item)[0])) return true;
    }
    return false;
}

const ProjectionParts = struct { distinct: bool, order_by: ?Index = null, skip: ?Index = null, limit: ?Index = null };

fn projectionParts(ast: *const Ast, clause_index: Index) ProjectionParts {
    var parts = ProjectionParts{ .distinct = if (ast.kind(clause_index) == .return_clause) ast.data(clause_index).return_.distinct else ast.data(clause_index).with_.distinct };
    for (ast.nodeChildren(clause_index)[1..]) |child| switch (ast.kind(child)) {
        .order_by => parts.order_by = child,
        .skip => parts.skip = child,
        .limit => parts.limit = child,
        else => {},
    };
    return parts;
}

/// Appends the stages of a WITH or RETURN, in the order they apply:
/// DISTINCT, ORDER BY (with a LIMIT and `use_top`, `top`), SKIP, then LIMIT
/// unless `top` kept SKIP + LIMIT rows already. True if there is one.
fn appendStages(allocator: Allocator, ast: *const Ast, clause_index: Index, use_top: bool, operators: *std.ArrayList(Operator)) Allocator.Error!bool {
    const parts = projectionParts(ast, clause_index);
    const top = use_top and parts.order_by != null and parts.limit != null;
    const count = operators.items.len;
    if (parts.distinct) try operators.append(allocator, .{ .projection_stage = .{ .clause = clause_index, .kind = .distinct } });
    if (parts.order_by != null) try operators.append(allocator, .{ .projection_stage = .{ .clause = clause_index, .kind = if (top) .top else .sort } });
    if (parts.skip != null) try operators.append(allocator, .{ .projection_stage = .{ .clause = clause_index, .kind = .skip } });
    if (parts.limit != null and !top) try operators.append(allocator, .{ .projection_stage = .{ .clause = clause_index, .kind = .limit } });
    return operators.items.len > count;
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
