//! Writes a replica forwards, run on the master
//! (replication/forwarded_writes.zig): a write commits and answers its rows
//! and the master's LSN; one that fails commits nothing and answers why.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const KeyValueStore = zypherdb.KeyValueStore;
const Graph = zypherdb.Graph;
const Value = zypherdb.Value;
const MapEntry = zypherdb.value.MapEntry;
const ErrorCode = zypherdb.diagnostics.ErrorCode;
const forwarding = zypherdb.replication_forwarding;
const forwarded_writes = zypherdb.replication_forwarded_writes;

const support = @import("../support.zig");

/// A master's database, its change log started.
const Master = struct {
    tmp: testing.TmpDir,
    store: KeyValueStore,
    graph: Graph,
    arena: std.heap.ArenaAllocator,

    fn init(self: *Master) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        var buffer: [256]u8 = undefined;
        self.store = try support.openStore(&self.tmp, &buffer);
        errdefer self.store.deinit();
        try self.store.startChangeLog();
        self.graph = .init(&self.store, testing.allocator);
        self.arena = .init(testing.allocator);
    }

    fn deinit(self: *Master) void {
        self.arena.deinit();
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn lastLsn(self: *Master) !u64 {
        return (try self.store.changeLogState()).?.next_lsn - 1;
    }

    /// Runs `text` with `parameters` as a replica would forward it.
    fn run(self: *Master, text: []const u8, parameters: []const MapEntry) !forwarding.Answer {
        const a = self.arena.allocator();
        var request: std.ArrayList(u8) = .empty;
        try forwarding.encodeRequest(&request, a, .{ .text = text, .parameters = parameters });
        return self.answer(request.items);
    }

    fn answer(self: *Master, request: []const u8) !forwarding.Answer {
        const a = self.arena.allocator();
        return forwarding.decodeAnswer(try forwarded_writes.run(&self.graph, a, request), a);
    }

    fn doors(self: *Master) !i64 {
        const answer_ = try self.run("MATCH (d:Door) RETURN count(d) AS doors", &.{});
        return answer_.done.results[0].rows[0][0].int;
    }

    fn expectFailure(self: *Master, text: []const u8, code: ErrorCode) !void {
        const lsn = try self.lastLsn();
        const answer_ = try self.run(text, &.{});
        try testing.expectEqual(@backingInt(code), answer_.failed.code);
        try testing.expect(answer_.failed.message.len > 0);
        try testing.expectEqual(lsn, try self.lastLsn());
    }
};

test "a forwarded write commits on the master and answers its rows and LSN" {
    var master: Master = undefined;
    try master.init();
    defer master.deinit();
    const before = try master.lastLsn();
    const answer = try master.run("CREATE (d:Door {name: $name}) RETURN d.name AS name, 1 + 1 AS two", &.{.{ .key = "name", .value = .{ .string = "B7" } }});
    const done = answer.done;
    try testing.expectEqual(before + 1, done.lsn);
    try testing.expectEqual(done.lsn, try master.lastLsn());
    try testing.expectEqual(2, done.results[0].columns.len);
    try testing.expectEqualStrings("name", done.results[0].columns[0]);
    try testing.expectEqualStrings("two", done.results[0].columns[1]);
    try testing.expectEqual(1, done.results[0].rows.len);
    try testing.expect(Value.eql(.{ .string = "B7" }, done.results[0].rows[0][0]));
    try testing.expect(Value.eql(.{ .int = 2 }, done.results[0].rows[0][1]));
    // A read commits nothing; its LSN is the master's last.
    try testing.expectEqual(1, try master.doors());
    try testing.expectEqual(done.lsn, try master.lastLsn());
    // Without RETURN: no columns, no rows.
    const bare = (try master.run("CREATE (:Door)", &.{})).done;
    try testing.expectEqual(before + 2, bare.lsn);
    try testing.expectEqual(0, bare.results[0].columns.len);
    try testing.expectEqual(0, bare.results[0].rows.len);
}

test "a forwarded write answers the entities its rows refer to, as it left them" {
    var master: Master = undefined;
    try master.init();
    defer master.deinit();
    const created = (try master.run("CREATE (a:Door:Exit {name: 'B7'})-[r:LEADS_TO {steps: 3}]->(b:Room) RETURN a, r, [b] AS rooms", &.{})).done.results[0];
    const door = created.entities.nodes.get(created.rows[0][0].node).?;
    try testing.expectEqual(2, door.labels.len);
    try testing.expectEqual(1, door.properties.len);
    try testing.expectEqualStrings("name", door.properties[0].name);
    try testing.expect(Value.eql(.{ .string = "B7" }, door.properties[0].value));
    const leads_to = created.entities.relationships.getContext(created.rows[0][1].relationship, .{}).?;
    try testing.expect(Value.eql(.{ .int = 3 }, leads_to[0].value));
    // Inside a list too.
    const room = created.entities.nodes.get(created.rows[0][2].list[0].node).?;
    try testing.expectEqualStrings("Room", room.labels[0]);
    try testing.expectEqual(3, created.entities.nodes.count() + created.entities.relationships.count());
    // A node the write deleted keeps its id, with nothing else.
    const deleted = (try master.run("MATCH (b:Room) DETACH DELETE b RETURN b", &.{})).done.results[0];
    const gone = deleted.entities.nodes.get(deleted.rows[0][0].node).?;
    try testing.expectEqual(0, gone.labels.len + gone.properties.len);
}

