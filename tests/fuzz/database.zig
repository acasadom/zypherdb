//! A database the fuzzers run statements on (faults.zig, crash.zig), with
//! what they compare databases by: a digest of every stored entry, and the
//! entries that differ.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zypherdb = @import("zypherdb");
const workload = @import("fault_workload.zig");
const Outcome = @import("query_results.zig").Outcome;

const Graph = zypherdb.Graph;
const KeyValueStore = zypherdb.KeyValueStore;
const Statement = zypherdb.Statement;

const Database = @This();

store: KeyValueStore,
graph: Graph,
/// Prepared statements by text (the caller keeps the texts alive).
statements: std.StringHashMapUnmanaged(*Statement) = .empty,

/// The fuzzers' store options: durability does not matter to them (the
/// crash fuzzer chooses its own).
pub const fuzz_options = KeyValueStore.Options{ .durability = .deferred };

pub fn open(self: *Database, allocator: Allocator, path: []const u8, options: KeyValueStore.Options) !void {
    self.* = .{ .store = try KeyValueStore.openWithOptions(allocator, path, options), .graph = undefined };
    self.graph = Graph.init(&self.store, allocator);
}

pub fn close(self: *Database, allocator: Allocator) void {
    var statements = self.statements.valueIterator();
    while (statements.next()) |statement| statement.*.destroy();
    self.statements.deinit(allocator);
    self.store.deinit();
}

/// Runs `step`'s statement (prepared, or kept from an earlier run, if
/// `prepared`); rows and the run's memory go to `arena`.
pub fn run(self: *Database, allocator: Allocator, arena: Allocator, step: workload.Step, prepared: bool, parameters: zypherdb.Executor.Parameters) Allocator.Error!Outcome {
    const rows = if (prepared) rows: {
        const statement = self.statements.get(step.text) orelse made: {
            const statement = Statement.prepare(allocator, step.text, .{ .graph = &self.graph }) catch |err| return failure(err);
            errdefer statement.destroy();
            try self.statements.put(allocator, step.text, statement);
            break :made statement;
        };
        var executor = statement.executorFor(&self.graph, arena);
        executor.parameters = parameters;
        break :rows statement.run(&executor) catch |err| return failure(err);
    } else rows: {
        const ast = try arena.create(zypherdb.Ast);
        ast.* = zypherdb.Ast.init(arena);
        const root = zypherdb.parser.parse(ast, step.text, null) catch |err| return failure(err);
        var executor = zypherdb.Executor.init(ast, &self.graph, arena);
        executor.parameters = parameters;
        break :rows executor.run(root) catch |err| return failure(err);
    };
    return Outcome.fromRows(arena, rows, step.ordered);
}

fn failure(err: anyerror) Allocator.Error!Outcome {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = err };
}

/// A hash of every record and key of the database, read in its own
/// transaction, without the engine's catalog of its tables.
pub fn digest(self: *Database) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    inline for (.{ KeyValueStore.scanAll, KeyValueStore.scanNodes, KeyValueStore.scanRelationships }) |scan| {
        var iterator = try scan(&self.store);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (isTableCatalogEntry(entry.key)) continue;
            hasher.update(std.mem.asBytes(&entry.key.len));
            hasher.update(entry.key);
            hasher.update(std.mem.asBytes(&entry.value.len));
            hasher.update(entry.value);
        }
        hasher.update("|");
    }
    return hasher.final();
}

/// Every entry of the three tables, in order, copied into `arena`
/// (the table's number first in each key).
pub fn entries(self: *Database, arena: Allocator) !std.ArrayList(Pair) {
    var list = std.ArrayList(Pair).empty;
    inline for (.{ KeyValueStore.scanAll, KeyValueStore.scanNodes, KeyValueStore.scanRelationships }, 0..) |scan, table| {
        var iterator = try scan(&self.store);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (isTableCatalogEntry(entry.key)) continue;
            const key = try std.mem.concat(arena, u8, &.{ &.{@as(u8, table)}, entry.key });
            try list.append(arena, .{ .key = key, .value = try arena.dupe(u8, entry.value) });
        }
    }
    return list;
}

pub fn checkIntegrity(self: *Database, allocator: Allocator, out: *std.Io.Writer) !bool {
    var report = try zypherdb.integrity.check(&self.graph, allocator);
    defer report.deinit();
    if (report.ok()) return true;
    try out.print("{f}", .{report});
    return false;
}

/// Prints the first entries that differ between `self` and `twin` (table
/// number, then key and value bytes).
pub fn printDifference(self: *Database, twin: *Database, arena: Allocator, out: *std.Io.Writer) !void {
    const mine = (try self.entries(arena)).items;
    const theirs = (try twin.entries(arena)).items;
    var i: usize = 0;
    var j: usize = 0;
    var printed: usize = 0;
    while ((i < mine.len or j < theirs.len) and printed < 10) {
        const order = if (i == mine.len) std.math.Order.gt else if (j == theirs.len) std.math.Order.lt else std.mem.order(u8, mine[i].key, theirs[j].key);
        switch (order) {
            .lt => {
                try out.print("only here: {x} = {x}\n", .{ mine[i].key, mine[i].value });
                i += 1;
                printed += 1;
            },
            .gt => {
                try out.print("only in the twin: {x} = {x}\n", .{ theirs[j].key, theirs[j].value });
                j += 1;
                printed += 1;
            },
            .eq => {
                if (!std.mem.eql(u8, mine[i].value, theirs[j].value)) {
                    try out.print("differs: {x} = {x}, twin {x}\n", .{ mine[i].key, mine[i].value, theirs[j].value });
                    printed += 1;
                }
                i += 1;
                j += 1;
            },
        }
    }
}

/// An entry the engine keeps in the main table for one of its other tables
/// (LMDB names them with a trailing 0x00, libmdbx without): its value
/// describes the table's pages, which may differ between equal databases.
fn isTableCatalogEntry(key: []const u8) bool {
    const name = if (std.mem.endsWith(u8, key, "\x00")) key[0 .. key.len - 1] else key;
    return std.mem.eql(u8, name, "#nodes") or std.mem.eql(u8, name, "#relationships");
}

/// A stored key and value, copied.
const Pair = struct { key: []const u8, value: []const u8 };
