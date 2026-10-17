//! Arena-based AST for the openCypher subset.
//!
//! Nodes live in a flat `std.ArrayList` and refer to each other by index, never
//! by pointer; there is no class hierarchy and no Visitor. Each node is a
//! `NodeKind` tag plus a small tagged-union payload, and its children are a
//! contiguous run of indices in a separate array. Strings are owned by an arena
//! allocator, so the whole AST is freed with a single `deinit`.
//!
//! Conventions:
//!
//! - Absent variable/label/type/alias is the empty string `""`.
//! - `query` children are a list of clauses, in source order:
//!   `match_clause`, `create_clause`, `set_clause`, `delete_clause`,
//!   `return_clause`.
//! - `match_clause` children are `[pattern0, ..., patternN, where_expr]`: one or
//!   more comma-separated patterns followed by the `WHERE` (a missing `WHERE`
//!   is `bool_literal(true)`).
//! - `create_clause` children are `[pattern]`.
//! - `set_clause` children are `set_item`s.
//! - `delete_clause` children are `delete_item`s.
//! - `return_clause` children are `[projection]`, plus an optional `order_by`
//!   and an optional `limit`; `distinct` is in the `return_` payload.
//! - `order_by` children are `order_item`s.
//! - `order_item` children are `[expr]` (`ascending` is in the payload).
//! - `limit` children are `[expr]`.
//! - `pattern` children are the chain `[node0, edge0, node1, edge1, ...]`
//!   (alternating node/edge, always an odd count).
//! - `node_pattern` children are its `{name: value}` property entries.
//! - `property` children are `[value_expr]` (the name is in `.text`).
//! - `property_access` children are `[object_expr]` (the property name is in
//!   `.text`).
//! - `set_item` children are `[property_access, value_expr]`.
//! - `delete_item` children are `[variable]`.
//! - `projection` children are its `projection_item`s.
//! - `projection_item` children are `[expr]` (the alias is in `.text`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Index of a node in the arena, or of a child in the child array.
pub const Index = u32;

/// Comparison and boolean operators for `binary_op` nodes.
pub const BinOp = enum {
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
    and_,
    or_,
};

pub const UnOp = enum {
    not_,
};

/// Written direction of an edge pattern.
pub const EdgeDirection = enum {
    left_to_right, // -[...]->
    right_to_left, // <-[...]-
};

pub const NodeKind = enum {
    query,
    pattern,
    node_pattern,
    edge_pattern,
    property,
    variable,
    property_access,
    int_literal,
    string_literal,
    bool_literal,
    binary_op,
    unary_op,
    projection,
    projection_item,
    match_clause,
    create_clause,
    merge_clause,
    set_clause,
    delete_clause,
    return_clause,
    set_item,
    delete_item,
    order_by,
    order_item,
    limit,
};

/// Node payload. The active variant is determined by the node's `kind`; kinds
/// that carry no extra data use `none`.
pub const Data = union(enum) {
    none: void,
    int: i64,
    boolean: bool,
    /// A single string: a literal value, an identifier (variable, property,
    /// label, edge type) or a RETURN alias.
    text: []const u8,
    node_pattern: struct { var_name: []const u8, label: []const u8 },
    edge_pattern: struct { var_name: []const u8, etype: []const u8, direction: EdgeDirection },
    bin_op: BinOp,
    un_op: UnOp,
    return_: struct { distinct: bool },
    order_item: struct { ascending: bool },
};

pub const Node = struct {
    kind: NodeKind,
    data: Data,
    /// Start of this node's children in `Ast.children`.
    first_child: Index,
    child_count: u32,
};

