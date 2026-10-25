"""Simulates a day at Helix Biolabs: door controllers and a monitor on one database.

    python -m examples.helix.simulate [--database DIR] [--every MINUTES] [--verbose]

The main process plays the card readers: it follows every badge's itinerary
(day.py) through the door controller. The monitor runs in a second process,
opening the same database, and checks it every few minutes of simulated time.
The two processes share nothing but the database file.

In production both would run on the clock, independently. Here the readers
wait for each check to finish before going on, so that every run of the
simulation prints the same day.
"""

from __future__ import annotations

import argparse
import datetime
import multiprocessing
import tempfile
from collections import Counter

import zypherdb

from . import day, load, monitor
from .controller import DoorController, door_of

# Who was in each room at a given time, from the log alone: each person's
# last granted swipe before that time, if it was a swipe in.
POSITIONS_AT = """
    MATCH (s:Swipe {granted: true})-[:BY]->(:Badge)-[:ISSUED_TO]->(p:Person),
          (s)-[:AT]->(:Door)-[:LEADS_TO]->(r:Room)
    WHERE s.at <= $at
    WITH p, s, r ORDER BY s.at DESC
    WITH p, collect([s.direction, r.name])[0] AS last
    WHERE last[0] = 'in'
    RETURN last[1] AS room, collect(p.name) AS people ORDER BY room
"""

REFUSALS = "MATCH (s:Swipe {granted: false}) RETURN s.refusal, count(*) ORDER BY count(*) DESC, s.refusal"

ALARMS = "MATCH (a:Alarm) RETURN a.raised, a.cleared, a.kind, a.room ORDER BY a.raised, a.kind"


class Simulation:
    def __init__(self, path: str, every: datetime.timedelta, verbose: bool):
        self.db = zypherdb.Database(path, durability="deferred")
        self.path = path
        self.every = every
        self.verbose = verbose
        self.doors = DoorController(self.db)
        self.holders: dict[int, str] = {}
        self.positions: dict[str, str] = {}  # person -> room, as the readers see it

    def run(self) -> None:
        if self.db.query("MATCH (n) RETURN count(n) > 0") != [[False]]:
            raise SystemExit(f"{self.path} is not empty: the simulation needs a new database")
        load.load(self.db)
        self.holders = dict(self.db.query("MATCH (b:Badge)-[:ISSUED_TO]->(p:Person) RETURN b.number, p.name"))
        movements = day.movements()
        print(f"Helix Biolabs, {day.DAY:%A %d %B %Y}: {load.summary(self.db)}, {len(movements)} movements planned")
        print()

        context = multiprocessing.get_context("spawn")
        times, reports = context.Queue(), context.Queue()
        checker = context.Process(target=monitor.serve, args=(self.path, times, reports))
        checker.start()
        try:
            events = sorted([*movements, *day.operations()], key=lambda event: event.at)
            next_check = day.START
            for event in events:
                while next_check < event.at:
                    self.check(next_check, times, reports)
                    next_check += self.every
                self.apply(event)
            while next_check <= day.END:
                self.check(next_check, times, reports)
                next_check += self.every
        finally:
            times.put(None)
            checker.join()
        self.report()
        self.db.close()

    def apply(self, event: day.Movement | day.Operation) -> None:
        if isinstance(event, day.Operation):
            self.db.query(event.query)
            print(f"{event.at:%H:%M} site     {event.description}")
            return
        person = self.holders[event.badge]
        current = self.positions.get(person)
        if event.room is None:
            if current is not None:
                self.doors.leave(event.badge, door_of(current), event.at)
                del self.positions[person]
                self.trace(event.at, person, f"leaves {current}")
            return
        refusal = self.doors.enter(event.badge, door_of(event.room), event.at)
        if refusal is None:
            self.positions[person] = event.room
            self.trace(event.at, person, f"enters {event.room}")
        else:
            print(f"{event.at:%H:%M} refused  {person:<19} {event.room:<17} {refusal}")

    def check(self, at: datetime.datetime, times: multiprocessing.Queue, reports: multiprocessing.Queue) -> None:
        times.put(at)
        report: monitor.Report = reports.get()
        for alarm in report.raised:
            people = ", ".join(alarm.people)
            print(f"{at:%H:%M} ALARM    {alarm.kind:<19} {alarm.room:<17} {people}".rstrip())
        for alarm in report.cleared:
            print(f"{at:%H:%M} cleared  {alarm.kind:<19} {alarm.room}")

    def trace(self, at: datetime.datetime, person: str, what: str) -> None:
        if self.verbose:
            print(f"{at:%H:%M}          {person:<19} {what}")

    def report(self) -> None:
        (swipes,), = self.db.query("MATCH (s:Swipe) RETURN count(s)")
        print()
        print(f"{swipes} swipes; refused:", ", ".join(f"{reason} {count}" for reason, count in self.db.query(REFUSALS)))

        print()
        print("Alarms:")
        for raised, cleared, kind, room in self.db.query(ALARMS):
            until = f"{cleared:%H:%M}" if cleared else "open"
            print(f"  {raised:%H:%M}-{until:<5} {kind:<19} {room}")

        at = datetime.datetime.combine(day.DAY, datetime.time(11, 40), day.MADRID)
        print()
        print(f"Where everyone was at {at:%H:%M}, from the log:")
        for room, people in self.db.query(POSITIONS_AT, at=at):
            print(f"  {room:<17} {', '.join(sorted(people))}")

        print()
        print(f"Still inside at {day.END:%H:%M}:")
        for room, people in self.db.query("MATCH (p:Person)-[:IS_IN]->(r:Room) RETURN r.name, collect(p.name) ORDER BY r.name"):
            print(f"  {room:<17} {', '.join(sorted(people))}")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--database", help="the database directory (default: a temporary one)")
    parser.add_argument("--every", type=int, default=5, help="minutes between monitor checks (default 5)")
    parser.add_argument("--verbose", action="store_true", help="also print every door that opened")
    args = parser.parse_args(argv)
    every = datetime.timedelta(minutes=args.every)
    if args.database:
        Simulation(args.database, every, args.verbose).run()
    else:
        with tempfile.TemporaryDirectory() as path:
            Simulation(path, every, args.verbose).run()


if __name__ == "__main__":
    main()
