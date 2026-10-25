//! Parser: query text to AST, and parse diagnostics.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const Index = zypherdb.Index;
const NodeKind = zypherdb.NodeKind;
const BinaryOperator = zypherdb.BinaryOperator;
const AggregateKind = zypherdb.AggregateKind;
const EdgeDirection = zypherdb.EdgeDirection;
const Diagnostic = zypherdb.Diagnostic;
const parse = zypherdb.parser.parse;

fn parseString(src: []const u8) !struct { ast: Ast, root: Index } {
    var ast = Ast.init(testing.allocator);
    errdefer ast.deinit();
    const root = try parse(&ast, src, null);
    return .{ .ast = ast, .root = root };
}

test "parses a simple MATCH/RETURN query" {
    var r = try parseString("MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born");
    defer r.ast.deinit();

    try testing.expectEqual(NodeKind.query, r.ast.kind(r.root));
    const query_children = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 2), query_children.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(query_children[0]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(query_children[1]));

    // match_clause -> [pattern, where=true]
    const match_children = r.ast.nodeChildren(query_children[0]);
    try testing.expectEqual(@as(usize, 2), match_children.len);
    try testing.expectEqual(NodeKind.pattern, r.ast.kind(match_children[0]));
    try testing.expectEqual(NodeKind.boolean_literal, r.ast.kind(match_children[1]));
    try testing.expect(r.ast.data(match_children[1]).boolean);

    // pattern -> single node
    const pattern_children = r.ast.nodeChildren(match_children[0]);
    try testing.expectEqual(@as(usize, 1), pattern_children.len);
    try testing.expectEqualStrings("p", r.ast.data(pattern_children[0]).node_pattern.variable_name);
    try testing.expectEqualStrings("Person", r.ast.data(pattern_children[0]).node_pattern.labels[0]);

    // return_clause -> projection -> property_access("born")
    const return_children = r.ast.nodeChildren(query_children[1]);
    const projection_children = r.ast.nodeChildren(return_children[0]);
    try testing.expectEqual(@as(usize, 1), projection_children.len);
    const item_children = r.ast.nodeChildren(projection_children[0]);
    try testing.expectEqual(NodeKind.property_access, r.ast.kind(item_children[0]));
    try testing.expectEqualStrings("born", r.ast.data(item_children[0]).text);
}

test "parses an edge, WHERE with AND, and multiple RETURN items" {
    var r = try parseString(
        "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE p.name = 'Keanu Reeves' AND m.released > 2000 RETURN p.name, m.title",
    );
    defer r.ast.deinit();

    const query_children = r.ast.nodeChildren(r.root);
    const match_children = r.ast.nodeChildren(query_children[0]);
    const pattern_children = r.ast.nodeChildren(match_children[0]);
    try testing.expectEqual(@as(usize, 3), pattern_children.len);
    try testing.expectEqualStrings("ACTED_IN", r.ast.data(pattern_children[1]).edge_pattern.singleType().?);
    try testing.expectEqual(EdgeDirection.left_to_right, r.ast.data(pattern_children[1]).edge_pattern.direction);

    try testing.expectEqual(NodeKind.binary_operation, r.ast.kind(match_children[1]));
    try testing.expectEqual(BinaryOperator.and_, r.ast.data(match_children[1]).binary_operator);

    const return_children = r.ast.nodeChildren(query_children[1]);
    try testing.expectEqual(@as(usize, 2), r.ast.nodeChildren(return_children[0]).len);
}

test "parses a reverse-direction edge chain" {
    var r = try parseString(
        "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name",
    );
    defer r.ast.deinit();

    const query_children = r.ast.nodeChildren(r.root);
    const match_children = r.ast.nodeChildren(query_children[0]);
    const pattern_children = r.ast.nodeChildren(match_children[0]);
    try testing.expectEqual(@as(usize, 5), pattern_children.len); // node edge node edge node
    try testing.expectEqual(EdgeDirection.left_to_right, r.ast.data(pattern_children[1]).edge_pattern.direction);
    try testing.expectEqualStrings("DIRECTED", r.ast.data(pattern_children[1]).edge_pattern.singleType().?);
    try testing.expectEqual(EdgeDirection.right_to_left, r.ast.data(pattern_children[3]).edge_pattern.direction);
    try testing.expectEqualStrings("ACTED_IN", r.ast.data(pattern_children[3]).edge_pattern.singleType().?);
}

