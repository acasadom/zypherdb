//! The integrity checker: rebuilds every structure derived from the primary
//! records and compares it with what is stored.
//!
//! Primary: the node records (`#nodes`), the relationship records
//! (`#relationships`), the relationship properties (`f` keys), the schema
//! definitions (`i` keys) and the id counters. Derived, and checked here:
//!
//! - the label index (`l`) and the label counters (`c`);
//! - the entries of every property index (`p`; property_indexes.zig);
//! - both edge keys of each relationship (`e`), with the labels they keep of
//!   the node at the other end;
//! - the relationship-type counters (`t`);
//! - the postings of every full-text index (`w`, `W`, `v`, `V`;
//!   integrity_fulltext.zig);
//! - that every uniqueness constraint holds, and that the id counters are
//!   above every id in use.
//!
//! Every key of the main table must be one of these: any other is reported.
//! The records themselves and their values are checked for their layout
//! (layout.zig).
//!
//! It runs in one read transaction (or in the active one, also a write
//! transaction, which it sees with its uncommitted changes), in O(database)
//! time and memory: it keeps every derived key it expects.

const std = @import("std");
const Allocator = std.mem.Allocator;

const graph_module = @import("graph.zig");
const Graph = graph_module.Graph;
const NodeId = graph_module.NodeId;
const RelationshipId = graph_module.RelationshipId;
const Value = graph_module.Value;
const StorageError = @import("key_value_store.zig").StorageError;
const key_encoding = @import("key_encoding.zig");
const value_encoding = @import("value_encoding.zig");
const NodeRecord = @import("node_record.zig").NodeRecord;
const layout = @import("layout.zig");
const Reader = layout.Reader;
const recordProblem = layout.recordProblem;
const valueProblem = layout.valueProblem;
const fulltext = @import("fulltext.zig");
const fulltext_postings = @import("fulltext_postings.zig");
const integrity_fulltext = @import("integrity_fulltext.zig");
const property_indexes = @import("property_indexes.zig");

/// What a check found: the first problems, described, and how many there were.
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    problems: std.ArrayList([]const u8) = .empty,
    /// Every problem found, also those past `max_kept`.
    count: usize = 0,

    pub const max_kept = 32;

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
    }

    pub fn ok(self: *const Report) bool {
        return self.count == 0;
    }

    pub fn add(self: *Report, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        self.count += 1;
        if (self.problems.items.len >= max_kept) return;
        const allocator = self.arena.allocator();
        try self.problems.append(allocator, try std.fmt.allocPrint(allocator, fmt, args));
    }

    pub fn format(self: Report, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.count == 0) return writer.writeAll("integrity check: ok\n");
        try writer.print("integrity check: {d} problem(s)\n", .{self.count});
        for (self.problems.items) |problem| try writer.print("  - {s}\n", .{problem});
        if (self.count > self.problems.items.len) try writer.print("  ... and {d} more\n", .{self.count - self.problems.items.len});
    }
};

/// Bytes shown as text, with `\xNN` for the unprintable ones (a key, a value).
pub const Bytes = struct {
    bytes: []const u8,

    pub fn format(self: Bytes, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.bytes) |byte| {
            if (byte >= 0x20 and byte < 0x7f and byte != '\\') try writer.writeByte(byte) else try writer.print("\\x{x:0>2}", .{byte});
        }
    }
};

/// Checks the whole database (see the module comment). The report is made
/// with `allocator`; `deinit` it.
pub fn check(graph: *Graph, allocator: Allocator) StorageError!Report {
    var report = Report{ .arena = .init(allocator) };
    errdefer report.deinit();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const own_transaction = !graph.store.inTransaction();
    if (own_transaction) try graph.beginRead();
    defer if (own_transaction) graph.commitRead();

    var checker = Checker{ .graph = graph, .arena = scratch.allocator(), .report = &report };
    try checker.loadNodes();
    try checker.loadRelationships();
    try checker.loadRelationshipProperties();
    checker.definitions = try fulltext.all(graph, checker.arena);
    try checker.expectNodeKeys();
    try checker.expectRelationshipKeys();
    for (checker.definitions) |definition| switch (definition.kind) {
        .fulltext => try integrity_fulltext.expectIndex(&checker, definition),
        .unique => {
            try checker.expectPropertyIndex(definition);
            try checker.checkUnique(definition);
        },
        .range => try checker.expectPropertyIndex(definition),
    };
    try checker.checkCounters();
    try checker.compareMainTable();
    return report;
}

