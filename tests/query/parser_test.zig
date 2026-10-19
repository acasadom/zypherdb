//! Parser: query text to AST, and parse diagnostics.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Index = acmedb.Index;
const NodeKind = acmedb.NodeKind;
const BinOp = acmedb.BinOp;
const AggKind = acmedb.AggKind;
const EdgeDirection = acmedb.EdgeDirection;
const Diagnostic = acmedb.Diagnostic;
const parse = acmedb.parser.parse;

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
    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 2), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[1]));

    // match_clause -> [pattern, where=true]
    const mc = r.ast.nodeChildren(qc[0]);
    try testing.expectEqual(@as(usize, 2), mc.len);
    try testing.expectEqual(NodeKind.pattern, r.ast.kind(mc[0]));
    try testing.expectEqual(NodeKind.bool_literal, r.ast.kind(mc[1]));
    try testing.expect(r.ast.data(mc[1]).boolean);

    // pattern -> single node
    const pc = r.ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 1), pc.len);
    try testing.expectEqualStrings("p", r.ast.data(pc[0]).node_pattern.var_name);
    try testing.expectEqualStrings("Person", r.ast.data(pc[0]).node_pattern.labels[0]);

    // return_clause -> projection -> property_access("born")
    const rc = r.ast.nodeChildren(qc[1]);
    const projc = r.ast.nodeChildren(rc[0]);
    try testing.expectEqual(@as(usize, 1), projc.len);
    const ic = r.ast.nodeChildren(projc[0]);
    try testing.expectEqual(NodeKind.property_access, r.ast.kind(ic[0]));
    try testing.expectEqualStrings("born", r.ast.data(ic[0]).text);
}

test "parses an edge, WHERE with AND, and multiple RETURN items" {
    var r = try parseString(
        "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE p.name = 'Keanu Reeves' AND m.released > 2000 RETURN p.name, m.title",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    const mc = r.ast.nodeChildren(qc[0]);
    const pc = r.ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 3), pc.len);
    try testing.expectEqualStrings("ACTED_IN", r.ast.data(pc[1]).edge_pattern.etype);
    try testing.expectEqual(EdgeDirection.left_to_right, r.ast.data(pc[1]).edge_pattern.direction);

    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(mc[1]));
    try testing.expectEqual(BinOp.and_, r.ast.data(mc[1]).bin_op);

    const rc = r.ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 2), r.ast.nodeChildren(rc[0]).len);
}

test "parses a reverse-direction edge chain" {
    var r = try parseString(
        "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    const mc = r.ast.nodeChildren(qc[0]);
    const pc = r.ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 5), pc.len); // node edge node edge node
    try testing.expectEqual(EdgeDirection.left_to_right, r.ast.data(pc[1]).edge_pattern.direction);
    try testing.expectEqualStrings("DIRECTED", r.ast.data(pc[1]).edge_pattern.etype);
    try testing.expectEqual(EdgeDirection.right_to_left, r.ast.data(pc[3]).edge_pattern.direction);
    try testing.expectEqualStrings("ACTED_IN", r.ast.data(pc[3]).edge_pattern.etype);
}

test "parses RETURN alias and comparison operators" {
    var r = try parseString("MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title AS movie");
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    const mc = r.ast.nodeChildren(qc[0]);
    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(mc[1]));
    try testing.expectEqual(BinOp.ge, r.ast.data(mc[1]).bin_op);

    const rc = r.ast.nodeChildren(qc[1]);
    const projc = r.ast.nodeChildren(rc[0]);
    try testing.expectEqualStrings("movie", r.ast.data(projc[0]).text);
}

test "parses string predicates and IN lists" {
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title STARTS WITH 'The' RETURN m.title");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinOp.starts_with, r.ast.data(mc[1]).bin_op);
        try testing.expectEqual(NodeKind.string_literal, r.ast.kind(r.ast.nodeChildren(mc[1])[1]));
    }
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title ENDS WITH 'Wick' RETURN m.title");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinOp.ends_with, r.ast.data(mc[1]).bin_op);
    }
    {
        var r = try parseString("MATCH (m:Movie) WHERE m.title CONTAINS 'Matrix' RETURN m.title");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        try testing.expectEqual(BinOp.contains, r.ast.data(mc[1]).bin_op);
    }
    {
        var r = try parseString("MATCH (p:Person) WHERE p.name IN ['Keanu Reeves', 'Tom Hanks'] RETURN p.name");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const where_expr = mc[1];
        try testing.expectEqual(BinOp.in_, r.ast.data(where_expr).bin_op);
        const list = r.ast.nodeChildren(where_expr)[1];
        try testing.expectEqual(NodeKind.list_literal, r.ast.kind(list));
        try testing.expectEqual(@as(usize, 2), r.ast.nodeChildren(list).len);
    }
}