test "parses RETURN alias and comparison operators" {
    var r = try parseString("MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title AS movie");
    defer r.ast.deinit();

    const query_children = r.ast.nodeChildren(r.root);
    const match_children = r.ast.nodeChildren(query_children[0]);
    try testing.expectEqual(NodeKind.binary_operation, r.ast.kind(match_children[1]));
    try testing.expectEqual(BinaryOperator.greater_or_equal, r.ast.data(match_children[1]).binary_operator);

    const return_children = r.ast.nodeChildren(query_children[1]);
    const projection_children = r.ast.nodeChildren(return_children[0]);
    try testing.expectEqualStrings("movie", r.ast.data(projection_children[0]).text);
}

test "parses string predicates and IN lists" {
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title STARTS WITH 'The' RETURN m.title");
        defer r.ast.deinit();
        const match_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinaryOperator.starts_with, r.ast.data(match_children[1]).binary_operator);
        try testing.expectEqual(NodeKind.string_literal, r.ast.kind(r.ast.nodeChildren(match_children[1])[1]));
    }
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title ENDS WITH 'Wick' RETURN m.title");
        defer r.ast.deinit();
        const match_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinaryOperator.ends_with, r.ast.data(match_children[1]).binary_operator);
    }
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title CONTAINS 'Matrix' RETURN m.title");
        defer r.ast.deinit();
        const match_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinaryOperator.contains, r.ast.data(match_children[1]).binary_operator);
    }
    {
        var r = try parseString("MATCH (p:Person) WHERE p.name IN ['Keanu Reeves', 'Tom Hanks'] RETURN p.name");
        defer r.ast.deinit();
        const match_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const where_expression = match_children[1];
        try testing.expectEqual(BinaryOperator.in_, r.ast.data(where_expression).binary_operator);
        const list = r.ast.nodeChildren(where_expression)[1];
        try testing.expectEqual(NodeKind.list_literal, r.ast.kind(list));
        try testing.expectEqual(@as(usize, 2), r.ast.nodeChildren(list).len);
    }
}

test "parses WITH and SKIP clauses" {
    var r = try parseString(
        "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt ORDER BY cnt DESC SKIP 1 LIMIT 5 WHERE cnt > 1 RETURN p.name, cnt",
    );
    defer r.ast.deinit();

    const query_children = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 3), query_children.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(query_children[0]));
    try testing.expectEqual(NodeKind.with_clause, r.ast.kind(query_children[1]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(query_children[2]));

    // with_clause children: [projection, order_by, skip, limit, where].
    const where_children = r.ast.nodeChildren(query_children[1]);
    try testing.expectEqual(@as(usize, 5), where_children.len);
    try testing.expectEqual(NodeKind.projection, r.ast.kind(where_children[0]));
    try testing.expectEqual(NodeKind.order_by, r.ast.kind(where_children[1]));
    try testing.expectEqual(NodeKind.skip, r.ast.kind(where_children[2]));
    try testing.expectEqual(NodeKind.limit, r.ast.kind(where_children[3]));
    try testing.expectEqual(NodeKind.binary_operation, r.ast.kind(where_children[4]));

    // projection has two items: `p` and `count(m) AS cnt`.
    const projection_children = r.ast.nodeChildren(where_children[0]);
    try testing.expectEqual(@as(usize, 2), projection_children.len);
    try testing.expectEqual(NodeKind.variable, r.ast.kind(r.ast.nodeChildren(projection_children[0])[0]));
    try testing.expectEqualStrings("cnt", r.ast.data(projection_children[1]).text);
}

