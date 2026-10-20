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
//! - `match_clause` children are `[pattern0, ..., patternN, where_expression]`: one or
//!   more comma-separated patterns followed by the `WHERE` (a missing `WHERE`
//!   is `bool_literal(true)`).
//! - `optional_match_clause` children are the same shape as `match_clause`.
//! - `create_clause` children are its patterns, `[pattern, ...]`.
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
//! - `property` children are `[value_expression]` (the name is in `.text`).
//! - `property_access` children are `[object_expression]` (the property name is in
//!   `.text`).
//! - `set_item` children are `[property_access, value_expression]`;
//!   `set_properties` children are `[variable, value_expression]`, data.boolean
//!   true for `+=` (merge) and false for `=` (replace); a `label_reference`
//!   item (data.text the label, child the variable) adds a label.
//! - `delete_item` children are `[variable]`.
//! - `agg` children are `[argument_expression]` (empty for `count(*)`); the function is in
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
pub const BinaryOperator = enum {
    equal,
    not_equal,
    less_than,
    greater_than,
    less_or_equal,
    greater_or_equal,
    and_,
    or_,
    xor,
    starts_with,
    ends_with,
    contains,
    in_,
    add,
    subtract,
    multiply,
    divide,
    modulo,
    power,
};

pub const UnaryOperator = enum {
    not_,
    negate,
    is_null,
    is_not_null,
};

/// Aggregation functions (`count`, `sum`, `avg`, `min`, `max`, `collect`,
/// `stDev`, `stDevP`).
/// An aggregate call: which aggregate, and whether over distinct values
/// (`count(DISTINCT x)`).
pub const AggregateCall = struct { kind: AggregateKind, distinct: bool = false };

pub const AggregateKind = enum {
    count,
    sum,
    avg,
    stDev,
    stDevP,
    min,
    max,
    collect,
    /// `percentileDisc(x, p)`, `percentileCont(x, p)`: the second child is p.
    percentileDisc,
    percentileCont,
};

/// Written direction of an edge pattern.
pub const EdgeDirection = enum {
    left_to_right, // -[...]->
    right_to_left, // <-[...]-
    undirected, // -[...]- (or <-[...]->): either direction
};

pub const NodeKind = enum {
    query,
    union_query, // children: the queries; data.boolean: UNION ALL (keep duplicates)
    pattern,
    node_pattern,
    edge_pattern,
    property,
    variable,
    property_access,
    integer_literal,
    float_literal,
    string_literal,
    boolean_literal,
    null_literal,
    parameter, // `$name`; data.text is the name
    list_literal,
    map_literal, // `{key: value, ...}`; children are `property` nodes
    subscript, // `value[index]`: children [value, index]
    slice, // `list[from..to]`: children [list, from, to] (null_literal for an open end); data.int: the written ends (1 from, 2 to)
    list_comprehension, // `[x IN list WHERE predicate | projection]`: data.text is x; children [list, predicate, projection]
    quantifier, // `any(x IN list WHERE predicate)`: data.quantifier; children [list, predicate]
    function_call, // `name(args...)`; data.text is the name as written, children the arguments
    pattern_predicate, // `(a)-->(b)` in a WHERE: children [pattern, true literal]
    pattern_comprehension, // `[p = (a)-->(b) WHERE w | e]`: children [pattern, w, e]
    exists_subquery, // `EXISTS { ... }`: children are match clauses
    case_expression, // children [condition, result]..., optional else
    simple_case_expression, // children [subject, (value, result)..., optional else]
    binary_operation,
    unary_operation,
    aggregate,
    projection,
    projection_item,
    match_clause,
    optional_match_clause,
    create_clause,
    merge_clause,
    set_clause,
    delete_clause,
    remove_clause,
    label_reference,
    with_clause,
    unwind_clause,
    return_clause,
    set_item,
    set_properties,
    delete_item,
    order_by,
    order_item,
    limit,
    skip,
    /// `x {.a, .*, key: expression, other}`: a map built from `x` (a node, a
    /// relationship or a map); children [x, item...], each item a `property`
    /// (key: expression), a `map_projection_property` (`.a`, data.text) or a
    /// `map_projection_all` (`.*`).
    map_projection,
    map_projection_property,
    map_projection_all,
    /// `x:A:B`: true if node `x` has every label (relationship `x`: its type is
    /// each); data.labels; children [x].
    label_predicate,
    /// `CALL proc(args) [YIELD ...] [WHERE ...]`: data.call; children are the
    /// arguments, then the `yield_item`s, then the WHERE (a `true` literal
    /// when there is none).
    call_clause,
    /// One `YIELD column [AS alias]`: data.yield_.
    yield_item,
    /// `CREATE FULLTEXT INDEX name FOR (n:L) ON EACH [n.p, ...] [OPTIONS {...}]`:
    /// data.fulltext_index; children: the OPTIONS map, if any.
    create_fulltext_index,
    /// `DROP INDEX name [IF EXISTS]`: data.drop_index.
    drop_index,
    /// `SHOW [FULLTEXT] INDEXES`: data.boolean is true for FULLTEXT only.
    show_indexes,
};

