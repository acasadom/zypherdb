//! Searching a full-text index: a query (`text/query.zig`) against the
//! postings, each matching entity scored with BM25 (as Lucene: k1 = 1.2,
//! b = 0.75).
//!
//! For a term t and an entity d,
//!
//!     idf(t)     = ln(1 + (N - n(t) + 0.5) / (n(t) + 0.5))
//!     score(t,d) = idf(t) * f(t,d) * (k1 + 1) / (f(t,d) + k1 * (1 - b + b * |d| / avg|d|))
//!
//! with N the index's entities, n(t) those with t, f(t,d) t's occurrences in
//! d, and |d| d's length in terms (the property's, for a field clause). A
//! phrase scores like a term whose occurrences are the phrase's and whose idf
//! is the sum of its terms'. A prefix or fuzzy clause scores each entity by
//! its best expansion (a fuzzy one less for each edit). Clauses combine as in
//! Lucene's boolean queries; entities come best first.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("graph.zig").Graph;
const StorageError = @import("key_value_store.zig").StorageError;
const fulltext = @import("fulltext.zig");
const postings = @import("fulltext_postings.zig");
const analyzer = @import("../text/analyzer.zig");
const query = @import("../text/query.zig");
const unicode = @import("../text/unicode.zig");

const k1 = 1.2;
const b = 0.75;

pub const Hit = struct { entity: []const u8, score: f64 };

pub const Error = StorageError || error{InvalidQuery};

/// Entity key -> score.
const Scores = std.StringArrayHashMapUnmanaged(f64);

