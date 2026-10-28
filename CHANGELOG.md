# Changelog

## Unreleased

## 0.1.0 — 2026-10-28

The first release.

### Added

- **openCypher**: reading and writing clauses, variable-length and shortest paths, subqueries,
  aggregation, temporal types and functions, `LOAD CSV`, `EXPLAIN` and `PROFILE`; the whole
  openCypher TCK's positive scenarios pass (see `tests/tck/REPORT.md`).
- **Indexes and constraints with Neo4j's syntax**: `CREATE INDEX` on node and relationship
  properties (a field of a document property too), read by equality and range predicates;
  `CREATE CONSTRAINT ... REQUIRE ... IS UNIQUE`; `SHOW INDEXES`, `SHOW CONSTRAINTS` and `DROP`.
- **Full-text search** with Neo4j's syntax: English and Spanish analyzers (Snowball stemmers), BM25
  scores.
- **Storage** on LMDB (the default) or libmdbx, chosen at build time: transactions, crash safety,
  readers that never wait, several processes on one database. Storage format 1.
- **Time zones** from the IANA database, embedded: no system time-zone data needed.
- **Prepared statements** and a cache of the statements `query` prepares.
- **Embeddings**: a C ABI (`include/zypherdb.h`) and a Python package (`import zypherdb`). Wheels
  for Python 3.10 and later (one abi3 wheel per platform) on Linux x86_64 and aarch64
  (manylinux2014), macOS arm64 and x86_64, and Windows x86_64.
- **An integrity checker** (`check()`), and the test machinery behind it: storage, query, fault and
  crash fuzzers, snapshot tests and pair assertions (see `docs/guide/testing.md`).
