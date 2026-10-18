# acmedb

*An embedded graph database in Zig, speaking openCypher, on LMDB.*

acmedb is a small, embeddable graph database: link it into your process (or load the shared
library from Python), write data and run queries in a subset of **openCypher**, over an
**index-free adjacency** graph stored in **LMDB**. No server, no configuration, one binary
toolchain.

The documentation has two tracks, like the codebase has two audiences:

- the **tutorial and references** — how to *use* the database: the language, the C ABI, Python;
- the **technical guides** — how it *works inside*, for reading and maintaining the code: the
  design, the storage encoding, the parser, and the planner/executor.

## Using it

```{toctree}
:maxdepth: 1
:caption: Using acmedb

tutorial/01-getting-started
tutorial/02-matching
tutorial/03-writing
tutorial/04-returning
tutorial/05-aggregating
tutorial/06-pipelines
tutorial/07-optional-nulls
tutorial/08-lists-strings
```

```{toctree}
:maxdepth: 1
:caption: References

guide/cypher
guide/c-api
guide/python
```

## How it works inside

```{toctree}
:maxdepth: 1
:caption: Technical

guide/architecture
guide/storage
guide/language
guide/planning-execution
guide/contributing
```
