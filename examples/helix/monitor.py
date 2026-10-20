"""The monitor: the rules no door can enforce, checked periodically.

A door always lets people out, so it cannot stop someone being left alone in
a lab; nobody can be forced out when a zone closes. Each such rule is a query
that returns the rooms in breach right now, with the people involved. A
breach raises an alarm, one per rule and room while it lasts, and the alarm
is cleared when the breach ends. Alarms are nodes, so their history stays in
the graph.

`serve` runs the monitor in a process of its own, next to the door
controllers, on the same database.
"""

from __future__ import annotations

import datetime
import multiprocessing
from dataclasses import dataclass

import acmedb

CHECKS = {
    # A lab with a minimum occupancy must not hold fewer people (it may be empty).
    "alone": """
        MATCH (p:Person)-[:IS_IN]->(r:Room) WHERE r.min_occupancy IS NOT NULL
        WITH r, collect(p.name) AS people
        WHERE size(people) < r.min_occupancy
        RETURN r.name, people
    """,
    # A staffed room must never be empty.
    "unstaffed": """
        MATCH (r:Room {staffed: true}) WHERE NOT ()-[:IS_IN]->(r)
        RETURN r.name, []
    """,
    # The doors refuse a full room, but a limit can be lowered with people inside.
    "over capacity": """
        MATCH (p:Person)-[:IS_IN]->(r:Room) WHERE r.max_occupancy IS NOT NULL
        WITH r, collect(p.name) AS people
        WHERE size(people) > r.max_occupancy
        RETURN r.name, people
    """,
    # A zone must be empty from its closing time.
    "after closing": """
        MATCH (p:Person)-[:IS_IN]->(r:Room)-[:IN]->(z:Zone)
        WHERE z.closes_at IS NOT NULL AND localtime($at) >= z.closes_at
        RETURN r.name, collect(p.name)
    """,
    # A visitor must be in the same room as their escort.
    "unescorted visitor": """
        MATCH (v:Visitor)-[:IS_IN]->(r:Room)
        WHERE NOT EXISTS { (v)-[:ESCORTED_BY]->(e) WHERE (e)-[:IS_IN]->(r) }
        RETURN r.name, collect(v.name)
    """,
    # Nobody stays in high containment for more than four hours.
    "overstay": """
        MATCH (p:Person)-[i:IS_IN]->(r:HighContainment)
        WHERE duration.inSeconds(i.since, $at).seconds > 4 * 3600
        RETURN r.name, collect(p.name)
    """,
}

RAISE = """
    MERGE (a:Alarm {kind: $kind, room: $room, open: true})
    ON CREATE SET a.raised = $at
    SET a.people = $people
    RETURN a.raised = $at
"""

CLEAR = """
    MATCH (a:Alarm {open: true}) WHERE NOT [a.kind, a.room] IN $active
    SET a.open = false, a.cleared = $at
    RETURN a.kind, a.room
"""


@dataclass(frozen=True)
class Alarm:
    kind: str
    room: str
    people: tuple[str, ...] = ()


@dataclass(frozen=True)
class Report:
    """What one run of the checks changed."""

    at: datetime.datetime
    raised: tuple[Alarm, ...]
    cleared: tuple[Alarm, ...]


def check(db: acmedb.Database, at: datetime.datetime) -> Report:
    """Runs every check at time `at`: raises the alarms for new breaches, clears the ended ones."""
    active = []
    raised = []
    for kind, query in CHECKS.items():
        for room, people in db.query(query, at=at):
            people = sorted(people)
            [[new]] = db.query(RAISE, kind=kind, room=room, people=people, at=at)
            if new:
                raised.append(Alarm(kind, room, tuple(people)))
            active.append([kind, room])
    cleared = [Alarm(kind, room) for kind, room in db.query(CLEAR, active=active, at=at)]
    return Report(at, tuple(raised), tuple(cleared))


def serve(path: str, times: multiprocessing.Queue, reports: multiprocessing.Queue) -> None:
    """Checks the database at `path` at each time that arrives on `times`, until None does.

    The process opens the database itself: the controllers and the monitor
    share the file, not a Python object.
    """
    with acmedb.Database(path, durability="deferred") as db:
        while (at := times.get()) is not None:
            reports.put(check(db, at))
