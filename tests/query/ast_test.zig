//! The arena AST: building, walking and string interning.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const NodeKind = acmedb.NodeKind;
const BinOp = acmedb.BinOp;

test "builds and walks the AST for a MATCH/RETURN query" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    // RETURN p.born -> projection_item(alias="", property_access("born", variable("p")))
    const v_p = try ast.addNode(.variable, .{ .text = "p" }, &.{});
    const access = try ast.addNode(.property_access, .{ .text = "born" }, &.{v_p});
    const item = try ast.addNode(.projection_item, .{ .text = "" }, &.{access});
    const projection = try ast.addNode(.projection, .{ .none = {} }, &.{item});

    // (p:Person {name: 'Keanu Reeves'})
    const lit = try ast.addNode(.string_literal, .{ .text = "Keanu Reeves" }, &.{});
    const prop = try ast.addNode(.property, .{ .text = "name" }, &.{lit});
    const np = try ast.addNode(.node_pattern, .{ .node_pattern = .{ .var_name = "p", .labels = &.{"Person"} } }, &.{prop});
    const pattern = try ast.addNode(.pattern, .{ .none = {} }, &.{np});

    // no WHERE -> true
    const true_expr = try ast.addNode(.bool_literal, .{ .boolean = true }, &.{});

    const match_clause = try ast.addNode(.match_clause, .{ .none = {} }, &.{ pattern, true_expr });
    const return_clause = try ast.addNode(.return_clause, .{ .none = {} }, &.{projection});
    const query = try ast.addNode(.query, .{ .none = {} }, &.{ match_clause, return_clause });

    try testing.expectEqual(query, ast.root());
    try testing.expectEqual(NodeKind.query, ast.kind(ast.root()));

    const qc = ast.nodeChildren(query);
    try testing.expectEqual(@as(usize, 2), qc.len);
    try testing.expectEqual(NodeKind.match_clause, ast.kind(qc[0]));
    try testing.expectEqual(NodeKind.return_clause, ast.kind(qc[1]));

    // match_clause -> [pattern, where]
    const mc = ast.nodeChildren(qc[0]);
    try testing.expectEqual(@as(usize, 2), mc.len);
    try testing.expectEqual(NodeKind.pattern, ast.kind(mc[0]));
    try testing.expectEqual(NodeKind.bool_literal, ast.kind(mc[1]));

    // pattern -> node_pattern
    const pc = ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 1), pc.len);
    try testing.expectEqual(NodeKind.node_pattern, ast.kind(pc[0]));
    try testing.expectEqualStrings("Person", ast.data(pc[0]).node_pattern.labels[0]);
    try testing.expectEqualStrings("p", ast.data(pc[0]).node_pattern.var_name);

    // node_pattern -> one property {name: 'Keanu Reeves'}
    const nprops = ast.nodeChildren(pc[0]);
    try testing.expectEqual(@as(usize, 1), nprops.len);
    try testing.expectEqual(NodeKind.property, ast.kind(nprops[0]));
    try testing.expectEqualStrings("name", ast.data(nprops[0]).text);

    // return_clause -> projection -> one item -> property_access("born", variable("p"))
    const rc = ast.nodeChildren(qc[1]);
    try testing.expectEqual(@as(usize, 1), rc.len);
    const projc = ast.nodeChildren(rc[0]);
    try testing.expectEqual(@as(usize, 1), projc.len);
    try testing.expectEqual(NodeKind.projection_item, ast.kind(projc[0]));

    const accessc = ast.nodeChildren(projc[0]);
    try testing.expectEqual(@as(usize, 1), accessc.len);
    try testing.expectEqual(NodeKind.property_access, ast.kind(accessc[0]));
    try testing.expectEqualStrings("born", ast.data(accessc[0]).text);

    const objc = ast.nodeChildren(accessc[0]);
    try testing.expectEqual(@as(usize, 1), objc.len);
    try testing.expectEqual(NodeKind.variable, ast.kind(objc[0]));
    try testing.expectEqualStrings("p", ast.data(objc[0]).text);
}

test "intern owns strings and binary_op holds two children" {
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    const name = try ast.intern("Keanu Reeves"); // arena-owned copy

    // p.name = 'Keanu Reeves'
    const lit = try ast.addNode(.string_literal, .{ .text = name }, &.{});
    const v_p = try ast.addNode(.variable, .{ .text = "p" }, &.{});
    const access = try ast.addNode(.property_access, .{ .text = "name" }, &.{v_p});
    const eq = try ast.addNode(.binary_op, .{ .bin_op = .eq }, &.{ access, lit });

    try testing.expectEqual(NodeKind.binary_op, ast.kind(eq));
    try testing.expectEqual(BinOp.eq, ast.data(eq).bin_op);

    const kids = ast.nodeChildren(eq);
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(NodeKind.property_access, ast.kind(kids[0]));
    try testing.expectEqualStrings("Keanu Reeves", ast.data(kids[1]).text);
}
