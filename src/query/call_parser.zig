//! The CALL clause: `CALL name.space.procedure(arguments) [YIELD ...] [WHERE ...]`.
//!
//! `YIELD column [AS alias], ...` names the procedure's columns that become
//! variables; `YIELD *` and a CALL without YIELD bind every column. A CALL
//! without YIELD can only end the query: its rows are the result.

const std = @import("std");

const Index = @import("ast.zig").Index;
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const expression_parser = @import("expression_parser.zig");

pub fn parseCallClause(self: *Parser) ParseError!Index {
    _ = self.advance(); // CALL (a `CALL {` is a subquery: Parser.parseCallSubquery)
    const procedure = try parseProcedureName(self);

    var children = std.ArrayList(Index).empty;
    defer children.deinit(self.ast.allocator);
    // `CALL proc` without parentheses takes its arguments from the parameters.
    const implicit_arguments = !self.at(.left_paren);
    if (!implicit_arguments) {
        _ = self.advance();
        if (!self.at(.right_paren)) {
            while (true) {
                try children.append(self.ast.allocator, try expression_parser.parseExpression(self));
                if (!self.at(.comma)) break;
                _ = self.advance();
            }
        }
        try self.expect(.right_paren);
    }
    const argument_count: u32 = @intCast(children.items.len);

    var yield_all = true;
    if (self.atKeyword("YIELD")) {
        _ = self.advance();
        if (self.at(.star)) {
            _ = self.advance();
        } else {
            yield_all = false;
            while (true) {
                const column = try self.internIdentifier();
                var alias: []const u8 = "";
                if (self.atKeyword("AS")) {
                    _ = self.advance();
                    alias = try self.internIdentifier();
                }
                try children.append(self.ast.allocator, try self.ast.addNode(.yield_item, .{ .yield_ = .{ .column = column, .alias = alias } }, &.{}));
                if (!self.at(.comma)) break;
                _ = self.advance();
            }
        }
    }
    try children.append(self.ast.allocator, try self.parseOptionalWhere());
    return self.ast.addNode(.call_clause, .{ .call = .{ .procedure = procedure, .argument_count = argument_count, .yield_all = yield_all, .implicit_arguments = implicit_arguments } }, children.items);
}

/// `db.index.fulltext.queryNodes`: identifiers joined by dots.
fn parseProcedureName(self: *Parser) ParseError![]const u8 {
    var name = std.ArrayList(u8).empty;
    defer name.deinit(self.ast.allocator);
    while (true) {
        const part = self.peek();
        if (part.kind != .identifier) {
            self.fail("expected a procedure name after CALL", .{});
            return error.UnexpectedToken;
        }
        _ = self.advance();
        try name.appendSlice(self.ast.allocator, part.text);
        if (!self.at(.dot)) break;
        _ = self.advance();
        try name.append(self.ast.allocator, '.');
    }
    return self.ast.intern(name.items);
}
