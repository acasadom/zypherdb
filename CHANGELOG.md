# Changelog

## Unreleased

Nothing has been released yet. The first release will contain:

### Added

- **openCypher**: reading and writing clauses, variable-length and shortest paths, subqueries,
  aggregation, temporal types and functions, `LOAD CSV`, uniqueness constraints, `EXPLAIN` and
  `PROFILE`; the whole openCypher TCK's positive scenarios pass (see `tests/tck/REPORT.md`).
- **Full-text search** with Neo4j's syntax: English and Spanish analyzers (Snowball stemmers), BM25
  scores.
- **Storage** on LMDB (the default) or libmdbx, chosen at build time: transactions, crash safety,
  readers that never wait, several processes on one database.
- **Prepared statements** and a cache of the statements `query` prepares.
- **Embeddings**: a C ABI (`include/zypherdb.h`) and a Python package (`import zypherdb`).
- **An integrity checker** (`check()`), and the test machinery behind it: storage, query, fault and
  crash fuzzers, snapshot tests and pair assertions (see `docs/guide/testing.md`).
