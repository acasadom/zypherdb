# 19. The monitor: rules that are checked, not enforced

Some rules cannot be enforced at the door. A door always lets people *out*, so it cannot stop the
second-to-last person leaving someone alone in the BSL-3 lab; nobody can be forced to leave when a
zone closes; an escort can walk away from a visitor. These rules are **checked**: a job runs every
minute, asks the database what is wrong right now, and raises an alarm for each problem — and
clears it when it is gone.

## One query per rule

Each check returns the rooms in breach, with the people involved. They all read the current
positions (`IS_IN`) and the rules stored on rooms and zones:

```python
CHECKS = {
    "alone": """
        MATCH (p:Person)-[:IS_IN]->(r:Room) WHERE r.min_occupancy IS NOT NULL
        WITH r, collect(p.name) AS people
        WHERE size(people) < r.min_occupancy
        RETURN r.name, people
    """,
    "unstaffed": """
        MATCH (r:Room {staffed: true}) WHERE NOT ()-[:IS_IN]->(r)
        RETURN r.name, []
    """,
    "over capacity": """
        MATCH (p:Person)-[:IS_IN]->(r:Room) WHERE r.max_occupancy IS NOT NULL
        WITH r, collect(p.name) AS people
        WHERE size(people) > r.max_occupancy
        RETURN r.name, people
    """,
    "after closing": """
        MATCH (p:Person)-[:IS_IN]->(r:Room)-[:IN]->(z:Zone)
        WHERE z.closes_at IS NOT NULL AND localtime($at) >= z.closes_at
        RETURN r.name, collect(p.name)
    """,
    "unescorted visitor": """
        MATCH (v:Visitor)-[:IS_IN]->(r:Room)
        WHERE NOT EXISTS { (v)-[:ESCORTED_BY]->(e) WHERE (e)-[:IS_IN]->(r) }
        RETURN r.name, collect(v.name)
    """,
    "overstay": """
        MATCH (p:Person)-[i:IS_IN]->(r:HighContainment)
        WHERE duration.inSeconds(i.since, $at).seconds > 4 * 3600
        RETURN r.name, collect(p.name)
    """,
}
```

`collect` gathers the people per room; `size(people) < r.min_occupancy` catches the lone worker
— a room with *nobody* in it has no rows at all, which is right for the BSL-3 lab (empty is safe)
and wrong for the vivarium control room, which is why *unstaffed* is a rule of its own.

## Alarms as nodes

A problem that persists should be one alarm, not one per minute. `MERGE` on the alarm's identity
— its kind, its room, and that it is still open — finds the existing one or raises a new one:

```python
RAISE = """
    MERGE (a:Alarm {kind: $kind, room: $room, open: true})
    ON CREATE SET a.raised = $at
    SET a.people = $people
"""
CLEAR = """
    MATCH (a:Alarm {open: true}) WHERE NOT [a.kind, a.room] IN $active
    SET a.open = false, a.cleared = $at
    RETURN a.kind, a.room
"""

def check(at):
    active = []
    for kind, query in CHECKS.items():
        for room, people in db.query(query, at=at):
            db.query(RAISE, kind=kind, room=room, people=sorted(people), at=at)
            active.append([kind, room])
    cleared = db.query(CLEAR, active=active, at=at)
    open_alarms = db.query("MATCH (a:Alarm {open: true}) RETURN a.kind, a.room, a.people ORDER BY a.kind")
    print(f"{at:%H:%M}", "open:", open_alarms or "none", "| cleared:", cleared or "none")
```

`CLEAR` closes every open alarm whose problem is no longer among the active ones: `[a.kind,
a.room] IN $active` compares lists element by element. Closed alarms stay in the graph, with when
they were raised and cleared — an audit trail.

## The rest of Tuesday

We left Dalia alone in the BSL-3 lab at noon. The monitor's runs through the afternoon, and what
the readers saw in between:

```python
check(tuesday(12, 1))
swipe(tuesday(12, 20), 70008, "D-BSL-3 Lab")         # Joon goes back in
check(tuesday(12, 21))                               # Dalia: in since 08:20
doors.leave(70006, "D-Vivarium Control", tuesday(13, 0))   # Fatima's lunch
check(tuesday(13, 1))
swipe(tuesday(13, 5), 70010, "D-Vivarium Control")    # Lars takes over
doors.leave(70001, "D-Lobby", tuesday(13, 10))        # Ada leaves the inspector
check(tuesday(13, 11))
```

