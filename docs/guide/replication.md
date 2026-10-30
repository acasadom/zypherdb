# Replication

A database can keep copies of itself on other machines, up to date as it changes: a **master**
takes the writes, and each **replica** follows it and answers reads. Replicas spread the reads
over more machines, and keep the data on more than one.

> **Warning.** Replication is **not encrypted**. The token and every change travel in clear over
> TCP, so anyone on the network can read them, and anyone who learns the token can follow the
> master. Run it only on a network you trust (a private network, a VPN or an SSH tunnel), and never
> open the master's port to the internet.

## Starting it

Replication is a role the database opens with; there is nothing else to start. The master opens
with `serve`, the address it listens at, and each replica with `replicate_from`, the master's
address. Both give the same `token`, the secret a replica must send to be served:

```python
import os, tempfile, zypherdb

# On the master's machine ("0.0.0.0:7000" listens on every interface; port 0 picks a free one).
master = zypherdb.Database(tempfile.mkdtemp(), serve="127.0.0.1:0", token="a long random secret")
address = master.replication_status()["address"]

# On each replica's machine, in an empty directory.
replica = zypherdb.Database(tempfile.mkdtemp(), replicate_from=address, token="a long random secret")
```

From then on the replica works on its own: it connects to the master, gets a copy of the whole
database, then each change committed there, in order. If the connection breaks, or either side
restarts, it reconnects and goes on from where it was; if it fell too far behind, it gets a new
copy. Closing the database stops replication.

A replica refuses writes (`StorageError`, "the database is a replica"): every write goes to the
master. A database that has been a master cannot become a replica (a replica starts from an empty
directory or is one already), and a replica cannot serve other replicas.

## Reading your own writes

A replica runs a little behind its master: the time a change takes to arrive and be applied,
usually milliseconds. A read on a replica right after a write on the master may not see it yet.
When it must, take the master's `last_lsn` after the write (the number of its last change) and
have the replica wait for it before reading:

```python
master.query("CREATE (:Person {name: 'Ada'})")
lsn = master.last_lsn

if replica.wait_for(lsn, timeout=5.0):
    print(replica.query("MATCH (p:Person) RETURN p.name"))
```

```text
[['Ada']]
```

`wait_for` returns `False` if the change has not arrived within the timeout (the master is
unreachable, or the replica halted). Pass the LSN along with whatever the reader needs, for
example in the response to the request that wrote. A read that may be a little old needs no
waiting.

## Watching it

`replication_status()` tells how replication goes, for monitoring and alerts. On the master:

```python
status = master.replication_status()
print(status["role"], status["last_lsn"], len(status["replicas"]))
```

```text
master 1 1
```

Each replica served has a `phase` (`"introducing"`, `"copying"` while a copy of the database is
made, sent or loaded, `"streaming"` once it follows change by change), the last change it applied
as it last told (`acked_lsn`, at least each heartbeat, one second), and its `lag`, the changes it
has yet to apply. On a replica:

```python
status = replica.replication_status()
print(status["role"], status["applied_lsn"], status["halted"])
```

```text
replica 1 None
```

`master_lsn` is the master's last change as its last heartbeat told, and `lag` the difference.
`halted` is set when the replica stopped following for good, because asking again cannot help: it
names the reason — `"token"` (the master refused the token), `"database_id"` (it is a replica of
another master), `"ahead"` (it has changes the master never made: the master was restored from an
older copy), or a version, format or engine the two do not share. A halted replica keeps answering
reads with what it has; fix the cause and open it again (or start it from an empty directory).
`last_refusal` names why the master last turned it away, when that was not for good.

```python
replica.close()
master.close()
```

## What to know

- **One process runs replication.** Open the database with `serve` or `replicate_from` in one
  process. Other processes may open the same directory without a role: on the master their
  writes reach the replicas too, within a heartbeat; on a replica they read.
- **Copies.** A replica's first copy is the whole database, written to `replication-copies` in
  the database's directory on both machines while it is sent and loaded, so plan disk space for
  one more copy on each side. With libmdbx a copy is at least 16 MiB.
- **The change log.** The master keeps the recent changes (up to 512 MiB) for replicas that
  reconnect; one that was away longer gets a new copy.
- **No automatic failover.** If the master is lost, the replicas keep their data and keep
  answering reads, but nothing becomes the master on its own. Promoting a replica is planned.
- **The same platform.** A replica must run the same ZypherDB storage format and storage engine
  as its master, on a machine of the same byte order (every common one is little-endian).

The C interface opens with a role through `zypherdb_open_replicated` (see the
[C reference](c-api.md#replication)). How replication works inside — the change log, the
protocol, the copies — is in [storage](storage.md#the-change-log) and the source under
`src/replication/`.
