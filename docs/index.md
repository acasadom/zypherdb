# ZypherDB

*An embedded graph database in Zig, speaking openCypher, on LMDB or libmdbx.*

ZypherDB is a graph database you embed in your program: no server, no configuration. You store
nodes and relationships, and you query them with **openCypher**, the language of graph databases —
from Python (`pip install zypherdb`), or from any language through its C ABI. Under the hood it is a
compact engine written in Zig, with storage on **LMDB** or **libmdbx**: transactions, crash safety, readers
that never wait.

## Is a graph database the right tool?

Use one when the questions are about **connections**: who reports to whom however deep, which
rules apply to this person through their teams, what is reachable from here, what links these
two things. In a relational database those are recursive joins; in a graph they are a pattern.
If your data is a set of independent records queried by their fields, a relational or document
store is the simpler choice.

## The tutorial, step by step

The tutorial builds one application from an empty directory: the access-control system of a
biomedical research lab, where who may enter which room, when, with which training — and who is
where right now — is not optional. Each step adds one capability and grows the same database.
Every Python block on every page is run by the test suite, so you can copy, paste and run it as
it is.

```{toctree}
:maxdepth: 1
:caption: Tutorial

tutorial/01-getting-started
tutorial/02-nodes
tutorial/03-relationships
tutorial/04-filtering
tutorial/05-parameters
tutorial/06-returning
tutorial/07-aggregating
tutorial/08-updating
tutorial/09-pipelines
tutorial/10-optional
tutorial/11-hierarchies
tutorial/12-exists
tutorial/13-documents
tutorial/14-time
tutorial/15-loading
tutorial/16-concurrency
tutorial/17-performance
tutorial/18-door-controller
tutorial/19-monitoring
tutorial/20-searching
```

## Examples

Complete programs under `examples/`, built on the same lab: the smallest program that uses ZypherDB,
and a simulated day of the whole access-control system, with door controllers and a monitor in
separate processes. They run in the test suite too.

```{toctree}
:maxdepth: 1
:caption: Examples

examples/minimal
examples/helix
```

## References

```{toctree}
:maxdepth: 1
:caption: References

guide/cypher
guide/c-api
guide/python
guide/replication
```

## How it works inside

For reading and changing the engine: its design, how data is stored, how a query is parsed,
planned and run, and how it is tested.

```{toctree}
:maxdepth: 1
:caption: Technical

guide/architecture
guide/storage
guide/language
guide/planning-execution
guide/performance
guide/testing
guide/contributing
```

## Reading the engine as a course

The technical guides can be read in order as a course on graph databases and systems programming in
Zig: each chapter explains one layer, and then you read that layer's code. The files below are listed
in the order to read them. Most are under 500 lines. Learn the language first, from tutorials 01 to 09
and the [openCypher reference](guide/cypher.md), so the queries in the guides read easily.

1. **The shape of the whole** — [architecture](guide/architecture.md). Read `src/root.zig` (the
   public surface), `src/value.zig` (the value every layer passes around) and
   `src/diagnostics.zig` (how errors carry a position).
2. **Storage: a graph as sorted keys** — [storage](guide/storage.md). Read
   `src/storage/engine/contract.zig` (what an engine must provide), `src/storage/engine/lmdb.zig`,
   `src/storage/key_value_store.zig` (transactions and prefix scans), `src/storage/key_encoding.zig`
   and `src/storage/value_encoding.zig` (the bytes), `src/storage/node_record.zig`, then
   `src/storage/graph.zig` (the graph operations, each with its cost). Finish with
   `src/storage/integrity.zig`.
3. **The language: text to a tree** — [language](guide/language.md). Read
   `src/query/lexer.zig`, `src/query/ast.zig` (the arena tree), `src/query/parser.zig` and
   `src/query/expression_parser.zig` (recursive descent, one function per precedence level), then
   `src/query/semantics.zig` (the checks before planning).
4. **Planning and execution: a tree to rows** — [planning and execution](guide/planning-execution.md).
   Read `src/planning/Plan.zig` (operators in chains), `src/planning/builder.zig`,
   `src/planning/patterns.zig` (anchors, seeks, estimates), `src/planning/expression_program.zig`,
   then `src/execution/Executor.zig`, `src/execution/bindings.zig` (a row as slots),
   `src/execution/operators.zig`, `src/execution/pattern_matching.zig` and
   `src/execution/expressions.zig`. Then `src/statement/Statement.zig` and `src/statement/Cache.zig`
   (plan once, run many times).
5. **Where the time goes** — [performance](guide/performance.md). It has no new files: it goes back
   to the code of chapters 2 to 4 and names its known costs.
6. **How the engine tests itself** — [testing](guide/testing.md). Its last section,
   [Reading the code](guide/testing.md#reading-the-code), lists the files in order, from
   `src/storage/integrity.zig` to `src/storage/layout.zig`.
7. **Changing it** — [contributing](guide/contributing.md): the build, the principles, and recipes
   for adding a clause, a function or an index.

The storage, language, planning and testing guides end with a "Why this way — and the
alternatives" section. Read that section after the code: it makes sense only once you know the
code. The architecture guide gives its reasons at the start, because they explain the layers that
follow.
