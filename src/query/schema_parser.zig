//! Schema commands, each a statement of its own:
//!
//!     CREATE FULLTEXT INDEX name [IF NOT EXISTS]
//!       FOR (n:Label1|Label2) ON EACH [n.property, ...] [OPTIONS {...}]
//!     CREATE FULLTEXT INDEX name [IF NOT EXISTS]
//!       FOR ()-[r:TYPE1|TYPE2]-() ON EACH [r.property, ...] [OPTIONS {...}]
//!     CREATE [RANGE|TEXT] INDEX [name] [IF NOT EXISTS]
//!       FOR (n:Label) ON (n.property, ...) [OPTIONS {...}]   (or FOR ()-[r:TYPE]-())
//!     CREATE CONSTRAINT [name] [IF NOT EXISTS]
//!       FOR (n:Label) REQUIRE n.property IS UNIQUE           (or (n.a, n.b); ON ... ASSERT)
//!     DROP INDEX name [IF EXISTS]
//!     DROP CONSTRAINT name [IF EXISTS]
//!     SHOW [FULLTEXT|RANGE] INDEXES
//!     SHOW CONSTRAINTS
//!
//! As in Neo4j. Every property is already indexed for equality (and ranges),
//! so a RANGE or TEXT index is recorded (SHOW INDEXES lists it) and changes
//! nothing; FULLTEXT is the kind of index that does.

const std = @import("std");

const Index = @import("ast.zig").Index;
const NodeKind = @import("ast.zig").NodeKind;
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;
const expression_parser = @import("expression_parser.zig");

/// True if the statement starting here is a schema command.
pub fn atSchemaCommand(self: *const Parser) bool {
    if (self.atKeyword("CREATE")) {
        for ([_][]const u8{ "FULLTEXT", "INDEX", "RANGE", "TEXT", "BTREE", "CONSTRAINT" }) |keyword| {
            if (self.atKeywordAhead(1, keyword)) return true;
        }
        return false;
    }
    if (self.atKeyword("DROP")) return self.atKeywordAhead(1, "INDEX") or self.atKeywordAhead(1, "CONSTRAINT");
    return self.atKeyword("SHOW");
}

pub fn parseSchemaCommand(self: *Parser) ParseError!Index {
    const command = if (self.atKeyword("CREATE"))
        if (self.atKeywordAhead(1, "CONSTRAINT")) try parseCreateConstraint(self) else try parseCreateIndex(self)
    else if (self.atKeyword("DROP"))
        try parseDrop(self)
    else
        try parseShow(self);
    if (!self.at(.end_of_input)) {
        self.fail("a schema command is a statement of its own; unexpected text after it", .{});
        return error.UnexpectedToken;
    }
    return command;
}

/// What an index or constraint is on: `(n:A|B)` or `()-[r:T|U]-()`.
const Entity = struct {
    relationships: bool,
    variable: []const u8,
    names: []const []const u8,
};

fn parseEntity(self: *Parser) ParseError!Entity {
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(self.ast.allocator);
    var relationships = false;
    var variable: []const u8 = "";
    try self.expect(.left_paren);
    if (self.at(.right_paren)) {
        relationships = true;
        _ = self.advance();
        try self.expect(.minus);
        try self.expect(.left_bracket);
        variable = try self.internIdentifier();
        try parseNames(self, &names);
        try self.expect(.right_bracket);
        try expectRelationshipEnd(self);
    } else {
        variable = try self.internIdentifier();
        try parseNames(self, &names);
        try self.expect(.right_paren);
    }
    return .{ .relationships = relationships, .variable = variable, .names = try self.ast.internSlice(names.items) };
}

/// `v.a, v.b, ...` (`close` ends the list): the property names, each of `variable`.
fn parseProperties(self: *Parser, variable: []const u8, close: @import("lexer.zig").TokenKind) ParseError![]const []const u8 {
    var properties = std.ArrayList([]const u8).empty;
    defer properties.deinit(self.ast.allocator);
    while (true) {
        const owner = try self.internIdentifier();
        if (!std.mem.eql(u8, owner, variable)) {
            self.fail("the properties must be of '{s}', not '{s}'", .{ variable, owner });
            return error.UnexpectedToken;
        }
        try self.expect(.dot);
        try properties.append(self.ast.allocator, try self.internIdentifier());
        if (!self.at(.comma)) break;
        _ = self.advance();
    }
    try self.expect(close);
    return self.ast.internSlice(properties.items);
}

