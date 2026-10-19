# The language — lexer, parser, AST

How a string of text becomes the arena AST the executor consumes. All of it is
`src/query/lexer.zig` (the lexer), `src/query/parser.zig` and `src/query/expression_parser.zig` (the
grammar) and `src/query/ast.zig` (the AST).

There are two passes: a **lexer** that turns text into a flat token array, then a
**recursive-descent parser** that turns tokens into the AST. No ANTLR, no generator.

## The lexer

`tokenize(allocator, src, diagnostic)` walks the source once, left to right, and appends one `Token` per
lexeme:

```zig
pub const TokenKind = enum {
    ident, string, integer,
    l_paren, r_paren, l_bracket, r_bracket, l_brace, r_brace,
    colon, comma, dot, minus, star,
    arrow_right, arrow_left,
    eq, ne, lt, gt, le, ge,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,   // lexeme (content for identifier/string/integer, symbol otherwise)
    pos: usize,         // byte offset in the source (for diagnostics)
};
```

Notable details:

- **Multi-character operators** are lexed greedily, in one branch each: `<-` (arrow) vs `<=` (le) vs
  `<>` (ne) vs `<`; `->` vs `-`; `>=` vs `>`. So `-` is never `->` and `<` is never `<=`.
- **Strings** (`'…'`) support `\` escapes (`\'`, `\\`); the lexer skips the escaped char, records the
  content between quotes, and reports `unterminated string literal` at the opening quote's offset if
  the closing quote is missing. Unescaping happens later, in `internString`.
- **Identifiers** are `[A-Za-z_][A-Za-z0-9_]*`. Keywords are *not* a lexer concern — they are plain
  `ident` tokens and the parser decides whether an identifier is a keyword by position.
- **Numbers** are digit runs, parsed to `i64` in the parser.
- An `eof` token is always appended, so the parser never has to handle running off the end.

Every token carries its byte `pos`, which is how a syntax error points at the exact spot.

## The parser

`Parser` is a hand-written recursive descent. The state is just `tokens`, a cursor `pos`, and the
`Ast` being built; `peek`/`advance`/`expect` are the primitives. Keywords are matched case-
insensitively (`atKeyword` uses `eqlIgnoreCase`), but identifiers are case-sensitive.

The grammar, in one nesting tree (each line is a `fn` in `parser.zig`):

```text
parseQuery
├── MATCH?        → parseMatchClause → parsePattern
├── OPTIONAL?     → parseOptionalMatchClause → parseMatchBody → parsePattern
├── UNWIND?       → parseUnwindClause   (expr AS var)
├── WITH?         → parseWithClause      (projection ORDER BY? SKIP? LIMIT? WHERE?)
│                    └── MATCH? → parseMatchClause
├── writes*       → parseCreate/Merge/Set/Delete/Remove
└── RETURN?       → parseReturnClause     (DISTINCT? projection ORDER BY? SKIP? LIMIT?)

parsePattern
└── parseNodePattern ( parseEdgePattern parseNodePattern )*

parseNodePattern    → '(' ident? (':' ident)* '{' prop (',' prop)* '}'? ')'
parseEdgePattern    → ('-' | '<-') '[' ident? (':' ident)? '{' … '}'? ']' ('->' | '-')

parseExpression   (expression_parser.zig)
└── parseOr → parseAnd → parseNot → parseComparison → parsePrimary

parseComparison     → parsePrimary ( op parsePrimary )?          # + STARTS/ENDS/CONTAINS/IN
parsePrimary        → CASE | integer | string | ident | '[' list ']' | '(' expr ')'
parseCaseExpression → CASE (WHEN expr THEN expr)+ (ELSE expr)? END
parseListLiteral    → '[' expr (',' expr)* ']'
parseAggregateCall  → count(*) | agg '(' expr ')'
```

Three things are worth spelling out:

- **Operator precedence** is encoded in the nesting: `OR` binds loosest, then `AND`, then `NOT`,
  then comparisons, then primary. Each level loops (`while atKeyword("AND")`) to make the operators
  left-associative, building left-deep `binary_operation` nodes.
- **Keywords vs identifiers.** In `parsePrimary`, an `identifier` is checked in order: `true`/`false`
  (booleans), an aggregation name followed by `(` (`count`/`sum`/…), `size` followed by `(`, then
  otherwise it's a variable — optionally a property access if a `.` follows. Because `WHERE`, `AND`,
  etc. are only recognized *between* expressions, a variable named `in`, `and`, or `where` still
  parses correctly when it isn't in operator position.
- **Multi-word operators.** `STARTS WITH`, `ENDS WITH`, `CONTAINS`, and `IN [...]` are handled in
  `parseComparison` after the left operand: they lex as plain identifiers, so the parser peeks for
  `STARTS`/`ENDS`/`CONTAINS` (then consumes `WITH` for the first two) or `IN` (then a list literal).

## The AST

The AST (`src/query/ast.zig`) is an **arena**: a flat `std.ArrayList` of `Node`s plus a parallel
child-index array. There are no pointers between nodes and no inheritance:

```zig
pub const Index = u32;                       // a node index, or a child index

pub const NodeKind = enum { query, pattern, node_pattern, edge_pattern, /* ... */ };

pub const Data = union(enum) {               // the payload; which field is active = the kind
    none: void,
    int: i64,
    boolean: bool,
    text: []const u8,                         // a literal, an identifier, an alias, a property name
    node_pattern: struct { variable_name: []const u8, labels: []const []const u8 },
    edge_pattern: struct { variable_name: []const u8, edge_type: []const u8, direction: EdgeDirection },
    binary_operator: BinaryOperator,
    unary_operator: UnaryOperator,
    aggregate: AggregateKind,
    // ...
};

pub const Node = struct { kind: NodeKind, data: Data, first_child: Index, child_count: u32 };
```

- A node's children are a contiguous run in the child array (`nodeChildren` slices it out), so a
  node never stores pointers to its kids.
- Strings are interned into the arena (`intern`/`internSlice`), so the whole tree — nodes, children,
  strings — is freed with one `deinit`.
- `addNode` is bottom-up: you build the leaves first and pass their indices up, which is why the
  parser returns indices and why `Ast.root()` is simply the last node added.

This shape is deliberate: no `Node` subclass to dispatch over, no `Visitor`, just a tag (`kind`) and
a payload (`data`), so adding a clause or an expression kind is *one enum value + one parser rule +
one executor match arm* — see [contributing](contributing).
