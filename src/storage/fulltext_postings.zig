//! The postings of full-text indexes, and how changes to the graph keep them
//! current.
//!
//! An entity is a node or a relationship: its 8-byte id.
//! Each indexed property is analyzed on its own; its terms and their
//! positions are kept per property, so changing one property touches only
//! the terms of its old and new text. Keys, after a one-byte marker and the
//! index's name and a 0x00:
//!
//!     w  term 0x00 entity  the term's occurrences in the entity: per property,
//!                          its ordinal (u8), a count (u16), positions (u32 each)
//!     W  entity            the entity's length in terms, per property (u32 each)
//!     v  term              how many entities have the term (u64)
//!     V  (nothing)         entities and terms in the index (u64, u64)
//!
//! A property is indexed when it holds a string, or a list of strings (read
//! as one text).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Graph = @import("graph.zig").Graph;
const NodeId = @import("graph.zig").NodeId;
const RelationshipId = @import("graph.zig").RelationshipId;
const NodeRecord = @import("node_record.zig").NodeRecord;
const StorageError = @import("key_value_store.zig").StorageError;
const Value = @import("../value.zig").Value;
const value_encoding = @import("value_encoding.zig");
const fulltext = @import("fulltext.zig");
const analyzer = @import("../text/analyzer.zig");

pub const posting_marker: u8 = 'w';
pub const document_marker: u8 = 'W';
pub const term_marker: u8 = 'v';
pub const statistics_marker: u8 = 'V';

/// The key of an entity in postings: a node's or a relationship's id (an
/// index holds one kind or the other).
pub fn entityOf(id: u64) [8]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, id, .big);
    return bytes;
}

/// The text an indexed property holds: a string, or a list's strings; null
/// for any other value.
pub fn textOf(allocator: Allocator, value: ?Value) Allocator.Error!?[]const u8 {
    const v = value orelse return null;
    switch (v) {
        .string => |s| return s,
        .list => |items| {
            var text = std.ArrayList(u8).empty;
            for (items) |item| if (item == .string) {
                if (text.items.len > 0) try text.append(allocator, ' ');
                try text.appendSlice(allocator, item.string);
            };
            return if (text.items.len > 0) text.items else null;
        },
        else => return null,
    }
}

// --- Keeping the indexes current ----------------------------------------------

/// After node `id` changed from `old` to `new` (an empty record: it did not or
/// no longer exists), updates every node index the change concerns.
/// `changed` names the one property that changed, or is null when labels did.
pub fn nodeChanged(graph: *Graph, id: NodeId, old: NodeRecord, new: NodeRecord, changed: ?[]const u8) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return; // no index was ever made
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const entity = entityOf(id);
    for (try fulltext.allOfKind(graph, arena, .fulltext)) |definition| {
        if (definition.entity != .nodes) continue;
        const was_in = hasAnyLabel(old, definition.labels_or_types);
        const is_in = hasAnyLabel(new, definition.labels_or_types);
        if (!was_in and !is_in) continue;
        for (definition.properties, 0..) |property, ordinal| {
            if (changed) |name| if (was_in == is_in and !std.mem.eql(u8, name, property)) continue;
            const old_text = if (was_in) try textOf(arena, try storedValue(arena, old, property)) else null;
            const new_text = if (is_in) try textOf(arena, try storedValue(arena, new, property)) else null;
            try updateProperty(graph, arena, definition, &entity, @intCast(ordinal), old_text, new_text);
        }
    }
}

/// After the property `name` of relationship `id` (of type `edge_type`)
/// changed from `old` to `new` (null: absent), updates the relationship
/// indexes it concerns.
pub fn relationshipPropertyChanged(graph: *Graph, id: RelationshipId, edge_type: []const u8, name: []const u8, old: ?Value, new: ?Value) StorageError!void {
    if (try fulltext.schemaVersion(graph) == 0) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    for (try fulltext.allOfKind(graph, arena, .fulltext)) |definition| {
        if (definition.entity != .relationships or !contains(definition.labels_or_types, edge_type)) continue;
        for (definition.properties, 0..) |property, ordinal| {
            if (!std.mem.eql(u8, property, name)) continue;
            const entity = entityOf(id);
            try updateProperty(graph, arena, definition, &entity, @intCast(ordinal), try textOf(arena, old), try textOf(arena, new));
        }
    }
}