test "parses WITH and SKIP clauses" {
    var r = try parseString(
        "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt ORDER BY cnt DESC SKIP 1 LIMIT 5 WHERE cnt > 1 RETURN p.name, cnt",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 3), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.with_clause, r.ast.kind(qc[1]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[2]));

    // with_clause children: [projection, order_by, skip, limit, where].
    const wc = r.ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 5), wc.len);
    try testing.expectEqual(NodeKind.projection, r.ast.kind(wc[0]));
    try testing.expectEqual(NodeKind.order_by, r.ast.kind(wc[1]));
    try testing.expectEqual(NodeKind.skip, r.ast.kind(wc[2]));
    try testing.expectEqual(NodeKind.limit, r.ast.kind(wc[3]));
    try testing.expectEqual(NodeKind.binary_op, r.ast.kind(wc[4]));

    // projection has two items: `p` and `count(m) AS cnt`.
    const projc = r.ast.nodeChildren(wc[0]);
    try testing.expectEqual(@as(usize, 2), projc.len);
    try testing.expectEqual(NodeKind.variable, r.ast.kind(r.ast.nodeChildren(projc[0])[0]));
    try testing.expectEqualStrings("cnt", r.ast.data(projc[1]).text);
}

test "parses OPTIONAL MATCH" {
    var r = try parseString(
        "MATCH (a:Person) OPTIONAL MATCH (a)-[:KNOWS]->(b:Person) RETURN a.name, b.name",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 3), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.optional_match_clause, r.ast.kind(qc[1]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[2]));

    // optional_match_clause children: [pattern, where].
    const omc = r.ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 2), omc.len);
    try testing.expectEqual(NodeKind.pattern, r.ast.kind(omc[0]));
}

test "parses lists: collect, size and UNWIND" {
    {
        var r = try parseString("MATCH (m:Movie) RETURN collect(m.title)");
        defer r.ast.deinit();
        const rc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[1]);
        const item = r.ast.nodeChildren(rc[0])[0];
        try testing.expectEqual(NodeKind.agg, r.ast.kind(r.ast.nodeChildren(item)[0]));
        try testing.expectEqual(AggKind.collect, r.ast.data(r.ast.nodeChildren(item)[0]).agg);
    }
    {
        var r = try parseString("RETURN size([1, 2, 3])");
        defer r.ast.deinit();
        const rc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const item = r.ast.nodeChildren(rc[0])[0];
        try testing.expectEqual(NodeKind.size_fn, r.ast.kind(r.ast.nodeChildren(item)[0]));
    }
    {
        var r = try parseString("UNWIND [1, 2, 3] AS x RETURN x");
        defer r.ast.deinit();
        const qc = r.ast.nodeChildren(r.root);
        try testing.expectEqual(@as(usize, 2), qc.len);
        try testing.expectEqual(NodeKind.unwind_clause, r.ast.kind(qc[0]));
        try testing.expectEqualStrings("x", r.ast.data(qc[0]).unwind.var_name);
        const expr = r.ast.nodeChildren(qc[0])[0];
        try testing.expectEqual(NodeKind.list_literal, r.ast.kind(expr));
    }
}

test "parses multi-label, CASE, REMOVE and MERGE ON" {
    {
        var r = try parseString("MATCH (n:Person:Employee) RETURN n.name");
        defer r.ast.deinit();
        const mc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const np = r.ast.data(r.ast.nodeChildren(mc[0])[0]).node_pattern;
        try testing.expectEqual(@as(usize, 2), np.labels.len);
        try testing.expectEqualStrings("Person", np.labels[0]);
        try testing.expectEqualStrings("Employee", np.labels[1]);
    }
    {
        var r = try parseString("RETURN CASE WHEN 1 > 0 THEN 'yes' ELSE 'no' END");
        defer r.ast.deinit();
        const rc = r.ast.nodeChildren(r.ast.nodeChildren(r.root)[0]);
        const item = r.ast.nodeChildren(rc[0])[0];
        try testing.expectEqual(NodeKind.case_expr, r.ast.kind(r.ast.nodeChildren(item)[0]));
    }
    {
        var r = try parseString("MATCH (n:Person) REMOVE n.name, n:Person");
        defer r.ast.deinit();
        const qc = r.ast.nodeChildren(r.root);
        try testing.expectEqual(NodeKind.remove_clause, r.ast.kind(qc[1]));
        const rc = r.ast.nodeChildren(qc[1]);
        try testing.expectEqual(@as(usize, 2), rc.len);
        try testing.expectEqual(NodeKind.property_access, r.ast.kind(rc[0]));
        try testing.expectEqual(NodeKind.label_ref, r.ast.kind(rc[1]));
    }
    {
        var r = try parseString("MERGE (n:Person {name: 'X'}) ON CREATE SET n.c = 1 ON MATCH SET n.m = 1");
        defer r.ast.deinit();
        const qc = r.ast.nodeChildren(r.root);
        const mc = r.ast.nodeChildren(qc[0]);
        try testing.expectEqual(@as(usize, 3), mc.len); // pattern + on_create + on_match
        try testing.expectEqual(NodeKind.pattern, r.ast.kind(mc[0]));
        try testing.expectEqual(NodeKind.set_clause, r.ast.kind(mc[1]));
        try testing.expectEqual(NodeKind.set_clause, r.ast.kind(mc[2]));
    }
}

