//! The node record: a node's labels and properties in one stored value, so
//! one B-tree search reads all of them (the value under the node's id in the
//! `#nodes` database).
//!
//! Layout, integers big-endian:
//!
//!     label count: u16
//!     per label, in byte order:          length: u16, bytes
//!     property count: u32
//!     per property, in name byte order:  name length: u16, name,
//!                                        value length: u32, value (value_encoding)
//!
//! An empty value is a node with neither. Records are read in place (a view
//! into the store) and rewritten whole on a change: a node's record is small,
//! and reads far outnumber writes.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A record's bytes, read without copying.
pub const NodeRecord = struct {
    bytes: []const u8,

    pub const empty = NodeRecord{ .bytes = "" };

    pub fn labels(self: NodeRecord) LabelIterator {
        return .{ .bytes = self.bytes, .remaining = if (self.bytes.len == 0) 0 else readInt(u16, self.bytes), .position = 2 };
    }

    pub fn labelCount(self: NodeRecord) usize {
        return self.labels().remaining;
    }

    pub fn properties(self: NodeRecord) PropertyIterator {
        var position = self.labelsEnd();
        const count = if (self.bytes.len == 0) 0 else readInt(u32, self.bytes[position..]);
        position += 4;
        return .{ .bytes = self.bytes, .remaining = count, .position = position };
    }

    pub fn hasLabel(self: NodeRecord, label: []const u8) bool {
        var iterator = self.labels();
        while (iterator.next()) |name| {
            if (std.mem.eql(u8, name, label)) return true;
        }
        return false;
    }

    /// The encoded value of property `name`, if the node has it.
    pub fn property(self: NodeRecord, name: []const u8) ?[]const u8 {
        var iterator = self.properties();
        while (iterator.next()) |entry| {
            switch (std.mem.order(u8, entry.name, name)) {
                .eq => return entry.encoded_value,
                .gt => return null, // sorted: it would have come already
                .lt => {},
            }
        }
        return null;
    }

    /// The record's labels part (count and labels), which edges keep a copy
    /// of for the node at their other end (see `Graph.addEdge`).
    pub fn labelSection(self: NodeRecord) []const u8 {
        return self.bytes[0..self.labelsEnd()];
    }

    fn labelsEnd(self: NodeRecord) usize {
        if (self.bytes.len == 0) return 0;
        var iterator = self.labels();
        while (iterator.next()) |_| {}
        return iterator.position;
    }
};

pub const LabelIterator = struct {
    bytes: []const u8,
    remaining: usize,
    position: usize,

    pub fn next(self: *LabelIterator) ?[]const u8 {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const length = readInt(u16, self.bytes[self.position..]);
        const start = self.position + 2;
        self.position = start + length;
        return self.bytes[start..self.position];
    }
};

pub const Property = struct { name: []const u8, encoded_value: []const u8 };

pub const PropertyIterator = struct {
    bytes: []const u8,
    remaining: usize,
    position: usize,

    pub fn next(self: *PropertyIterator) ?Property {
        if (self.remaining == 0) return null;
        self.remaining -= 1;
        const name_length = readInt(u16, self.bytes[self.position..]);
        const name_start = self.position + 2;
        const value_length_at = name_start + name_length;
        const value_length = readInt(u32, self.bytes[value_length_at..]);
        const value_start = value_length_at + 4;
        self.position = value_start + value_length;
        return .{ .name = self.bytes[name_start..value_length_at], .encoded_value = self.bytes[value_start..self.position] };
    }
};

/// `record` with `label` added or removed.
pub fn withLabel(allocator: Allocator, record: NodeRecord, label: []const u8, present: bool) Allocator.Error![]u8 {
    var labels = std.ArrayList([]const u8).empty;
    defer labels.deinit(allocator);
    var iterator = record.labels();
    var placed = false;
    while (iterator.next()) |name| {
        switch (std.mem.order(u8, name, label)) {
            .lt => try labels.append(allocator, name),
            .eq => {
                placed = true;
                if (present) try labels.append(allocator, name);
            },
            .gt => {
                if (present and !placed) try labels.append(allocator, label);
                placed = true;
                try labels.append(allocator, name);
            },
        }
    }
    if (present and !placed) try labels.append(allocator, label);
    return build(allocator, labels.items, record.properties());
}