/// Indexes what the graph already holds for a new index.
pub fn populate(graph: *Graph, definition: fulltext.Definition) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    switch (definition.entity) {
        .nodes => {
            // Collect first: indexing writes, and no scan may be open across writes.
            var ids = std.AutoArrayHashMapUnmanaged(NodeId, void).empty;
            for (definition.labels_or_types) |label| {
                var nodes = try graph.nodesWithLabel(label);
                defer nodes.deinit();
                while (try nodes.next()) |id| try ids.put(arena, id, {});
            }
            for (ids.keys()) |id| {
                const record = NodeRecord{ .bytes = try graph.recordCopy(id, arena) };
                const entity = entityOf(id);
                for (definition.properties, 0..) |property, ordinal| {
                    const text = try textOf(arena, try storedValue(arena, record, property)) orelse continue;
                    try updateProperty(graph, arena, definition, &entity, @intCast(ordinal), null, text);
                }
            }
        },
        .relationships => {
            // Relationship properties are keys `f | relationship_id | name`.
            const Found = struct { entity: [8]u8, ordinal: u8, text: []const u8 };
            var found = std.ArrayList(Found).empty;
            {
                var keys = try graph.store.scanPrefix("f");
                defer keys.deinit();
                while (try keys.next()) |entry| {
                    const id = std.mem.readInt(u64, entry.key[1..9], .big);
                    const name = entry.key[9..];
                    const ordinal = indexOf(definition.properties, name) orelse continue;
                    const stored = try graph.relationship(id, arena) orelse continue;
                    if (!contains(definition.labels_or_types, stored.edge_type)) continue;
                    const value = try value_encoding.decodeValue(try arena.dupe(u8, entry.value), arena);
                    const text = try textOf(arena, value) orelse continue;
                    try found.append(arena, .{ .entity = entityOf(id), .ordinal = @intCast(ordinal), .text = try arena.dupe(u8, text) });
                }
            }
            for (found.items) |*item| try updateProperty(graph, arena, definition, &item.entity, item.ordinal, null, item.text);
        },
    }
}

/// Removes every key of index `name` (its definition is removed by the caller).
pub fn clear(graph: *Graph, name: []const u8) StorageError!void {
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var stale = std.ArrayList([]const u8).empty;
    for ([_]u8{ posting_marker, document_marker, term_marker }) |marker| {
        var keys = try graph.store.scanPrefix(try indexPrefix(arena, marker, name));
        defer keys.deinit();
        while (try keys.next()) |entry| try stale.append(arena, try arena.dupe(u8, entry.key));
    }
    for (stale.items) |key| try graph.store.del(key);
    try graph.store.del(try statisticsKey(arena, name));
}

// --- One property's text ------------------------------------------------------

/// Changes the text of property `ordinal` of `entity` in `definition` from
/// `old` to `new` (null: none).
fn updateProperty(graph: *Graph, arena: Allocator, definition: fulltext.Definition, entity: []const u8, ordinal: u8, old: ?[]const u8, new: ?[]const u8) StorageError!void {
    if (old == null and new == null) return;
    if (old != null and new != null and std.mem.eql(u8, old.?, new.?)) return;
    const analysis = analyzer.Analyzer.fromName(definition.analyzer) orelse .standard;
    const old_terms = try groupByTerm(arena, if (old) |text| try analyzer.analyze(arena, analysis, text) else &.{});
    const new_terms = try groupByTerm(arena, if (new) |text| try analyzer.analyze(arena, analysis, text) else &.{});

    // The term no longer in the text loses this property's section.
    var old_iterator = old_terms.iterator();
    while (old_iterator.next()) |entry| {
        if (new_terms.contains(entry.key_ptr.*)) continue;
        try writeSection(graph, arena, definition.name, entry.key_ptr.*, entity, ordinal, &.{});
    }
    var new_iterator = new_terms.iterator();
    while (new_iterator.next()) |entry| {
        try writeSection(graph, arena, definition.name, entry.key_ptr.*, entity, ordinal, entry.value_ptr.items);
    }

    // The entity's length, and the index's totals.
    const document_key = try entityKey(arena, document_marker, definition.name, entity);
    const lengths = try arena.alloc(u32, definition.properties.len);
    @memset(lengths, 0);
    const existed = if (try graph.store.get(document_key)) |raw| existed: {
        defer graph.store.allocator.free(raw);
        for (lengths, 0..) |*length, i| if ((i + 1) * 4 <= raw.len) {
            length.* = std.mem.readInt(u32, raw[i * 4 ..][0..4], .big);
        };
        break :existed true;
    } else false;
    const old_length = lengths[ordinal];
    lengths[ordinal] = @intCast(termCount(new_terms));
    var total: u64 = 0;
    for (lengths) |length| total += length;
    if (total == 0) {
        if (existed) try graph.store.del(document_key);
    } else {
        const encoded = try arena.alloc(u8, lengths.len * 4);
        for (lengths, 0..) |length, i| std.mem.writeInt(u32, encoded[i * 4 ..][0..4], length, .big);
        try graph.store.put(document_key, encoded);
    }
    var statistics = try readStatistics(graph, arena, definition.name);
    if (!existed and total > 0) statistics.documents += 1;
    if (existed and total == 0) statistics.documents -|= 1;
    statistics.terms = statistics.terms + lengths[ordinal] -| old_length;
    try writeStatistics(graph, arena, definition.name, statistics);
}

