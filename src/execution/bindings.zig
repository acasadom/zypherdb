//! Variable bindings: what a query variable is bound to (a node, an edge or a
//! scalar) while a query runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Wyhash = std.hash.Wyhash;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;

/// Reference to a directed edge, used to bind relationship variables.
pub const EdgeRef = struct {
    src: NodeId,
    dst: NodeId,
    edge_type: []const u8,

    pub fn eql(a: EdgeRef, b: EdgeRef) bool {
        return a.src == b.src and a.dst == b.dst and std.mem.eql(u8, a.edge_type, b.edge_type);
    }

    pub fn hash(self: EdgeRef, hasher: *Wyhash) void {
        hasher.update(std.mem.asBytes(&self.src));
        hasher.update(std.mem.asBytes(&self.dst));
        hasher.update(self.edge_type);
    }
};

/// What one variable is bound to. A regular type (`eql` + `hash`), so
/// bindings can be deduplicated and grouped by `sequence_algorithms`.
pub const Binding = union(enum) {
    node: NodeId,
    edge: EdgeRef,
    value: Value, // scalar bound by a WITH projection

    pub fn eql(a: Binding, b: Binding) bool {
        return switch (a) {
            .node => |x| b == .node and x == b.node,
            .edge => |x| b == .edge and x.eql(b.edge),
            .value => |x| b == .value and x.eql(b.value),
        };
    }

    pub fn hash(self: Binding, hasher: *Wyhash) void {
        hasher.update(&.{@backingInt(self)});
        switch (self) {
            .node => |id| hasher.update(std.mem.asBytes(&id)),
            .edge => |edge| edge.hash(hasher),
            .value => |value| value.hash(hasher),
        }
    }
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

    /// Equal when both bind the same names, in the same order, to equal
    /// values (rows of one WITH projection always share their name order).
    pub fn eql(a: Bindings, b: Bindings) bool {
        if (a.entries.items.len != b.entries.items.len) return false;
        for (a.entries.items, b.entries.items) |x, y| {
            if (!std.mem.eql(u8, x.name, y.name) or !x.value.eql(y.value)) return false;
        }
        return true;
    }

    pub fn hash(self: Bindings, hasher: *Wyhash) void {
        hasher.update(std.mem.asBytes(&self.entries.items.len));
        for (self.entries.items) |entry| {
            hasher.update(entry.name);
            entry.value.hash(hasher);
        }
    }
};
