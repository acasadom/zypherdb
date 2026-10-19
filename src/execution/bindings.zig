//! Variable bindings: the `Value` each query variable is bound to while a
//! query runs — a node or relationship of a pattern, or a projected value.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Wyhash = std.hash.Wyhash;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;
const Relationship = @import("../value.zig").Relationship;

/// Dynamic variable-name -> value bindings, in binding order. A regular type
/// (`eql` + `hash`), so bindings can be deduplicated by `sequence_algorithms`.
pub const Bindings = struct {
    entries: std.ArrayList(struct { name: []const u8, value: Value }),

    pub fn get(self: *const Bindings, name: []const u8) ?Value {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.value;
        }
        return null;
    }

    pub fn put(self: *Bindings, allocator: Allocator, name: []const u8, value: Value) !void {
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

    /// The current extent of the bindings, to `restore` on backtracking.
    pub fn mark(self: *const Bindings) usize {
        return self.entries.items.len;
    }

    /// Unbinds every variable bound since `saved` (a `mark`). Matching only
    /// appends new bindings, so this undoes exactly one search branch.
    pub fn restore(self: *Bindings, saved: usize) void {
        self.entries.shrinkRetainingCapacity(saved);
    }

    /// Binds node variable `name` to `id`, or, if `name` is already bound
    /// (earlier in the pattern or the query), checks that it is that node.
    /// An anonymous node (empty name) always fits.
    pub fn bindNode(self: *Bindings, allocator: Allocator, name: []const u8, id: NodeId) !bool {
        if (name.len == 0) return true;
        if (self.get(name)) |bound| return bound == .node and bound.node == id;
        try self.entries.append(allocator, .{ .name = name, .value = .{ .node = id } });
        return true;
    }

    /// The node `name` is bound to, if it is bound to a node.
    pub fn getNode(self: *const Bindings, name: []const u8) ?NodeId {
        return switch (self.get(name) orelse return null) {
            .node => |id| id,
            else => null,
        };
    }

    /// The relationship `name` is bound to, if it is bound to one.
    pub fn getRelationship(self: *const Bindings, name: []const u8) ?Relationship {
        return switch (self.get(name) orelse return null) {
            .relationship => |relationship| relationship,
            else => null,
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
