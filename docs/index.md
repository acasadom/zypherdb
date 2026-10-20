# acmedb

*An embedded graph database in Zig, speaking openCypher, on LMDB.*

acmedb is a graph database you embed in your program: no server, no configuration. You store
nodes and relationships, and you query them with **openCypher**, the language of graph databases —
from Python (`pip install acmedb`), or from any language through its C ABI. Under the hood it is a
compact engine written in Zig, with storage on **LMDB**: transactions, crash safety, readers that
never wait.

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
```

## Examples

Complete programs under `examples/`, built on the same lab: the smallest program that uses acmedb,
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
guide/contributing
```
