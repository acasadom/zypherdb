//! LOAD CSV: records as rows, read only from the import directory.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const Value = acmedb.Value;
const Executor = acmedb.Executor;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectRows = support.expectRows;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn string(s: []const u8) Value {
    return .{ .string = s };
}

const null_value: Value = .{ .null = {} };

/// Runs `src` with LOAD CSV reading from `import_directory` (null: off).
fn run(ast: *Ast, g: *Graph, import_directory: ?[]const u8, src: []const u8, expected: []const []const Value) !void {
    const query = try acmedb.parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    executor.import_directory = import_directory;
    try expectRows(try executor.run(query), expected);
}

fn runError(ast: *Ast, g: *Graph, import_directory: ?[]const u8, src: []const u8, expected: anyerror) !void {
    const query = try acmedb.parser.parse(ast, src, null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = Executor.init(ast, g, arena.allocator());
    executor.import_directory = import_directory;
    try testing.expectError(expected, executor.run(query));
}

test "LOAD CSV reads records as lists, or as maps with headers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    var imports = testing.tmpDir(.{});
    defer imports.cleanup();
    var import_buffer: [256]u8 = undefined;
    const import_directory = support.testPath(&imports, &import_buffer);
    const io = testing.io;
    try imports.dir.writeFile(io, .{ .sub_path = "people.csv", .data = "name,card,zone\nAna,1001,north\nBo,1002,\n\"Cy, Jr.\",1003,\"south\"\n" });
    try imports.dir.createDirPath(io, "doors");
    try imports.dir.writeFile(io, .{ .sub_path = "doors/main.csv", .data = "1;Main;on\r\n2;Side;off\r\n" });

    // Without headers: lists of strings; an empty field is null.
    try run(&ast, &g, import_directory, "LOAD CSV FROM 'file:///people.csv' AS row RETURN row", &.{
        &.{.{ .list = &.{ string("name"), string("card"), string("zone") } }},
        &.{.{ .list = &.{ string("Ana"), string("1001"), string("north") } }},
        &.{.{ .list = &.{ string("Bo"), string("1002"), null_value } }},
        &.{.{ .list = &.{ string("Cy, Jr."), string("1003"), string("south") } }},
    });
    // With headers: maps; converted and written in one query.
    try run(&ast, &g, import_directory,
        \\LOAD CSV WITH HEADERS FROM 'file:///people.csv' AS row
        \\CREATE (:Person {name: row.name, card: toInteger(row.card), zone: row.zone})
    , &.{});
    try expectQuery(&ast, &g, "MATCH (p:Person) RETURN p.name, p.card, p.zone ORDER BY p.card", &.{
        &.{ string("Ana"), int(1001), string("north") },
        &.{ string("Bo"), int(1002), null_value },
        &.{ string("Cy, Jr."), int(1003), string("south") },
    });
    // A subdirectory, a field terminator, CRLF line ends, a URL from a parameter-free expression.
    try run(&ast, &g, import_directory, "LOAD CSV FROM 'file:///doors/' + 'main.csv' AS row FIELDTERMINATOR ';' RETURN row[1] ORDER BY row[0]", &.{ &.{string("Main")}, &.{string("Side")} });
    // `file:/x` and percent-escapes name the same file.
    try run(&ast, &g, import_directory, "LOAD CSV FROM 'file:/doors/%6Dain.csv' AS row FIELDTERMINATOR ';' RETURN count(*)", &.{&.{int(2)}});
}

test "LOAD CSV reads nothing outside the import directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    var imports = testing.tmpDir(.{});
    defer imports.cleanup();
    var import_buffer: [256]u8 = undefined;
    const import_directory = support.testPath(&imports, &import_buffer);
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    const io = testing.io;
    try outside.dir.writeFile(io, .{ .sub_path = "secret.csv", .data = "s3cret\n" });
    try imports.dir.writeFile(io, .{ .sub_path = "ok.csv", .data = "a\n" });
    // A symbolic link that leads out.
    var link_target_buffer: [256]u8 = undefined;
    const link_target = try std.fmt.bufPrint(&link_target_buffer, "../{s}/secret.csv", .{&outside.sub_path});
    try imports.dir.symLink(io, link_target, "link.csv", .{});

    const refused = [_][]const u8{
        "LOAD CSV FROM 'file:///../" ++ "x.csv' AS row RETURN row",
        "LOAD CSV FROM 'file:///link.csv' AS row RETURN row",
        "LOAD CSV FROM 'file:///missing.csv' AS row RETURN row",
        "LOAD CSV FROM 'https://example.com/x.csv' AS row RETURN row",
        "LOAD CSV FROM '/etc/hosts' AS row RETURN row",
    };
    for (refused) |query| try runError(&ast, &g, import_directory, query, error.ExternalResourceFailed);
    var escape_buffer: [256]u8 = undefined;
    const escape = try std.fmt.bufPrint(&escape_buffer, "LOAD CSV FROM 'file:///../{s}/secret.csv' AS row RETURN row", .{&outside.sub_path});
    try runError(&ast, &g, import_directory, escape, error.ExternalResourceFailed);
    // Without an import directory, LOAD CSV is off.
    try runError(&ast, &g, null, "LOAD CSV FROM 'file:///ok.csv' AS row RETURN row", error.ExternalResourceFailed);
    try run(&ast, &g, import_directory, "LOAD CSV FROM 'file:///ok.csv' AS row RETURN row", &.{&.{.{ .list = &.{string("a")} }}});
    // A terminator of two characters, a URL that is not a string.
    try runError(&ast, &g, import_directory, "LOAD CSV FROM 'file:///ok.csv' AS row FIELDTERMINATOR ';;' RETURN row", error.InvalidExpression);
    try runError(&ast, &g, import_directory, "LOAD CSV FROM 1 AS row RETURN row", error.TypeMismatch);
}