/// Sets property `ordinal`'s positions in the posting of `term` for `entity`
/// (none: removes them), keeping the other properties' sections. Creating or
/// emptying the posting counts the term's entities up or down.
fn writeSection(graph: *Graph, arena: Allocator, name: []const u8, term: []const u8, entity: []const u8, ordinal: u8, positions: []const u32) StorageError!void {
    const key = try postingKey(arena, name, term, entity);
    var sections = std.ArrayList(u8).empty;
    var existed = false;
    if (try graph.store.get(key)) |raw| {
        defer graph.store.allocator.free(raw);
        existed = true;
        var reader = SectionReader{ .bytes = raw };
        while (reader.next()) |section| {
            if (section.ordinal == ordinal) continue;
            try sections.appendSlice(arena, section.bytes);
        }
    }
    if (positions.len > 0) {
        try sections.append(arena, ordinal);
        try appendInt(&sections, arena, u16, @intCast(positions.len));
        for (positions) |position| try appendInt(&sections, arena, u32, position);
    }
    if (sections.items.len == 0) {
        if (!existed) return;
        try graph.store.del(key);
        try bumpTerm(graph, arena, name, term, false);
    } else {
        try graph.store.put(key, sections.items);
        if (!existed) try bumpTerm(graph, arena, name, term, true);
    }
}

fn bumpTerm(graph: *Graph, arena: Allocator, name: []const u8, term: []const u8, increment: bool) StorageError!void {
    const key = try termKey(arena, name, term);
    var count: u64 = 0;
    if (try graph.store.get(key)) |raw| {
        defer graph.store.allocator.free(raw);
        if (raw.len == 8) count = std.mem.readInt(u64, raw[0..8], .big);
    }
    count = if (increment) count + 1 else count -| 1;
    if (count == 0) return graph.store.del(key);
    var buffer: [8]u8 = undefined;
    std.mem.writeInt(u64, &buffer, count, .big);
    try graph.store.put(key, &buffer);
}

// --- Reading -------------------------------------------------------------------

pub const Statistics = struct { documents: u64 = 0, terms: u64 = 0 };

pub fn readStatistics(graph: *Graph, arena: Allocator, name: []const u8) StorageError!Statistics {
    const raw = (try graph.store.get(try statisticsKey(arena, name))) orelse return .{};
    defer graph.store.allocator.free(raw);
    if (raw.len != 16) return .{};
    return .{ .documents = std.mem.readInt(u64, raw[0..8], .big), .terms = std.mem.readInt(u64, raw[8..16], .big) };
}

fn writeStatistics(graph: *Graph, arena: Allocator, name: []const u8, statistics: Statistics) StorageError!void {
    var buffer: [16]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], statistics.documents, .big);
    std.mem.writeInt(u64, buffer[8..16], statistics.terms, .big);
    try graph.store.put(try statisticsKey(arena, name), &buffer);
}

/// One property's occurrences of a term in a posting.
pub const Section = struct { ordinal: u8, positions_bytes: []const u8, bytes: []const u8 };

pub const SectionReader = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn next(self: *SectionReader) ?Section {
        if (self.position + 3 > self.bytes.len) return null;
        const start = self.position;
        const ordinal = self.bytes[start];
        const count = std.mem.readInt(u16, self.bytes[start + 1 ..][0..2], .big);
        const end = start + 3 + @as(usize, count) * 4;
        self.position = end;
        return .{ .ordinal = ordinal, .positions_bytes = self.bytes[start + 3 .. end], .bytes = self.bytes[start..end] };
    }
};

