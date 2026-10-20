# 15. A month of swipes: loading data in bulk

Every swipe at every door is a record the lab must keep: who, where, when, and whether the door
opened. Over a month that is thousands of records; for a real site, millions. This step designs
the event log, loads a month of it, and covers what makes loading fast — and durable.

## Events as nodes

A swipe is an event with properties of its own (when, which way, granted or not), connected to
the badge and the door. It is a node:

```text
(:Swipe {at, direction, granted})-[:BY]->(:Badge)
(:Swipe)-[:AT]->(:Door)
```

Why not a relationship from badge to door? Because acmedb keeps **one relationship of a type
between two nodes**: a badge swiped at the same door a hundred times is a hundred events, not one
fact. Modelling events as nodes is the usual graph pattern for anything that happens repeatedly.

## The month's data

Real swipes would come from the readers; here a small generator makes a deterministic month: every
working day in March 2025, each employee enters their usual room in the morning and leaves in the
afternoon.

```python
import random

usual_rooms = {
    70001: "Lobby", 70002: "Genomics Office", 70013: "Sequencing Lab", 70004: "BSL-3 Lab",
    70005: "Sequencing Lab", 70006: "Vivarium Control", 70007: "Seminar Room",
    70008: "BSL-3 Lab", 70009: "Sequencing Lab", 70010: "Animal Holding",
}
rng = random.Random(2025)
events = []
for day in range(3, 32):
    date = datetime.date(2025, 3, day)
    if date.isoweekday() > 5:
        continue
    for badge, room in usual_rooms.items():
        arrive = datetime.datetime.combine(date, datetime.time(7, 30), MADRID) + datetime.timedelta(minutes=rng.randrange(90))
        leave = arrive + datetime.timedelta(hours=8, minutes=rng.randrange(-60, 60))
        events.append({"badge": badge, "door": "D-" + room, "at": arrive, "direction": "in"})
        events.append({"badge": badge, "door": "D-" + room, "at": leave, "direction": "out"})
print(len(events), events[0])
```

```text
420 {'badge': 70001, 'door': 'D-Lobby', 'at': datetime.datetime(2025, 3, 3, 8, 41, tzinfo=zoneinfo.ZoneInfo(key='Europe/Madrid')), 'direction': 'in'}
```

## Loading in batches

One query per event would work, but each query is its own transaction, and a write transaction
waits for the disk when it commits. Thousands of commits are thousands of waits. The fast way is
the one from [step 9](09-pipelines): send a batch as a list parameter, and let one query `UNWIND`
it — one transaction, one commit, for the whole batch.

```python
LOG_SWIPES = """
    UNWIND $events AS event
    MATCH (b:Badge {number: event.badge}), (d:Door {id: event.door})
    CREATE (s:Swipe {at: event.at, direction: event.direction, granted: true}),
           (s)-[:BY]->(b), (s)-[:AT]->(d)
"""
for start in range(0, len(events), 200):
    db.query(LOG_SWIPES, events=events[start:start + 200])
print(db.query("MATCH (s:Swipe) RETURN count(s)"))
```

```text
[[420]]
```

Batches of a few hundred to a few thousand items work well: large enough that the commit is paid
rarely, small enough that a failed batch is cheap to retry.

## The mutator API and write()

Besides queries, `Database` has direct mutators — `allocate_node_id`, `add_node`, `add_edge`,
`set_property` — for loaders that already know their data's shape. Each is a commit of its own,
unless it runs inside a `write()` block, which makes the whole block one transaction:

```python
with db.write():
    for number in range(91000, 91003):
        node = db.allocate_node_id()
        db.add_node(node, "Badge")
        db.set_property(node, "number", number)
        db.set_property(node, "active", False)   # spare badges, not yet issued
print(db.query("MATCH (b:Badge) WHERE b.number >= 91000 RETURN count(b)"))
```

```text
[[3]]
```

If the block raises, nothing in it is written. Queries cannot run inside a `write()` block.

## How durable is a commit?

By default, when a write returns, its data is on disk: a power cut a millisecond later loses
nothing. That guarantee costs a disk flush per commit — milliseconds. For an event log written
swipe by swipe, the database can be opened with a cheaper guarantee:

```python
events_db = Database("helix-audit", durability="deferred")
events_db.query("CREATE (:Swipe {at: $at, door: 'D-Lobby', badge: 70001})", at=monday_morning)
events_db.sync()   # everything so far is on disk now
events_db.close()
```

| `durability` | A commit returns when… | A power cut can lose… |
| --- | --- | --- |
| `"full"` (default) | its data is on disk | nothing |
| `"relaxed"` | its data is on disk; the last commit's bookkeeping follows with the next one | the last commit |
| `"deferred"` | it is in memory; the operating system writes it soon, or `sync()` does | the commits since the last `sync()` |

The database is never corrupted in any mode: what a power cut can do is lose recent commits, never
leave half of one. `deferred` is hundreds of times faster for many small writes; a program using it
calls `sync()` at the points where it needs the guarantee (every second, after every batch).

## Questions over history

With the log in place, history is a query. How many people came through each door in the first
week:

```python
print(db.query("""
    MATCH (s:Swipe {direction: 'in'})-[:AT]->(d:Door)
    WHERE date(s.at) <= date('2025-03-07')
    RETURN d.id, count(s) AS entries ORDER BY entries DESC, d.id LIMIT 3
"""))
```

```text
[['D-Sequencing Lab', 15], ['D-BSL-3 Lab', 10], ['D-Animal Holding', 5]]
```

And each person's average day on site, from their first entry to their last exit:

```python
for name, hours in db.query("""
    MATCH (s:Swipe)-[:BY]->(:Badge)-[:ISSUED_TO]->(p:Person)
    WITH p, date(s.at) AS day, min(s.at) AS first, max(s.at) AS last
    WITH p, avg(duration.between(first, last).minutes) AS minutes
    RETURN p.name, round(minutes / 6.0) / 10.0 AS hours ORDER BY hours DESC, p.name LIMIT 3
"""):
    print(f"{name:<16} {hours} h")
```

```text
Gustavo Pérez    8.1 h
Bruno Lindqvist  8.0 h
Chen Wei         8.0 h
```

Grouping by `date(s.at)` makes one row per person per day; the second `WITH` averages the days.
`round(minutes / 6.0) / 10.0` rounds to tenths of an hour.

Writing fast is half of it; reading safely while others write is the other. [Next](16-concurrency),
errors, threads and processes.