/// `[name] [IF NOT EXISTS]`, before FOR (or ON): the name, or one made of
/// what the index or constraint is on, once that is known (empty here).
fn parseNameAndIfNotExists(self: *Parser, name_required: bool, what: []const u8) ParseError!struct { name: []const u8, if_not_exists: bool } {
    var name: []const u8 = "";
    if (!self.atKeyword("IF") and !self.atKeyword("FOR") and !self.atKeyword("ON")) {
        name = try self.internIdentifier();
    } else if (name_required) {
        self.fail("{s} needs a name: CREATE {s} name FOR ...", .{ what, what });
        return error.UnexpectedToken;
    }
    var if_not_exists = false;
    if (self.atKeyword("IF")) {
        _ = self.advance();
        try self.expectKeyword("NOT");
        try self.expectKeyword("EXISTS");
        if_not_exists = true;
    }
    return .{ .name = name, .if_not_exists = if_not_exists };
}

/// A name for an unnamed index or constraint: `prefix_Label_property_...`.
fn generatedName(self: *Parser, prefix: []const u8, entity: Entity, properties: []const []const u8) ParseError![]const u8 {
    var name = std.ArrayList(u8).empty;
    defer name.deinit(self.ast.allocator);
    try name.appendSlice(self.ast.allocator, prefix);
    for (entity.names) |label| {
        try name.append(self.ast.allocator, '_');
        try name.appendSlice(self.ast.allocator, label);
    }
    for (properties) |property| {
        try name.append(self.ast.allocator, '_');
        try name.appendSlice(self.ast.allocator, property);
    }
    return self.ast.intern(name.items);
}

/// `OPTIONS {...}`, if there is one: the map's expression.
fn parseOptions(self: *Parser, children: *std.ArrayList(Index)) ParseError!void {
    if (!self.atKeyword("OPTIONS")) return;
    _ = self.advance();
    if (!self.at(.left_brace)) {
        self.fail("OPTIONS takes a map: OPTIONS {{indexConfig: {{...}}}}", .{});
        return error.UnexpectedToken;
    }
    try children.append(self.ast.allocator, try expression_parser.parseExpression(self));
}

fn parseCreateIndex(self: *Parser) ParseError!Index {
    _ = self.advance(); // CREATE
    const fulltext = self.atKeyword("FULLTEXT");
    if (fulltext or self.atKeyword("RANGE") or self.atKeyword("TEXT") or self.atKeyword("BTREE")) _ = self.advance();
    try self.expectKeyword("INDEX");
    const header = try parseNameAndIfNotExists(self, fulltext, "FULLTEXT INDEX");
    try self.expectKeyword("FOR");
    const entity = try parseEntity(self);
    try self.expectKeyword("ON");
    var properties: []const []const u8 = undefined;
    if (fulltext) {
        try self.expectKeyword("EACH");
        try self.expect(.left_bracket);
        properties = try parseProperties(self, entity.variable, .right_bracket);
    } else {
        try self.expect(.left_paren);
        properties = try parseProperties(self, entity.variable, .right_paren);
    }
    var children = std.ArrayList(Index).empty;
    defer children.deinit(self.ast.allocator);
    try parseOptions(self, &children);
    const kind: NodeKind = if (fulltext) .create_fulltext_index else .create_index;
    return self.ast.addNode(kind, .{ .schema_definition = .{
        .name = if (header.name.len > 0) header.name else try generatedName(self, "index", entity, properties),
        .relationships = entity.relationships,
        .labels_or_types = entity.names,
        .properties = properties,
        .if_not_exists = header.if_not_exists,
    } }, if (fulltext) children.items else &.{});
}

