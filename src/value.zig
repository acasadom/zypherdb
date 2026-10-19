//! `Value`: the typed value of properties and expressions.
//!
//! `Value` is a regular type: `eql` is an equivalence relation, `order` a
//! total order consistent with it (`order(a, b) == .eq` exactly when
//! `eql(a, b)`), and `hash` agrees with `eql`. Sorting, deduplication and
//! grouping rely on those laws; the tests below check them over random values.

const std = @import("std");

/// A reference to a stored relationship: its endpoints and type identify it
/// (acmedb keeps one relationship per source, target and type). A regular type.
pub const Relationship = struct {
    src: u64,
    dst: u64,
    edge_type: []const u8,

    pub fn eql(a: Relationship, b: Relationship) bool {
        return a.src == b.src and a.dst == b.dst and std.mem.eql(u8, a.edge_type, b.edge_type);
    }

    pub fn order(a: Relationship, b: Relationship) std.math.Order {
        const by_src = std.math.order(a.src, b.src);
        if (by_src != .eq) return by_src;
        const by_dst = std.math.order(a.dst, b.dst);
        if (by_dst != .eq) return by_dst;
        return std.mem.order(u8, a.edge_type, b.edge_type);
    }

    pub fn hash(self: Relationship, hasher: *std.hash.Wyhash) void {
        hasher.update(std.mem.asBytes(&self.src));
        hasher.update(std.mem.asBytes(&self.dst));
        hasher.update(self.edge_type);
    }
};

/// A path: `nodes.len == relationships.len + 1`, each relationship joining
/// the nodes on either side of it (in either direction). A regular type.
pub const Path = struct {
    nodes: []const u64,
    relationships: []const Relationship,

    pub fn order(a: Path, b: Path) std.math.Order {
        const common = @min(a.nodes.len, b.nodes.len);
        for (a.nodes[0..common], b.nodes[0..common]) |x, y| {
            if (x != y) return std.math.order(x, y);
        }
        const by_length = std.math.order(a.nodes.len, b.nodes.len);
        if (by_length != .eq) return by_length;
        for (a.relationships, b.relationships) |x, y| {
            const by_relationship = x.order(y);
            if (by_relationship != .eq) return by_relationship;
        }
        return .eq;
    }

    pub fn hash(self: Path, hasher: *std.hash.Wyhash) void {
        hasher.update(std.mem.sliceAsBytes(self.nodes));
        for (self.relationships) |relationship| relationship.hash(hasher);
    }
};

/// One entry of a map value.
pub const MapEntry = struct { key: []const u8, value: Value };

