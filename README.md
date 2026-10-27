# ZypherDB

*An embedded graph database that speaks openCypher.*

[![CI](https://github.com/acasadom/zypherdb/actions/workflows/ci.yml/badge.svg)](https://github.com/acasadom/zypherdb/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/acasadom/zypherdb/blob/main/LICENSE)
![Python](https://img.shields.io/badge/python-3.10%2B-blue)
[![Docs](https://img.shields.io/badge/docs-acasadom.github.io%2Fzypherdb-blue)](https://acasadom.github.io/zypherdb/)

ZypherDB is to graphs what SQLite is to tables: a database that lives inside your process and
keeps its data in a directory, with no server to run. You store nodes and relationships and
query them in **openCypher**, the language of Neo4j. Several processes can share a database, and
a crash never leaves it half-written. The engine is written in Zig, on LMDB.

## Install

```bash
pip install zypherdb
```

Python 3.10 or later, on Linux (x86_64, aarch64), macOS (Apple silicon, Intel) and Windows
(x86_64). No dependencies (on Windows, only `tzdata`).

## A first look

Who may open a door, through groups nested to any depth, and at what times:

```python
from zypherdb import Database

db = Database("lab.db")  # a directory, created if missing

db.query("CREATE INDEX FOR (d:Door) ON (d.name)")  # doors are looked up by name
db.query("""
    CREATE (ana:Person {name: 'Ana'}), (bo:Person {name: 'Bo'}),
           (staff:Group {name: 'Lab staff'}), (bsl3:Group {name: 'BSL-3'}),
           (airlock:Door {name: 'BSL-3 airlock'})
    CREATE (ana)-[:MEMBER_OF]->(bsl3)-[:PART_OF]->(staff),
           (bo)-[:MEMBER_OF]->(staff),
           (bsl3)-[:MAY_OPEN {from: localtime('07:00'), until: localtime('19:00')}]->(airlock)
""")

rows = db.query("""
    MATCH (:Door {name: $door})<-[rule:MAY_OPEN]-(:Group)<-[:PART_OF*0..]-(:Group)<-[:MEMBER_OF]-(p:Person)
    RETURN p.name, rule.from, rule.until
""", door="BSL-3 airlock")
print(rows)  # [['Ana', datetime.time(7, 0), datetime.time(19, 0)]]
```

Results come back as Python values: numbers, strings, lists, dicts, `datetime` types with their
time zones, and nodes, relationships and paths.

Full-text search, with stemming and BM25 ranking, in Neo4j's syntax:

```python
db.query("CREATE (:Protocol {title: 'Airlock', body: 'Spray the doors before opening them'})")
db.query("""
    CREATE FULLTEXT INDEX protocols FOR (p:Protocol) ON EACH [p.title, p.body]
    OPTIONS {indexConfig: {`fulltext.analyzer`: 'english'}}
""")
print(db.query("""
    CALL db.index.fulltext.queryNodes('protocols', 'door AND open') YIELD node, score
    RETURN node.title, score
"""))  # [['Airlock', 0.5753641449035617]]
```

And a look at how a query runs: `explain` returns its plan, and `profile` runs it and counts the
rows each step made:

```python
def show(plan, depth=0):
    print("  " * depth + f"{plan['operator']} {plan['details']}   rows: {plan['rows']}")
    for child in plan["children"]:
        show(child, depth + 1)

rows, plan = db.profile("""
    MATCH (:Door {name: $door})<-[rule:MAY_OPEN]-(:Group)<-[:PART_OF*0..]-(:Group)<-[:MEMBER_OF]-(p:Person)
    RETURN p.name, rule.from, rule.until
""", door="BSL-3 airlock")
show(plan)
```

```text
Return p.name, rule.from, rule.until   rows: 1
  Expand(All) (:Group)<-[:MEMBER_OF]-(p:Person)   rows: 1
    VarLengthExpand(All) (:Group)<-[:PART_OF*0..]-(:Group)   rows: 1
      Expand(All) (:Door {name: $door})<-[rule:MAY_OPEN]-(:Group)   rows: 1
        NodeIndexSeek (:Door {name: $door})   rows: 1
```

The [tutorial](https://acasadom.github.io/zypherdb/tutorial/01-getting-started.html) goes from
here to a complete access-control system in twenty short steps.

## What it can do

- **openCypher**: `MATCH` and `OPTIONAL MATCH`, variable-length and shortest paths, `WITH`,
  `UNWIND`, `UNION`, subqueries, `EXISTS { }` and `COUNT { }`; `CREATE`, `MERGE`, `SET`,
  `REMOVE`, `DELETE`, `FOREACH`; `LOAD CSV`; every aggregate; string, list, math, temporal and
  graph functions.
- **Values**: integers, floats, strings, booleans, lists, maps, and the six temporal types with
  time zones. Properties can also hold maps, so a node can carry a document.
- **Indexes**: property indexes for equality and ranges, on node labels and relationship types,
  and on fields inside documents; full-text indexes in English and Spanish; uniqueness constraints.
- **Storage**: transactions, crash safety, three durability levels, one writer and any number of
  readers across processes (readers never wait), and an integrity checker.
- **Queries**: plans of operators with index seeks, `EXPLAIN` and `PROFILE`, prepared statements
  and a statement cache.

ZypherDB passes all 3202 scenarios of the [openCypher TCK](https://github.com/acasadom/zypherdb/blob/main/tests/tck/README.md)
that expect a result, and all 694 that expect an error. The
[Cypher reference](https://acasadom.github.io/zypherdb/guide/cypher.html) lists what it does not
support yet. Python is the first language binding; C, C++ and JavaScript come next.

## Documentation

[acasadom.github.io/zypherdb](https://acasadom.github.io/zypherdb/) has the tutorial, the
[Cypher](https://acasadom.github.io/zypherdb/guide/cypher.html) and
[Python](https://acasadom.github.io/zypherdb/guide/python.html) references, and how it works
inside: the [architecture](https://acasadom.github.io/zypherdb/guide/architecture.html), the
storage layout, the query planner, [performance](https://acasadom.github.io/zypherdb/guide/performance.html)
and [testing](https://acasadom.github.io/zypherdb/guide/testing.html) (fuzzers, crash and fault
injection, the TCK).

## Building from source

You need [Zig 0.17](https://ziglang.org/download/): `zig build test` runs the tests and
`pip install .` builds the Python package. The
[contributing guide](https://acasadom.github.io/zypherdb/guide/contributing.html) has the rest.

## License

Apache License 2.0. ZypherDB includes LMDB, libmdbx, the IANA time-zone database, and data and
algorithms from Unicode and Snowball, under their own licenses: see
[THIRD_PARTY_NOTICES.md](https://github.com/acasadom/zypherdb/blob/main/THIRD_PARTY_NOTICES.md).
