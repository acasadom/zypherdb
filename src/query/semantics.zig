//! Static semantic checks on a parsed query, before it runs: how each
//! variable is used must agree with what it is. Checked per clause, in order,
//! tracking the kind of every variable in scope (WITH starts a new scope):
//!
//! - a relationship variable appears once per MATCH (openCypher's
//!   VariableAlreadyBound);
//! - a name is a node, a relationship or a value, never two of them
//!   (VariableTypeConflict), e.g. `(r)-[r]-()`, or `WITH 1 AS r MATCH ()-[r]-()`;
//! - a literal operand has a type its operator or function accepts: `1 IN true`,
//!   `123 AND true`, `NOT {}`, `properties(1)` fail (InvalidArgumentType). The
//!   variable of a comprehension or quantifier over a literal list whose
//!   elements share a type has that type: `any(x IN ['a'] WHERE x % 2 = 0)`
//!   fails;
//! - no aggregate inside a comprehension or quantifier.
//!
//! The checks do not depend on the data, so they fail on an empty graph too.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("ast.zig").Ast;
const Index = @import("ast.zig").Index;
const NodeKind = @import("ast.zig").NodeKind;
const BinaryOperator = @import("ast.zig").BinaryOperator;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;
const procedures = @import("procedures.zig");

pub const SemanticError = Allocator.Error || error{InvalidExpression};

/// `value` is something that is not an entity (a literal, arithmetic);
/// `any` is not known until the query runs (null, a function's result, a
/// list's element), so any use of it is accepted here.
const Kind = enum { node, relationship, path, value, any };

const Star = struct { projection: Index, names: []const []const u8 };

const Scope = struct {
    names: std.StringHashMapUnmanaged(Kind) = .empty,

    fn kindOf(self: *const Scope, name: []const u8) ?Kind {
        return self.names.get(name);
    }
};

/// An expression that can never be a node, relationship or path.
fn isPlainValue(ast: *const Ast, expression: Index) bool {
    return switch (ast.kind(expression)) {
        .integer_literal, .float_literal, .string_literal, .boolean_literal, .list_literal, .map_literal, .binary_operation, .unary_operation, .map_projection => true,
        else => false,
    };
}

/// What is known statically about an expression's type.
const StaticType = enum { number, string, boolean, list, map };

