//! Variable bindings: what a query variable is bound to (a node, an edge or a
//! scalar) while a query runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;

const Executor = @import("Executor.zig");

/// Reference to a directed edge, used to bind relationship variables.
pub const EdgeRef = struct {
    src: NodeId,
    dst: NodeId,
    etype: []const u8,
};

pub const Binding = union(enum) {
    node: NodeId,
    edge: EdgeRef,
    value: Value, // scalar bound by a WITH projection
};

/// Dynamic variable-name -> value bindings (nodes and relationships).
pub const Bindings = struct {
    entries: std.ArrayList(struct { name: []const u8, value: Binding }),

    pub fn get(self: *const Bindings, name: []const u8) ?Binding {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }

    pub fn put(self: *Bindings, allocator: Allocator, name: []const u8, value: Binding) !void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                e.value = value;
                return;
            }
        }
        try self.entries.append(allocator, .{ .name = name, .value = value });
    }

    pub fn remove(self: *Bindings, name: []const u8) void {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) {
                _ = self.entries.swapRemove(i);
                return;
            }
        }
    }

    pub fn getNode(self: *const Bindings, name: []const u8) ?NodeId {
        return switch (self.get(name) orelse return null) {
            .node => |id| id,
            .edge, .value => null,
        };
    }

    pub fn getEdge(self: *const Bindings, name: []const u8) ?EdgeRef {
        return switch (self.get(name) orelse return null) {
            .node, .value => null,
            .edge => |e| e,
        };
    }
};

pub fn bindingEq(a: Binding, b: Binding) bool {
    return switch (a) {
        .node => |x| switch (b) {
            .node => |y| x == y,
            else => false,
        },
        .edge => |x| switch (b) {
            .edge => |y| x.src == y.src and x.dst == y.dst and std.mem.eql(u8, x.etype, y.etype),
            else => false,
        },
        .value => |x| switch (b) {
            .value => |y| Value.eql(x, y),
            else => false,
        },
    };
}

pub fn bindingsEq(a: Bindings, b: Bindings) bool {
    if (a.entries.items.len != b.entries.items.len) return false;
    for (a.entries.items) |ea| {
        const eb = b.get(ea.name) orelse return false;
        if (!bindingEq(ea.value, eb)) return false;
    }
    return true;
}

pub fn bindingKeysEq(a: []const Binding, b: []const Binding) bool {
    if (a.len != b.len) return false;
    for (a, b) |av, bv| {
        if (!bindingEq(av, bv)) return false;
    }
    return true;
}