pub const Checker = struct {
    graph: *Graph,
    arena: Allocator,
    report: *Report,
    /// The well-formed node records, by id.
    nodes: std.AutoArrayHashMapUnmanaged(NodeId, NodeRecord) = .empty,
    relationships: std.AutoArrayHashMapUnmanaged(RelationshipId, Relationship) = .empty,
    definitions: []const fulltext.Definition = &.{},
    /// The derived keys the primary records call for, with their values
    /// (null: any value).
    expected: std.StringArrayHashMapUnmanaged(?[]const u8) = .empty,

    pub const Relationship = struct {
        src: NodeId,
        dst: NodeId,
        edge_type: []const u8,
        properties: std.ArrayList(Property) = .empty,
    };

    pub const Property = struct { name: []const u8, encoded: []const u8 };

    /// Records that derived key `key` must hold `value` (null: any value).
    pub fn expect(self: *Checker, key: []const u8, value: ?[]const u8) StorageError!void {
        const entry = try self.expected.getOrPut(self.arena, key);
        if (entry.found_existing) try self.report.add("derived key {f} is called for twice", .{Bytes{ .bytes = key }});
        entry.value_ptr.* = value;
    }

    /// An 8-byte big-endian count, as counters store it.
    pub fn countBytes(self: *Checker, count: u64) Allocator.Error![]const u8 {
        const bytes = try self.arena.alloc(u8, 8);
        std.mem.writeInt(u64, bytes[0..8], count, .big);
        return bytes;
    }

    fn loadNodes(self: *Checker) StorageError!void {
        var iterator = try self.graph.store.scanNodes();
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.key.len != 8) {
                try self.report.add("node table key {f} is not an id", .{Bytes{ .bytes = entry.key }});
                continue;
            }
            const id = std.mem.readInt(NodeId, entry.key[0..8], .native);
            const bytes = try self.arena.dupe(u8, entry.value);
            if (recordProblem(bytes)) |problem| {
                try self.report.add("node {d}: malformed record ({s}): {f}", .{ id, problem, Bytes{ .bytes = bytes } });
                continue;
            }
            try self.nodes.put(self.arena, id, .{ .bytes = bytes });
        }
    }

    fn loadRelationships(self: *Checker) StorageError!void {
        var iterator = try self.graph.store.scanRelationships();
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.key.len != 8) {
                try self.report.add("relationship table key {f} is not an id", .{Bytes{ .bytes = entry.key }});
                continue;
            }
            const id = std.mem.readInt(RelationshipId, entry.key[0..8], .native);
            const raw = entry.value;
            if (layout.relationshipRecordProblem(raw)) |problem| {
                try self.report.add("relationship {d}: malformed record ({s}): {f}", .{ id, problem, Bytes{ .bytes = raw } });
                continue;
            }
            const record = key_encoding.decodeRelationshipRecord(raw);
            try self.relationships.put(self.arena, id, .{ .src = record.src, .dst = record.dst, .edge_type = try self.arena.dupe(u8, record.edge_type) });
        }
    }

    /// Relationship properties: keys `f | relationship_id | name`.
    fn loadRelationshipProperties(self: *Checker) StorageError!void {
        var iterator = try self.graph.store.scanPrefix(&.{key_encoding.edge_property_marker});
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            const key = entry.key;
            if (key.len <= 1 + key_encoding.node_id_length) {
                try self.report.add("relationship property key {f} has no name", .{Bytes{ .bytes = key }});
                continue;
            }
            const id = key_encoding.readNodeId(key[1 .. 1 + key_encoding.node_id_length]);
            const relationship = self.relationships.getPtr(id) orelse {
                try self.report.add("property key {f} of a relationship {d} that does not exist", .{ Bytes{ .bytes = key }, id });
                continue;
            };
            if (valueProblem(entry.value)) |problem| {
                try self.report.add("relationship {d}: property {f} has a malformed value ({s}): {f}", .{ id, Bytes{ .bytes = key[9..] }, problem, Bytes{ .bytes = entry.value } });
                continue;
            }
            try relationship.properties.append(self.arena, .{ .name = try self.arena.dupe(u8, key[9..]), .encoded = try self.arena.dupe(u8, entry.value) });
        }
    }

    /// Label-index keys and the label counters.
    fn expectNodeKeys(self: *Checker) StorageError!void {
        var label_counts = std.StringArrayHashMapUnmanaged(u64).empty;
        for (self.nodes.keys(), self.nodes.values()) |id, record| {
            var labels = record.labels();
            while (labels.next()) |label| {
                var key = std.ArrayList(u8).empty;
                try key_encoding.appendLabelKey(&key, self.arena, label, id);
                try self.expect(key.items, "");
                const count = try label_counts.getOrPut(self.arena, label);
                count.value_ptr.* = if (count.found_existing) count.value_ptr.* + 1 else 1;
            }
        }
        for (label_counts.keys(), label_counts.values()) |label, count| {
            const key = try std.mem.concat(self.arena, u8, &.{ &.{key_encoding.label_count_marker}, label });
            try self.expect(key, try self.countBytes(count));
        }
    }

    /// Both edge keys of each relationship and the type counters.
    fn expectRelationshipKeys(self: *Checker) StorageError!void {
        var type_counts = std.StringArrayHashMapUnmanaged(u64).empty;
        for (self.relationships.keys(), self.relationships.values()) |id, relationship| {
            const ends = [_]struct { NodeId, key_encoding.Direction, NodeId }{
                .{ relationship.src, .out, relationship.dst },
                .{ relationship.dst, .in, relationship.src },
            };
            for (ends) |end| {
                const node, const direction, const neighbour = end;
                if (!self.nodes.contains(node)) try self.report.add("relationship {d} ({d})-[:{s}]->({d}): node {d} does not exist", .{ id, relationship.src, relationship.edge_type, relationship.dst, node });
                var key = std.ArrayList(u8).empty;
                try key_encoding.appendEdgeKey(&key, self.arena, node, direction, relationship.edge_type, neighbour, id);
                try self.expect(key.items, try self.neighbourLabels(neighbour));
            }
            const count = try type_counts.getOrPut(self.arena, relationship.edge_type);
            count.value_ptr.* = if (count.found_existing) count.value_ptr.* + 1 else 1;
        }
        for (type_counts.keys(), type_counts.values()) |edge_type, count| {
            const key = try std.mem.concat(self.arena, u8, &.{ &.{key_encoding.edge_type_marker}, edge_type });
            try self.expect(key, try self.countBytes(count));
        }
    }

    /// The entries of the property index of `definition`: one per entity with
    /// its label or type and its property.
    fn expectPropertyIndex(self: *Checker, definition: fulltext.Definition) StorageError!void {
        const label_or_type = definition.labels_or_types[0];
        const property = definition.properties[0];
        const top = property_indexes.topProperty(property);
        switch (definition.entity) {
            .nodes => for (self.nodes.keys(), self.nodes.values()) |id, record| {
                if (!record.hasLabel(label_or_type)) continue;
                const encoded = record.property(top) orelse continue;
                try self.expectIndexEntry(definition.index_id, property, encoded, id);
            },
            .relationships => for (self.relationships.keys(), self.relationships.values()) |id, relationship| {
                if (!std.mem.eql(u8, relationship.edge_type, label_or_type)) continue;
                for (relationship.properties.items) |stored| {
                    if (std.mem.eql(u8, stored.name, top)) try self.expectIndexEntry(definition.index_id, property, stored.encoded, id);
                }
            },
        }
    }

    /// The entry of entity `id` in index `index_id` on `property` (a name or
    /// a path), whose property is `encoded`; none if the path finds nothing.
    fn expectIndexEntry(self: *Checker, index_id: u32, property: []const u8, encoded: []const u8, id: u64) StorageError!void {
        const value = property_indexes.valueAt(try value_encoding.decodeValue(encoded, self.arena), property) orelse return;
        var key = std.ArrayList(u8).empty;
        try property_indexes.appendKey(&key, self.arena, index_id, value, id);
        try self.expect(key.items, "");
    }

    /// The value an edge key keeps of node `id` at its other end: its labels
    /// (null, any value, if the node does not exist: that is reported apart).
    fn neighbourLabels(self: *Checker, id: NodeId) Allocator.Error!?[]const u8 {
        const record = self.nodes.get(id) orelse return null;
        return try std.mem.concat(self.arena, u8, &.{ &.{graph_module.neighbour_labels_version}, record.labelSection() });
    }

    /// No two nodes with the constraint's label have equal values (as the
    /// index encodes them: 1 and 1.0 are equal) of all its properties.
    fn checkUnique(self: *Checker, definition: fulltext.Definition) StorageError!void {
        if (definition.labels_or_types.len != 1 or definition.properties.len == 0) {
            return self.report.add("constraint '{s}' is malformed", .{definition.name});
        }
        var holders = std.StringHashMapUnmanaged(NodeId).empty;
        node: for (self.nodes.keys(), self.nodes.values()) |id, record| {
            if (!record.hasLabel(definition.labels_or_types[0])) continue;
            var values = std.ArrayList(u8).empty;
            for (definition.properties) |property| {
                const encoded = record.property(property) orelse continue :node;
                try value_encoding.encodeIndexValue(&values, self.arena, try value_encoding.decodeValue(encoded, self.arena));
            }
            const holder = try holders.getOrPut(self.arena, values.items);
            if (holder.found_existing) {
                try self.report.add("constraint '{s}' is broken: nodes {d} and {d} have the same values", .{ definition.name, holder.value_ptr.*, id });
            } else holder.value_ptr.* = id;
        }
    }

    /// The id counters are above every id in use; definitions are counted
    /// in the schema version (else no write would keep their indexes).
    fn checkCounters(self: *Checker) StorageError!void {
        const store = self.graph.store;
        const next_node = try self.storedCounter(key_encoding.counter_key);
        for (self.nodes.keys()) |id| if (id >= next_node) {
            try self.report.add("node {d} is not below the node id counter ({d})", .{ id, next_node });
        };
        // In a write transaction the counter is written when it commits.
        const next_relationship = store.write_transaction_memo.next_relationship_id orelse try self.storedCounter(key_encoding.relationship_counter_key);
        for (self.relationships.keys()) |id| if (id >= next_relationship) {
            try self.report.add("relationship {d} is not below the relationship id counter ({d})", .{ id, next_relationship });
        };
        if (try store.get(key_encoding.format_key)) |raw| {
            defer store.allocator.free(raw);
            if (raw.len != 4 or std.mem.readInt(u32, raw[0..4], .big) != Graph.format_version) try self.report.add("format key holds {f}", .{Bytes{ .bytes = raw }});
        }
        if (self.definitions.len > 0 and try fulltext.schemaVersion(self.graph) == 0) {
            try self.report.add("{d} schema definition(s) but the schema version is 0", .{self.definitions.len});
        }
    }

    fn storedCounter(self: *Checker, key: []const u8) StorageError!u64 {
        const raw = (try self.graph.store.get(key)) orelse return 0;
        defer self.graph.store.allocator.free(raw);
        if (raw.len != 8) {
            try self.report.add("counter {s} holds {f}", .{ key, Bytes{ .bytes = raw } });
            return 0;
        }
        return std.mem.readInt(u64, raw[0..8], .big);
    }

    /// Every key of the main table against the expected ones, and the
    /// expected ones that are missing.
    fn compareMainTable(self: *Checker) StorageError!void {
        const seen = try self.arena.alloc(bool, self.expected.count());
        @memset(seen, false);
        var iterator = try self.graph.store.scanAll();
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            const key = entry.key;
            if (isMetadataKey(key)) continue;
            switch (key[0]) {
                fulltext.definition_marker, key_encoding.edge_property_marker => {}, // primary
                key_encoding.edge_marker,
                key_encoding.label_marker,
                property_indexes.marker,
                key_encoding.label_count_marker,
                key_encoding.edge_type_marker,
                fulltext_postings.posting_marker,
                fulltext_postings.document_marker,
                fulltext_postings.term_marker,
                fulltext_postings.statistics_marker,
                => try self.compareDerived(key, entry.value, seen),
                else => try self.report.add("unknown key {f}", .{Bytes{ .bytes = key }}),
            }
        }
        for (self.expected.keys(), self.expected.values(), seen) |key, value, was_seen| {
            if (was_seen) continue;
            try self.report.add("missing key {f} (value {f})", .{ Bytes{ .bytes = key }, Bytes{ .bytes = value orelse "any" } });
        }
    }

    fn compareDerived(self: *Checker, key: []const u8, value: []const u8, seen: []bool) StorageError!void {
        const index = self.expected.getIndex(key) orelse {
            // A counter of what is no longer there stays, at zero.
            if (isCounter(key[0]) and std.mem.allEqual(u8, value, 0)) return;
            return self.report.add("unexpected key {f} (value {f})", .{ Bytes{ .bytes = key }, Bytes{ .bytes = value } });
        };
        seen[index] = true;
        const want = self.expected.values()[index] orelse return;
        if (key[0] == key_encoding.edge_marker) {
            if (!sameNeighbourLabels(want, value)) try self.report.add("edge key {f} keeps the labels {f}, expected {f}", .{ Bytes{ .bytes = key }, Bytes{ .bytes = value }, Bytes{ .bytes = want } });
            return;
        }
        const have = if (key[0] == fulltext_postings.posting_marker)
            try integrity_fulltext.canonicalPosting(self.arena, value) orelse return self.report.add("posting {f} is malformed: {f}", .{ Bytes{ .bytes = key }, Bytes{ .bytes = value } })
        else
            value;
        if (!std.mem.eql(u8, want, have)) try self.report.add("key {f} holds {f}, expected {f}", .{ Bytes{ .bytes = key }, Bytes{ .bytes = value }, Bytes{ .bytes = want } });
    }
};