pub const Ast = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: std.ArrayList(Node),
    children: std.ArrayList(Index),

    pub fn init(allocator: Allocator) Ast {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .nodes = .empty,
            .children = .empty,
        };
    }

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Dupes `s` into the arena and returns it; valid until `deinit`.
    pub fn intern(self: *Ast, s: []const u8) Allocator.Error![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    /// Appends a node and returns its index. `kids` only needs to stay valid
    /// for the duration of this call (the indices are copied).
    pub fn addNode(self: *Ast, node_kind: NodeKind, payload: Data, kids: []const Index) Allocator.Error!Index {
        const first_child: Index = @intCast(self.children.items.len);
        try self.children.appendSlice(self.allocator, kids);
        const index: Index = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .kind = node_kind,
            .data = payload,
            .first_child = first_child,
            .child_count = @intCast(kids.len),
        });
        return index;
    }

    pub fn node(self: *const Ast, index: Index) Node {
        return self.nodes.items[index];
    }

    pub fn kind(self: *const Ast, index: Index) NodeKind {
        return self.nodes.items[index].kind;
    }

    pub fn data(self: *const Ast, index: Index) Data {
        return self.nodes.items[index].data;
    }

    /// The child indices of `index`, in order.
    pub fn nodeChildren(self: *const Ast, index: Index) []const Index {
        const n = self.nodes.items[index];
        return self.children.items[n.first_child .. n.first_child + n.child_count];
    }

    /// The root node (a `query`). The AST is built bottom-up, so the root is
    /// the last node added.
    pub fn root(self: *const Ast) Index {
        std.debug.assert(self.nodes.items.len > 0);
        return @intCast(self.nodes.items.len - 1);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "builds and walks the AST for a MATCH/RETURN query" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // RETURN p.born -> projection_item(alias="", property_access("born", variable("p")))
    const v_p = try ast.addNode(.variable, .{ .text = "p" }, &.{});
    const access = try ast.addNode(.property_access, .{ .text = "born" }, &.{v_p});
    const item = try ast.addNode(.projection_item, .{ .text = "" }, &.{access});
    const projection = try ast.addNode(.projection, .{ .none = {} }, &.{item});

    // (p:Person {name: 'Keanu Reeves'})
    const lit = try ast.addNode(.string_literal, .{ .text = "Keanu Reeves" }, &.{});
    const prop = try ast.addNode(.property, .{ .text = "name" }, &.{lit});
    const np = try ast.addNode(.node_pattern, .{ .node_pattern = .{ .var_name = "p", .label = "Person" } }, &.{prop});
    const pattern = try ast.addNode(.pattern, .{ .none = {} }, &.{np});

    // no WHERE -> true
    const true_expr = try ast.addNode(.bool_literal, .{ .boolean = true }, &.{});

    const match_clause = try ast.addNode(.match_clause, .{ .none = {} }, &.{ pattern, true_expr });
    const return_clause = try ast.addNode(.return_clause, .{ .none = {} }, &.{projection});
    const query = try ast.addNode(.query, .{ .none = {} }, &.{ match_clause, return_clause });

    try testing.expectEqual(query, ast.root());
    try testing.expectEqual(NodeKind.query, ast.kind(ast.root()));

    const qc = ast.nodeChildren(query);
    try testing.expectEqual(@as(usize, 2), qc.len);
    try testing.expectEqual(NodeKind.match_clause, ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.return_clause, ast.kind(qc[1]));

    // match_clause -> [pattern, where]
    const mc = ast.nodeChildren(qc[0]);
    try testing.expectEqual(@as(usize, 2), mc.len);
    try testing.expectEqual(NodeKind.pattern, ast.kind(mc[0]));
    try testing.expectEqual(NodeKind.bool_literal, ast.kind(mc[1]));

    // pattern -> node_pattern
    const pc = ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 1), pc.len);
    try testing.expectEqual(NodeKind.node_pattern, ast.kind(pc[0]));
    try testing.expectEqualStrings("Person", ast.data(pc[0]).node_pattern.label);
    try testing.expectEqualStrings("p", ast.data(pc[0]).node_pattern.var_name);

    // node_pattern -> one property {name: 'Keanu Reeves'}
    const nprops = ast.nodeChildren(pc[0]);
    try testing.expectEqual(@as(usize, 1), nprops.len);
    try testing.expectEqual(NodeKind.property, ast.kind(nprops[0]));
    try testing.expectEqualStrings("name", ast.data(nprops[0]).text);

    // return_clause -> projection -> one item -> property_access("born", variable("p"))
    const rc = ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 1), rc.len);
    const projc = ast.nodeChildren(rc[0]);
    try testing.expectEqual(@as(usize, 1), projc.len);
    try testing.expectEqual(NodeKind.projection_item, ast.kind(projc[0]));

    const accessc = ast.nodeChildren(projc[0]);
    try testing.expectEqual(@as(usize, 1), accessc.len);
    try testing.expectEqual(NodeKind.property_access, ast.kind(accessc[0]));
    try testing.expectEqualStrings("born", ast.data(accessc[0]).text);

    const objc = ast.nodeChildren(accessc[0]);
    try testing.expectEqual(@as(usize, 1), objc.len);
    try testing.expectEqual(NodeKind.variable, ast.kind(objc[0]));
    try testing.expectEqualStrings("p", ast.data(objc[0]).text);
}

test "intern owns strings and binary_op holds two children" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    const name = try ast.intern("Keanu Reeves"); // arena-owned copy

    // p.name = 'Keanu Reeves'
    const lit = try ast.addNode(.string_literal, .{ .text = name }, &.{});
    const v_p = try ast.addNode(.variable, .{ .text = "p" }, &.{});
    const access = try ast.addNode(.property_access, .{ .text = "name" }, &.{v_p});
    const eq = try ast.addNode(.binary_op, .{ .bin_op = .eq }, &.{ access, lit });

    try testing.expectEqual(NodeKind.binary_op, ast.kind(eq));
    try testing.expectEqual(BinOp.eq, ast.data(eq).bin_op);

    const kids = ast.nodeChildren(eq);
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(NodeKind.property_access, ast.kind(kids[0]));
    try testing.expectEqualStrings("Keanu Reeves", ast.data(kids[1]).text);
}
