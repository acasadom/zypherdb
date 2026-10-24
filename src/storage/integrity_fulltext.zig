//! The integrity checker's part for full-text indexes (integrity.zig): the
//! postings an index must hold, rebuilt from its entities' properties as
//! fulltext_postings.zig writes them.
//!
//! A posting's sections (one per property) are kept in the order they were
//! written, which depends on the history of the entity; the checker compares
//! them sorted by property (`canonicalPosting`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Checker = @import("integrity.zig").Checker;
const StorageError = @import("key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const NodeRecord = @import("node_record.zig").NodeRecord;
const value_encoding = @import("value_encoding.zig");
const fulltext = @import("fulltext.zig");
const fulltext_postings = @import("fulltext_postings.zig");
const analyzer = @import("../text/analyzer.zig");

/// Records the keys full-text index `definition` must hold: a posting per
/// term and entity, each entity's lengths, each term's entity count, and the
/// index's totals.
pub fn expectIndex(checker: *Checker, definition: fulltext.Definition) StorageError!void {
    const arena = checker.arena;
    var index = Index{ .checker = checker, .definition = definition };
    const values = try arena.alloc(?Value, definition.properties.len);
    switch (definition.entity) {
        .nodes => for (checker.nodes.keys(), checker.nodes.values()) |id, record| {
            if (!hasAnyLabel(record, definition.labels_or_types)) continue;
            for (values, definition.properties) |*value, property| {
                value.* = if (record.property(property)) |encoded| try value_encoding.decodeValue(encoded, arena) else null;
            }
            try index.addEntity(id, values);
        },
        .relationships => for (checker.relationships.keys(), checker.relationships.values()) |id, relationship| {
            if (!contains(definition.labels_or_types, relationship.edge_type)) continue;
            for (values, definition.properties) |*value, property| {
                value.* = null;
                for (relationship.properties.items) |stored| if (std.mem.eql(u8, stored.name, property)) {
                    value.* = try value_encoding.decodeValue(stored.encoded, arena);
                };
            }
            try index.addEntity(id, values);
        },
    }
    try index.finish();
}

const Index = struct {
    checker: *Checker,
    definition: fulltext.Definition,
    /// How many entities have each term.
    term_entities: std.StringArrayHashMapUnmanaged(u64) = .empty,
    documents: u64 = 0,
    terms: u64 = 0,

    /// The keys of one entity whose properties hold `values` (in the
    /// definition's order; null: absent).
    fn addEntity(self: *Index, id: u64, values: []const ?Value) StorageError!void {
        const arena = self.checker.arena;
        const analysis = analyzer.Analyzer.fromName(self.definition.analyzer) orelse .standard;
        const entity = fulltext_postings.entityOf(id);
        const lengths = try arena.alloc(u32, values.len);
        @memset(lengths, 0);
        // Each term's sections, one per property, in property order.
        var postings = std.StringArrayHashMapUnmanaged(std.ArrayList(u8)).empty;
        for (values, 0..) |value, ordinal| {
            const text = try fulltext_postings.textOf(arena, value) orelse continue;
            const terms = try analyzer.analyze(arena, analysis, text);
            lengths[ordinal] = @intCast(terms.len);
            var positions = std.StringArrayHashMapUnmanaged(std.ArrayList(u32)).empty;
            for (terms) |term| {
                const entry = try positions.getOrPut(arena, term.text);
                if (!entry.found_existing) entry.value_ptr.* = .empty;
                try entry.value_ptr.append(arena, term.position);
            }
            for (positions.keys(), positions.values()) |term, term_positions| {
                const posting = try postings.getOrPut(arena, term);
                if (!posting.found_existing) posting.value_ptr.* = .empty;
                try appendSection(posting.value_ptr, arena, @intCast(ordinal), term_positions.items);
            }
        }
        for (postings.keys(), postings.values()) |term, sections| {
            try self.checker.expect(try fulltext_postings.postingKey(arena, self.definition.name, term, &entity), sections.items);
            const count = try self.term_entities.getOrPut(arena, term);
            count.value_ptr.* = if (count.found_existing) count.value_ptr.* + 1 else 1;
        }
        var total: u64 = 0;
        for (lengths) |length| total += length;
        if (total == 0) return;
        const encoded = try arena.alloc(u8, lengths.len * 4);
        for (lengths, 0..) |length, i| std.mem.writeInt(u32, encoded[i * 4 ..][0..4], length, .big);
        const document_key = try std.mem.concat(arena, u8, &.{ try fulltext_postings.indexPrefix(arena, fulltext_postings.document_marker, self.definition.name), &entity });
        try self.checker.expect(document_key, encoded);
        self.documents += 1;
        self.terms += total;
    }

    fn finish(self: *Index) StorageError!void {
        const arena = self.checker.arena;
        for (self.term_entities.keys(), self.term_entities.values()) |term, count| {
            try self.checker.expect(try fulltext_postings.termKey(arena, self.definition.name, term), try self.checker.countBytes(count));
        }
        // Totals of nothing may stay, at zero (a counter).
        if (self.documents == 0 and self.terms == 0) return;
        const totals = try arena.alloc(u8, 16);
        std.mem.writeInt(u64, totals[0..8], self.documents, .big);
        std.mem.writeInt(u64, totals[8..16], self.terms, .big);
        try self.checker.expect(try fulltext_postings.indexPrefix(arena, fulltext_postings.statistics_marker, self.definition.name), totals);
    }
};

/// A section of a posting: the property's ordinal (u8), a count (u16), the
/// positions (u32 each).
fn appendSection(sections: *std.ArrayList(u8), arena: Allocator, ordinal: u8, positions: []const u32) Allocator.Error!void {
    try sections.append(arena, ordinal);
    var buffer: [4]u8 = undefined;
    std.mem.writeInt(u16, buffer[0..2], @intCast(positions.len), .big);
    try sections.appendSlice(arena, buffer[0..2]);
    for (positions) |position| {
        std.mem.writeInt(u32, &buffer, position, .big);
        try sections.appendSlice(arena, &buffer);
    }
}

/// A stored posting with its sections sorted by property, or null if it is
/// malformed (truncated, empty, a property twice, no positions).
pub fn canonicalPosting(arena: Allocator, posting: []const u8) Allocator.Error!?[]const u8 {
    const Section = struct { ordinal: u8, bytes: []const u8 };
    var sections = std.ArrayList(Section).empty;
    var position: usize = 0;
    while (position < posting.len) {
        if (posting.len - position < 3) return null;
        const count = std.mem.readInt(u16, posting[position + 1 ..][0..2], .big);
        const end = position + 3 + @as(usize, count) * 4;
        if (count == 0 or end > posting.len) return null;
        try sections.append(arena, .{ .ordinal = posting[position], .bytes = posting[position..end] });
        position = end;
    }
    if (sections.items.len == 0) return null;
    std.mem.sort(Section, sections.items, {}, struct {
        fn lessThan(_: void, a: Section, b: Section) bool {
            return a.ordinal < b.ordinal;
        }
    }.lessThan);
    var canonical = std.ArrayList(u8).empty;
    for (sections.items, 0..) |section, i| {
        if (i > 0 and sections.items[i - 1].ordinal == section.ordinal) return null;
        try canonical.appendSlice(arena, section.bytes);
    }
    return canonical.items;
}

fn hasAnyLabel(record: NodeRecord, labels: []const []const u8) bool {
    for (labels) |label| if (record.hasLabel(label)) return true;
    return false;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

test "a posting's sections are compared in property order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Property 1 (one position, 7), then property 0 (one position, 2).
    const stored = "\x01\x00\x01\x00\x00\x00\x07" ++ "\x00\x00\x01\x00\x00\x00\x02";
    const canonical = (try canonicalPosting(arena.allocator(), stored)).?;
    try std.testing.expectEqualStrings("\x00\x00\x01\x00\x00\x00\x02" ++ "\x01\x00\x01\x00\x00\x00\x07", canonical);
    try std.testing.expectEqual(@as(?[]const u8, null), try canonicalPosting(arena.allocator(), "\x00\x00\x02\x00\x00\x00\x02"));
}
