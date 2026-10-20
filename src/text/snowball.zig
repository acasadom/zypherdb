//! What Snowball stemmers run on: the word, a cursor, limits, and a slice,
//! with the operations Snowball's algorithms are written in. The stemmers
//! (`stem_english.zig`, `stem_spanish.zig`) are the published algorithms
//! (https://snowballstem.org, BSD license), translated by hand onto this:
//! each routine follows its definition in the algorithm's .sbl source.
//!
//! The word is a sequence of code points `p[0..l]`. Forward mode moves the
//! cursor `c` right, up to the limit `l`; backward mode moves it left, down
//! to `lb`. `bra` and `ket` delimit the slice that `sliceFrom` replaces.
//! Operations that fail leave the cursor where it was, as in Snowball.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Env = struct {
    p: std.ArrayList(u21),
    allocator: Allocator,
    c: usize = 0,
    l: usize,
    lb: usize = 0,
    bra: usize = 0,
    ket: usize,

    pub fn init(allocator: Allocator, initial: []const u21) Allocator.Error!Env {
        var p = std.ArrayList(u21).empty;
        try p.appendSlice(allocator, initial);
        return .{ .p = p, .allocator = allocator, .l = initial.len, .ket = initial.len };
    }

    pub fn word(self: *const Env) []const u21 {
        return self.p.items[0..self.l];
    }

    // --- Forward mode ------------------------------------------------------------

    /// `s` at the cursor: past it.
    pub fn eq(self: *Env, s: []const u21) bool {
        if (self.l - self.c < s.len or !std.mem.eql(u21, self.p.items[self.c..][0..s.len], s)) return false;
        self.c += s.len;
        return true;
    }

    pub fn inGrouping(self: *Env, group: []const u21) bool {
        if (self.c >= self.l or !member(group, self.p.items[self.c])) return false;
        self.c += 1;
        return true;
    }

    pub fn outGrouping(self: *Env, group: []const u21) bool {
        if (self.c >= self.l or member(group, self.p.items[self.c])) return false;
        self.c += 1;
        return true;
    }

    /// `gopast group`: to just past the next code point in `group`.
    pub fn gopastIn(self: *Env, group: []const u21) bool {
        var c = self.c;
        while (c < self.l) {
            c += 1;
            if (member(group, self.p.items[c - 1])) {
                self.c = c;
                return true;
            }
        }
        return false;
    }

    /// `gopast non-group`: to just past the next code point not in `group`.
    pub fn gopastOut(self: *Env, group: []const u21) bool {
        var c = self.c;
        while (c < self.l) {
            c += 1;
            if (!member(group, self.p.items[c - 1])) {
                self.c = c;
                return true;
            }
        }
        return false;
    }

    /// The longest string of `strings` at the cursor: past it, and its index.
    pub fn findAmong(self: *Env, strings: []const []const u21) ?usize {
        var best: ?usize = null;
        for (strings, 0..) |s, i| {
            if (self.l - self.c < s.len or !std.mem.eql(u21, self.p.items[self.c..][0..s.len], s)) continue;
            if (best == null or s.len > strings[best.?].len) best = i;
        }
        if (best) |i| self.c += strings[i].len;
        return best;
    }

    // --- Backward mode -----------------------------------------------------------

    /// `s` ending at the cursor: before it.
    pub fn eqB(self: *Env, s: []const u21) bool {
        if (self.c - self.lb < s.len or !std.mem.eql(u21, self.p.items[self.c - s.len .. self.c], s)) return false;
        self.c -= s.len;
        return true;
    }

    pub fn inGroupingB(self: *Env, group: []const u21) bool {
        if (self.c <= self.lb or !member(group, self.p.items[self.c - 1])) return false;
        self.c -= 1;
        return true;
    }

    pub fn outGroupingB(self: *Env, group: []const u21) bool {
        if (self.c <= self.lb or member(group, self.p.items[self.c - 1])) return false;
        self.c -= 1;
        return true;
    }

    /// `gopast group`, backwards: to just before the previous code point in `group`.
    pub fn gopastInB(self: *Env, group: []const u21) bool {
        var c = self.c;
        while (c > self.lb) {
            c -= 1;
            if (member(group, self.p.items[c])) {
                self.c = c;
                return true;
            }
        }
        return false;
    }

    /// The longest string of `strings` ending at the cursor: before it, and its index.
    pub fn findAmongB(self: *Env, strings: []const []const u21) ?usize {
        var best: ?usize = null;
        for (strings, 0..) |s, i| {
            if (self.c - self.lb < s.len or !std.mem.eql(u21, self.p.items[self.c - s.len .. self.c], s)) continue;
            if (best == null or s.len > strings[best.?].len) best = i;
        }
        if (best) |i| self.c -= strings[i].len;
        return best;
    }

    /// `hop n` backwards.
    pub fn hopB(self: *Env, n: usize) bool {
        if (self.c - self.lb < n) return false;
        self.c -= n;
        return true;
    }

    // --- Changing the word --------------------------------------------------------

    /// Replaces the slice `bra..ket` with `s`, keeping the cursor and limit
    /// on the same text (as Snowball's `slice_from`).
    pub fn sliceFrom(self: *Env, s: []const u21) Allocator.Error!void {
        try self.replace(self.bra, self.ket, s);
        self.ket = self.bra + s.len;
    }

    pub fn sliceDel(self: *Env) Allocator.Error!void {
        try self.sliceFrom(&.{});
    }

    fn replace(self: *Env, from: usize, to: usize, s: []const u21) Allocator.Error!void {
        try self.p.replaceRange(self.allocator, from, to - from, s);
        const adjustment = @as(isize, @intCast(s.len)) - @as(isize, @intCast(to - from));
        self.l = @intCast(@as(isize, @intCast(self.l)) + adjustment);
        if (self.c >= to) {
            self.c = @intCast(@as(isize, @intCast(self.c)) + adjustment);
        } else if (self.c > from) {
            self.c = from;
        }
    }
};

fn member(group: []const u21, code: u21) bool {
    return std.mem.indexOfScalar(u21, group, code) != null;
}

/// A UTF-8 literal as code points, at compile time.
pub fn u(comptime text: []const u8) []const u21 {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        var codes: [text.len]u21 = undefined;
        var count = 0;
        const view = std.unicode.Utf8View.initComptime(text);
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |code| {
            codes[count] = code;
            count += 1;
        }
        const result = codes[0..count].*;
        break :blk &result;
    };
}

/// UTF-8 literals as code points, at compile time.
pub fn us(comptime texts: []const []const u8) []const []const u21 {
    return comptime blk: {
        var list: [texts.len][]const u21 = undefined;
        for (texts, 0..) |text, i| list[i] = u(text);
        const result = list;
        break :blk &result;
    };
}
