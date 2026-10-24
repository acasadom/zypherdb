//! The variables in scope at a point of a query, as the planner knows them:
//! each name and the slot of the row it is bound in. The planner follows
//! exactly what the semantic checks do (a WITH starts a new scope, a
//! comprehension's variable is its own), so every variable a query reads
//! resolves to the slot that holds it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Slot = @import("../execution/bindings.zig").Slot;

pub const Scope = struct {
    names: std.StringHashMapUnmanaged(Slot) = .empty,

    pub fn contains(self: *const Scope, name: []const u8) bool {
        return name.len > 0 and self.names.contains(name);
    }

    /// The slot `name` is bound in, if it is in scope.
    pub fn slotOf(self: *const Scope, name: []const u8) ?Slot {
        if (name.len == 0) return null;
        return self.names.get(name);
    }

    /// Binds `name` to `slot` (an empty name, an anonymous element, is not
    /// a variable).
    pub fn bind(self: *Scope, allocator: Allocator, name: []const u8, slot: Slot) Allocator.Error!void {
        if (name.len > 0) try self.names.put(allocator, name, slot);
    }

    pub fn clone(self: *const Scope, allocator: Allocator) Allocator.Error!Scope {
        return .{ .names = try self.names.clone(allocator) };
    }
};
