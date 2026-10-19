//! Static semantic checks on a parsed query, before it runs: how each
//! variable is used must agree with what it is. Checked per clause, in order,
//! tracking the kind of every variable in scope (WITH starts a new scope):
//!
//! - a relationship variable appears once per MATCH (openCypher's
//!   VariableAlreadyBound);
//! - a name is a node, a relationship or a value, never two of them
//!   (VariableTypeConflict), e.g. `(r)-[r]-()`, or `WITH 1 AS r MATCH ()-[r]-()`;
//! - a literal operand has a type its operator or function accepts: `1 IN true`,
//!   `123 AND true`, `NOT {}`, `properties(1)` fail (InvalidArgumentType).
//!
//! The checks do not depend on the data, so they fail on an empty graph too.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("ast.zig").Ast;
const Index = @import("ast.zig").Index;
const NodeKind = @import("ast.zig").NodeKind;
const Diagnostic = @import("../diagnostics.zig").Diagnostic;

pub const SemanticError = Allocator.Error || error{InvalidExpression};

const Kind = enum { node, relationship, value };

const Scope = struct {
    names: std.StringHashMapUnmanaged(Kind) = .empty,

    fn kindOf(self: *const Scope, name: []const u8) ?Kind {
        return self.names.get(name);
    }
};

const Checker = struct {
    ast: *const Ast,
    allocator: Allocator,
    diagnostic: ?*Diagnostic,
    scope: Scope = .{},

    fn fail(self: *Checker, comptime fmt: []const u8, args: anytype) SemanticError {
        if (self.diagnostic) |d| d.set(.invalid_expression, 0, fmt, args);
        return error.InvalidExpression;
    }

    /// Declares `name` as `kind`, or checks it against its existing kind.
    fn use(self: *Checker, name: []const u8, kind: Kind) SemanticError!void {
        if (name.len == 0) return;
        if (self.scope.kindOf(name)) |existing| {
            if (existing != kind) {
                return self.fail("variable '{s}' is a {s}; it cannot be used as a {s}", .{ name, @tagName(existing), @tagName(kind) });
            }
            return;
        }
        try self.scope.names.put(self.allocator, name, kind);
    }

    /// Checks the patterns of one MATCH / OPTIONAL MATCH / CREATE / MERGE.
    fn checkPatterns(self: *Checker, patterns: []const Index, reading: bool) SemanticError!void {
        var relationships = std.StringHashMapUnmanaged(void).empty;
        defer relationships.deinit(self.allocator);
        for (patterns) |pattern| {
            for (self.ast.nodeChildren(pattern)) |element| {
                switch (self.ast.kind(element)) {
                    .node_pattern => try self.use(self.ast.data(element).node_pattern.variable_name, .node),
                    .edge_pattern => {
                        const name = self.ast.data(element).edge_pattern.variable_name;
                        if (name.len == 0) continue;
                        if (reading and (try relationships.fetchPut(self.allocator, name, {})) != null) {
                            return self.fail("relationship variable '{s}' is used twice in one pattern", .{name});
                        }
                        try self.use(name, .relationship);
                    },
                    else => {},
                }
            }
        }
    }

    /// WITH replaces the scope by its projected names: a projected variable
    /// keeps its kind, anything else is a value.
    fn projectScope(self: *Checker, projection: Index) SemanticError!void {
        var next = Scope{};
        for (self.ast.nodeChildren(projection)) |item| {
            const expression = self.ast.nodeChildren(item)[0];
            const alias = self.ast.data(item).text;
            var kind: Kind = .value;
            var name = alias;
            if (self.ast.kind(expression) == .variable) {
                const source = self.ast.data(expression).text;
                kind = self.scope.kindOf(source) orelse .value;
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
            .binary_operation => switch (self.ast.data(index).binary_operator) {
                .in_ => if (isLiteralOf(self.ast, children[1], &.{ .integer_literal, .string_literal, .boolean_literal, .map_literal })) {
                    return self.fail("the right side of IN must be a list", .{});
                },
                .and_, .or_ => for (children) |operand| {
                    if (isLiteralOf(self.ast, operand, &non_boolean_literals)) return self.fail("AND and OR need boolean operands", .{});
                },
                else => {},
            },
            .unary_operation => if (self.ast.data(index).unary_operator == .not_ and isLiteralOf(self.ast, children[0], &non_boolean_literals)) {
                return self.fail("NOT needs a boolean operand", .{});
            },
            .function_call => {
                try self.checkEntityArgument(index);
                if (std.ascii.eqlIgnoreCase(self.ast.data(index).text, "properties") and children.len == 1 and
                    isLiteralOf(self.ast, children[0], &.{ .integer_literal, .string_literal, .boolean_literal, .list_literal }))
                {
                    return self.fail("properties() takes a map, a node or a relationship", .{});
                }
            },
            else => {},
        }
        for (self.ast.nodeChildren(index)) |child| try self.checkExpressions(child);
    }

    /// Literals that can never be booleans (null can: it is unknown).
    const non_boolean_literals = [_]NodeKind{ .integer_literal, .string_literal, .list_literal, .map_literal };

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
    };

    fn checkEntityArgument(self: *Checker, call: Index) SemanticError!void {
        const name = self.ast.data(call).text;
        const arguments = self.ast.nodeChildren(call);
        if (arguments.len != 1 or self.ast.kind(arguments[0]) != .variable) return;
        const variable = self.ast.data(arguments[0]).text;
        const actual = self.scope.kindOf(variable) orelse return;
        for (entity_functions) |function| {
            if (!std.ascii.eqlIgnoreCase(function.name, name)) continue;
            if (actual != function.kind and actual != .value) {
                return self.fail("{s}() takes a {s}, but '{s}' is a {s}", .{ function.name, @tagName(function.kind), variable, @tagName(actual) });
            }
        }
    }

    /// Clause by clause: declare what the clause binds, then check its
    /// expressions with those variables in scope (WITH and RETURN expressions
    /// see the scope before their projection).
    fn checkQuery(self: *Checker, query: Index) SemanticError!void {
        for (self.ast.nodeChildren(query)) |clause| {
            const children = self.ast.nodeChildren(clause);
            switch (self.ast.kind(clause)) {
                .match_clause, .optional_match_clause => try self.checkPatterns(children[0 .. children.len - 1], true),
                .create_clause => try self.checkPatterns(children, false),
                .merge_clause => try self.checkPatterns(children[0..1], false),
                .unwind_clause => {
                    try self.checkExpressions(clause);
                    try self.use(self.ast.data(clause).unwind.variable_name, .value);
                    continue;
                },
                .with_clause => {
                    try self.checkExpressions(clause);
                    try self.projectScope(children[0]);
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
pub fn check(ast: *const Ast, query: Index, allocator: Allocator, diagnostic: ?*Diagnostic) SemanticError!void {
    var checker = Checker{ .ast = ast, .allocator = allocator, .diagnostic = diagnostic };
    defer checker.scope.names.deinit(allocator);
    try checker.checkQuery(query);
}