/// `CREATE CONSTRAINT [name] [IF NOT EXISTS] FOR (n:L) REQUIRE n.p IS UNIQUE`
/// (`(n.a, n.b)` for several properties; Neo4j 4's `ON ... ASSERT` too).
fn parseCreateConstraint(self: *Parser) ParseError!Index {
    _ = self.advance(); // CREATE
    _ = self.advance(); // CONSTRAINT
    const header = try parseNameAndIfNotExists(self, false, "CONSTRAINT");
    const old_form = self.atKeyword("ON");
    if (old_form) _ = self.advance() else try self.expectKeyword("FOR");
    const entity = try parseEntity(self);
    if (old_form) try self.expectKeyword("ASSERT") else try self.expectKeyword("REQUIRE");
    const properties = if (self.at(.left_paren)) list: {
        _ = self.advance();
        break :list try parseProperties(self, entity.variable, .right_paren);
    } else try parseSingleProperty(self, entity.variable);
    try self.expectKeyword("IS");
    if (!self.atKeyword("UNIQUE")) {
        self.fail("only uniqueness constraints are supported (REQUIRE n.property IS UNIQUE), not {s}", .{@import("lexer.zig").describeToken(self.peek())});
        return error.UnexpectedToken;
    }
    _ = self.advance();
    if (entity.relationships) {
        self.fail("uniqueness constraints are on nodes, not relationships", .{});
        return error.UnexpectedToken;
    }
    if (entity.names.len != 1) {
        self.fail("a constraint is on one label", .{});
        return error.UnexpectedToken;
    }
    var children = std.ArrayList(Index).empty;
    defer children.deinit(self.ast.allocator);
    try parseOptions(self, &children);
    return self.ast.addNode(.create_constraint, .{ .schema_definition = .{
        .name = if (header.name.len > 0) header.name else try generatedName(self, "constraint", entity, properties),
        .relationships = false,
        .labels_or_types = entity.names,
        .properties = properties,
        .if_not_exists = header.if_not_exists,
    } }, &.{});
}

/// `n.property`: one property of `variable`.
fn parseSingleProperty(self: *Parser, variable: []const u8) ParseError![]const []const u8 {
    const owner = try self.internIdentifier();
    if (!std.mem.eql(u8, owner, variable)) {
        self.fail("the properties must be of '{s}', not '{s}'", .{ variable, owner });
        return error.UnexpectedToken;
    }
    try self.expect(.dot);
    return self.ast.internSlice(&.{try self.internIdentifier()});
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

/// `DROP INDEX name [IF EXISTS]` or `DROP CONSTRAINT name [IF EXISTS]`.
fn parseDrop(self: *Parser) ParseError!Index {
    _ = self.advance(); // DROP
    const kind: NodeKind = if (self.atKeyword("CONSTRAINT")) .drop_constraint else .drop_index;
    _ = self.advance();
    const name = try self.internIdentifier();
    var if_exists = false;
    if (self.atKeyword("IF")) {
        _ = self.advance();
        try self.expectKeyword("EXISTS");
        if_exists = true;
    }
    return self.ast.addNode(kind, .{ .drop_index = .{ .name = name, .if_exists = if_exists } }, &.{});
}

/// `SHOW [FULLTEXT|RANGE] INDEXES` or `SHOW CONSTRAINTS` (singular too).
fn parseShow(self: *Parser) ParseError!Index {
    _ = self.advance(); // SHOW
    if (self.atKeyword("CONSTRAINTS") or self.atKeyword("CONSTRAINT")) {
        _ = self.advance();
        return self.ast.addNode(.show_constraints, .{ .none = {} }, &.{});
    }
    var which: @FieldType(@import("ast.zig").Data, "show_indexes") = .all;
    if (self.atKeyword("FULLTEXT")) {
        _ = self.advance();
        which = .fulltext;
    } else if (self.atKeyword("RANGE")) {
        _ = self.advance();
        which = .range;
    }
    if (self.atKeyword("INDEXES") or self.atKeyword("INDEX")) {
        _ = self.advance();
    } else {
        self.fail("expected INDEXES or CONSTRAINTS after SHOW", .{});
        return error.UnexpectedToken;
    }
    return self.ast.addNode(.show_indexes, .{ .show_indexes = which }, &.{});
}
