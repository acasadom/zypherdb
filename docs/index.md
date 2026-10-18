# acmedb

*An embedded graph database in Zig, speaking openCypher, on LMDB.*

acmedb is a small, embeddable graph database: you link it into your process (or load the
shared library from Python), write your data and queries in a subset of **openCypher**, and it
answers them over an **index-free adjacency** graph stored in **LMDB**. No server, no
configuration, one binary toolchain.

It is built for embedding: the whole engine is a Zig library exposing a small **C ABI**, so any
language that can call C — Python via `ctypes`, any FFI — can open a database, write nodes and
edges, and run queries.

This documentation has two halves:

- a **tutorial** that grows a single "people and movies" graph from a first `MATCH` to
  aggregation, `WITH` pipelines and `OPTIONAL MATCH`;
- a set of **guides** — the architecture (how the keys are laid out and how the executor plans),
  the openCypher subset reference, and the C ABI.

## The tutorial, step by step

```{toctree}
:maxdepth: 1
:caption: Tutorial

tutorial/01-getting-started
tutorial/02-matching
tutorial/03-writing
tutorial/04-returning
tutorial/05-aggregating
tutorial/06-pipelines
tutorial/07-optional-nulls
tutorial/08-lists-strings
```

## Guides

```{toctree}
:maxdepth: 1
:caption: Guides

guide/architecture
guide/cypher
guide/c-api
guide/python
```