test "parses OPTIONAL MATCH" {
    var r = try parseString(
        "MATCH (a:Person) OPTIONAL MATCH (a)-[:KNOWS]->(b:Person) RETURN a.name, b.name",
    );
    defer r.ast.deinit();

    const query_children = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 3), query_children.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(query_children[0]));
    try testing.expectEqual(NodeKind.optional_match_clause, r.ast.kind(query_children[1]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(query_children[2]));

    // optional_match_clause children: [pattern, where].
    const omc = r.ast.nodeChildren(query_children[1]);
    try testing.expectEqual(@as(usize, 2), omc.len);
    try testing.expectEqual(NodeKind.pattern, r.ast.kind(omc[0]));
}

test "parses lists: collect, size and UNWIND" {
    {
        var r = try parseString("MATCH (m:Movie) RETURN collect(m.title)");
        defer r.ast.deinit();
        const return_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[1]);
        const item = r.ast.nodeChildren(return_children[0])[0];
        try testing.expectEqual(NodeKind.aggregate, r.ast.kind(r.ast.nodeChildren(item)[0]));
        try testing.expectEqual(AggregateKind.collect, r.ast.data(r.ast.nodeChildren(item)[0]).aggregate.kind);
    }
    {
        var r = try parseString("RETURN size([1, 2, 3])");
        defer r.ast.deinit();
        const return_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const item = r.ast.nodeChildren(return_children[0])[0];
        const call = r.ast.nodeChildren(item)[0];
        try testing.expectEqual(NodeKind.function_call, r.ast.kind(call));
        try testing.expectEqualStrings("size", r.ast.data(call).text);
    }
    {
        var r = try parseString("UNWIND [1, 2, 3] AS x RETURN x");
        defer r.ast.deinit();
        const query_children = r.ast.nodeChildren(r.root);
        try testing.expectEqual(@as(usize, 2), query_children.len);
        try testing.expectEqual(NodeKind.unwind_clause, r.ast.kind(query_children[0]));
        try testing.expectEqualStrings("x", r.ast.data(query_children[0]).unwind.variable_name);
        const expr = r.ast.nodeChildren(query_children[0])[0];
        try testing.expectEqual(NodeKind.list_literal, r.ast.kind(expr));
    }
}

test "parses multi-label, CASE, REMOVE and MERGE ON" {
    {
        var r = try parseString("MATCH (n:Person:Employee) RETURN n.name");
        defer r.ast.deinit();
        const match_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const node_pattern = r.ast.data(r.ast.nodeChildren(match_children[0])[0]).node_pattern;
        try testing.expectEqual(@as(usize, 2), node_pattern.labels.len);
        try testing.expectEqualStrings("Person", node_pattern.labels[0]);
        try testing.expectEqualStrings("Employee", node_pattern.labels[1]);
    }
    {
        var r = try parseString("RETURN CASE WHEN 1 > 0 THEN 'yes' ELSE 'no' END");
        defer r.ast.deinit();
        const return_children = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const item = r.ast.nodeChildren(return_children[0])[0];
        try testing.expectEqual(NodeKind.case_expression, r.ast.kind(r.ast.nodeChildren(item)[0]));
    }
    {
        var r = try parseString("MATCH (n:Person) REMOVE n.name, n:Person");
        defer r.ast.deinit();
        const query_children = r.ast.nodeChildren(r.root);
        try testing.expectEqual(NodeKind.remove_clause, r.ast.kind(query_children[1]));
        const return_children = r.ast.nodeChildren(query_children[1]);
        try testing.expectEqual(@as(usize, 2), return_children.len);
        try testing.expectEqual(NodeKind.property_access, r.ast.kind(return_children[0]));
        try testing.expectEqual(NodeKind.label_reference, r.ast.kind(return_children[1]));
    }
    {
        var r = try parseString("MERGE (n:Person {name: 'X'}) ON CREATE SET n.c = 1 ON MATCH SET n.m = 1");
        defer r.ast.deinit();
        const query_children = r.ast.nodeChildren(r.root);
        const match_children = r.ast.nodeChildren(query_children[0]);
        try testing.expectEqual(@as(usize, 3), match_children.len); // pattern + on_create + on_match
        try testing.expectEqual(NodeKind.pattern, r.ast.kind(match_children[0]));
        try testing.expectEqual(NodeKind.set_clause, r.ast.kind(match_children[1]));
        try testing.expectEqual(NodeKind.set_clause, r.ast.kind(match_children[2]));
    }
}

