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
//! - `optional_match_clause` children are the same shape as `match_clause`.
//! - `create_clause` children are `[pattern]`.
//! - `set_clause` children are `set_item`s.
//! - `delete_clause` children are `delete_item`s; `detach` is in the `delete`
//!   payload.
//! - `return_clause` children are `[projection]`, plus an optional `order_by`
//!   and an optional `limit`; `distinct` is in the `return_` payload.
//! - `with_clause` children are `[projection, order_by?, skip?, limit?, where]`
//!   (the `WHERE` is always present, `bool_literal(true)` if absent, and is the
//!   last child); `distinct` is in the `with_` payload.
//! - `order_by` children are `order_item`s.
//! - `order_item` children are `[expr]` (`ascending` is in the payload).
//! - `limit` children are `[expr]`.
//! - `skip` children are `[expr]`.
//! - `pattern` children are the chain `[node0, edge0, node1, edge1, ...]`
//!   (alternating node/edge, always an odd count).
//! - `node_pattern` children are its `{name: value}` property entries.
//! - `edge_pattern` children are its `{name: value}` property entries (usually
//!   empty).
//! - `property` children are `[value_expr]` (the name is in `.text`).
//! - `property_access` children are `[object_expr]` (the property name is in
//!   `.text`).
//! - `set_item` children are `[property_access, value_expr]`.
//! - `delete_item` children are `[variable]`.
//! - `agg` children are `[arg_expr]` (empty for `count(*)`); the function is in
//!   the `agg` payload.
//! - `list_literal` children are the list elements (used by `IN [...]` and list
//!   expressions).
//! - `size_fn` children are `[expr]` (the `size(...)` function).
//! - `case_expr` children are `[cond0, then0, cond1, then1, ..., else?]`.
//! - `remove_clause` children are `property_access` or `label_ref` items.
//! - `label_ref` children are `[variable]` (the label name is in `.text`).
//! - `unwind_clause` children are `[expr]`; the bound variable is in the
//!   `unwind` payload.
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
    starts_with,
    ends_with,
    contains,
    in_,
};

pub const UnOp = enum {
    not_,
};

/// Aggregation functions (`count`, `sum`, `min`, `max`, `collect`).
pub const AggKind = enum {
    count,
    sum,
    min,
    max,
    collect,
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
    list_literal,
    size_fn,
    case_expr,
    binary_op,
    unary_op,
    agg,
    projection,
    projection_item,
    match_clause,
    optional_match_clause,
    create_clause,
    merge_clause,
    set_clause,
    delete_clause,
    remove_clause,
    label_ref,
    with_clause,
    unwind_clause,
    return_clause,
    set_item,
    delete_item,
    order_by,
    order_item,
    limit,
    skip,
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
    node_pattern: struct { var_name: []const u8, labels: []const []const u8 },
    edge_pattern: struct { var_name: []const u8, etype: []const u8, direction: EdgeDirection },
    bin_op: BinOp,
    un_op: UnOp,
    agg: AggKind,
    return_: struct { distinct: bool },
    with_: struct { distinct: bool },
    unwind: struct { var_name: []const u8 },
    order_item: struct { ascending: bool },
    delete: struct { detach: bool },
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

    /// Dupes a slice of strings into the arena; valid until `deinit`.
    pub fn internSlice(self: *Ast, s: []const []const u8) Allocator.Error![]const []const u8 {
        return self.arena.allocator().dupe([]const u8, s);
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