test "a schema command runs in a transaction of its own" {
    var master: Master = undefined;
    try master.init();
    defer master.deinit();
    const before = try master.lastLsn();
    const done = (try master.run("CREATE INDEX door_name FOR (d:Door) ON (d.name)", &.{})).done;
    try testing.expect(done.lsn > before);
    try testing.expectEqual(done.lsn, try master.lastLsn());
}

test "a forwarded write that fails commits nothing and answers why" {
    var master: Master = undefined;
    try master.init();
    defer master.deinit();
    try master.expectFailure("CREATE (", .parse);
    try master.expectFailure("CREATE (:Door {name: $name})", .parameter_missing);
    try master.expectFailure("CREATE (:Door {width: 1 / 0})", .arithmetic);
    // Fails after it wrote: rolled back.
    try master.expectFailure("CREATE (d:Door) WITH d RETURN 1 / 0 AS x", .arithmetic);
    // Its result cannot be sent: rolled back.
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(testing.allocator);
    try deep.appendSlice(testing.allocator, "CREATE (d:Door) RETURN ");
    try deep.appendNTimes(testing.allocator, '[', 65);
    try deep.append(testing.allocator, '1');
    try deep.appendNTimes(testing.allocator, ']', 65);
    try deep.appendSlice(testing.allocator, " AS deep");
    try master.expectFailure(deep.items, .invalid_expression);
    // The replica's import directory and procedures are not the master's.
    const load = try master.run("LOAD CSV FROM 'doors.csv' AS row CREATE (:Door {name: row[0]})", &.{});
    try testing.expect(load == .failed);
    const call = try master.run("CALL my.procedure()", &.{});
    try testing.expect(call == .failed);
    try testing.expectEqual(0, try master.doors());
}

test "a malformed request is answered with a failure" {
    var master: Master = undefined;
    try master.init();
    defer master.deinit();
    for ([_][]const u8{ "", "\xff\xff\xff\xff", "\x00\x00\x00\x00\x05" }) |request| {
        const answer = try master.answer(request);
        try testing.expectEqual(@backingInt(ErrorCode.invalid_expression), answer.failed.code);
    }
}

test "a batch runs in one transaction: each statement sees the ones before, one LSN for all" {
    var master: Master = undefined;
    try master.init();
    defer master.deinit();
    const before = try master.lastLsn();
    const a = master.arena.allocator();
    var request: std.ArrayList(u8) = .empty;
    try forwarding.encodeRequests(&request, a, &.{
        .{ .text = "CREATE (:Door {name: $name})", .parameters = &.{.{ .key = "name", .value = .{ .string = "B7" } }} },
        .{ .text = "MATCH (d:Door) RETURN count(d) AS doors", .parameters = &.{} },
        .{ .text = "CREATE (d:Door {name: 'B8'}) RETURN d", .parameters = &.{} },
    });
    const done = (try master.answer(request.items)).done;
    try testing.expectEqual(before + 1, done.lsn);
    try testing.expectEqual(done.lsn, try master.lastLsn());
    try testing.expectEqual(3, done.results.len);
    try testing.expectEqual(0, done.results[0].columns.len);
    try testing.expect(Value.eql(.{ .int = 1 }, done.results[1].rows[0][0]));
    const door = done.results[2].entities.nodes.get(done.results[2].rows[0][0].node).?;
    try testing.expectEqualStrings("Door", door.labels[0]);
    try testing.expectEqual(2, try master.doors());
}

test "a batch that fails commits nothing and says which statement failed" {
    var master: Master = undefined;
    try master.init();
    defer master.deinit();
    const before = try master.lastLsn();
    const a = master.arena.allocator();
    const batches = [_]struct { requests: []const forwarding.Request, failed: u32, code: ErrorCode }{
        // At run time.
        .{ .requests = &.{
            .{ .text = "CREATE (:Door)", .parameters = &.{} },
            .{ .text = "RETURN 1 / 0 AS never", .parameters = &.{} },
        }, .failed = 1, .code = .arithmetic },
        // Before: one that does not parse, one that cannot go in a batch.
        .{ .requests = &.{
            .{ .text = "CREATE (:Door)", .parameters = &.{} },
            .{ .text = "CREATE (:Door)", .parameters = &.{} },
            .{ .text = "CREATE (", .parameters = &.{} },
        }, .failed = 2, .code = .parse },
        .{ .requests = &.{
            .{ .text = "CREATE (:Door)", .parameters = &.{} },
            .{ .text = "CREATE INDEX door_name FOR (d:Door) ON (d.name)", .parameters = &.{} },
        }, .failed = 1, .code = .invalid_expression },
        .{ .requests = &.{
            .{ .text = "LOAD CSV FROM 'doors.csv' AS row CREATE (:Door {name: row[0]})", .parameters = &.{} },
            .{ .text = "CREATE (:Door)", .parameters = &.{} },
        }, .failed = 0, .code = .invalid_expression },
    };
    for (batches) |batch| {
        var request: std.ArrayList(u8) = .empty;
        try forwarding.encodeRequests(&request, a, batch.requests);
        const failure = (try master.answer(request.items)).failed;
        try testing.expectEqual(batch.failed, failure.statement);
        try testing.expectEqual(@backingInt(batch.code), failure.code);
    }
    try testing.expectEqual(0, try master.doors());
    try testing.expectEqual(before, try master.lastLsn());
}