/// Node payload. The active variant is determined by the node's `kind`; kinds
/// that carry no extra data use `none`.
pub const Data = union(enum) {
    none: void,
    int: i64,
    float: f64,
    boolean: bool,
    /// A single string: a literal value, an identifier (variable, property,
    /// label, edge type) or a RETURN alias.
    text: []const u8,
    /// `has_map`: a property map was written, even an empty one (`(n {})`).
    node_pattern: struct { variable_name: []const u8, labels: []const []const u8, has_map: bool = false },
    edge_pattern: EdgePatternData,
    binary_operator: BinaryOperator,
    unary_operator: UnaryOperator,
    aggregate: AggregateCall,
    return_: struct { distinct: bool },
    with_: struct { distinct: bool },
    unwind: struct { variable_name: []const u8 },
    order_item: struct { ascending: bool },
    delete: struct { detach: bool },
    quantifier: struct { kind: QuantifierKind, variable_name: []const u8 },
    call: struct {
        procedure: []const u8,
        argument_count: u32,
        /// No YIELD: every column of the procedure, as the query's result.
        yield_all: bool,
        /// `CALL proc` without parentheses: the arguments are the query
        /// parameters named as the procedure's arguments.
        implicit_arguments: bool = false,
    },
    yield_: struct { column: []const u8, alias: []const u8 },
    fulltext_index: struct {
        name: []const u8,
        /// Indexes relationships of these types, not nodes with these labels.
        relationships: bool,
        labels_or_types: []const []const u8,
        properties: []const []const u8,
        if_not_exists: bool,
    },
    drop_index: struct { name: []const u8, if_exists: bool },
    labels: []const []const u8,
};

pub const QuantifierKind = enum { any, all, none, single };

/// An edge of a pattern: `-[variable:A|B*min..max {...}]->`.
pub const EdgePatternData = struct {
    variable_name: []const u8,
    /// The types it may have (`:A|B`); empty means any type.
    edge_types: []const []const u8,
    direction: EdgeDirection,
    /// `*`: a path of `min_hops` to `max_hops` edges (null: unbounded); the
    /// variable is bound to the list of its relationships.
    variable_length: bool = false,
    min_hops: u32 = 1,
    max_hops: ?u32 = 1,

    /// The single type a written edge must have, if there is exactly one.
    pub fn singleType(self: EdgePatternData) ?[]const u8 {
        return if (self.edge_types.len == 1) self.edge_types[0] else null;
    }
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

    /// Appends a node and returns its index. `children` only needs to stay valid
    /// for the duration of this call (the indices are copied).
    pub fn addNode(self: *Ast, node_kind: NodeKind, payload: Data, children: []const Index) Allocator.Error!Index {
        const first_child: Index = @intCast(self.children.items.len);
        try self.children.appendSlice(self.allocator, children);
        const index: Index = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{
            .kind = node_kind,
            .data = payload,
            .first_child = first_child,
            .child_count = @intCast(children.len),
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
    /// Makes `parent`'s child `old` be `new` instead (if it has it).
    pub fn replaceChild(self: *Ast, parent: Index, old: Index, new: Index) void {
        const n = self.nodes.items[parent];
        for (self.children.items[n.first_child .. n.first_child + n.child_count]) |*child| {
            if (child.* == old) child.* = new;
        }
    }

    pub fn nodeChildren(self: *const Ast, index: Index) []const Index {
        const n = self.nodes.items[index];
        return self.children.items[n.first_child .. n.first_child + n.child_count];
    }

    /// The root node (a `query`). The AST is built bottom-up, so the root is
    /// the last node added.
    /// Structural equality of two expression subtrees: same kinds, payloads
    /// and children. Used to recognise an ORDER BY expression that repeats a
    /// projected one (`RETURN p.g, count(*) ORDER BY count(*)`).
    pub fn sameExpression(self: *const Ast, a: Index, b: Index) bool {
        if (self.kind(a) != self.kind(b)) return false;
        if (!sameExpressionData(self.data(a), self.data(b))) return false;
        const a_children = self.nodeChildren(a);
        const b_children = self.nodeChildren(b);
        if (a_children.len != b_children.len) return false;
        for (a_children, b_children) |x, y| {
            if (!self.sameExpression(x, y)) return false;
        }
        return true;
    }

    pub fn root(self: *const Ast) Index {
        std.debug.assert(self.nodes.items.len > 0);
        return @intCast(self.nodes.items.len - 1);
    }
};

/// Payload equality for expression nodes; clause and pattern payloads never
/// compare equal (they are not expressions).
fn sameExpressionData(a: Data, b: Data) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none => true,
        .int => |x| x == b.int,
        .float => |x| x == b.float,
        .boolean => |x| x == b.boolean,
        .text => |x| std.mem.eql(u8, x, b.text),
        .binary_operator => |x| x == b.binary_operator,
        .unary_operator => |x| x == b.unary_operator,
        .aggregate => |x| x.kind == b.aggregate.kind and x.distinct == b.aggregate.distinct,
        else => false,
    };
}
