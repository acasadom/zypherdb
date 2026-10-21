//! The variables in scope at a point of a query, as the planner knows them.
//!
//! A scope may leave out a variable that is bound, never include one that is
//! not: a pattern node in scope is planned as bound (checked, not scanned),
//! while one left out is scanned and then compared with the row's binding,
//! which is slower but gives the same matches.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Scope = struct {
    names: std.StringHashMapUnmanaged(void) = .empty,

    pub fn contains(self: *const Scope, name: []const u8) bool {
        return name.len > 0 and self.names.contains(name);
    }

    /// Adds `name` (an empty name, an anonymous element, is not a variable).
    pub fn add(self: *Scope, allocator: Allocator, name: []const u8) Allocator.Error!void {
        if (name.len > 0) try self.names.put(allocator, name, {});
    }

    pub fn clone(self: *const Scope, allocator: Allocator) Allocator.Error!Scope {
        return .{ .names = try self.names.clone(allocator) };
    }
};