/// How many entities of index `name` have `term`.
pub fn termEntities(graph: *Graph, arena: Allocator, name: []const u8, term: []const u8) StorageError!u64 {
    const raw = (try graph.store.get(try termKey(arena, name, term))) orelse return 0;
    defer graph.store.allocator.free(raw);
    return if (raw.len == 8) std.mem.readInt(u64, raw[0..8], .big) else 0;
}

/// An entity's length in terms, per property (empty if not indexed).
pub fn entityLengths(graph: *Graph, arena: Allocator, name: []const u8, entity: []const u8) StorageError![]const u32 {
    const raw = (try graph.store.get(try entityKey(arena, document_marker, name, entity))) orelse return &.{};
    defer graph.store.allocator.free(raw);
    const lengths = try arena.alloc(u32, raw.len / 4);
    for (lengths, 0..) |*length, i| length.* = std.mem.readInt(u32, raw[i * 4 ..][0..4], .big);
    return lengths;
}

/// An entity's length in terms (over every property), 0 if not indexed.
pub fn entityLength(graph: *Graph, arena: Allocator, name: []const u8, entity: []const u8) StorageError!u64 {
    const raw = (try graph.store.get(try entityKey(arena, document_marker, name, entity))) orelse return 0;
    defer graph.store.allocator.free(raw);
    var total: u64 = 0;
    var i: usize = 0;
    while (i + 4 <= raw.len) : (i += 4) total += std.mem.readInt(u32, raw[i..][0..4], .big);
    return total;
}

// --- Keys ------------------------------------------------------------------------

pub fn indexPrefix(arena: Allocator, marker: u8, name: []const u8) Allocator.Error![]u8 {
    var key = std.ArrayList(u8).empty;
    try key.append(arena, marker);
    try key.appendSlice(arena, name);
    try key.append(arena, 0);
    return key.items;
}

/// `w | name 0x00 | term 0x00`: every posting of `term`.
pub fn postingPrefix(arena: Allocator, name: []const u8, term: []const u8) Allocator.Error![]u8 {
    var key = std.ArrayList(u8).fromOwnedSlice(try indexPrefix(arena, posting_marker, name));
    try key.appendSlice(arena, term);
    try key.append(arena, 0);
    return key.items;
}

pub fn postingKey(arena: Allocator, name: []const u8, term: []const u8, entity: []const u8) Allocator.Error![]u8 {
    var key = std.ArrayList(u8).fromOwnedSlice(try postingPrefix(arena, name, term));
    try key.appendSlice(arena, entity);
    return key.items;
}

fn entityKey(arena: Allocator, marker: u8, name: []const u8, entity: []const u8) Allocator.Error![]u8 {
    var key = std.ArrayList(u8).fromOwnedSlice(try indexPrefix(arena, marker, name));
    try key.appendSlice(arena, entity);
    return key.items;
}

/// `v | name 0x00 | term`.
pub fn termKey(arena: Allocator, name: []const u8, term: []const u8) Allocator.Error![]u8 {
    var key = std.ArrayList(u8).fromOwnedSlice(try indexPrefix(arena, term_marker, name));
    try key.appendSlice(arena, term);
    return key.items;
}

fn statisticsKey(arena: Allocator, name: []const u8) Allocator.Error![]u8 {
    return indexPrefix(arena, statistics_marker, name);
}

// --- Helpers ---------------------------------------------------------------------

const TermPositions = std.StringArrayHashMapUnmanaged(std.ArrayList(u32));

fn groupByTerm(arena: Allocator, terms: []const analyzer.Term) Allocator.Error!TermPositions {
    var grouped = TermPositions.empty;
    for (terms) |term| {
        const entry = try grouped.getOrPut(arena, term.text);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, term.position);
    }
    return grouped;
}

fn termCount(grouped: TermPositions) usize {
    var count: usize = 0;
    for (grouped.values()) |positions| count += positions.items.len;
    return count;
}

fn storedValue(arena: Allocator, record: NodeRecord, property: []const u8) Allocator.Error!?Value {
    const encoded = record.property(property) orelse return null;
    return try value_encoding.decodeValue(encoded, arena);
}

fn hasAnyLabel(record: NodeRecord, labels: []const []const u8) bool {
    for (labels) |label| if (record.hasLabel(label)) return true;
    return false;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    return indexOf(names, name) != null;
}

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, i| if (std.mem.eql(u8, candidate, name)) return i;
    return null;
}

fn appendInt(list: *std.ArrayList(u8), arena: Allocator, comptime T: type, n: T) Allocator.Error!void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, n, .big);
    try list.appendSlice(arena, &buffer);
}
