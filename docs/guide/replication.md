# Replication

A database can keep copies of itself on other machines, up to date as it changes: a **master**
takes the writes, and each **replica** follows it and answers reads. Replicas spread the reads
over more machines, and keep the data on more than one.

> **The token is the key.** With a token, every conversation is encrypted and authenticated, and
> the token itself never travels: a side that does not hold it gets no further than the handshake.
> Anyone who learns the token can follow the master and send it writes, and someone who recorded
> a conversation can try guesses of the token against it, so make it long and random (16 bytes
> from a secure source or more). With no token (C only), or `encrypted=False`, everything travels
> in clear, the token too: then run replication only on a network you trust, or inside a VPN or an
> SSH tunnel. See [Encryption](#encryption).

## Starting it

Replication is a role the database opens with; there is nothing else to start. The master opens
with `serve`, the address it listens at, and each replica with `replicate_from`, the master's
address. Both give the same `token`, the secret they share:

```python
import os, tempfile, zypherdb

# On the master's machine ("0.0.0.0:7000" listens on every interface; port 0 picks a free one).
master = zypherdb.Database(tempfile.mkdtemp(), serve="127.0.0.1:0", token="a long random secret")
address = master.replication_status()["address"]

# On each replica's machine, in an empty directory.
replica = zypherdb.Database(tempfile.mkdtemp(), replicate_from=address, token="a long random secret", name="eu-1")
```

`name` is what the replica calls itself in its master's status; without it, the name of its host.

From then on the replica works on its own: it connects to the master, gets a copy of the whole
database, then each change committed there, in order. If the connection breaks, or either side
restarts, it reconnects and goes on from where it was; if it fell too far behind, it gets a new
copy. Closing the database stops replication.

A replica refuses writes (`StorageError`, "the database is a replica"): every write goes to the
master, or the replica forwards it there ([writing on a replica](#writing-on-a-replica)). A database that has been a master cannot become a replica (a replica starts from an empty
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
print(status["role"], status["standby"], status["last_lsn"], len(status["replicas"]))
```

```text
master False 1 1
```

`standby` is true in a process standing by to take over (see below), which serves no replica.
Each replica served has its `name`, the `address` it connected from, how long ago it connected
(`connected_ms`), a `phase` (`"introducing"`, `"copying"` while a copy of the database is made,
sent or loaded, `"streaming"` once it follows change by change), the last change it applied as it
last told (`acked_lsn`, at least each heartbeat, one second), and its `lag`, the changes it has yet
to apply:

```python
served = status["replicas"][0]
print(served["name"], served["address"].startswith("127.0.0.1:"))
```

```text
eu-1 True
```

On a replica:

```python
status = replica.replication_status()
print(status["role"], status["standby"], status["name"], status["applied_lsn"], status["halted"])
```

```text
replica False eu-1 1 None
```

`phase` is `"connecting"` (also while waiting to connect again, or standing by), `"copying"`,
`"streaming"` or `"halted"`; `master_address` is the master it follows, and `last_contact_ms` how
long ago it last heard from it (`None` if never): a master silent for five of its heartbeats (the
master tells the replica how often it sends them; five seconds) is left, and the replica connects
again. `master_lsn` is the master's last change as its last heartbeat told,
and `lag` the difference.
`halted` is set when the replica stopped following for good, because asking again cannot help: it
names the reason — `"token"` (the master holds another token), `"encryption"` (one side encrypts
and the other does not), `"database_id"` (it is a replica of another master), `"ahead"` (it has changes the master never made: the master was restored from an
older copy), or a version, format or engine the two do not share. A halted replica keeps answering
reads with what it has; fix the cause and open it again (or start it from an empty directory).
`last_refusal` names why the master last turned it away, when that was not for good.

## Encryption

A token makes each conversation between a master and a replica encrypted: the Noise protocol's
`Noise_NNpsk0_25519_ChaChaPoly_SHA256`, with the token as its pre-shared key. Each connection makes
fresh keys, so what it carried stays secret even if the token is learned later, and every byte
after the handshake is authenticated: anything changed, repeated or moved on the way ends the
connection, and the replica connects again. There are no certificates: only the two sides that hold
the token can finish the handshake.

The master and its replicas must agree: `encrypted=False` (on by default) on all of them sends
everything in clear, for a network that is already encrypted, or to save the CPU. A side that
encrypts and one that does not stop with `"encryption"`.

Before there are keys there is nothing to protect a message with, so a refusal for a wrong token
or for not encrypting travels in clear, and whoever can write on the connection can forge one and
stop a replica, until it is opened again.

## Writing on a replica

An application that mostly reads, close to its users, and writes now and then, can write through
the replica: opened with `forward_writes=True`, a replica sends each query that writes to its
master, which runs it as its own; the replica waits until that change has come back to it and
returns the query's rows, so a read on the replica right after sees the write:

```python
edge = zypherdb.Database(tempfile.mkdtemp(), replicate_from=address, token="a long random secret",
                         name="edge-1", forward_writes=True, forward_timeout=30.0)
edge.wait_for(master.last_lsn)  # its first copy

rows = edge.query("CREATE (p:Person {name: $name}) RETURN p.name", name="Grace")
print(rows, rows.visible)
print(edge.query("MATCH (p:Person {name: 'Grace'}) RETURN count(p)"))
```

```text
[['Grace']] True
[[1]]
```

A forwarded write costs a round trip to the master, its run there, and the time the change takes
to come back; reads run on the replica as ever, at no extra cost. The replica opens one connection
to its master for writes, apart from replication's, the first time it forwards one. Threads
share it: up to 64 writes are on their way at once, so one thread's write does not wait for
another's round trip (the master still runs them one after another, in the order they came). A
process that opened the replica with a role and stands by forwards writes too.

Each forwarded write takes at most `forward_timeout` seconds, and how it ended is told apart:

- **Its rows come back**: the master committed it. If the change had not reached the replica
  when the time ran out, the rows still come back, with `rows.visible` `False`: a read on the
  replica may not show the write yet, until replication catches up.
- **`MasterUnreachableError`**: the write did not run, because the master could not be reached
  (or turned it away). It is safe to try again.
- **`OutcomeUnknownError`**: the write was sent, then the connection was lost or the time ran
  out; the master may have committed it or not. Check before trying again, or make the write
  safe to repeat (`MERGE`).
- A query that fails on the master raises as it would there (a `ConstraintViolationError`, a
  `TypeMismatchError`...).

Some writes are not forwarded and raise `WriteNotForwardedError`: `LOAD CSV` (the file is on the
replica's machine), queries that call a procedure defined in this process, `PROFILE` of a
query that writes, and `write()` blocks. Only queries are forwarded: the mutators (`add_node`,
`set_property`...) still raise `StorageError` on a replica. Schema statements (`CREATE INDEX`,
`CREATE CONSTRAINT`) are forwarded; `EXPLAIN` and `SHOW` run on the replica.

Several writes that belong together go as one `write_many` (see the [Python
reference](python.md)): one request, one transaction on the
master, one round trip, and one wait for the change to come back:

```python
card, door = edge.write_many([
    ("CREATE (c:Card {number: $number}) RETURN c.number", {"number": 77}),
    ("MATCH (c:Card {number: $number}) CREATE (c)-[:OPENS]->(d:Door {name: 'B7'}) RETURN d.name", {"number": 77}),
])
print(card, door, door.visible)
```

```text
[[77]] [['B7']] True
```

```python
edge.close()
replica.close()
master.close()
```

## Staying available

ZypherDB is embedded: a database is available while a process that has it open runs, on the
machine that holds its directory. Replication keeps going through what can happen to them:

- **A process dies.** Open the database with the same role in more than one process on the
  machine. One runs replication and the others stand by; when it closes the database or dies,
  one of them takes over within a fraction of a second (see below). On the master it serves at
  the same address, so its replicas reconnect on their own and go on from the last change they
  applied, without a new copy. On a replica it follows the master from the last change applied.
  The application's other processes keep reading and writing all along.
- **The machine restarts.** While the master is down its replicas keep answering reads, with the
  data as of the last change they got, and keep trying to reconnect; writes wait for the master.
  When the processes open the database again, its replicas reconnect and go on from where they
  were (or get a new copy if the master's change log no longer holds what they miss). What was
  committed on the master survives as the durability it was opened with says. A replica that
  restarts reconnects and catches up the same way.
- **The machine is lost.** Its replicas keep the data and keep answering reads, but none of them
  becomes the master, and a replica's directory stays a replica's: writing again needs the
  master's directory back. Changes committed on the master and not yet applied on a replica
  exist only there (replication is asynchronous).

So the processes that write run on the master's machine, more than one of them with the master's
role for a process failure, and a machine failure is covered by restarting it.

## What to know

- **One process runs replication, others stand by.** The process that opens the database with
  `serve` or `replicate_from` first runs replication, holding a lock on `replication.lock` in its
  directory. Another process that opens it with a role stands by: it works as any other process,
  and when the first one closes the database or dies, it takes over within a fraction of a
  second, from where replication was (the change log and the last change applied are in the
  database, not in the process). Replicas reconnect on their own. `replication_status()` tells
  which process is which (`"standby"`). So that a master's replicas find the process taking over,
  give a fixed port (`"0.0.0.0:7000"`, not port 0), and the same address and token in every
  process. Processes may also open the directory without a role: on the master they write too,
  and their writes reach the replicas within a heartbeat; on a replica they read, and
  `last_lsn` and `wait_for` work in them as well.
- **Copies.** A replica's first copy is the whole database, written to `replication-copies` in
  the master's directory while it is sent: plan disk space for one more copy there. Replicas
  asking for a copy while one is made or sent share it. A replica loads its copy as it arrives,
  with no file of its own, and goes on serving the database it had until the copy is whole; a
  copy cut short leaves it as it was, and it asks for another.
- **The change log.** The master keeps the recent changes (up to 512 MiB) for replicas that
  reconnect; one that was away longer gets a new copy.
- **No failover to another machine.** A replica never becomes a master, on its own or by hand
  ([staying available](#staying-available)).
- **The same platform.** A replica must run the same ZypherDB storage format and storage engine
  as its master, on a machine of the same byte order (every common one is little-endian).

The C interface opens with a role through `zypherdb_open_replicated` (see the
[C reference](c-api.md#replication)). How replication works inside — the change log, the
protocol, the copies — is in [storage](storage.md#the-change-log) and the source under
`src/replication/`.