const Checker = struct {
    ast: *const Ast,
    allocator: Allocator,
    diagnostic: ?*Diagnostic,
    /// The procedures defined besides the built-in ones.
    table_procedures: []const procedures.TableProcedure = &.{},
    scope: Scope = .{},
    /// Comprehension and quantifier variables in scope with a known type.
    local_types: std.ArrayList(struct { name: []const u8, type: StaticType }) = .empty,
    /// The `*` projections met, each with the variables in scope there.
    stars: std.ArrayList(Star) = .empty,
    /// Nesting depth of comprehensions and quantifiers being checked.
    iteration_depth: usize = 0,
    /// Variables local to the expression being checked: of comprehensions,
    /// quantifiers, pattern comprehensions and EXISTS subqueries.
    local_names: std.ArrayList([]const u8) = .empty,

    fn fail(self: *Checker, comptime fmt: []const u8, args: anytype) SemanticError {
        if (self.diagnostic) |d| d.set(.invalid_expression, 0, fmt, args);
        return error.InvalidExpression;
    }

    /// Declares `name` as `kind`, or checks it against its existing kind.
    fn use(self: *Checker, name: []const u8, kind: Kind) SemanticError!void {
        if (name.len == 0) return;
        if (self.scope.kindOf(name)) |existing| {
            if (existing != kind and existing != .any) {
                return self.fail("variable '{s}' is a {s}; it cannot be used as a {s}", .{ name, @tagName(existing), @tagName(kind) });
            }
            return;
        }
        try self.scope.names.put(self.allocator, name, kind);
    }

    fn failUnknown(self: *Checker, name: []const u8) SemanticError {
        if (self.diagnostic) |d| d.set(.unknown_variable, 0, "unknown variable '{s}'", .{name});
        return error.InvalidExpression;
    }

    const PatternUse = enum { match, create, merge };

    /// Checks the patterns of one MATCH / OPTIONAL MATCH / CREATE / MERGE.
    /// A written pattern can only reuse a bound node as an endpoint, as it is
    /// (no new labels or properties), and cannot reuse a relationship.
    fn checkPatterns(self: *Checker, patterns: []const Index, pattern_use: PatternUse) SemanticError!void {
        const reading = pattern_use == .match;
        if (!reading) for (patterns) |pattern| try self.checkWrittenPattern(pattern, pattern_use);
        var relationships = std.StringHashMapUnmanaged(void).empty;
        defer relationships.deinit(self.allocator);
        for (patterns) |pattern| {
            // A path variable (`p = ...`) is new: it cannot rebind a name.
            const path_variable = self.ast.data(pattern).text;
            if (path_variable.len > 0) {
                if (self.scope.kindOf(path_variable) != null) return self.fail("path variable '{s}' is already bound", .{path_variable});
                try self.use(path_variable, .path);
            }
            for (self.ast.nodeChildren(pattern)) |element| {
                switch (self.ast.kind(element)) {
                    .node_pattern => try self.use(self.ast.data(element).node_pattern.variable_name, .node),
                    .edge_pattern => {
                        const edge = self.ast.data(element).edge_pattern;
                        const name = edge.variable_name;
                        if (name.len == 0) continue;
                        if (reading and (try relationships.fetchPut(self.allocator, name, {})) != null) {
                            return self.fail("relationship variable '{s}' is used twice in one pattern", .{name});
                        }
                        // A variable-length edge's variable is a list of relationships.
                        try self.use(name, if (edge.variable_length) .value else .relationship);
                    },
                    else => {},
                }
            }
        }
    }

    fn checkWrittenPattern(self: *Checker, pattern: Index, pattern_use: PatternUse) SemanticError!void {
        const verb = if (pattern_use == .merge) "MERGE" else "CREATE";
        const elements = self.ast.nodeChildren(pattern);
        for (elements) |element| switch (self.ast.kind(element)) {
            .node_pattern => {
                const node = self.ast.data(element).node_pattern;
                if (node.variable_name.len == 0 or self.scope.kindOf(node.variable_name) == null) continue;
                if (elements.len == 1) return self.fail("{s} of node '{s}', which is already bound", .{ verb, node.variable_name });
                if (node.labels.len > 0 or node.has_map) {
                    return self.fail("{s} cannot add labels or properties to '{s}', which is already bound", .{ verb, node.variable_name });
                }
            },
            .edge_pattern => {
                const edge = self.ast.data(element).edge_pattern;
                if (edge.variable_name.len > 0 and self.scope.kindOf(edge.variable_name) != null) {
                    return self.fail("{s} of relationship '{s}', which is already bound", .{ verb, edge.variable_name });
                }
                if (edge.edge_types.len != 1) return self.fail("{s} needs a relationship with exactly one type", .{verb});
            },
            else => {},
        };
    }

    /// WITH replaces the scope by its projected names: a projected variable
    /// keeps its kind, anything else is a value.
    /// True if `projection` starts with `*`.
    fn hasStar(self: *const Checker, projection: Index) bool {
        const data = self.ast.data(projection);
        return data == .boolean and data.boolean;
    }

    /// Records the variables a `*` projection stands for: those in scope,
    /// sorted (as Neo4j orders its columns).
    fn recordStar(self: *Checker, projection: Index, in_return: bool) SemanticError!void {
        if (!self.hasStar(projection)) return;
        var names = std.ArrayList([]const u8).empty;
        var iterator = self.scope.names.keyIterator();
        while (iterator.next()) |name| try names.append(self.allocator, name.*);
        if (names.items.len == 0 and in_return) return self.fail("RETURN * needs a variable in scope", .{});
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        try self.stars.append(self.allocator, .{ .projection = projection, .names = names.items });
    }

    fn projectScope(self: *Checker, projection: Index) SemanticError!void {
        var next = Scope{};
        // `WITH *` keeps every variable in scope.
        if (self.hasStar(projection)) {
            var entries = self.scope.names.iterator();
            while (entries.next()) |entry| try next.names.put(self.allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
        for (self.ast.nodeChildren(projection)) |item| {
            const expression = self.ast.nodeChildren(item)[0];
            const alias = self.ast.data(item).text;
            var kind: Kind = if (isPlainValue(self.ast, expression)) .value else .any;
            var name = alias;
            if (self.ast.kind(expression) == .variable) {
                const source = self.ast.data(expression).text;
                kind = self.scope.kindOf(source) orelse .any;
                if (name.len == 0) name = source;
            }
            if (name.len > 0) try next.names.put(self.allocator, name, kind);
        }
        self.scope.names.deinit(self.allocator);
        self.scope = next;
    }

    /// Checks the expressions under `index` against the variables in scope:
    /// literal argument types (`1 IN true`) and entity functions given a
    /// variable of the wrong kind (`type(n)` with `n` a node).
    fn checkExpressions(self: *Checker, index: Index) SemanticError!void {
        const children = self.ast.nodeChildren(index);
        switch (self.ast.kind(index)) {
            .list_comprehension, .quantifier => return self.checkIteration(index),
            .variable => {
                const name = self.ast.data(index).text;
                if (self.scope.kindOf(name) == null and !self.isLocal(name)) return self.failUnknown(name);
            },
            // A pattern predicate only tests variables already bound.
            .pattern_predicate => for (self.ast.nodeChildren(children[0])) |element| {
                const name = elementName(self.ast, element);
                if (name.len > 0 and self.scope.kindOf(name) == null and !self.isLocal(name)) {
                    return self.fail("variable '{s}' is not defined: a pattern in a predicate cannot introduce variables", .{name});
                }
            },
            .pattern_comprehension => return self.checkWithLocals(&.{children[0]}, children),
            .exists_subquery => {
                var patterns = std.ArrayList(Index).empty;
                defer patterns.deinit(self.allocator);
                for (children) |clause| {
                    const parts = self.ast.nodeChildren(clause);
                    try patterns.appendSlice(self.allocator, parts[0 .. parts.len - 1]);
                }
                return self.checkWithLocals(patterns.items, children);
            },
            .aggregate => {
                if (self.iteration_depth > 0) return self.fail("an aggregate cannot be used inside a list comprehension or quantifier", .{});
                // Aggregating values that change from call to call is meaningless.
                if (callsFunction(self.ast, index, "rand")) return self.fail("rand() cannot be used inside an aggregate", .{});
            },
            .binary_operation => switch (self.ast.data(index).binary_operator) {
                .add, .subtract, .multiply, .divide, .modulo, .power => |operator| try self.checkArithmetic(operator, children),
                .in_ => if (isLiteralOf(self.ast, children[1], &.{ .integer_literal, .float_literal, .string_literal, .boolean_literal, .map_literal })) {
                    return self.fail("the right side of IN must be a list", .{});
                },
                .and_, .or_, .xor => for (children) |operand| {
                    if (isLiteralOf(self.ast, operand, &non_boolean_literals)) return self.fail("AND and OR need boolean operands", .{});
                },
                else => {},
            },
            .unary_operation => if (self.ast.data(index).unary_operator == .not_ and isLiteralOf(self.ast, children[0], &non_boolean_literals)) {
                return self.fail("NOT needs a boolean operand", .{});
            },
            .property_access => if (self.ast.kind(children[0]) == .variable and self.scope.kindOf(self.ast.data(children[0]).text) == .path) {
                return self.fail("a path has no properties", .{});
            },
            .function_call => {
                try self.checkEntityArgument(index);
                if (std.ascii.eqlIgnoreCase(self.ast.data(index).text, "properties") and children.len == 1 and
                    isLiteralOf(self.ast, children[0], &.{ .integer_literal, .float_literal, .string_literal, .boolean_literal, .list_literal }))
                {
                    return self.fail("properties() takes a map, a node or a relationship", .{});
                }
            },
            else => {},
        }
        for (self.ast.nodeChildren(index)) |child| try self.checkExpressions(child);
    }

    fn isLocal(self: *const Checker, name: []const u8) bool {
        for (self.local_names.items) |local| {
            if (std.mem.eql(u8, local, name)) return true;
        }
        return false;
    }

    /// Checks `children` with the variables of `patterns` local to them.
    fn checkWithLocals(self: *Checker, patterns: []const Index, children: []const Index) SemanticError!void {
        const mark = self.local_names.items.len;
        defer self.local_names.shrinkRetainingCapacity(mark);
        for (patterns) |pattern| {
            if (self.ast.data(pattern).text.len > 0) try self.local_names.append(self.allocator, self.ast.data(pattern).text);
            for (self.ast.nodeChildren(pattern)) |element| {
                const name = elementName(self.ast, element);
                if (name.len > 0) try self.local_names.append(self.allocator, name);
            }
        }
        for (children) |child| try self.checkExpressions(child);
    }

    /// The variable of a node or relationship pattern (empty if anonymous).
    fn elementName(ast: *const Ast, element: Index) []const u8 {
        return switch (ast.kind(element)) {
            .node_pattern => ast.data(element).node_pattern.variable_name,
            .edge_pattern => ast.data(element).edge_pattern.variable_name,
            else => "",
        };
    }

    /// A comprehension or quantifier: its list in the enclosing scope, the
    /// rest with its variable typed when the list is a literal of one type.
    fn checkIteration(self: *Checker, index: Index) SemanticError!void {
        const children = self.ast.nodeChildren(index);
        try self.checkExpressions(children[0]);
        const variable_name = if (self.ast.kind(index) == .quantifier) self.ast.data(index).quantifier.variable_name else self.ast.data(index).text;
        const element_type = self.literalElementType(children[0]);
        if (element_type) |t| try self.local_types.append(self.allocator, .{ .name = variable_name, .type = t });
        defer if (element_type != null) {
            _ = self.local_types.pop();
        };
        self.iteration_depth += 1;
        defer self.iteration_depth -= 1;
        try self.local_names.append(self.allocator, variable_name);
        defer _ = self.local_names.pop();
        for (children[1..]) |child| try self.checkExpressions(child);
    }

    /// The common type of a list literal's elements, if they all have one.
    fn literalElementType(self: *Checker, list: Index) ?StaticType {
        if (self.ast.kind(list) != .list_literal) return null;
        const elements = self.ast.nodeChildren(list);
        if (elements.len == 0) return null;
        const first = self.staticType(elements[0]) orelse return null;
        for (elements[1..]) |element| {
            if (self.staticType(element) != first) return null;
        }
        return first;
    }

    /// The type of a literal, or of a typed comprehension variable.
    fn staticType(self: *Checker, index: Index) ?StaticType {
        return switch (self.ast.kind(index)) {
            .integer_literal, .float_literal => .number,
            .string_literal => .string,
            .boolean_literal => .boolean,
            .list_literal => .list,
            .map_literal => .map,
            .variable => {
                const name = self.ast.data(index).text;
                var i = self.local_types.items.len;
                while (i > 0) {
                    i -= 1;
                    if (std.mem.eql(u8, self.local_types.items[i].name, name)) return self.local_types.items[i].type;
                }
                return null;
            },
            else => null,
        };
    }

    /// Arithmetic on numbers only, except `+`, which also joins strings and
    /// lists (and a string with a number).
    fn checkArithmetic(self: *Checker, operator: BinaryOperator, operands: []const Index) SemanticError!void {
        // `list + anything` adds an element.
        if (operator == .add) for (operands) |operand| {
            if (self.staticType(operand) == .list) return;
        };
        for (operands) |operand| {
            const t = self.staticType(operand) orelse continue;
            const accepted = switch (t) {
                .number => true,
                .string, .list => operator == .add,
                .boolean, .map => false,
            };
            if (!accepted) return self.fail("{s} cannot be applied to a {s}", .{ @tagName(operator), @tagName(t) });
        }
    }

    /// True if `name` is called anywhere in the expression `index`.
    fn callsFunction(ast: *const Ast, index: Index, name: []const u8) bool {
        if (ast.kind(index) == .function_call and std.ascii.eqlIgnoreCase(ast.data(index).text, name)) return true;
        for (ast.nodeChildren(index)) |child| {
            if (callsFunction(ast, child, name)) return true;
        }
        return false;
    }

    /// Literals that can never be booleans (null can: it is unknown).
    const non_boolean_literals = [_]NodeKind{ .integer_literal, .float_literal, .string_literal, .list_literal, .map_literal };

    fn isLiteralOf(ast: *const Ast, index: Index, kinds: []const NodeKind) bool {
        return std.mem.indexOfScalar(NodeKind, kinds, ast.kind(index)) != null;
    }

    /// The kind of entity each entity function takes.
    const entity_functions = [_]struct { name: []const u8, kind: Kind }{
        .{ .name = "type", .kind = .relationship },
        .{ .name = "startNode", .kind = .relationship },
        .{ .name = "endNode", .kind = .relationship },
        .{ .name = "labels", .kind = .node },
        .{ .name = "id", .kind = .node },
        .{ .name = "length", .kind = .path },
        .{ .name = "nodes", .kind = .path },
        .{ .name = "relationships", .kind = .path },
        // A plain value: not a node, relationship or path.
        .{ .name = "size", .kind = .value },
    };

    fn checkEntityArgument(self: *Checker, call: Index) SemanticError!void {
        const name = self.ast.data(call).text;
        const arguments = self.ast.nodeChildren(call);
        if (arguments.len != 1 or self.ast.kind(arguments[0]) != .variable) return;
        const variable = self.ast.data(arguments[0]).text;
        const actual = self.scope.kindOf(variable) orelse return;
        for (entity_functions) |function| {
            if (!std.ascii.eqlIgnoreCase(function.name, name)) continue;
            if (actual != function.kind and actual != .value and actual != .any) {
                return self.fail("{s}() takes a {s}, but '{s}' is a {s}", .{ function.name, @tagName(function.kind), variable, @tagName(actual) });
            }
        }
    }

    /// A CALL names a known procedure, with as many arguments as it takes, and
    /// yields columns it has: they become variables, of the column's kind. A
    /// CALL that yields every column ends the query.
    fn checkCall(self: *Checker, clause: Index, last: bool) SemanticError!void {
        const call = self.ast.data(clause).call;
        const signature = procedures.find(call.procedure, self.table_procedures) orelse return self.fail("unknown procedure '{s}'", .{call.procedure});
        const children = self.ast.nodeChildren(clause);
        if (call.implicit_arguments) {
            // Only a CALL that is the whole query takes its arguments from the parameters.
            if (signature.max_arguments > 0 and !(call.yield_all and last)) {
                return self.fail("{s} needs its arguments in parentheses here: CALL {s}(...)", .{ call.procedure, call.procedure });
            }
        } else if (call.argument_count < signature.min_arguments or call.argument_count > signature.max_arguments) {
            return self.fail("{s}() takes {d} to {d} arguments, not {d}", .{ call.procedure, signature.min_arguments, signature.max_arguments, call.argument_count });
        }
        for (children[0..call.argument_count]) |expression| {
            if (containsAggregate(self.ast, expression)) return self.fail("an aggregate cannot be a procedure's argument; aggregate in a WITH first", .{});
        }
        for (signature.arguments[0..@min(signature.arguments.len, call.argument_count)], children[0..@min(signature.arguments.len, call.argument_count)]) |argument, expression| {
            if (!literalFits(self.ast, expression, argument.type)) {
                return self.fail("{s}(): the argument '{s}' must be of type {s}", .{ call.procedure, argument.name, @tagName(argument.type) });
            }
        }
        if (call.yield_all) {
            // A procedure without columns needs no YIELD anywhere.
            if (!last and signature.columns.len > 0) return self.fail("a CALL inside a query must YIELD the columns it uses: CALL {s}(...) YIELD ...", .{call.procedure});
            return;
        }
        const yield_items = children[call.argument_count .. children.len - 1];
        for (yield_items, 0..) |item, i| {
            const yield_item = self.ast.data(item).yield_;
            const column = signature.column(yield_item.column) orelse return self.fail("{s}() has no column '{s}'", .{ call.procedure, yield_item.column });
            const kind: Kind = switch (column.kind) {
                .node => .node,
                .relationship => .relationship,
                .value => .value,
            };
            const name = yieldedName(self.ast, item);
            for (yield_items[0..i]) |earlier| {
                if (std.mem.eql(u8, yieldedName(self.ast, earlier), name)) return self.fail("YIELD binds '{s}' twice", .{name});
            }
            if (self.scope.kindOf(name) != null) return self.fail("YIELD binds '{s}', which is already bound", .{name});
            try self.use(name, kind);
        }
    }

    fn yieldedName(ast: *const Ast, item: Index) []const u8 {
        const yield_item = ast.data(item).yield_;
        return if (yield_item.alias.len > 0) yield_item.alias else yield_item.column;
    }

    /// False for a literal that can never be of `declared` type (null fits
    /// any; an integer fits FLOAT and NUMBER); other expressions are checked
    /// when they run.
    fn literalFits(ast: *const Ast, expression: Index, declared: procedures.ArgumentType) bool {
        const accepted: []const procedures.ArgumentType = switch (ast.kind(expression)) {
            .integer_literal => &.{ .integer, .float, .number },
            .float_literal => &.{ .float, .number },
            .string_literal => &.{.string},
            .boolean_literal => &.{.boolean},
            .list_literal => &.{.list},
            .map_literal => &.{.map},
            else => return true,
        };
        return declared == .any or std.mem.indexOfScalar(procedures.ArgumentType, accepted, declared) != null;
    }

    /// A WHERE is a condition on each row: no aggregates, and not a bare
    /// node, relationship or path (`WHERE (n)`).
    fn checkWhere(self: *Checker, where: Index) SemanticError!void {
        if (containsAggregate(self.ast, where)) return self.fail("an aggregate cannot be used in WHERE; aggregate in a WITH, then filter", .{});
        if (self.ast.kind(where) == .variable) {
            const kind = self.scope.kindOf(self.ast.data(where).text) orelse return;
            if (kind == .node or kind == .relationship or kind == .path) return self.fail("WHERE needs a condition, not a {s}", .{@tagName(kind)});
        }
    }

    /// The projection of a WITH or RETURN sees the variables in scope; its
    /// WHERE and ORDER BY see its names as well, except that after DISTINCT
    /// the ORDER BY sees only what is projected.
    fn checkProjectionClause(self: *Checker, clause: Index, distinct: bool) SemanticError!void {
        const children = self.ast.nodeChildren(clause);
        const projection = children[0];
        try self.checkExpressions(projection);
        try self.checkColumnNames(projection);

        var shadowed = std.ArrayList(struct { name: []const u8, kind: ?Kind }).empty;
        defer shadowed.deinit(self.allocator);
        for (self.ast.nodeChildren(projection)) |item| {
            const alias = self.ast.data(item).text;
            if (alias.len == 0) continue;
            try shadowed.append(self.allocator, .{ .name = alias, .kind = self.scope.kindOf(alias) });
            try self.scope.names.put(self.allocator, alias, .any);
        }
        defer {
            var i = shadowed.items.len;
            while (i > 0) {
                i -= 1;
                const entry = shadowed.items[i];
                if (entry.kind) |kind| self.scope.names.putAssumeCapacity(entry.name, kind) else _ = self.scope.names.remove(entry.name);
            }
        }
        for (children[1..]) |child| {
            if (distinct and !self.hasStar(projection) and self.ast.kind(child) == .order_by) try self.checkProjectedOnly(projection, child);
            try self.checkExpressions(child);
        }
    }

    /// Every variable in `index` is a projected name, or is inside a part
    /// that repeats a projected expression.
    fn checkProjectedOnly(self: *Checker, projection: Index, index: Index) SemanticError!void {
        for (self.ast.nodeChildren(projection)) |item| {
            if (self.ast.sameExpression(self.ast.nodeChildren(item)[0], index)) return;
        }
        if (self.ast.kind(index) == .variable) {
            const name = self.ast.data(index).text;
            if (!self.isLocal(name) and !projectsName(self.ast, projection, name)) return self.failUnknown(name);
            return;
        }
        for (self.ast.nodeChildren(index)) |child| try self.checkProjectedOnly(projection, child);
    }

    /// No two columns of a projection have the same name.
    fn checkColumnNames(self: *Checker, projection: Index) SemanticError!void {
        const items = self.ast.nodeChildren(projection);
        for (items, 0..) |item, i| {
            const name = columnName(self.ast, item) orelse continue;
            for (items[0..i]) |earlier| {
                const other = columnName(self.ast, earlier) orelse continue;
                if (std.mem.eql(u8, name, other)) return self.fail("two columns are named '{s}'", .{name});
            }
        }
    }

    /// DELETE takes a node, a relationship or a path; an expression that can
    /// only be something else fails here (DELETE of a label is REMOVE's job).
    fn checkDeleted(self: *Checker, expression: Index) SemanticError!void {
        switch (self.ast.kind(expression)) {
            .label_predicate => return self.fail("DELETE removes nodes, relationships and paths; use REMOVE n:Label to remove a label", .{}),
            .integer_literal, .float_literal, .string_literal, .boolean_literal, .list_literal, .map_literal, .binary_operation, .unary_operation, .map_projection => {
                return self.fail("DELETE needs a node, a relationship or a path", .{});
            },
            else => {},
        }
    }

    /// Clause by clause: declare what the clause binds, then check its
    /// expressions with those variables in scope (WITH and RETURN expressions
    /// see the scope before their projection).
    fn checkQuery(self: *Checker, query: Index) SemanticError!void {
        const query_clauses = self.ast.nodeChildren(query);
        for (query_clauses, 0..) |clause, position| {
            const children = self.ast.nodeChildren(clause);
            switch (self.ast.kind(clause)) {
                .delete_clause => for (children) |item| try self.checkDeleted(self.ast.nodeChildren(item)[0]),
                .call_clause => {
                    try self.checkCall(clause, position + 1 == query_clauses.len);
                    try self.checkExpressions(clause);
                    continue;
                },
                .match_clause, .optional_match_clause => {
                    try self.checkPatterns(children[0 .. children.len - 1], .match);
                    try self.checkWhere(children[children.len - 1]);
                },
                .create_clause => try self.checkPatterns(children, .create),
                .merge_clause => try self.checkPatterns(children[0..1], .merge),
                .unwind_clause => {
                    try self.checkExpressions(clause);
                    try self.use(self.ast.data(clause).unwind.variable_name, .any);
                    continue;
                },
                .with_clause => {
                    try self.recordStar(children[0], false);
                    try self.checkWhere(children[children.len - 1]);
                    try self.checkProjectionClause(clause, self.ast.data(clause).with_.distinct);
                    try self.projectScope(children[0]);
                    continue;
                },
                .return_clause => {
                    try self.recordStar(children[0], true);
                    try self.checkProjectionClause(clause, self.ast.data(clause).return_.distinct);
                    continue;
                },
                else => {},
            }
            try self.checkExpressions(clause);
        }
    }
};

/// Checks `query`; on a violation fills `diagnostic` and returns
/// `error.InvalidExpression`. O(size of the query).
pub fn check(ast: *Ast, query: Index, allocator: Allocator, diagnostic: ?*Diagnostic, table_procedures: []const procedures.TableProcedure) SemanticError!void {
    var checker = Checker{ .ast = ast, .allocator = allocator, .diagnostic = diagnostic, .table_procedures = table_procedures };
    defer checker.scope.names.deinit(allocator);
    defer checker.local_types.deinit(allocator);
    defer checker.stars.deinit(allocator);
    try checker.checkQuery(query);
    // `*` becomes the variables it stands for, so execution sees plain items.
    for (checker.stars.items) |star| try expandStar(ast, query, star);
    for (ast.nodeChildren(query)) |clause| try nameProjectedInOrderBy(ast, clause);
}

/// In the ORDER BY of a WITH or RETURN, each part that repeats a projected
/// expression becomes the column's name: `WITH a.name AS name, count(*) AS c
/// ORDER BY a.name + 'C'` sorts by `name + 'C'`, which the projected rows can
/// evaluate after grouping has removed `a`.
fn nameProjectedInOrderBy(ast: *Ast, clause: Index) Allocator.Error!void {
    if (ast.kind(clause) != .with_clause and ast.kind(clause) != .return_clause) return;
    const children = ast.nodeChildren(clause);
    if (children.len < 2 or ast.kind(children[1]) != .order_by) return;
    const projection = children[0];
    for (ast.nodeChildren(children[1])) |order_item| try nameProjectedParts(ast, projection, order_item);
}

fn nameProjectedParts(ast: *Ast, projection: Index, parent: Index) Allocator.Error!void {
    for (ast.nodeChildren(parent)) |child| {
        if (projectedName(ast, projection, child)) |name| {
            const variable = try ast.addNode(.variable, .{ .text = name }, &.{});
            ast.replaceChild(parent, child, variable);
        } else {
            try nameProjectedParts(ast, projection, child);
        }
    }
}

/// The alias of the projection item whose expression is `expression`, if it
/// has one (a projected variable needs no renaming; an aggregate stays, for
/// the checks on aggregating expressions).
fn projectedName(ast: *const Ast, projection: Index, expression: Index) ?[]const u8 {
    if (ast.kind(expression) == .variable or containsAggregate(ast, expression)) return null;
    for (ast.nodeChildren(projection)) |item| {
        const alias = ast.data(item).text;
        if (alias.len > 0 and ast.sameExpression(ast.nodeChildren(item)[0], expression)) return alias;
    }
    return null;
}

/// Replaces a `*` projection with one that lists `star.names` (as variables)
/// and then the projection's own items.
fn expandStar(ast: *Ast, query: Index, star: Star) Allocator.Error!void {
    var items = std.ArrayList(Index).empty;
    defer items.deinit(ast.allocator);
    for (star.names) |name| {
        const variable = try ast.addNode(.variable, .{ .text = try ast.intern(name) }, &.{});
        try items.append(ast.allocator, try ast.addNode(.projection_item, .{ .text = "" }, &.{variable}));
    }
    try items.appendSlice(ast.allocator, ast.nodeChildren(star.projection));
    const expanded = try ast.addNode(.projection, .{ .none = {} }, items.items);
    for (ast.nodeChildren(query)) |clause| ast.replaceChild(clause, star.projection, expanded);
}

fn containsAggregate(ast: *const Ast, expression: Index) bool {
    if (ast.kind(expression) == .aggregate) return true;
    for (ast.nodeChildren(expression)) |child| if (containsAggregate(ast, child)) return true;
    return false;
}

/// The name of a projection item's column: its alias, or the variable it
/// projects (null for an expression without an alias).
fn columnName(ast: *const Ast, item: Index) ?[]const u8 {
    const alias = ast.data(item).text;
    if (alias.len > 0) return alias;
    const expression = ast.nodeChildren(item)[0];
    return if (ast.kind(expression) == .variable) ast.data(expression).text else null;
}

fn projectsName(ast: *const Ast, projection: Index, name: []const u8) bool {
    for (ast.nodeChildren(projection)) |item| {
        if (columnName(ast, item)) |column| if (std.mem.eql(u8, column, name)) return true;
    }
    return false;
}