/// A property or expression value. `int`, `string` and `boolean` are storable
/// as properties; `null` and `list` exist during evaluation, and `node` and
/// `relationship` are references to stored entities (what a variable of a
/// pattern is bound to).
pub const Value = union(enum) {
    int: i64,
    string: []const u8,
    boolean: bool,
    null: void,
    list: []const Value,
    node: u64,
    relationship: Relationship,
    /// Entries sorted by key, keys unique (build with `mapOf`), so maps that
    /// hold the same entries are equal whatever order they were written in.
    map: []const MapEntry,
    path: Path,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    /// Structural equality. `null` equals `null` here (this is identity for
    /// DISTINCT and grouping, not the three-valued `=` operator).
    pub fn eql(a: Value, b: Value) bool {
        return order(a, b) == .eq;
    }

    /// The openCypher global sort order, ascending: map < node <
    /// relationship < list < path < string < boolean < number < null. Within a type,
    /// maps compare entry by entry (key, then value), nodes by id,
    /// relationships by (source, target, type), lists lexicographically,
    /// strings by byte (= Unicode code point, for UTF-8), and `false < true`.
    pub fn order(a: Value, b: Value) std.math.Order {
        const rank_order = std.math.order(typeRank(a), typeRank(b));
        if (rank_order != .eq) return rank_order;
        return switch (a) {
            .null => .eq,
            .int => |x| std.math.order(x, b.int),
            .string => |x| std.mem.order(u8, x, b.string),
            .boolean => |x| std.math.order(@intFromBool(x), @intFromBool(b.boolean)),
            .list => |x| orderSequences(x, b.list),
            .node => |x| std.math.order(x, b.node),
            .relationship => |x| x.order(b.relationship),
            .map => |x| orderMaps(x, b.map),
            .path => |x| x.order(b.path),
        };
    }

    /// The value of `key` in a map, or null.
    pub fn mapGet(entries: []const MapEntry, key: []const u8) Value {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return .{ .null = {} };
    }

    /// A deep copy whose strings and lists are allocated with `allocator`.
    pub fn clone(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
        return switch (self) {
            .int, .boolean, .null, .node => self,
            .string => |s| .{ .string = try allocator.dupe(u8, s) },
            .relationship => |r| .{ .relationship = .{ .src = r.src, .dst = r.dst, .edge_type = try allocator.dupe(u8, r.edge_type) } },
            .list => |items| blk: {
                const copies = try allocator.alloc(Value, items.len);
                for (copies, items) |*copy, item| copy.* = try item.clone(allocator);
                break :blk .{ .list = copies };
            },
            .path => |p| blk: {
                const relationships = try allocator.alloc(Relationship, p.relationships.len);
                for (relationships, p.relationships) |*copy, r| copy.* = .{ .src = r.src, .dst = r.dst, .edge_type = try allocator.dupe(u8, r.edge_type) };
                break :blk .{ .path = .{ .nodes = try allocator.dupe(u64, p.nodes), .relationships = relationships } };
            },
            .map => |entries| blk: {
                const copies = try allocator.alloc(MapEntry, entries.len);
                for (copies, entries) |*copy, entry| copy.* = .{ .key = try allocator.dupe(u8, entry.key), .value = try entry.value.clone(allocator) };
                break :blk .{ .map = copies };
            },
        };
    }

    /// Feeds the value into `hasher`; values that are `eql` hash equally.
    pub fn hash(self: Value, hasher: *std.hash.Wyhash) void {
        hasher.update(&.{self.typeRank()});
        switch (self) {
            .null => {},
            .int => |x| hasher.update(std.mem.asBytes(&x)),
            .string => |x| {
                hasher.update(std.mem.asBytes(&x.len));
                hasher.update(x);
            },
            .boolean => |x| hasher.update(&.{@intFromBool(x)}),
            .list => |items| {
                hasher.update(std.mem.asBytes(&items.len));
                for (items) |item| item.hash(hasher);
            },
            .node => |id| hasher.update(std.mem.asBytes(&id)),
            .relationship => |relationship| relationship.hash(hasher),
            .path => |p| p.hash(hasher),
            .map => |entries| {
                hasher.update(std.mem.asBytes(&entries.len));
                for (entries) |entry| {
                    hasher.update(std.mem.asBytes(&entry.key.len));
                    hasher.update(entry.key);
                    entry.value.hash(hasher);
                }
            },
        }
    }

    /// Position of the value's type in the global sort order.
    fn typeRank(self: Value) u8 {
        return switch (self) {
            .map => 0,
            .node => 1,
            .relationship => 2,
            .list => 3,
            .path => 4,
            .string => 5,
            .boolean => 6,
            .int => 7,
            .null => 8,
        };
    }
};

