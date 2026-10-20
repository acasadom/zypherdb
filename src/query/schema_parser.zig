//! Schema commands, each a statement of its own:
//!
//!     CREATE FULLTEXT INDEX name [IF NOT EXISTS]
//!       FOR (n:Label1|Label2) ON EACH [n.property, ...] [OPTIONS {...}]
//!     CREATE FULLTEXT INDEX name [IF NOT EXISTS]
//!       FOR ()-[r:TYPE1|TYPE2]-() ON EACH [r.property, ...] [OPTIONS {...}]
//!     DROP INDEX name [IF EXISTS]
//!     SHOW [FULLTEXT] INDEXES
//!
//! As in Neo4j. Every property is already indexed for equality (and ranges),
//! so FULLTEXT is the only kind of index a command creates.

const std = @import("std");

const Index = @import("ast.zig").Index;
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const expression_parser = @import("expression_parser.zig");

/// True if the statement starting here is a schema command.
pub fn atSchemaCommand(self: *const Parser) bool {
    if (self.atKeyword("CREATE")) return self.atKeywordAhead(1, "FULLTEXT") or self.atKeywordAhead(1, "INDEX");
    if (self.atKeyword("DROP")) return self.atKeywordAhead(1, "INDEX");
    return self.atKeyword("SHOW");
}

pub fn parseSchemaCommand(self: *Parser) ParseError!Index {
    const command = if (self.atKeyword("CREATE"))
        try parseCreateIndex(self)
    else if (self.atKeyword("DROP"))
        try parseDropIndex(self)
    else
        try parseShowIndexes(self);
    if (!self.at(.end_of_input)) {
        self.fail("a schema command is a statement of its own; unexpected text after it", .{});
        return error.UnexpectedToken;
    }
    return command;
}

fn parseCreateIndex(self: *Parser) ParseError!Index {
    _ = self.advance(); // CREATE
    if (!self.atKeyword("FULLTEXT")) {
        self.fail("only FULLTEXT indexes can be created: every property is already indexed for equality and ranges", .{});
        return error.UnexpectedToken;
    }
    _ = self.advance();
    try self.expectKeyword("INDEX");
    if (self.atKeyword("IF") or self.atKeyword("FOR")) {
        self.fail("a full-text index needs a name: CREATE FULLTEXT INDEX name FOR ...", .{});
        return error.UnexpectedToken;
    }
    const name = try self.internIdentifier();
    var if_not_exists = false;
    if (self.atKeyword("IF")) {
        _ = self.advance();
        try self.expectKeyword("NOT");
        try self.expectKeyword("EXISTS");
        if_not_exists = true;
    }
    try self.expectKeyword("FOR");

    // `(n:A|B)` or `()-[r:T|U]-()`, with the variable the properties use.
    var relationships = false;
    var variable: []const u8 = "";
    var labels_or_types = std.ArrayList([]const u8).empty;
    defer labels_or_types.deinit(self.ast.allocator);
    try self.expect(.left_paren);
    if (self.at(.right_paren)) {
        relationships = true;
        _ = self.advance();
        try self.expect(.minus);
        try self.expect(.left_bracket);
        variable = try self.internIdentifier();
        try parseNames(self, &labels_or_types);
        try self.expect(.right_bracket);
        try expectRelationshipEnd(self);
    } else {
        variable = try self.internIdentifier();
        try parseNames(self, &labels_or_types);
        try self.expect(.right_paren);
    }

    try self.expectKeyword("ON");
    try self.expectKeyword("EACH");
    try self.expect(.left_bracket);
    var properties = std.ArrayList([]const u8).empty;
    defer properties.deinit(self.ast.allocator);
    while (true) {
        const owner = try self.internIdentifier();
        if (!std.mem.eql(u8, owner, variable)) {
            self.fail("the indexed properties must be of '{s}', not '{s}'", .{ variable, owner });
            return error.UnexpectedToken;
        }
        try self.expect(.dot);
        try properties.append(self.ast.allocator, try self.internIdentifier());
        if (!self.at(.comma)) break;
        _ = self.advance();
    }
    try self.expect(.right_bracket);

    var children = std.ArrayList(Index).empty;
    defer children.deinit(self.ast.allocator);
    if (self.atKeyword("OPTIONS")) {
        _ = self.advance();
        if (!self.at(.left_brace)) {
            self.fail("OPTIONS takes a map: OPTIONS {{indexConfig: {{...}}}}", .{});
            return error.UnexpectedToken;
        }
        try children.append(self.ast.allocator, try expression_parser.parseExpression(self));
    }
    return self.ast.addNode(.create_fulltext_index, .{ .fulltext_index = .{
        .name = name,
        .relationships = relationships,
        .labels_or_types = try self.ast.internSlice(labels_or_types.items),
        .properties = try self.ast.internSlice(properties.items),
        .if_not_exists = if_not_exists,
    } }, children.items);
}

/// `:A|B|C` after a variable: at least one name.
fn parseNames(self: *Parser, names: *std.ArrayList([]const u8)) ParseError!void {
    try self.expect(.colon);
    while (true) {
        try names.append(self.ast.allocator, try self.internIdentifier());
        if (!self.at(.pipe)) break;
        _ = self.advance();
    }
}

/// The `-()` or `->()` that ends `()-[r:T]-()`.
fn expectRelationshipEnd(self: *Parser) ParseError!void {
    if (self.at(.arrow_right)) _ = self.advance() else try self.expect(.minus);
    try self.expect(.left_paren);
    try self.expect(.right_paren);
}

fn parseDropIndex(self: *Parser) ParseError!Index {
    _ = self.advance(); // DROP
    try self.expectKeyword("INDEX");
    const name = try self.internIdentifier();
    var if_exists = false;
    if (self.atKeyword("IF")) {
        _ = self.advance();
        try self.expectKeyword("EXISTS");
        if_exists = true;
    }
    return self.ast.addNode(.drop_index, .{ .drop_index = .{ .name = name, .if_exists = if_exists } }, &.{});
}

fn parseShowIndexes(self: *Parser) ParseError!Index {
    _ = self.advance(); // SHOW
    var fulltext_only = false;
    if (self.atKeyword("FULLTEXT")) {
        _ = self.advance();
        fulltext_only = true;
    }
    if (self.atKeyword("INDEXES") or self.atKeyword("INDEX")) {
        _ = self.advance();
    } else {
        self.fail("expected INDEXES after SHOW", .{});
        return error.UnexpectedToken;
    }
    return self.ast.addNode(.show_indexes, .{ .boolean = fulltext_only }, &.{});
}
