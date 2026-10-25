//! The arena AST: building, walking and string interning.

const std = @import("std");
const testing = std.testing;
const zypherdb = @import("zypherdb");

const Ast = zypherdb.Ast;
const NodeKind = zypherdb.NodeKind;
const BinaryOperator = zypherdb.BinaryOperator;

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
    const property = try ast.addNode(.property, .{ .text = "name" }, &.{lit});
    const node_pattern = try ast.addNode(.node_pattern, .{ .node_pattern = .{ .variable_name = "p", .labels = &.{"Person"} } }, &.{property});
    const pattern = try ast.addNode(.pattern, .{ .none = {} }, &.{node_pattern});

    // no WHERE -> true
    const true_expression = try ast.addNode(.boolean_literal, .{ .boolean = true }, &.{});

    const match_clause = try ast.addNode(.match_clause, .{ .none = {} }, &.{ pattern, true_expression });
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
    try testing.expectEqual(NodeKind.boolean_literal, ast.kind(mc[1]));

    // pattern -> node_pattern
    const pc = ast.nodeChildren(mc[0]);
    try testing.expectEqual(@as(usize, 1), pc.len);
    try testing.expectEqual(NodeKind.node_pattern, ast.kind(pc[0]));
    try testing.expectEqualStrings("Person", ast.data(pc[0]).node_pattern.labels[0]);
    try testing.expectEqualStrings("p", ast.data(pc[0]).node_pattern.variable_name);

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
    const eq = try ast.addNode(.binary_operation, .{ .binary_operator = .equal }, &.{ access, lit });

    try testing.expectEqual(NodeKind.binary_operation, ast.kind(eq));
    try testing.expectEqual(BinaryOperator.equal, ast.data(eq).binary_operator);

    const children = ast.nodeChildren(eq);
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expectEqual(NodeKind.property_access, ast.kind(children[0]));
    try testing.expectEqualStrings("Keanu Reeves", ast.data(children[1]).text);
}
