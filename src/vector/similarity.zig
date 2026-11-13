//! Vector similarity: the distances a vector index orders by, and the
//! scores it and the functions `vector.similarity.cosine` /
//! `vector.similarity.euclidean` return (as Neo4j scores them, in [0, 1],
//! higher is closer).
//!
//! An index keeps its vectors as f32 and, under cosine, normalized to
//! length 1, so that its distance is `1 - a·b`. Under euclidean its
//! distance is the squared distance. Both are O(dimensions).

const std = @import("std");

pub const Similarity = enum(u8) {
    cosine = 0,
    euclidean = 1,

    pub fn name(self: Similarity) []const u8 {
        return @tagName(self);
    }

    pub fn parse(text: []const u8) ?Similarity {
        inline for (@typeInfo(Similarity).@"enum".field_names) |field_name| {
            if (std.ascii.eqlIgnoreCase(text, field_name)) return @field(Similarity, field_name);
        }
        return null;
    }
};

/// The most dimensions a vector index takes (as FalkorDB and Neo4j).
pub const max_dimensions = 4096;

/// Lanes of the SIMD loops.
const lanes = std.simd.suggestVectorLength(f32) orelse 4;
const Lanes = @Vector(lanes, f32);
/// Sums the SIMD loops keep apart.
const chains = 4;

/// The distance between two vectors of an index (or a query prepared by
/// `prepare`), of the same length.
pub fn distance(similarity: Similarity, a: []const f32, b: []const f32) f32 {
    return switch (similarity) {
        .cosine => 1 - dot(a, b),
        .euclidean => squaredDistance(a, b),
    };
}

/// The score of a distance `distance` gives: cosine (1 + cos) / 2,
/// euclidean 1 / (1 + d²).
pub fn score(similarity: Similarity, from_distance: f32) f64 {
    const d: f64 = from_distance;
    return switch (similarity) {
        .cosine => std.math.clamp((2 - d) / 2, 0, 1),
        .euclidean => 1 / (1 + d),
    };
}

/// Why a list of numbers cannot be a vector of an index.
pub const Invalid = enum {
    not_finite,
    zero_under_cosine,

    pub fn message(self: Invalid) []const u8 {
        return switch (self) {
            .not_finite => "has an element that is NaN or infinite",
            .zero_under_cosine => "is all zeros, which has no direction for cosine",
        };
    }
};

/// Writes `numbers` into `out` as an index keeps them (f32, normalized
/// under cosine), or says why they cannot be. An f64 out of the f32 range
/// is not finite.
pub fn prepare(similarity: Similarity, numbers: []const f64, out: []f32) ?Invalid {
    std.debug.assert(numbers.len == out.len);
    for (numbers, out) |number, *element| {
        element.* = @floatCast(number);
        if (!std.math.isFinite(element.*)) return .not_finite;
    }
    if (similarity == .cosine) {
        const length = @sqrt(dot(out, out));
        if (length == 0 or !std.math.isFinite(length)) return .zero_under_cosine;
        for (out) |*element| element.* /= length;
    }
    return null;
}

/// a·b in f32.
pub fn dot(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    // Independent sums, so that one multiply-add need not wait for the last.
    var sums: [chains]Lanes = @splat(@splat(0));
    var i: usize = 0;
    while (i + chains * lanes <= a.len) : (i += chains * lanes) {
        inline for (&sums, 0..) |*chain_sum, chain| {
            const x: Lanes = a[i + chain * lanes ..][0..lanes].*;
            const y: Lanes = b[i + chain * lanes ..][0..lanes].*;
            chain_sum.* += x * y;
        }
    }
    while (i + lanes <= a.len) : (i += lanes) {
        const x: Lanes = a[i..][0..lanes].*;
        const y: Lanes = b[i..][0..lanes].*;
        sums[0] += x * y;
    }
    var sum = @reduce(.Add, (sums[0] + sums[1]) + (sums[2] + sums[3]));
    while (i < a.len) : (i += 1) sum += a[i] * b[i];
    return sum;
}

/// |a - b|² in f32.
pub fn squaredDistance(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var sums: [chains]Lanes = @splat(@splat(0));
    var i: usize = 0;
    while (i + chains * lanes <= a.len) : (i += chains * lanes) {
        inline for (&sums, 0..) |*chain_sum, chain| {
            const x: Lanes = a[i + chain * lanes ..][0..lanes].*;
            const y: Lanes = b[i + chain * lanes ..][0..lanes].*;
            const difference = x - y;
            chain_sum.* += difference * difference;
        }
    }
    while (i + lanes <= a.len) : (i += lanes) {
        const x: Lanes = a[i..][0..lanes].*;
        const y: Lanes = b[i..][0..lanes].*;
        const difference = x - y;
        sums[0] += difference * difference;
    }
    var sum = @reduce(.Add, (sums[0] + sums[1]) + (sums[2] + sums[3]));
    while (i < a.len) : (i += 1) sum += (a[i] - b[i]) * (a[i] - b[i]);
    return sum;
}

/// The score of two lists of numbers of the same length, in f64, for
/// `vector.similarity.*`: null under cosine when one of them is all zeros.
pub fn scoreOfNumbers(similarity: Similarity, a: []const f64, b: []const f64) ?f64 {
    std.debug.assert(a.len == b.len);
    switch (similarity) {
        .cosine => {
            var ab: f64 = 0;
            var aa: f64 = 0;
            var bb: f64 = 0;
            for (a, b) |x, y| {
                ab += x * y;
                aa += x * x;
                bb += y * y;
            }
            if (aa == 0 or bb == 0) return null;
            const cosine = std.math.clamp(ab / (@sqrt(aa) * @sqrt(bb)), -1, 1);
            return (1 + cosine) / 2;
        },
        .euclidean => {
            var squared: f64 = 0;
            for (a, b) |x, y| squared += (x - y) * (x - y);
            return 1 / (1 + squared);
        },
    }
}
