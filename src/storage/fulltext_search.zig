//! Searching a full-text index: a query's terms against the postings, each
//! matching entity scored with BM25 (as Lucene: k1 = 1.2, b = 0.75).
//!
//! For each query term t and entity d,
//!
//!     idf(t)     = ln(1 + (N - n(t) + 0.5) / (n(t) + 0.5))
//!     score(t,d) = idf(t) * f(t,d) * (k1 + 1) / (f(t,d) + k1 * (1 - b + b * |d| / avg|d|))
//!
//! with N the index's entities, n(t) those with t, f(t,d) t's occurrences in
//! d, and |d| d's length in terms. An entity's score is the sum over the
//! query's terms; entities come best first.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("graph.zig").Graph;
const StorageError = @import("key_value_store.zig").StorageError;
const fulltext = @import("fulltext.zig");
const postings = @import("fulltext_postings.zig");
const analyzer = @import("../text/analyzer.zig");

const k1 = 1.2;
const b = 0.75;

pub const Hit = struct { entity: []const u8, score: f64 };

/// The entities of `definition`'s index that match `query`, best first (ties
/// by entity key), allocated with `arena`.
pub fn search(graph: *Graph, arena: Allocator, definition: fulltext.Definition, query: []const u8) StorageError![]Hit {
    const analysis = analyzer.Analyzer.fromName(definition.analyzer) orelse .standard;
    const terms = try analyzer.analyze(arena, analysis, query);
    const statistics = try postings.readStatistics(graph, arena, definition.name);
    if (statistics.documents == 0) return &.{};
    const documents: f64 = @floatFromInt(statistics.documents);
    const average_length = @as(f64, @floatFromInt(statistics.terms)) / documents;

    var scores = std.StringArrayHashMapUnmanaged(f64).empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    for (terms) |term| {
        // A term twice in the query counts once.
        if ((try seen.getOrPut(arena, term.text)).found_existing) continue;
        const with_term: f64 = @floatFromInt(try postings.termEntities(graph, arena, definition.name, term.text));
        if (with_term == 0) continue;
        const idf = @log(1 + (documents - with_term + 0.5) / (with_term + 0.5));

        // Collect first: each posting's entity length is a read of its own.
        const Occurrence = struct { entity: []const u8, frequency: f64 };
        var occurrences = std.ArrayList(Occurrence).empty;
        {
            const prefix = try postings.postingPrefix(arena, definition.name, term.text);
            var keys = try graph.store.scanPrefix(prefix);
            defer keys.deinit();
            while (try keys.next()) |entry| {
                var frequency: usize = 0;
                var sections = postings.SectionReader{ .bytes = entry.value };
                while (sections.next()) |section| frequency += section.positions_bytes.len / 4;
                try occurrences.append(arena, .{ .entity = try arena.dupe(u8, entry.key[prefix.len..]), .frequency = @floatFromInt(frequency) });
            }
        }
        for (occurrences.items) |occurrence| {
            const length: f64 = @floatFromInt(try postings.entityLength(graph, arena, definition.name, occurrence.entity));
            const tf = occurrence.frequency;
            const score = idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * length / average_length));
            const entry = try scores.getOrPut(arena, occurrence.entity);
            entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + score else score;
        }
    }

    const hits = try arena.alloc(Hit, scores.count());
    for (hits, scores.keys(), scores.values()) |*hit, entity, score| hit.* = .{ .entity = entity, .score = score };
    std.mem.sort(Hit, hits, {}, struct {
        fn better(_: void, x: Hit, y: Hit) bool {
            if (x.score != y.score) return x.score > y.score;
            return std.mem.order(u8, x.entity, y.entity) == .lt;
        }
    }.better);
    return hits;
}
