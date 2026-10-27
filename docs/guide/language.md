# The language: lexer, parser, AST

This guide covers how query text becomes the arena AST that the executor consumes. The code is in
four files:

- `src/query/lexer.zig`, the lexer;
- `src/query/parser.zig`, the grammar of clauses and patterns;
- `src/query/expression_parser.zig`, the grammar of expressions;
- `src/query/ast.zig`, the AST.

Text becomes an AST in two passes. A **lexer** turns the text into a flat array of tokens, and a
hand-written **recursive-descent parser** turns the tokens into the AST. No parser generator is
involved.

## The lexer

`tokenize(allocator, src, diagnostic)` walks the source once, left to right, and appends one
`Token` per lexeme:

```zig
pub const Token = struct {
    kind: TokenKind,
    text: []const u8,     // a view into the source: the content of a literal, or the symbol
    pos: usize,           // byte offset in the source, for error messages
    quoted: bool = false, // a `backticked` identifier
};
```

The token kinds are:

- `identifier`, `parameter` (`$name`), `string`, `integer`, `float`;
- brackets of the three kinds, `colon`, `comma`, `dot`, `range_dots` (`..`), `pipe`;
- the arithmetic operators `plus`, `minus`, `star`, `slash`, `percent`, `caret`;
- the comparisons `equal`, `not_equal`, `less_than`, `less_or_equal`, `greater_than`,
  `greater_or_equal`, and `regex_match` (`=~`);
- the arrows `arrow_left` and `arrow_right`;
- `end_of_input`.

The lexer has these properties:

- **No keywords.** Keywords lex as identifiers, and the parser decides by position whether an
  identifier is a keyword (`atKeyword`, case-insensitive). So a variable can be named `in` or `end`
  wherever no keyword is expected. A backticked identifier is never a keyword.
- **Greedy operators.** Each multi-character operator has one branch: `<-` against `<=`, `<>` and
  `<`; `->` against `-`; `>=` against `>`; `..` against `.`.
- **Numbers.** Integers can be decimal, hexadecimal (`0x1F`) or octal (`0o17`). Floats can be
  `1.5`, `.5`, `1e3` or `1.5e-3`. A dot followed by a digit starts a float unless it follows an
  operand, so `n.5` stays a property access. Keywords that start an expression (`RETURN .5`) do not
  count as operands. The sign is not part of a number token; the parser folds a `-` directly before
  a number literal into the literal, which is how the most negative integer can be written.
- **Strings** are single-quoted with backslash escapes. The lexer only finds the closing quote;
  `Parser.internString` unescapes the content into the arena.
- **Comments.** `//` and `/* */` comments are skipped.
- **An `end_of_input` token is always appended**, so the parser never runs off the end.

Every token carries its byte offset, so a syntax error can point at the exact spot.

## The parser

`parse(ast, src, diagnostic)` tokenizes and returns the index of the root node. The `Parser` state
is the tokens, a cursor `pos` and the `Ast` being built. Its primitives are `peek`, `advance`,
`expect`, `expectKeyword` and `atKeyword`. On error, `fail` records a message and the token's
offset in the `Diagnostic`, and returns an error.

### Clauses

```text
parseUnion          query (UNION [ALL] query)*       the parts must RETURN the same columns
parseQuery          parseClauses: clause*
  MATCH             parseMatchClause → parseMatchBody: pattern (',' pattern)* WHERE?
  OPTIONAL MATCH    parseOptionalMatchClause → parseMatchBody
  UNWIND            parseUnwindClause: expression AS name
  LOAD CSV          parseLoadCsvClause: [WITH HEADERS] FROM expression AS name [FIELDTERMINATOR string]
  CALL { }          a subquery: parseClauses until '}'
  CALL              parseCallClause (call_parser.zig, below)
  FOREACH           parseForeachClause: '(' name IN expression '|' updating clause+ ')'
  WITH              parseWithClause: projection ORDER BY? SKIP? LIMIT? WHERE?
  CREATE            parseCreateClause: pattern (',' pattern)*
  MERGE             parseMergeClause: pattern (ON CREATE SET … | ON MATCH SET …)*
  SET               parseSetClause: item (',' item)*
  DELETE            parseDeleteClause (DETACH DELETE too)
  REMOVE            parseRemoveClause
  RETURN            parseReturnClause: DISTINCT? projection ORDER BY? SKIP? LIMIT?
```

