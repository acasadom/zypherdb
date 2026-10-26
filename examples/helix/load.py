"""Loads the site (site.json) and its people (staff.json) into an empty database.

Each kind of thing is one query over a list parameter (UNWIND), so the whole
load is a dozen transactions however large the files are. Times and dates
arrive as ISO 8601 text and become temporal values inside the queries.
"""

from __future__ import annotations

import json
from pathlib import Path

import zypherdb

HERE = Path(__file__).parent

SITE = [
    # The building and its zones.
    """
    CREATE (b:Building {name: $site.building})
    WITH b
    UNWIND $site.zones AS zone
    CREATE (z:Zone {name: zone.name})-[:IN]->(b)
    SET z.public = zone.public, z.closes_at = localtime(zone.closes_at)
    """,
    # Rooms, each with its door and the certifications it requires.
    """
    UNWIND $site.rooms AS room
    MATCH (z:Zone {name: room.zone})
    CREATE (r:Room {name: room.name, bsl: room.bsl})-[:IN]->(z),
           (:Door {id: 'D-' + room.name})-[:LEADS_TO]->(r)
    SET r.min_occupancy = room.min_occupancy, r.max_occupancy = room.max_occupancy,
        r.staffed = room.staffed
    """,
    "UNWIND $site.rooms AS room WITH room WHERE room.high_containment MATCH (r:Room {name: room.name}) SET r:HighContainment",
    "UNWIND $site.certifications AS name CREATE (:Certification {name: name})",
    """
    UNWIND $site.rooms AS room
    UNWIND coalesce(room.requires, []) AS certification
    MATCH (r:Room {name: room.name}), (c:Certification {name: certification})
    CREATE (r)-[:REQUIRES]->(c)
    """,
    # Teams and their hierarchy.
    "UNWIND $site.teams AS team CREATE (:Team {name: team.name})",
    """
    UNWIND $site.teams AS team
    MATCH (t:Team {name: team.name}), (parent:Team {name: team.part_of})
    CREATE (t)-[:PART_OF]->(parent)
    """,
    # Team grants: a zone, with optional days and hours.
    """
    UNWIND $site.grants AS grant
    MATCH (t:Team {name: grant.team}), (z:Zone {name: grant.zone})
    CREATE (t)-[g:MAY_ENTER]->(z)
    SET g.days = grant.days, g.from = localtime(grant.from), g.until = localtime(grant.until)
    """,
]

STAFF = [
    # Employees: who they are, their team, the teams they manage, their badges.
    """
    UNWIND $staff.employees AS e
    MATCH (t:Team {name: e.team})
    CREATE (p:Person:Employee {name: e.name, employee_id: e.employee_id, role: e.role})-[:MEMBER_OF]->(t)
    WITH p, e
    UNWIND e.badges AS number
    CREATE (:Badge {number: number, active: true})-[:ISSUED_TO]->(p)
    """,
    """
    UNWIND $staff.employees AS e
    UNWIND coalesce(e.revoked_badges, []) AS number
    MATCH (p:Person {name: e.name})
    CREATE (:Badge {number: number, active: false})-[:ISSUED_TO]->(p)
    """,
    """
    UNWIND $staff.employees AS e
    UNWIND coalesce(e.manages, []) AS team
    MATCH (p:Person {name: e.name}), (t:Team {name: team})
    CREATE (p)-[:MANAGES]->(t)
    """,
    # Certifications and bans are maps in the file: name -> expiry, zone -> reason.
    """
    UNWIND $staff.employees AS e
    WITH e WHERE e.certifications IS NOT NULL
    UNWIND keys(e.certifications) AS name
    MATCH (p:Person {name: e.name}), (c:Certification {name: name})
    CREATE (p)-[:CERTIFIED {expires: date(e.certifications[name])}]->(c)
    """,
    """
    UNWIND $staff.employees AS e
    WITH e WHERE e.denied IS NOT NULL
    UNWIND keys(e.denied) AS zone
    MATCH (p:Person {name: e.name}), (z:Zone {name: zone})
    CREATE (p)-[:DENIED {reason: e.denied[zone]}]->(z)
    """,
    # Contractors: a badge with an end date, and grants to single rooms.
    """
    UNWIND $staff.contractors AS c
    CREATE (p:Person:Contractor {name: c.name, company: c.company, role: c.role}),
           (:Badge {number: c.badge, active: true, valid_until: date(c.valid_until)})-[:ISSUED_TO]->(p)
    WITH p, c
    UNWIND c.rooms AS room
    MATCH (r:Room {name: room})
    CREATE (p)-[:MAY_ENTER]->(r)
    """,
    # Visitors: a badge for the visit, and the employee who escorts them.
    """
    UNWIND $staff.visitors AS v
    MATCH (escort:Employee {name: v.escort})
    CREATE (p:Person:Visitor {name: v.name, organisation: v.organisation})-[:ESCORTED_BY]->(escort),
           (:Badge {number: v.badge, active: true, valid_until: date(v.valid_until)})-[:ISSUED_TO]->(p)
    """,
]


def load(db: zypherdb.Database, site_file: Path = HERE / "site.json", staff_file: Path = HERE / "staff.json") -> None:
    """Loads the site and its people into `db`, which must be empty."""
    site = json.loads(site_file.read_text(encoding="utf-8"))
    staff = json.loads(staff_file.read_text(encoding="utf-8"))
    for query in SITE:
        db.query(query, site=site)
    for query in STAFF:
        db.query(query, staff=staff)


def summary(db: zypherdb.Database) -> str:
    """One line on what was loaded."""
    (rooms, people, badges), = db.query("""
        MATCH (r:Room) WITH count(r) AS rooms
        MATCH (p:Person) WITH rooms, count(p) AS people
        MATCH (b:Badge) RETURN rooms, people, count(b)
    """)
    return f"{rooms} rooms, {people} people, {badges} badges"
