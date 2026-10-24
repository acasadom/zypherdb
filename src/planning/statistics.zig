//! The graph's counts as the planner reads them: how many nodes carry a
//! label, how many relationships have a type. Each count is read from
//! storage once per plan and kept, with its value, so the plan records what
//! it was built on (a prepared statement plans again when they drift).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Graph = @import("../storage/graph.zig").Graph;

/// A count the plan used.
pub const Count = struct {
    kind: Kind,
    name: []const u8,
    value: usize,

    pub const Kind = enum { label, edge_type };
};

/// A count storage could not give (a read error): as large as can be, so
/// planning avoids what it would have counted, and estimates say nothing.
pub const unknown: usize = std.math.maxInt(usize);

pub const Statistics = struct {
    graph: *Graph,
    allocator: Allocator,
    /// Every count read so far, in the order first read.
    used: std.ArrayList(Count) = .empty,

    /// How many nodes carry `label`.
    pub fn labelCount(self: *Statistics, label: []const u8) Allocator.Error!usize {
        return self.count(.label, label);
    }

    /// How many relationships have type `edge_type`.
    pub fn edgeTypeCount(self: *Statistics, edge_type: []const u8) Allocator.Error!usize {
        return self.count(.edge_type, edge_type);
    }

    fn count(self: *Statistics, kind: Count.Kind, name: []const u8) Allocator.Error!usize {
        for (self.used.items) |known| {
            if (known.kind == kind and std.mem.eql(u8, known.name, name)) return known.value;
        }
        const value = read(self.graph, kind, name);
        try self.used.append(self.allocator, .{ .kind = kind, .name = name, .value = value });
        return value;
    }
};

/// The count's current value in storage.
pub fn read(graph: *Graph, kind: Count.Kind, name: []const u8) usize {
    return switch (kind) {
        .label => graph.labelCount(name),
        .edge_type => graph.edgeTypeCount(name),
    } catch unknown;
}
