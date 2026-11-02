//! Forwarded writes (replication/forwarding.zig): requests and answers read
//! back as written, malformed bytes are refused, and parts join only when
//! they belong together and stay within the limit.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const forwarding = zypherdb.replication_forwarding;
const Value = zypherdb.Value;
const MapEntry = zypherdb.value.MapEntry;
const EntitySnapshot = zypherdb.entities.EntitySnapshot;
const Property = zypherdb.entities.Property;

const knows: zypherdb.value.Relationship = .{ .id = 4, .src = 1, .dst = 2, .edge_type = "KNOWS" };

/// Node 1 (:Person:Admin {name: "Ada", born: 1815}) and `knows` {since: 2020}.
fn snapshot(a: std.mem.Allocator) !EntitySnapshot {
    var entities: EntitySnapshot = .{};
    try entities.nodes.put(a, 1, .{ .labels = &.{ "Person", "Admin" }, .properties = &.{
        .{ .name = "name", .value = .{ .string = "Ada" } },
        .{ .name = "born", .value = .{ .int = 1815 } },
    } });
    try entities.nodes.put(a, 2, .{ .labels = &.{}, .properties = &.{} });
    try entities.relationships.putContext(a, knows, &.{.{ .name = "since", .value = .{ .int = 2020 } }}, .{});
    return entities;
}

fn expectSameEntities(expected: EntitySnapshot, actual: EntitySnapshot) !void {
    try testing.expectEqual(expected.nodes.count(), actual.nodes.count());
    var nodes = expected.nodes.iterator();
    while (nodes.next()) |node| {
        const other = actual.nodes.get(node.key_ptr.*).?;
        try testing.expectEqual(node.value_ptr.labels.len, other.labels.len);
        for (node.value_ptr.labels, other.labels) |x, y| try testing.expectEqualStrings(x, y);
        try expectSameProperties(node.value_ptr.properties, other.properties);
    }
    try testing.expectEqual(expected.relationships.count(), actual.relationships.count());
    var relationships = expected.relationships.iterator();
    while (relationships.next()) |relationship| {
        try expectSameProperties(relationship.value_ptr.*, actual.relationships.getContext(relationship.key_ptr.*, .{}).?);
    }
}

fn expectSameProperties(expected: []const Property, actual: []const Property) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |x, y| {
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expect(Value.eql(x.value, y.value));
    }
}

test "a request reads back as written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const requests = [_]forwarding.Request{
        .{ .text = "CREATE (:Door {name: $name})", .parameters = &.{.{ .key = "name", .value = .{ .string = "B7" } }} },
        .{ .text = "", .parameters = &.{} },
        .{ .text = "MATCH (n) WHERE id(n) = $id SET n += $props", .parameters = &.{
            .{ .key = "id", .value = .{ .int = 3 } },
            .{ .key = "props", .value = .{ .map = &.{.{ .key = "since", .value = .{ .date = .{ .days = 19000 } } }} } },
        } },
    };
    for (requests) |request| {
        var bytes = std.ArrayList(u8).empty;
        try forwarding.encodeRequest(&bytes, a, request);
        const decoded = try forwarding.decodeRequest(bytes.items, a);
        try testing.expectEqualStrings(request.text, decoded.text);
        try testing.expect(Value.eql(.{ .map = request.parameters }, .{ .map = decoded.parameters }));
    }
}

test "an answer reads back as written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const answers = [_]forwarding.Answer{
        .{ .done = .{ .lsn = 42, .columns = &.{ "n", "r" }, .rows = &.{
            &.{ .{ .node = 1 }, .{ .relationship = knows } },
            &.{ .null, .{ .list = &.{ .{ .int = 1 }, .{ .string = "a" } } } },
            &.{ .{ .node = 2 }, .null },
        }, .entities = try snapshot(a) } },
        .{ .done = .{ .lsn = 0, .columns = &.{}, .rows = &.{} } },
        .{ .done = .{ .lsn = 1, .columns = &.{"count"}, .rows = &.{} } },
        .{ .failed = .{ .code = 10, .position = 0, .message = "Node(3) already exists with label `Door` and property `name` = 'B7'" } },
        .{ .failed = .{ .code = 999, .position = 12, .message = "" } },
    };
    for (answers) |answer| {
        var bytes = std.ArrayList(u8).empty;
        try forwarding.encodeAnswer(&bytes, a, answer);
        const decoded = try forwarding.decodeAnswer(bytes.items, a);
        switch (answer) {
            .done => |done| {
                try testing.expectEqual(done.lsn, decoded.done.lsn);
                try testing.expectEqual(done.columns.len, decoded.done.columns.len);
                for (done.columns, decoded.done.columns) |x, y| try testing.expectEqualStrings(x, y);
                try testing.expectEqual(done.rows.len, decoded.done.rows.len);
                for (done.rows, decoded.done.rows) |x, y| try testing.expect(Value.eql(.{ .list = x }, .{ .list = y }));
                try expectSameEntities(done.entities, decoded.done.entities);
            },
            .failed => |failure| {
                try testing.expectEqual(failure.code, decoded.failed.code);
                try testing.expectEqual(failure.position, decoded.failed.position);
                try testing.expectEqualStrings(failure.message, decoded.failed.message);
            },
        }
    }
}