/// A counter, the format, the schema version, or an entry of the engine's
/// catalog of its tables (LMDB keeps the names of `#nodes` and
/// `#relationships` in the main table, with their trailing 0x00).
fn isMetadataKey(key: []const u8) bool {
    for ([_][]const u8{ key_encoding.counter_key, key_encoding.relationship_counter_key, key_encoding.format_key, fulltext.schema_version_key, fulltext.index_id_key }) |metadata| {
        if (std.mem.eql(u8, key, metadata)) return true;
    }
    const name = if (std.mem.endsWith(u8, key, "\x00")) key[0 .. key.len - 1] else key;
    return std.mem.eql(u8, name, "#nodes") or std.mem.eql(u8, name, "#relationships");
}

fn isCounter(marker: u8) bool {
    return marker == key_encoding.label_count_marker or marker == key_encoding.edge_type_marker or marker == fulltext_postings.statistics_marker;
}

/// True if two edge-key values keep the same labels: a version byte, then
/// a record's label section, which an empty section and a count of zero
/// both leave without labels.
fn sameNeighbourLabels(want: []const u8, have: []const u8) bool {
    if (have.len == 0 or have[0] != graph_module.neighbour_labels_version) return false;
    var wanted = Reader{ .bytes = want[1..] };
    var stored = Reader{ .bytes = have[1..] };
    const count = if (wanted.bytes.len == 0) 0 else wanted.int(u16).?;
    const stored_count = if (stored.bytes.len == 0) 0 else stored.int(u16) orelse return false;
    if (count != stored_count) return false;
    for (0..count) |_| {
        const label = wanted.take(wanted.int(u16).?).?;
        const length = stored.int(u16) orelse return false;
        if (!std.mem.eql(u8, label, stored.take(length) orelse return false)) return false;
    }
    return stored.position == stored.bytes.len;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "an edge key's labels of its neighbour are compared as labels" {
    try testing.expect(sameNeighbourLabels("\x01", "\x01\x00\x00"));
    try testing.expect(sameNeighbourLabels("\x01\x00\x01\x00\x01A", "\x01\x00\x01\x00\x01A"));
    try testing.expect(!sameNeighbourLabels("\x01\x00\x01\x00\x01A", "\x01"));
    try testing.expect(!sameNeighbourLabels("\x01", ""));
    try testing.expect(!sameNeighbourLabels("\x01", "\x01\x00\x01\x00\x09A"));
}
