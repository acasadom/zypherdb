//! Variable bindings: the `Value` each query variable is bound to while a
//! query runs — a node or relationship of a pattern, or a projected value.
//!
//! The planner gives every variable of a query a slot (`Plan.slot_of`), so
//! a row is a fixed array, one value per slot, and reading a variable is an
//! index. Binding records what it changed (the trail), so a search branch is
//! undone exactly by `restore`ing to a `mark`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const NodeId = @import("../storage/graph.zig").NodeId;
const Value = @import("../value.zig").Value;
const Relationship = @import("../value.zig").Relationship;
const sequence_algorithms = @import("../sequence_algorithms.zig");

/// A variable's place in a row.
pub const Slot = u32;

/// The slot of no variable: an anonymous pattern element, or a name the
/// planner did not resolve (reading it fails as an unknown variable).
pub const no_slot: Slot = std.math.maxInt(Slot);

pub const Bindings = struct {
    values: []Value,
    bound: []bool,
    /// What each binding since the row was made changed, to undo it: the
    /// slot, and whether it held a value then (kept in `overwritten`).
    trail: std.ArrayList(Undo) = .empty,
    overwritten: std.ArrayList(Value) = .empty,

    const Undo = struct { slot: Slot, overwrote: bool };

    /// A row of `width` slots, none bound.
    pub fn init(allocator: Allocator, width: usize) Allocator.Error!Bindings {
        const bound = try allocator.alloc(bool, width);
        @memset(bound, false);
        return .{ .values = try allocator.alloc(Value, width), .bound = bound };
    }

    /// A copy whose bindings change independently (with no trail).
    pub fn copy(self: *const Bindings, allocator: Allocator) Allocator.Error!Bindings {
        return .{ .values = try allocator.dupe(Value, self.values), .bound = try allocator.dupe(bool, self.bound) };
    }

    pub fn get(self: *const Bindings, slot: Slot) ?Value {
        if (slot >= self.values.len or !self.bound[slot]) return null;
        return self.values[slot];
    }

    /// Binds `slot` to `value`, whatever it was bound to (undone by `restore`).
    pub fn put(self: *Bindings, allocator: Allocator, slot: Slot, value: Value) Allocator.Error!void {
        if (slot == no_slot) return;
        if (self.bound[slot]) {
            try self.overwritten.append(allocator, self.values[slot]);
            try self.trail.append(allocator, .{ .slot = slot, .overwrote = true });
            self.values[slot] = value;
            return;
        }
        try self.bindFree(allocator, slot, value);
    }

    /// Binds `slot`, which is not bound.
    fn bindFree(self: *Bindings, allocator: Allocator, slot: Slot, value: Value) Allocator.Error!void {
        try self.trail.append(allocator, .{ .slot = slot, .overwrote = false });
        self.values[slot] = value;
        self.bound[slot] = true;
    }

    /// The current extent of the bindings, to `restore` on backtracking.
    pub fn mark(self: *const Bindings) usize {
        return self.trail.items.len;
    }

    /// Undoes every binding made since `saved` (a `mark`), latest first.
    pub fn restore(self: *Bindings, saved: usize) void {
        while (self.trail.items.len > saved) {
            const undo = self.trail.pop().?;
            if (undo.overwrote) {
                self.values[undo.slot] = self.overwritten.pop().?;
            } else self.bound[undo.slot] = false;
        }
    }

    /// Binds node variable `slot` to `id`, or, if it is bound already
    /// (earlier in the pattern or the query), checks that it is that node.
    /// An anonymous node (no slot) always fits.
    pub fn bindNode(self: *Bindings, allocator: Allocator, slot: Slot, id: NodeId) Allocator.Error!bool {
        if (slot == no_slot) return true;
        if (self.bound[slot]) return self.values[slot] == .node and self.values[slot].node == id;
        try self.bindFree(allocator, slot, .{ .node = id });
        return true;
    }

    /// Binds `slot` to `value`, or, if it is bound already, checks that it
    /// is bound to an equal value. No slot always fits.
    pub fn bindValue(self: *Bindings, allocator: Allocator, slot: Slot, value: Value) Allocator.Error!bool {
        if (slot == no_slot) return true;
        if (self.bound[slot]) return self.values[slot].eql(value);
        try self.bindFree(allocator, slot, value);
        return true;
    }

    /// The node `slot` is bound to, if it is bound to a node.
    pub fn getNode(self: *const Bindings, slot: Slot) ?NodeId {
        return switch (self.get(slot) orelse return null) {
            .node => |id| id,
            else => null,
        };
    }

    /// The relationship `slot` is bound to, if it is bound to one.
    pub fn getRelationship(self: *const Bindings, slot: Slot) ?Relationship {
        return switch (self.get(slot) orelse return null) {
            .relationship => |relationship| relationship,
            else => null,
        };
    }
};

/// Rows equal in some slots (a projection's): a std.HashMap context, so
/// rows can be deduplicated by them (`sequence_algorithms.removeDuplicates`).
pub const SlotsContext = struct {
    slots: []const Slot,

    pub fn hash(self: SlotsContext, row: Bindings) u64 {
        var result = sequence_algorithms.hashWord(self.slots.len);
        for (self.slots) |slot| {
            const value = row.get(slot) orelse Value.null;
            result = sequence_algorithms.combineHashes(result, value.hash());
        }
        return result;
    }

    pub fn eql(self: SlotsContext, a: Bindings, b: Bindings) bool {
        for (self.slots) |slot| {
            const x = a.get(slot) orelse Value.null;
            const y = b.get(slot) orelse Value.null;
            if (!x.eql(y)) return false;
        }
        return true;
    }
};