`parseQuery` also checks how the clauses may be ordered:

- a `MATCH`, `OPTIONAL MATCH`, `UNWIND`, `LOAD CSV` or procedure `CALL` after a writing clause
  needs a `WITH` in between;
- nothing may follow `RETURN` except `UNION`;
- a query cannot end with a reading clause;
- a subquery that only reads (`EXISTS { }`, `COUNT { }`) holds no writing clause, and no
  `CALL { }` that writes.

The same function parses a whole query and the body of a subquery (`parseClauses`, told which one
it is parsing), so a subquery has exactly the grammar of a query, with these limits.

### Patterns

```text
parsePattern        (name '=')? parseNodePattern (parseEdgePattern parseNodePattern)*
parseNodePattern    '(' name? (':' label)* properties? ')'
parseEdgePattern    ('<-' | '-') ('[' parseEdgeDetails ']')? ('->' | '-')
parseEdgeDetails    name? (':' type ('|' type)*)? parseHops? properties?
parseHops           '*' (count | min? '..' max?)?
```

`properties` is a map literal: `{key: expression, …}`. Inside a `WHERE`, the flag `in_where` lets a
parenthesized pattern stand as an expression (a pattern predicate).

### Expressions

There is one function per precedence level, from the loosest to the tightest. Each level calls the
next one for its operands, and loops while it sees its own operator, so binary operators are
left-associative:

```text
parseExpression → parseOr → parseXor → parseAnd → parseNot
  → parseComparison      = <> < <= > >=, chained: a < b <= c becomes a < b AND b <= c
  → parsePredicate       IS [NOT] NULL, STARTS WITH, ENDS WITH, CONTAINS, IN
  → parseAdditive        + -
  → parseMultiplicative  * / %
  → parsePower           ^
  → parseUnary           - +
  → parsePrimary         an atom, then any number of .key, [index], [from..to]
  → parseAtom            literals, $parameters, variables, (expression), CASE,
                         [list], [comprehension], [pattern comprehension], {map},
                         quantifiers, EXISTS { … }, function and aggregate calls
```

`parseAtom` tells apart the forms that start alike by looking ahead:

- after `[`, a list comprehension is `name IN`, a pattern comprehension is `(` or `name =`, and
  anything else is a list literal;
- an identifier followed by `(` is a call: an aggregate when its name is one
  (`aggregateKindFromName`), a quantifier for `any`, `all`, `none` and `single` followed by
  `name IN`, and a function otherwise. Dotted names (`date.truncate`) are function names too
  (`isNamespacedCall`);
- `true`, `false` and `null` are literals unless backticked;
- `count(*)` is a special case of the aggregate call.

Functions are not resolved here: the parser stores the name as written, and
`functions.checkCalls` resolves it before the query runs.

### CALL and schema commands

`call_parser.zig` reads `CALL name.space.procedure(arguments) [YIELD ...] [WHERE ...]`:

- the dotted name;
- the arguments, as expressions (no parentheses: no arguments);
- the yield items, each a column and an optional alias, or `*`;
- the `WHERE`, as in `MATCH` (a `true` literal when there is none).

`parseQuery` lets a `CALL` without `YIELD`, or a `CALL` that is the whole query, end it.

Schema commands are statements of their own. `parse` checks for one first (`schema_parser.zig`:
`CREATE FULLTEXT INDEX`, `CREATE [RANGE|TEXT] INDEX`, `CREATE CONSTRAINT ... IS UNIQUE`,
`DROP INDEX`, `DROP CONSTRAINT`, `SHOW [FULLTEXT|RANGE] INDEXES`, `SHOW CONSTRAINTS`) and parses
no query after it. A text index is parsed as a range index. A property written as a document path
(`ON (n.a.b)`, range indexes only) is kept as its names joined by `ast.path_separator` (0x00, which
the parser refuses inside a name).
The labels or types and properties of an index are kept in the node's data; the `OPTIONS` map is
its one child, evaluated by the executor.

## The AST

The AST (`src/query/ast.zig`) is an **arena**: a flat `std.ArrayList` of `Node`s, plus a separate
array of child indices. Nodes hold no pointers to each other and there is no inheritance:

```zig
pub const Index = u32;

pub const Node = struct {
    kind: NodeKind,     // query, match_clause, binary_operation, function_call, …
    data: Data,         // the payload, whose active field depends on the kind
    first_child: Index, // where its children start in the child array
    child_count: u32,
};

pub const Data = union(enum) {
    none: void,
    int: i64,
    float: f64,
    boolean: bool,
    text: []const u8, // a literal, a name, an alias, a property key
    node_pattern: struct { variable_name: []const u8, labels: []const []const u8 },
    edge_pattern: EdgePatternData, // variable, types, direction, hop range
    binary_operator: BinaryOperator,
    unary_operator: UnaryOperator,
    aggregate: AggregateCall,
    // … and the flags of RETURN, WITH, UNWIND, LOAD CSV, ORDER BY items, DELETE,
    // quantifiers, CALL and YIELD items
};
```

- **Children.** A node's children are a contiguous run in the child array, and `nodeChildren`
  returns them as a slice. The comment on each `NodeKind` documents the order of its children (for
  example, `slice` is `[list, from, to]`, with a `null_literal` for an open end).
- **Strings.** All strings are interned into the arena (`intern`), so a single `deinit` frees the
  whole tree: nodes, children and strings.
- **Bottom-up construction.** `addNode` builds the tree from the bottom up: leaves first, with
  their indices passed up. That is why every parser function returns an `Index`.
- **Structural equality.** `sameExpression` compares two subtrees structurally. It decides when a
  `RETURN` item repeats a grouping key, and when the parts of a `UNION` return the same column.

This shape is deliberate. There is a tag (`kind`) and a payload (`data`), with no `Node` subclasses
to dispatch over and no `Visitor`. Adding an expression kind takes one enum value, one parser rule
and one evaluation case; a clause also takes a plan operator (see
[contributing](contributing.md#the-recipes)).

## After parsing

Before the query is planned, `Executor.check` passes the AST through two static checks (a prepared
statement runs them once, when it is prepared):

- **`semantics.check`** (`src/query/semantics.zig`) tracks the kind of each variable in scope,
  clause by clause; a `WITH` starts a new scope. It rejects:
  - a name used as two kinds (`(r)-[r]-()`);
  - a relationship variable bound twice in one `MATCH`;
  - a literal operand of the wrong type (`1 IN true`, `NOT {}`);
  - `SET n = ` a literal that is not a map;
  - an aggregate inside a comprehension.
- **`functions.checkCalls`** rejects an unknown function or a wrong number of arguments.
- **For a CALL**, the semantic checks (`checkCall`) look the procedure up in `procedures.zig` and rejects:
  - an unknown name;
  - a wrong number of arguments;
  - a yield of a column the procedure does not have;
  - a CALL without YIELD inside a longer query.

  It declares each yielded variable with its column's kind, so `YIELD node` is a node that a
  later pattern can use.

Both checks report through the same `Diagnostic` as the parser. They depend only on the text, so
they fail on an empty database too, as the openCypher TCK requires.

## Why this way — and the alternatives

- **A hand-written parser, not a generator.** openCypher publishes its grammar (ANTLR and EBNF), and
  a generated parser would follow it to the letter. It would also bring a tool and a runtime into
  the build, which ZypherDB avoids (no third-party dependencies), and generated parsers give poor
  error messages unless they are worked on. Recursive descent keeps every rule a function that can
  say what it expected where (`expected an expression, found RETURN`), and the grammar is small
  enough that the functions stay readable.
- **No keywords in the lexer.** Reserving keywords would make the lexer decide, but openCypher lets
  many keywords name variables. Deciding by position, in the parser, accepts `MATCH (end) RETURN end`
  without a list of exceptions.
- **One function per precedence level**, not a table-driven (Pratt) parser. A Pratt parser handles
  many levels compactly; with about a dozen fixed levels, one function each reads like the grammar
  and makes each level's special rules (chained comparisons, `IS NULL` after an operand) local.
- **An arena AST.** A tree of allocated nodes with pointers would need a free per node and a type per
  kind. One array, indices for children and interned strings make building cheap (appends),
  freeing one call, and copying or comparing subtrees (`sameExpression`) simple; Zig's own compiler
  stores its AST this way.