/// The entities of `definition`'s index that match `text`, best first (ties
/// by entity key), allocated with `arena`. A query that does not parse fails
/// with `error.InvalidQuery`, and `message` says why.
pub fn search(graph: *Graph, arena: Allocator, definition: fulltext.Definition, text: []const u8, message: *[]const u8) Error![]Hit {
    const clauses = try query.parse(arena, text, message);
    const statistics = try postings.readStatistics(graph, arena, definition.name);
    if (statistics.documents == 0) return &.{};
    var searcher = Searcher{
        .graph = graph,
        .arena = arena,
        .definition = definition,
        .analysis = analyzer.Analyzer.fromName(definition.analyzer) orelse .standard,
        .documents = @floatFromInt(statistics.documents),
        .average_length = @as(f64, @floatFromInt(statistics.terms)) / @as(f64, @floatFromInt(statistics.documents)),
        .message = message,
    };
    const scores = try searcher.combine(clauses, null);

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

const Searcher = struct {
    graph: *Graph,
    arena: Allocator,
    definition: fulltext.Definition,
    analysis: analyzer.Analyzer,
    documents: f64,
    average_length: f64,
    message: *[]const u8,

    /// Boolean combination: required clauses all match (optional ones add to
    /// the score), else at least one optional clause; excluded ones remove.
    fn combine(self: *Searcher, list: []const query.Clause, inherited_field: ?u8) Error!Scores {
        var required: ?Scores = null;
        var optional = Scores.empty;
        var excluded = std.StringHashMapUnmanaged(void).empty;
        var has_optional = false;
        for (list) |clause| {
            const field = if (clause.field) |name| try self.fieldOrdinal(name) else inherited_field;
            var scores = try self.evaluate(clause, field);
            if (clause.boost != 1) for (scores.values()) |*score| {
                score.* *= clause.boost;
            };
            switch (clause.occur) {
                .must => required = if (required) |previous| try self.intersect(previous, scores) else scores,
                .should => {
                    has_optional = true;
                    try add(self.arena, &optional, scores);
                },
                .must_not => for (scores.keys()) |entity| try excluded.put(self.arena, entity, {}),
            }
        }
        var result = if (required) |must| must: {
            var must_scores = must;
            for (optional.keys(), optional.values()) |entity, score| {
                if (must_scores.getPtr(entity)) |total| total.* += score;
            }
            break :must must_scores;
        } else if (has_optional) optional else Scores.empty;
        var index: usize = 0;
        while (index < result.count()) {
            if (excluded.contains(result.keys()[index])) result.swapRemoveAt(index) else index += 1;
        }
        return result;
    }

    fn evaluate(self: *Searcher, item: query.Clause, field: ?u8) Error!Scores {
        return switch (item.kind) {
            .term => |text| self.words(text, field),
            .phrase => |text| self.words(text, field),
            .prefix => |text| self.expansions(text, field, null),
            .fuzzy => |fuzzy| self.expansions(fuzzy.text, field, fuzzy.max_edits),
            .group => |inner| self.combine(inner, field),
        };
    }

    /// Text analyzed as the index's: one term, or a phrase of several.
    fn words(self: *Searcher, text: []const u8, field: ?u8) Error!Scores {
        const terms = try analyzer.analyze(self.arena, self.analysis, text);
        if (terms.len == 0) return .empty;
        if (terms.len == 1) return self.termScores(terms[0].text, field, 1);
        return self.phrase(terms, field);
    }

    /// Every term of the index's vocabulary that `text` is a prefix of (no
    /// `max_edits`), or within `max_edits` edits of: each entity keeps its
    /// best expansion's score.
    fn expansions(self: *Searcher, text: []const u8, field: ?u8, max_edits: ?u8) Error!Scores {
        const normalized = try analyzer.normalize(self.arena, text);
        if (normalized.len == 0) return .empty;
        const vocabulary_prefix = try postings.termKey(self.arena, self.definition.name, if (max_edits == null) normalized else "");
        var candidates = std.ArrayList(struct { term: []const u8, weight: f64 }).empty;
        {
            var keys = try self.graph.store.scanPrefix(vocabulary_prefix);
            defer keys.deinit();
            const term_start = vocabulary_prefix.len - (if (max_edits == null) normalized.len else 0);
            while (try keys.next()) |entry| {
                const candidate = entry.key[term_start..];
                var weight: f64 = 1;
                if (max_edits) |edits| {
                    const distance = editDistance(normalized, candidate, edits) orelse continue;
                    weight = 1 - @as(f64, @floatFromInt(distance)) / @as(f64, @floatFromInt(codePointCount(normalized) + 1));
                }
                try candidates.append(self.arena, .{ .term = try self.arena.dupe(u8, candidate), .weight = weight });
            }
        }
        var best = Scores.empty;
        for (candidates.items) |candidate| {
            const scores = try self.termScores(candidate.term, field, candidate.weight);
            for (scores.keys(), scores.values()) |entity, score| {
                const entry = try best.getOrPut(self.arena, entity);
                if (!entry.found_existing or score > entry.value_ptr.*) entry.value_ptr.* = score;
            }
        }
        return best;
    }

    /// BM25 of `term` (an analyzed term), times `weight`.
    fn termScores(self: *Searcher, text: []const u8, field: ?u8, weight: f64) Error!Scores {
        var scores = Scores.empty;
        const idf = try self.inverseFrequency(text);
        if (idf == 0) return scores;
        const Occurrence = struct { entity: []const u8, frequency: usize };
        var occurrences = std.ArrayList(Occurrence).empty;
        {
            const prefix = try postings.postingPrefix(self.arena, self.definition.name, text);
            var keys = try self.graph.store.scanPrefix(prefix);
            defer keys.deinit();
            while (try keys.next()) |entry| {
                var frequency: usize = 0;
                var sections = postings.SectionReader{ .bytes = entry.value };
                while (sections.next()) |section| {
                    if (field) |ordinal| if (section.ordinal != ordinal) continue;
                    frequency += section.positions_bytes.len / 4;
                }
                if (frequency == 0) continue;
                try occurrences.append(self.arena, .{ .entity = try self.arena.dupe(u8, entry.key[prefix.len..]), .frequency = frequency });
            }
        }
        for (occurrences.items) |occurrence| {
            try scores.put(self.arena, occurrence.entity, weight * try self.bm25(idf, occurrence.frequency, occurrence.entity, field));
        }
        return scores;
    }

    /// The entities with `terms` at their relative positions (one after
    /// another, or with the gaps stop words left), in one property.
    fn phrase(self: *Searcher, terms: []const analyzer.Term, field: ?u8) Error!Scores {
        var scores = Scores.empty;
        var idf: f64 = 0;
        for (terms) |t| {
            const term_idf = try self.inverseFrequency(t.text);
            if (term_idf == 0) return scores; // a term nothing has
            idf += term_idf;
        }
        // Candidates: the entities with the first term; each is checked against the others.
        var candidates = std.ArrayList([]const u8).empty;
        {
            const prefix = try postings.postingPrefix(self.arena, self.definition.name, terms[0].text);
            var keys = try self.graph.store.scanPrefix(prefix);
            defer keys.deinit();
            while (try keys.next()) |entry| try candidates.append(self.arena, try self.arena.dupe(u8, entry.key[prefix.len..]));
        }
        candidate: for (candidates.items) |entity| {
            const sections = try self.arena.alloc([]const u8, terms.len);
            for (terms, sections) |t, *section| {
                const raw = (try self.graph.store.get(try postings.postingKey(self.arena, self.definition.name, t.text, entity))) orelse continue :candidate;
                defer self.graph.store.allocator.free(raw);
                section.* = try self.arena.dupe(u8, raw);
            }
            const offsets = try self.arena.alloc(u32, terms.len);
            for (offsets, terms) |*offset, t| offset.* = t.position - terms[0].position;
            const frequency = phraseOccurrences(sections, offsets, field);
            if (frequency == 0) continue;
            try scores.put(self.arena, entity, try self.bm25(idf, frequency, entity, field));
        }
        return scores;
    }

    fn inverseFrequency(self: *Searcher, text: []const u8) Error!f64 {
        const with_term: f64 = @floatFromInt(try postings.termEntities(self.graph, self.arena, self.definition.name, text));
        if (with_term == 0) return 0;
        return @log(1 + (self.documents - with_term + 0.5) / (with_term + 0.5));
    }

    fn bm25(self: *Searcher, idf: f64, frequency: usize, entity: []const u8, field: ?u8) Error!f64 {
        const lengths = try postings.entityLengths(self.graph, self.arena, self.definition.name, entity);
        var length: f64 = 0;
        if (field) |ordinal| {
            if (ordinal < lengths.len) length = @floatFromInt(lengths[ordinal]);
        } else for (lengths) |l| {
            length += @floatFromInt(l);
        }
        const tf: f64 = @floatFromInt(frequency);
        return idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * length / self.average_length));
    }

    fn fieldOrdinal(self: *Searcher, name: []const u8) Error!u8 {
        for (self.definition.properties, 0..) |property, i| if (std.mem.eql(u8, property, name)) return @intCast(i);
        self.message.* = try std.fmt.allocPrint(self.arena, "the index '{s}' has no property '{s}'", .{ self.definition.name, name });
        return error.InvalidQuery;
    }

    fn intersect(self: *Searcher, a: Scores, other: Scores) Allocator.Error!Scores {
        var both = Scores.empty;
        for (a.keys(), a.values()) |entity, score| {
            if (other.get(entity)) |more| try both.put(self.arena, entity, score + more);
        }
        return both;
    }
};

