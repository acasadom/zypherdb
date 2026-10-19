//! The C ABI, exercised the way a foreign caller uses it.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const c_api = acmedb.c_api;
const acmedb_open = c_api.acmedb_open;
const acmedb_close = c_api.acmedb_close;
const acmedb_last_error = c_api.acmedb_last_error;
const acmedb_error_code = c_api.acmedb_error_code;
const acmedb_begin_write = c_api.acmedb_begin_write;
const acmedb_commit_write = c_api.acmedb_commit_write;
const acmedb_abort_write = c_api.acmedb_abort_write;
const acmedb_allocate_node_id = c_api.acmedb_allocate_node_id;
const acmedb_add_node = c_api.acmedb_add_node;
const acmedb_add_edge = c_api.acmedb_add_edge;
const acmedb_set_property_int64 = c_api.acmedb_set_property_int64;
const acmedb_set_property_string = c_api.acmedb_set_property_string;
const acmedb_query = c_api.acmedb_query;
const acmedb_result_free = c_api.acmedb_result_free;
const acmedb_result_row_count = c_api.acmedb_result_row_count;
const acmedb_result_column_count = c_api.acmedb_result_column_count;
const acmedb_result_type = c_api.acmedb_result_type;
const acmedb_result_int = c_api.acmedb_result_int;
const acmedb_result_string = c_api.acmedb_result_string;
const acmedb_result_to_json = c_api.acmedb_result_to_json;
const acmedb_result_list_length = c_api.acmedb_result_list_length;
const acmedb_result_list_item_type = c_api.acmedb_result_list_item_type;
const acmedb_result_list_item_int = c_api.acmedb_result_list_item_int;
const TYPE_INT64 = c_api.TYPE_INT64;
const TYPE_STRING = c_api.TYPE_STRING;
const TYPE_LIST = c_api.TYPE_LIST;
const RETURN_OK = c_api.RETURN_OK;
const RETURN_NODE_NOT_FOUND = c_api.RETURN_NODE_NOT_FOUND;

test "C ABI: open, load, query and read results" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const context = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(context);

    try testing.expectEqual(@as(c_int, 0), acmedb_add_node(context, 1, "Person".ptr, "Person".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_set_property_string(context, 1, "name".ptr, "name".len, "Keanu Reeves".ptr, "Keanu Reeves".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_set_property_int64(context, 1, "born".ptr, "born".len, 1964));
    try testing.expectEqual(@as(c_int, 0), acmedb_add_node(context, 100, "Movie".ptr, "Movie".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_set_property_string(context, 100, "title".ptr, "title".len, "The Matrix".ptr, "The Matrix".len));
    try testing.expectEqual(@as(c_int, 0), acmedb_add_edge(context, 1, 100, "ACTED_IN".ptr, "ACTED_IN".len));

    const q = "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title";
    const result = acmedb_query(context, q.ptr, q.len).?;
    defer acmedb_result_free(result);

    try testing.expectEqual(@as(usize, 1), acmedb_result_row_count(result));
    try testing.expectEqual(@as(usize, 1), acmedb_result_column_count(result));
    try testing.expectEqual(TYPE_STRING, acmedb_result_type(result, 0, 0));

    var len: usize = 0;
    const s = acmedb_result_string(result, 0, 0, &len);
    try testing.expectEqualStrings("The Matrix", s[0..len]);
}

test "C ABI: node ids, list results and error codes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const context = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(context);

    // Node id allocation is monotonic.
    const a = acmedb_allocate_node_id(context);
    const b = acmedb_allocate_node_id(context);
    try testing.expect(a != b);
    try testing.expectEqual(a + 1, b);

    // A list result is readable.
    const q1 = "RETURN [1, 2, 3]";
    const r1 = acmedb_query(context, q1.ptr, q1.len).?;
    defer acmedb_result_free(r1);
    try testing.expectEqual(TYPE_LIST, acmedb_result_type(r1, 0, 0));
    try testing.expectEqual(@as(usize, 3), acmedb_result_list_length(r1, 0, 0));
    try testing.expectEqual(TYPE_INT64, acmedb_result_list_item_type(r1, 0, 0, 0));
    try testing.expectEqual(@as(i64, 2), acmedb_result_list_item_int(r1, 0, 0, 1));

    // A parse error carries a code + message.
    const q2 = "MATCH (";
    try testing.expect(acmedb_query(context, q2.ptr, q2.len) == null);
    try testing.expectEqual(@as(c_int, 1), acmedb_error_code(context));

    // An unknown variable carries code 2.
    const q3 = "RETURN n.name";
    try testing.expect(acmedb_query(context, q3.ptr, q3.len) == null);
    try testing.expectEqual(@as(c_int, 2), acmedb_error_code(context));

    // A type mismatch carries code 4 (and a generic message).
    const q4 = "RETURN size(1)";
    try testing.expect(acmedb_query(context, q4.ptr, q4.len) == null);
    try testing.expectEqual(@as(c_int, 4), acmedb_error_code(context));
    var len: usize = 0;
    const msg = acmedb_last_error(context, &len);
    try testing.expect(len > 0);
    _ = msg;
}

test "C ABI: bulk JSON result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const context = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(context);

    // Scalars, a string and a list, in one JSON array-of-arrays.
    const q1 = "RETURN 1, 'x', [1, 2, 3]";
    const r1 = acmedb_query(context, q1.ptr, q1.len).?;
    defer acmedb_result_free(r1);
    var len1: usize = 0;
    const json1 = acmedb_result_to_json(r1, &len1);
    try testing.expectEqualStrings("[[1,\"x\",[1,2,3]]]", json1[0..len1]);

    // A double quote inside a string is escaped.
    const q2 = "RETURN 'say \"hi\"'";
    const r2 = acmedb_query(context, q2.ptr, q2.len).?;
    defer acmedb_result_free(r2);
    var len2: usize = 0;
    const json2 = acmedb_result_to_json(r2, &len2);
    try testing.expectEqualStrings("[[\"say \\\"hi\\\"\"]]", json2[0..len2]);
}