/// `record` with property `name` set to `encoded_value`, or removed (null).
pub fn withProperty(allocator: Allocator, record: NodeRecord, name: []const u8, encoded_value: ?[]const u8) Allocator.Error![]u8 {
    var properties = std.ArrayList(Property).empty;
    defer properties.deinit(allocator);
    var iterator = record.properties();
    var placed = false;
    while (iterator.next()) |entry| {
        switch (std.mem.order(u8, entry.name, name)) {
            .lt => try properties.append(allocator, entry),
            .eq => {
                placed = true;
                if (encoded_value) |bytes| try properties.append(allocator, .{ .name = name, .encoded_value = bytes });
            },
            .gt => {
                if (!placed) if (encoded_value) |bytes| try properties.append(allocator, .{ .name = name, .encoded_value = bytes });
                placed = true;
                try properties.append(allocator, entry);
            },
        }
    }
    if (!placed) if (encoded_value) |bytes| try properties.append(allocator, .{ .name = name, .encoded_value = bytes });
    var labels = std.ArrayList([]const u8).empty;
    defer labels.deinit(allocator);
    var label_iterator = record.labels();
    while (label_iterator.next()) |label| try labels.append(allocator, label);
    return buildFromSlices(allocator, labels.items, properties.items);
}

fn build(allocator: Allocator, labels: []const []const u8, properties: PropertyIterator) Allocator.Error![]u8 {
    var list = std.ArrayList(Property).empty;
    defer list.deinit(allocator);
    var iterator = properties;
    while (iterator.next()) |entry| try list.append(allocator, entry);
    return buildFromSlices(allocator, labels, list.items);
}

/// A record from sorted labels and sorted properties.
fn buildFromSlices(allocator: Allocator, labels: []const []const u8, properties: []const Property) Allocator.Error![]u8 {
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(allocator);
    if (labels.len == 0 and properties.len == 0) return bytes.toOwnedSlice(allocator);
    try appendInt(&bytes, allocator, u16, @intCast(labels.len));
    for (labels) |label| {
        try appendInt(&bytes, allocator, u16, @intCast(label.len));
        try bytes.appendSlice(allocator, label);
    }
    try appendInt(&bytes, allocator, u32, @intCast(properties.len));
    for (properties) |entry| {
        try appendInt(&bytes, allocator, u16, @intCast(entry.name.len));
        try bytes.appendSlice(allocator, entry.name);
        try appendInt(&bytes, allocator, u32, @intCast(entry.encoded_value.len));
        try bytes.appendSlice(allocator, entry.encoded_value);
    }
    return bytes.toOwnedSlice(allocator);
}

fn appendInt(list: *std.ArrayList(u8), allocator: Allocator, comptime T: type, n: T) Allocator.Error!void {
    var buffer: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buffer, n, .big);
    try list.appendSlice(allocator, &buffer);
}

fn readInt(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

test "labels and properties are kept sorted, set and removed" {
    const a = std.testing.allocator;
    const one = try withLabel(a, .empty, "Person", true);
    defer a.free(one);
    const two = try withLabel(a, .{ .bytes = one }, "Admin", true);
    defer a.free(two);
    const three = try withProperty(a, .{ .bytes = two }, "name", "\x02Ana");
    defer a.free(three);
    const four = try withProperty(a, .{ .bytes = three }, "age", "\x01\x00\x00\x00\x00\x00\x00\x00\x28");
    defer a.free(four);
    const record = NodeRecord{ .bytes = four };
    var labels = record.labels();
    try std.testing.expectEqualStrings("Admin", labels.next().?);
    try std.testing.expectEqualStrings("Person", labels.next().?);
    try std.testing.expect(labels.next() == null);
    try std.testing.expect(record.hasLabel("Person") and !record.hasLabel("Robot"));
    try std.testing.expectEqualStrings("\x02Ana", record.property("name").?);
    try std.testing.expect(record.property("missing") == null);
    var properties = record.properties();
    try std.testing.expectEqualStrings("age", properties.next().?.name);
    const five = try withProperty(a, record, "name", null);
    defer a.free(five);
    const six = try withLabel(a, .{ .bytes = five }, "Admin", false);
    defer a.free(six);
    try std.testing.expect((NodeRecord{ .bytes = six }).property("name") == null);
    try std.testing.expect(!(NodeRecord{ .bytes = six }).hasLabel("Admin"));
    try std.testing.expect((NodeRecord{ .bytes = six }).property("age") != null);
}