test "parses write clauses (CREATE, SET, DELETE)" {
    var r = try parseString(
        "MATCH (a:Person {name: 'Keanu Reeves'}) CREATE (a)-[:KNOWS]->(b:Person {name: 'Neo'}) SET b.born = 1964 DELETE a RETURN b.name",
    );
    defer r.ast.deinit();

    const query_children = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 5), query_children.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(query_children[0]));
    try testing.expectEqual(NodeKind.create_clause, r.ast.kind(query_children[1]));
    try testing.expectEqual(NodeKind.set_clause, r.ast.kind(query_children[2]));
    try testing.expectEqual(NodeKind.delete_clause, r.ast.kind(query_children[3]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(query_children[4]));

    // create_clause -> pattern (node edge node)
    const cc = r.ast.nodeChildren(query_children[1]);
    const cpc = r.ast.nodeChildren(cc[0]);
    try testing.expectEqual(@as(usize, 3), cpc.len);
    try testing.expectEqualStrings("KNOWS", r.ast.data(cpc[1]).edge_pattern.singleType().?);

    // set_clause -> one set_item (property_access + value)
    const sc = r.ast.nodeChildren(query_children[2]);
    try testing.expectEqual(@as(usize, 1), sc.len);
    try testing.expectEqual(NodeKind.set_item, r.ast.kind(sc[0]));
    const set_item_children = r.ast.nodeChildren(sc[0]);
    try testing.expectEqual(NodeKind.property_access, r.ast.kind(set_item_children[0]));
    try testing.expectEqualStrings("born", r.ast.data(set_item_children[0]).text);
}

test "reports unterminated string" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:Person {name: 'Keanu}) RETURN p.born", null));
}

test "reports unexpected token" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:Person) RETURN", null));
}

test "diagnostics carry a message and position" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    var diagnostic = Diagnostic.init();
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:Person) RETURN )", &diagnostic));
    try testing.expectEqualStrings("expected an expression, found ')'", diagnostic.message());
    try testing.expectEqual(@as(usize, 24), diagnostic.pos);

    var second_diagnostic = Diagnostic.init();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:Person {name: 'Keanu}) RETURN p.born", &second_diagnostic));
    try testing.expectEqualStrings("unterminated string literal", second_diagnostic.message());
}

test "UTF-8 and backtick-quoted identifiers" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    _ = try parse(&ast, "MATCH (p:Pérsona {año: 2024}) RETURN p.año", null);
    // A quoted identifier may hold spaces and keywords, and is never a keyword.
    _ = try parse(&ast, "MATCH (`my node`:`Zona Norte`)-[:`ACCEDE A`]->(m:`MATCH`) RETURN `my node`.`full name`, m.count", null);

    var diagnostic = Diagnostic.init();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:`Open", &diagnostic));
    try testing.expectEqualStrings("unterminated quoted identifier", diagnostic.message());
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:``) RETURN p", null));
}

test "every parse failure carries a message" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    const cases = [_][]const u8{
        "RETURN 1 2", // trailing tokens
        "", // no clause
        "MERGE (a) ON DELETE SET a.x = 1", // bad ON
        "RETURN 99999999999999999999", // integer overflow
    };
    for (cases) |src| {
        var diagnostic = Diagnostic.init();
        try testing.expectError(error.UnexpectedToken, parse(&ast, src, &diagnostic));
        try testing.expect(diagnostic.message().len > 0);
        try testing.expectEqual(zypherdb.diagnostics.ErrorCode.parse, diagnostic.code);
    }
}