/// Node 7 with no labels and no properties, as an answer's entities hold it.
const node_seven = "\x00\x00\x00\x00\x00\x00\x00\x07" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00";

test "malformed requests and answers are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const requests = [_][]const u8{
        "", // no text length
        "\x00\x00\x00\x05abc", // a text shorter than its length
        "\x00\x00\x00\x00", // no parameters
        "\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01", // parameters that are no map
        "\x00\x00\x00\x00\x06\x00\x00\x00\x00\x00", // something after the parameters
    };
    for (requests) |bytes| try testing.expectError(error.MalformedMessage, forwarding.decodeRequest(bytes, a));
    const answers = [_][]const u8{
        "", // no kind
        "\x02", // an unknown kind
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x01", // a row with no columns
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01" ++ "\x00\x00\x00\x01" ++ "\x00\x00\x00\x01n" ++ "\xff\xff\xff\xff", // more rows than bytes
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01" ++ "\xff\xff\xff\xff", // more columns than bytes
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00", // no entities
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x02" ++
            node_seven ++ node_seven ++ "\x00\x00\x00\x00", // a node given twice
        "\x00\x00\x00\x00\x00\x00\x00\x00\x01" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x01" ++
            "\x07\x00\x00\x00\x00\x00\x00\x00\x07" ++ node_seven ++ "\x00\x00\x00\x00\x00\x00\x00\x00", // a relationship that is a node
        "\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x09oops", // a message shorter than its length
        "\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00", // something after the message
    };
    for (answers) |bytes| try testing.expectError(error.MalformedMessage, forwarding.decodeAnswer(bytes, a));
}

test "every request and answer cut short is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var request = std.ArrayList(u8).empty;
    try forwarding.encodeRequest(&request, a, .{ .text = "CREATE (n)", .parameters = &.{.{ .key = "x", .value = .{ .int = 1 } }} });
    for (0..request.items.len) |length| try testing.expectError(error.MalformedMessage, forwarding.decodeRequest(request.items[0..length], a));
    var answer = std.ArrayList(u8).empty;
    try forwarding.encodeAnswer(&answer, a, .{ .done = .{ .lsn = 5, .columns = &.{ "n", "r" }, .rows = &.{&.{ .{ .node = 1 }, .{ .relationship = knows } }}, .entities = try snapshot(a) } });
    for (0..answer.items.len) |length| try testing.expectError(error.MalformedMessage, forwarding.decodeAnswer(answer.items[0..length], a));
}

test "a request or an answer past its limit is refused when written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try a.alloc(u8, forwarding.max_request_bytes);
    @memset(text, 'x');
    var request = std.ArrayList(u8).empty;
    try testing.expectError(error.TooLarge, forwarding.encodeRequest(&request, a, .{ .text = text, .parameters = &.{} }));
    // Rows of a 1 MiB string each: the answer stops growing past the limit.
    const row: []const Value = &.{.{ .string = text[0 .. 1 << 20] }};
    const rows = try a.alloc([]const Value, forwarding.max_answer_bytes / (1 << 20) + 1);
    @memset(rows, row);
    var answer = std.ArrayList(u8).empty;
    try testing.expectError(error.TooLarge, forwarding.encodeAnswer(&answer, a, .{ .done = .{ .lsn = 1, .columns = &.{"s"}, .rows = rows } }));
}

test "parts join in order, one id at a time, within the limit" {
    var assembly: forwarding.Assembly = .{ .limit = 8 };
    defer assembly.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), try assembly.add(testing.allocator, 1, false, "CRE"));
    try testing.expectEqualStrings("CREATE", (try assembly.add(testing.allocator, 1, true, "ATE")).?);
    // The next request starts afresh, under another id.
    try testing.expectEqualStrings("", (try assembly.add(testing.allocator, 2, true, "")).?);
    try testing.expectEqual(@as(?[]const u8, null), try assembly.add(testing.allocator, 3, false, "ab"));
    try testing.expectError(error.MixedParts, assembly.add(testing.allocator, 4, true, "cd"));
    var small: forwarding.Assembly = .{ .limit = 4 };
    defer small.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), try small.add(testing.allocator, 1, false, "abcd"));
    try testing.expectError(error.TooLarge, small.add(testing.allocator, 1, true, "e"));
}
