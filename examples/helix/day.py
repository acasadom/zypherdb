"""Tuesday 11 March 2025 at Helix Biolabs, as data.

Each badge has an itinerary: the times its holder goes into a room, and the
time they go home. Going into a room is a swipe at its door; going home is a
swipe out of the room they are in. The simulation follows the itineraries
whatever the doors answer: a refused person stays where they were.

Most of the day is ordinary. The comments mark the moments where a rule is
tested, by the doors (a refusal) or by the monitor (an alarm).
"""

from __future__ import annotations

import datetime
from dataclasses import dataclass
from zoneinfo import ZoneInfo

MADRID = ZoneInfo("Europe/Madrid")
DAY = datetime.date(2025, 3, 11)

ITINERARIES = {
    # Animal care: the vivarium control room is never left empty.
    70010: "mon 21:30 Vivarium Control, 07:10 Animal Holding, 07:20 home",  # night shift; not trained for the animals
    70006: "06:55 Lobby, 07:00 Vivarium Control, 08:30 Animal Holding, 09:30 Vivarium Control, "
           "13:00 Animal Holding, 13:30 Vivarium Control, 15:00 home",  # 13:00: Olga is at lunch
    70022: "07:30 Lobby, 07:35 Vivarium Control, 10:00 Animal Holding, 11:00 Vivarium Control, "
           "12:45 Seminar Room, 13:40 Vivarium Control, 16:00 home",
    70023: "14:30 Lobby, 14:35 Vivarium Control",  # the evening shift, still there at the end

    # Virology: the BSL-3 lab takes two to four people, for at most four hours.
    70004: "08:15 Lobby, 08:25 Airlock, 08:30 BSL-3 Lab, 12:40 Seminar Room, "
           "13:30 Airlock, 13:35 BSL-3 Lab, 16:30 home",  # 12:35: in for over four hours
    70008: "08:15 Lobby, 08:25 Airlock, 08:30 BSL-3 Lab, 12:40 Seminar Room, "
           "13:30 Airlock, 13:35 BSL-3 Lab, 16:30 home",
    70009: "08:15 Lobby, 08:25 Airlock, 08:30 BSL-3 Lab, 09:00 Seminar Room, 12:00 home",  # not certified
    70018: "08:50 Lobby, 09:00 Airlock, 09:05 BSL-3 Lab, 12:50 Seminar Room, "
           "14:00 Airlock, 14:10 BSL-3 Lab, 14:15 home",  # 12:40: left alone; 14:10: the lab is full
    70019: "08:50 Lobby, 09:00 Airlock, 09:05 BSL-3 Lab, 11:30 home",
    70020: "10:00 Lobby, 10:05 Airlock, 10:10 BSL-3 Lab, 10:15 Seminar Room, "
           "14:00 Airlock, 14:05 BSL-3 Lab, 18:20 home",  # 10:10: full; 18:00: past closing
    70021: "10:00 Lobby, 10:05 Airlock, 10:10 BSL-3 Lab, 10:15 Seminar Room, "
           "14:00 Airlock, 14:05 BSL-3 Lab, 18:20 home",

    # Biosafety: rounds everywhere, and an inspector to escort.
    70001: "07:45 Lobby, 08:00 Genomics Office, 09:50 Lobby, 10:00 Seminar Room, 11:00 Airlock, "
           "11:35 BSL-3 Lab, 11:45 Seminar Room, 12:30 Lobby, 12:35 Genomics Office, 17:00 home",
    70011: "15:30 Lobby, 15:40 Sequencing Lab, 16:00 Animal Holding, 16:40 Airlock, 16:45 BSL-3 Lab, 17:00 home",
    90001: "09:55 Lobby, 10:00 Seminar Room, 10:30 Sequencing Lab, 12:30 Lobby, 12:35 home",  # 11:00: Ada leaves her

    # Research and genomics: the head of research manages every team, but is barred from containment.
    70007: "09:00 Lobby, 09:05 Genomics Office, 10:30 Airlock, 10:35 Genomics Office, 16:00 home",
    70002: "08:10 Lobby, 08:15 Genomics Office, 14:00 Lobby, 14:05 Seminar Room, 15:00 Lobby, "
           "15:05 Genomics Office, 18:00 home",
    90002: "14:00 Lobby, 14:05 Seminar Room, 15:00 Lobby, 15:05 home",
    70012: "08:30 Lobby, 08:35 Genomics Office, 17:30 home",
    70014: "09:00 Lobby, 09:05 Genomics Office, 10:00 Sequencing Lab, 11:00 Genomics Office, 18:30 home",  # 10:00: full

    # Sequencing: the lab takes five.
    70003: "07:55 Lobby",  # Chen's old badge, revoked
    70013: "07:57 Lobby, 08:00 Sequencing Lab, 12:30 Seminar Room, 13:15 Sequencing Lab, 17:00 home",
    70005: "06:50 Lobby, 06:55 Sequencing Lab, 07:00 Sequencing Lab, 12:00 Seminar Room, "
           "12:45 Sequencing Lab, 16:00 home",  # 06:55: the floor opens at 07:00
    70015: "08:45 Lobby, 08:50 Sequencing Lab, 17:30 home",
    70016: "09:10 Lobby, 09:15 Sequencing Lab, 15:30 home",
    70017: "09:20 Lobby, 09:25 Sequencing Lab, 18:00 home",

    # Contractors: a single room, until their contract ends.
    80001: "10:00 Lobby, 10:05 Genomics Office, 10:40 Sequencing Lab, 11:30 home",  # only the office
    80002: "10:00 Lobby",  # her badge expired last Friday
}

# Changes to the site during the day, made by the facilities team.
OPERATIONS = [
    ("15:00", "a sequencer is serviced: the Sequencing Lab takes 3",
     "MATCH (r:Room {name: 'Sequencing Lab'}) SET r.max_occupancy = 3"),
    ("15:45", "the service is done: the Sequencing Lab takes 5 again",
     "MATCH (r:Room {name: 'Sequencing Lab'}) SET r.max_occupancy = 5"),
]

START = datetime.datetime.combine(DAY, datetime.time(6, 0), MADRID)
END = datetime.datetime.combine(DAY, datetime.time(19, 0), MADRID)


@dataclass(frozen=True)
class Movement:
    at: datetime.datetime
    badge: int
    room: str | None  # None: going home


@dataclass(frozen=True)
class Operation:
    at: datetime.datetime
    description: str
    query: str


def _time(text: str) -> datetime.datetime:
    day = DAY
    if text.startswith("mon "):
        day, text = DAY - datetime.timedelta(days=1), text[4:]
    return datetime.datetime.combine(day, datetime.time.fromisoformat(text), MADRID)


def movements() -> list[Movement]:
    """Every movement of the day, in time order (badges in itinerary order within a minute)."""
    result = []
    for badge, itinerary in ITINERARIES.items():
        for step in itinerary.split(", "):
            *time, place = step.split(" ", 2) if step.startswith("mon ") else step.split(" ", 1)
            result.append(Movement(_time(" ".join(time)), badge, None if place == "home" else place))
    return sorted(result, key=lambda movement: movement.at)


def operations() -> list[Operation]:
    return [Operation(_time(at), description, query) for at, description, query in OPERATIONS]