fn add(arena: Allocator, total: *Scores, more: Scores) Allocator.Error!void {
    for (more.keys(), more.values()) |entity, score| {
        const entry = try total.getOrPut(arena, entity);
        entry.value_ptr.* = if (entry.found_existing) entry.value_ptr.* + score else score;
    }
}

/// How many times the phrase occurs: the property sections (one posting per
/// term, in phrase order) where the terms sit at consecutive positions.
fn phraseOccurrences(term_postings: []const []const u8, offsets: []const u32, field: ?u8) usize {
    var occurrences: usize = 0;
    var first = postings.SectionReader{ .bytes = term_postings[0] };
    while (first.next()) |section| {
        if (field) |ordinal| if (section.ordinal != ordinal) continue;
        var i: usize = 0;
        start: while (i + 4 <= section.positions_bytes.len) : (i += 4) {
            const start = std.mem.readInt(u32, section.positions_bytes[i..][0..4], .big);
            for (term_postings[1..], offsets[1..]) |posting, offset| {
                if (!hasPosition(posting, section.ordinal, start + offset)) continue :start;
            }
            occurrences += 1;
        }
    }
    return occurrences;
}

fn hasPosition(posting: []const u8, ordinal: u8, position: u32) bool {
    var sections = postings.SectionReader{ .bytes = posting };
    while (sections.next()) |section| {
        if (section.ordinal != ordinal) continue;
        var i: usize = 0;
        while (i + 4 <= section.positions_bytes.len) : (i += 4) {
            if (std.mem.readInt(u32, section.positions_bytes[i..][0..4], .big) == position) return true;
        }
    }
    return false;
}

/// The Levenshtein distance between `a` and `b` (in code points), if at most
/// `limit`.
fn editDistance(a: []const u8, b_text: []const u8, limit: u8) ?usize {
    var buffer_a: [256]u21 = undefined;
    var buffer_b: [256]u21 = undefined;
    const x = codePoints(a, &buffer_a) orelse return null;
    const y = codePoints(b_text, &buffer_b) orelse return null;
    const longer = @max(x.len, y.len);
    if (longer - @min(x.len, y.len) > limit) return null;
    var previous: [257]usize = undefined;
    var current: [257]usize = undefined;
    for (0..y.len + 1) |j| previous[j] = j;
    for (x, 1..) |cx, i| {
        current[0] = i;
        var row_minimum = current[0];
        for (y, 1..) |cy, j| {
            const substitution = previous[j - 1] + @intFromBool(cx != cy);
            current[j] = @min(substitution, @min(previous[j] + 1, current[j - 1] + 1));
            row_minimum = @min(row_minimum, current[j]);
        }
        if (row_minimum > limit) return null;
        @memcpy(previous[0 .. y.len + 1], current[0 .. y.len + 1]);
    }
    return if (previous[y.len] <= limit) previous[y.len] else null;
}

fn codePoints(text: []const u8, buffer: *[256]u21) ?[]const u21 {
    var iterator = unicode.CodePoints{ .bytes = text };
    var count: usize = 0;
    while (iterator.next()) |code| {
        if (count == buffer.len) return null;
        buffer[count] = code;
        count += 1;
    }
    return buffer[0..count];
}

fn codePointCount(text: []const u8) usize {
    var iterator = unicode.CodePoints{ .bytes = text };
    var count: usize = 0;
    while (iterator.next()) |_| count += 1;
    return count;
}