test "parses write clauses (CREATE, SET, DELETE)" {
    var r = try parseString(
        "MATCH (a:Person {name: 'Keanu Reeves'}) CREATE (a)-[:KNOWS]->(b:Person {name: 'Neo'}) SET b.born = 1964 DELETE a RETURN b.name",
    );
    defer r.ast.deinit();

    const qc = r.ast.nodeChildren(r.root);
    try testing.expectEqual(@as(usize, 5), qc.len);
    try testing.expectEqual(NodeKind.match_clause, r.ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.create_clause, r.ast.kind(qc[1]));
    try testing.expectEqual(NodeKind.set_clause, r.ast.kind(qc[2]));
    try testing.expectEqual(NodeKind.delete_clause, r.ast.kind(qc[3]));
    try testing.expectEqual(NodeKind.return_clause, r.ast.kind(qc[4]));

    // create_clause -> pattern (node edge node)
    const cc = r.ast.nodeChildren(qc[1]);
    const cpc = r.ast.nodeChildren(cc[0]);
    try testing.expectEqual(@as(usize, 3), cpc.len);
    try testing.expectEqualStrings("KNOWS", r.ast.data(cpc[1]).edge_pattern.etype);

    // set_clause -> one set_item (property_access + value)
    const sc = r.ast.nodeChildren(qc[2]);
    try testing.expectEqual(@as(usize, 1), sc.len);
    try testing.expectEqual(NodeKind.set_item, r.ast.kind(sc[0]));
    const sic = r.ast.nodeChildren(sc[0]);
    try testing.expectEqual(NodeKind.property_access, r.ast.kind(sic[0]));
    try testing.expectEqualStrings("born", r.ast.data(sic[0]).text);
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

    var diag = Diagnostic.init();
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:Person) RETURN )", &diag));
    try testing.expectEqualStrings("expected an expression, found ')'", diag.message());
    try testing.expectEqual(@as(usize, 24), diag.pos);

    var diag2 = Diagnostic.init();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:Person {name: 'Keanu}) RETURN p.born", &diag2));
    try testing.expectEqualStrings("unterminated string literal", diag2.message());
}

test "UTF-8 and backtick-quoted identifiers" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    _ = try parse(&ast, "MATCH (p:Pérsona {año: 2024}) RETURN p.año", null);
    // A quoted identifier may hold spaces and keywords, and is never a keyword.
    _ = try parse(&ast, "MATCH (`my node`:`Zona Norte`)-[:`ACCEDE A`]->(m:`MATCH`) RETURN `my node`.`full name`, m.count", null);

    var diag = Diagnostic.init();
    try testing.expectError(error.UnexpectedEof, parse(&ast, "MATCH (p:`Open", &diag));
    try testing.expectEqualStrings("unterminated quoted identifier", diag.message());
    try testing.expectError(error.UnexpectedToken, parse(&ast, "MATCH (p:``) RETURN p", null));
}

test "every parse failure carries a message" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    const cases = [_][]const u8{
        "MATCH (a) WHERE a.x IS NULL RETURN a", // trailing tokens
        "", // no clause
        "MERGE (a) ON DELETE SET a.x = 1", // bad ON
        "RETURN 99999999999999999999", // integer overflow
    };
    for (cases) |src| {
        var diag = Diagnostic.init();
        try testing.expectError(error.UnexpectedToken, parse(&ast, src, &diag));
        try testing.expect(diag.message().len > 0);
        try testing.expectEqual(acmedb.diag.ErrorCode.parse, diag.code);
    }
}
