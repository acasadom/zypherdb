# Changelog

## 0.2.0 — 2026-11-07

### Added

- **Replication.** A database opened with `serve` is a master; one opened with `replicate_from`
  is a read-only replica on another machine (C: `zypherdb_open_replicated`). A replica gets a copy
  of the whole database, then each change committed on the master, in order, and reconnects on its
  own. A replica starts from an empty directory or a replica: a master or a database holding data
  is refused, not overwritten. `last_lsn` and `wait_for` let a client read its own writes; `replication_status()` tells
  each replica's phase and lag. Another process on the master's or a replica's directory stands by
  and takes over when the first one ends. There is no failover to another machine. Addresses are
  `"host:port"`, the host an IP address or a name. A replica's readers can see the master's states
  in jumps, never one the master did not have. See `docs/guide/replication.md`.
- **Copies for replicas.** Replicas asking for a copy at once, or while one is sent, share one
  file on the master's disk, deleted once sent. A replica writes no file of its own and keeps
  serving its database until the copy is whole. A copy holds the database's entries, not the
  storage engine's pages.
- **Encrypted replication.** Replication needs a token: a master and its replicas talk over an
  encrypted, authenticated channel (Noise `NNpsk0` with X25519, ChaCha20-Poly1305 and SHA-256, the
  token as its pre-shared key), and the token never travels. `encrypted=False` (Python) or
  `encrypted = false` (C) sends everything in clear, on both sides. A side that encrypts and one
  that does not are refused with `"encryption"`. A replica refused for that or for its token keeps
  asking (`last_refusal` tells why) instead of halting, as those refusals cannot be authenticated.
- **Writing on a replica.** With `forward_writes=True`, a replica sends each query that writes to
  its master, waits until the change comes back, and returns the rows, within `forward_timeout`
  seconds. `Rows.visible` (C: `zypherdb_result_visible`) is false when the change has not arrived
  in time. `WriteNotForwardedError`, `MasterUnreachableError` and `OutcomeUnknownError` tell how a
  forwarded write failed.
- **Threads.** A Python `Database` can be shared among threads, with no lock across calls: readers
  run at once, and a thread reads its own writes. In C, `zypherdb_open_session` gives another
  thread a context of its own on the same database.
- **`write_many`** (Python) and `zypherdb_write_many` (C): several queries in one transaction,
  each seeing what the ones before it wrote, committed together or not at all; the error tells
  which query failed. On a replica that forwards writes, a batch that writes goes to the master
  as one request.

### Changed

- **A stored value is at most 64 MiB** (was 4 GiB): a node with all its properties, or one
  property of a relationship. A replica holds each write whole while it applies it. A database
  from 0.1.0 holding a larger value cannot be copied to a replica.
- **On macOS, locks are SysV semaphores** (were POSIX ones), for the fix below. When the last process
  on a database is killed, its semaphores stay until the machine restarts, with room for thousands.

### Fixed

- **A process killed during a read no longer makes the file grow.** While another process kept the
  database open, the pages the dead one could see were never reused, and the file grew for ever.
  Opening a database and every 1024th write transaction now drop the readers of dead processes.
- **On macOS, a process killed while writing no longer hangs the others.** Their writes waited for
  ever for the lock it held.

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