/// A map value from `entries` in any order: sorted by key; when a key repeats,
/// the last entry wins (as in a Cypher map literal). Sorts `entries` in place.
pub fn mapOf(entries: []MapEntry) Value {
    std.sort.block(MapEntry, entries, {}, struct {
        fn lessThan(_: void, a: MapEntry, b: MapEntry) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lessThan);
    // Stable sort: of equal keys, the last written comes last; keep it.
    var kept: usize = 0;
    for (entries, 0..) |entry, i| {
        if (i + 1 < entries.len and std.mem.eql(u8, entries[i + 1].key, entry.key)) continue;
        entries[kept] = entry;
        kept += 1;
    }
    return .{ .map = entries[0..kept] };
}

fn orderMaps(a: []const MapEntry, b: []const MapEntry) std.math.Order {
    const common = @min(a.len, b.len);
    for (a[0..common], b[0..common]) |x, y| {
        const by_key = std.mem.order(u8, x.key, y.key);
        if (by_key != .eq) return by_key;
        const by_value = Value.order(x.value, y.value);
        if (by_value != .eq) return by_value;
    }
    return std.math.order(a.len, b.len);
}

/// Element-wise equality of two value sequences (rows, lists, grouping keys).
pub fn eqlSequences(a: []const Value, b: []const Value) bool {
    return orderSequences(a, b) == .eq;
}

/// Lexicographic order of two value sequences; a proper prefix comes first.
pub fn orderSequences(a: []const Value, b: []const Value) std.math.Order {
    const common = @min(a.len, b.len);
    for (a[0..common], b[0..common]) |x, y| {
        const element_order = Value.order(x, y);
        if (element_order != .eq) return element_order;
    }
    return std.math.order(a.len, b.len);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Random values for the law tests: every type, with lists nested up to
/// `depth` and small domains so that equal values actually occur.
fn randomValue(random: std.Random, arena: std.mem.Allocator, depth: u8) !Value {
    const strings = [_][]const u8{ "", "a", "ab", "b", "é", "Z" };
    const kinds: u8 = if (depth == 0) 6 else 8;
    return switch (random.uintLessThan(u8, kinds)) {
        4 => .{ .node = random.uintLessThan(u64, 3) },
        5 => .{ .relationship = .{ .src = random.uintLessThan(u64, 2), .dst = random.uintLessThan(u64, 2), .edge_type = strings[random.uintLessThan(usize, 3)] } },
        0 => .{ .null = {} },
        1 => .{ .int = random.intRangeAtMost(i64, -2, 2) },
        2 => .{ .string = strings[random.uintLessThan(usize, strings.len)] },
        3 => .{ .boolean = random.boolean() },
        7 => blk: {
            const entries = try arena.alloc(MapEntry, random.uintLessThan(usize, 3));
            for (entries) |*entry| entry.* = .{ .key = strings[random.uintLessThan(usize, 3)], .value = try randomValue(random, arena, depth - 1) };
            break :blk mapOf(entries);
        },
        else => blk: {
            const items = try arena.alloc(Value, random.uintLessThan(usize, 3));
            for (items) |*item| item.* = try randomValue(random, arena, depth - 1);
            break :blk .{ .list = items };
        },
    };
}

test "order is a total order and eql its equivalence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0xacde);
    const random = prng.random();

    var values: [60]Value = undefined;
    for (&values) |*v| v.* = try randomValue(random, arena, 2);

    for (values) |a| {
        // Reflexive.
        try testing.expectEqual(std.math.Order.eq, Value.order(a, a));
        for (values) |b| {
            // Antisymmetric.
            try testing.expectEqual(Value.order(a, b).invert(), Value.order(b, a));
            for (values) |c| {
                // Transitive.
                if (Value.order(a, b) != .gt and Value.order(b, c) != .gt) {
                    try testing.expect(Value.order(a, c) != .gt);
                }
            }
        }
    }
}

test "hash agrees with eql" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var prng = std.Random.DefaultPrng.init(0xbeef);
    const random = prng.random();

    var values: [80]Value = undefined;
    for (&values) |*v| v.* = try randomValue(random, arena_state.allocator(), 2);

    for (values) |a| {
        for (values) |b| {
            if (!Value.eql(a, b)) continue;
            var hash_a = std.hash.Wyhash.init(0);
            var hash_b = std.hash.Wyhash.init(0);
            a.hash(&hash_a);
            b.hash(&hash_b);
            try testing.expectEqual(hash_a.final(), hash_b.final());
        }
    }
}

test "order follows the openCypher global sort order" {
    const ascending = [_]Value{
        .{ .map = &.{} },
        .{ .node = 9 },
        .{ .relationship = .{ .src = 0, .dst = 0, .edge_type = "R" } },
        .{ .list = &.{} },
        .{ .string = "a" },
        .{ .boolean = true },
        .{ .int = 1 },
        .{ .null = {} },
    };
    for (ascending[0 .. ascending.len - 1], ascending[1..]) |lower, higher| {
        try testing.expectEqual(std.math.Order.lt, Value.order(lower, higher));
    }
    // Lists: lexicographic, a proper prefix first.
    const one: Value = .{ .int = 1 };
    const two: Value = .{ .int = 2 };
    try testing.expectEqual(std.math.Order.lt, Value.order(.{ .list = &.{one} }, .{ .list = &.{ one, two } }));
    try testing.expectEqual(std.math.Order.gt, Value.order(.{ .list = &.{two} }, .{ .list = &.{ one, two } }));
}