test "C ABI: batched write transaction commits atomically and aborts cleanly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const context = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(context);

    // 100 nodes in one transaction.
    try testing.expectEqual(@as(c_int, 0), acmedb_begin_write(context));
    for (0..100) |i| {
        const id = acmedb_allocate_node_id(context);
        try testing.expect(id != std.math.maxInt(u64));
        try testing.expectEqual(@as(c_int, 0), acmedb_add_node(context, id, "Person".ptr, "Person".len));
        try testing.expectEqual(@as(c_int, 0), acmedb_set_property_int64(context, id, "n".ptr, "n".len, @intCast(i)));
    }
    try testing.expectEqual(@as(c_int, 0), acmedb_commit_write(context));

    const q = "MATCH (n:Person) RETURN count(n)";
    const r = acmedb_query(context, q.ptr, q.len).?;
    defer acmedb_result_free(r);
    try testing.expectEqual(@as(i64, 100), acmedb_result_int(r, 0, 0));

    // An aborted transaction leaves nothing behind.
    try testing.expectEqual(@as(c_int, 0), acmedb_begin_write(context));
    const id = acmedb_allocate_node_id(context);
    try testing.expectEqual(@as(c_int, 0), acmedb_add_node(context, id, "Ghost".ptr, "Ghost".len));
    acmedb_abort_write(context);

    const q2 = "MATCH (n:Ghost) RETURN count(n)";
    const r2 = acmedb_query(context, q2.ptr, q2.len).?;
    defer acmedb_result_free(r2);
    // No Ghost nodes survive the abort: the count over zero matches is 0.
    try testing.expectEqual(@as(usize, 1), acmedb_result_row_count(r2));
    try testing.expectEqual(@as(i64, 0), acmedb_result_int(r2, 0, 0));
}

test "C ABI: mutators reject nodes that do not exist" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;

    const context = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(context);

    try testing.expectEqual(RETURN_OK, acmedb_add_node(context, 1, "P".ptr, "P".len));
    // A dangling edge and properties on a missing node are refused.
    try testing.expectEqual(RETURN_NODE_NOT_FOUND, acmedb_add_edge(context, 1, 999, "X".ptr, "X".len));
    try testing.expectEqual(RETURN_NODE_NOT_FOUND, acmedb_add_edge(context, 999, 1, "X".ptr, "X".len));
    try testing.expectEqual(RETURN_NODE_NOT_FOUND, acmedb_set_property_int64(context, 999, "v".ptr, "v".len, 1));
    try testing.expectEqual(RETURN_NODE_NOT_FOUND, acmedb_set_property_string(context, 999, "v".ptr, "v".len, "a".ptr, "a".len));
    try testing.expect(!try context.graph.hasNode(999));
    try testing.expect(!try context.graph.hasEdge(1, 999, "X"));

    try testing.expectEqual(RETURN_OK, acmedb_add_node(context, 2, "P".ptr, "P".len));
    try testing.expectEqual(RETURN_OK, acmedb_add_edge(context, 1, 2, "X".ptr, "X".len));
}

test "C ABI: export the whole graph as JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
    const context = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(context);

    const create = "CREATE (a:Person:Admin {name: 'Ana', age: 40})-[:KNOWS {since: 2020}]->(b {name: 'Bo'})";
    acmedb_result_free(acmedb_query(context, create.ptr, create.len).?);

    var length: usize = 0;
    const json = c_api.acmedb_export_json(context, &length).?;
    try testing.expectEqualStrings(
        "{\"nodes\":[" ++
            "{\"id\":0,\"labels\":[\"Admin\",\"Person\"],\"properties\":{\"age\":40,\"name\":\"Ana\"}}," ++
            "{\"id\":1,\"labels\":[],\"properties\":{\"name\":\"Bo\"}}" ++
            "],\"relationships\":[" ++
            "{\"source\":0,\"target\":1,\"type\":\"KNOWS\",\"properties\":{\"since\":2020}}" ++
            "]}",
        json[0..length],
    );
}

test "C ABI: whole nodes and relationships in the JSON result" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path}) catch unreachable;
    const context = acmedb_open(path.ptr, path.len).?;
    defer acmedb_close(context);

    const create = "CREATE (:A {k: 1})-[:R {w: 2}]->(:B)";
    acmedb_result_free(acmedb_query(context, create.ptr, create.len).?);
    const query = "MATCH (a:A)-[r]->(b) RETURN a, r";
    const result = acmedb_query(context, query.ptr, query.len).?;
    defer acmedb_result_free(result);

    try testing.expectEqual(c_api.TYPE_NODE, acmedb_result_type(result, 0, 0));
    try testing.expectEqual(c_api.TYPE_RELATIONSHIP, acmedb_result_type(result, 0, 1));
    var length: usize = 0;
    const json = acmedb_result_to_json(result, &length);
    try testing.expectEqualStrings(
        "[[{\"~node\":{\"id\":0,\"labels\":[\"A\"],\"properties\":{\"k\":1}}}," ++
            "{\"~relationship\":{\"source\":0,\"target\":1,\"type\":\"R\",\"properties\":{\"w\":2}}}]]",
        json[0..length],
    );
}