```text
12:01 open: [['alone', 'BSL-3 Lab', ['Dalia Haddad']]] | cleared: none
12:20 Joon Park        D-BSL-3 Lab          open
12:21 open: [['overstay', 'BSL-3 Lab', ['Dalia Haddad']]] | cleared: [['alone', 'BSL-3 Lab']]
13:01 open: [['overstay', 'BSL-3 Lab', ['Dalia Haddad']], ['unstaffed', 'Vivarium Control', []]] | cleared: none
13:05 Lars Becker      D-Vivarium Control   open
13:11 open: [['overstay', 'BSL-3 Lab', ['Dalia Haddad']], ['unescorted visitor', 'Lobby', ['Ines Moreau']]] | cleared: [['unstaffed', 'Vivarium Control']]
```

Joon's return clears the lone-worker alarm at 12:21 — and the same run raises another: Dalia has
been in the sealed lab since 08:20, over four hours. She comes out, and the day goes on until the
suite closes with Joon still inside:

```python
doors.leave(70004, "D-BSL-3 Lab", tuesday(13, 20))
swipe(tuesday(13, 25), 70001, "D-Lobby")              # Ada is back with the inspector
check(tuesday(13, 26))
check(tuesday(18, 5))
```

```text
13:25 Ada Okafor       D-Lobby              open
13:26 open: [['alone', 'BSL-3 Lab', ['Joon Park']]] | cleared: [['overstay', 'BSL-3 Lab'], ['unescorted visitor', 'Lobby']]
18:05 open: [['after closing', 'BSL-3 Lab', ['Joon Park']], ['alone', 'BSL-3 Lab', ['Joon Park']], ['overstay', 'BSL-3 Lab', ['Joon Park']]] | cleared: none
```

By 18:05 Joon is alone, past closing time, and in for over four hours: three alarms for one
situation, each a different rule broken, each cleared on its own when it is fixed.

The day's alarm history is a query like any other:

```python
for kind, room, raised, cleared in db.query("""
    MATCH (a:Alarm) RETURN a.kind, a.room, a.raised, a.cleared ORDER BY a.raised, a.kind
"""):
    print(f"{raised:%H:%M}-{f'{cleared:%H:%M}' if cleared else '     '} {kind:<19} {room}")
```

```text
12:01-12:21 alone               BSL-3 Lab
12:21-13:26 overstay            BSL-3 Lab
13:01-13:11 unstaffed           Vivarium Control
13:11-13:26 unescorted visitor  Lobby
13:26-      alone               BSL-3 Lab
18:05-      after closing       BSL-3 Lab
18:05-      overstay            BSL-3 Lab
```

## Running it every minute

The check is a function; running it periodically is the job of whatever runs your services. In a
long-lived process, a loop:

```python
# docs-test: skip
import time

while True:
    check(datetime.datetime.now(MADRID))
    time.sleep(60)
```

As a separate program, the system's scheduler can start a script every minute — with `cron`, a
line like `* * * * * /usr/bin/python3 /srv/helix/check.py` — where `check.py` opens the database,
calls `check` once and exits. Both work alongside the door controllers: the monitor's queries read
a consistent snapshot, and its few writes take their turn with the controllers' ([step
16](16-concurrency)).

What happens with an alarm — a page, a siren, a message to the security desk — is up to the
program: `check` knows exactly which alarms are new (raised in this run) and which cleared.

## What you have built

Over nineteen steps, Helix Biolabs got:

- a graph of its people, teams, buildings, rooms and doors ([1](01-getting-started)–[3](03-relationships));
- the queries to explore it, report on it and keep it current ([4](04-filtering)–[10](10-optional));
- access rules as data — team grants with hours, management reach, personal exceptions, bans,
  training — and the one query that applies them all ([11](11-hierarchies)–[14](14-time));
- an event log at volume, used safely from many threads and processes ([15](15-loading)–[17](17-performance));
- a door controller that decides, records and tracks in one transaction ([18](18-door-controller)),
  and a monitor for the rules no door can enforce.

From here, the [Cypher reference](../guide/cypher) lists everything the language can do, the
[Python reference](../guide/python) every method, and the technical guides explain how acmedb
works inside.
