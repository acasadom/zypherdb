"""The door controller: the program behind every card reader.

On each swipe it decides whether the door opens, records the swipe with the
reason for a refusal, and, if the door opened, moves the person into the
room. All of it is one query, so one transaction: the log and the positions
never disagree.
"""

from __future__ import annotations

import datetime

import acmedb

# The access decision. Each rule is a column of the WITH, and `refusal` names
# the first rule broken (null if none is):
#
# - the badge must be active and not expired;
# - a ban on the zone overrides every grant;
# - a grant must reach the zone: the person's team or a team above it, a team
#   the person manages or one below it, or a grant to that single room; public
#   zones need none;
# - a team grant may be limited to some days and hours;
# - the room may require certifications, which must not have expired;
# - a zone may close at a fixed time;
# - a room may have a maximum occupancy.
ENTER = """
    WITH $at AS at, localtime($at) AS clock, date($at) AS today
    MATCH (b:Badge {number: $badge})-[:ISSUED_TO]->(p:Person),
          (d:Door {id: $door})-[:LEADS_TO]->(r:Room)-[:IN]->(z:Zone)
    WITH b, d, p, r, z, at, clock, today,
         [(p)-[:MEMBER_OF]->(:Team)-[:PART_OF*0..]->(:Team)-[g:MAY_ENTER]->(z) | g]
         + [(p)-[:MANAGES]->(:Team)<-[:PART_OF*0..]-(:Team)-[g:MAY_ENTER]->(z) | g] AS grants,
         coalesce(z.public, false) OR EXISTS { (p)-[:MAY_ENTER]->(r) } AS always_open
    WITH b, d, p, r, at,
         b.active AND (b.valid_until IS NULL OR b.valid_until >= today) AS badge_ok,
         EXISTS { (p)-[:DENIED]->(z) } AS barred,
         always_open OR size(grants) > 0 AS reaches_zone,
         always_open OR any(g IN grants WHERE g.days IS NULL
                                           OR (at.dayOfWeek IN g.days AND g.from <= clock < g.until)) AS in_hours,
         EXISTS { (r)-[:REQUIRES]->(c:Certification)
                  WHERE NOT EXISTS { (p)-[held:CERTIFIED]->(c) WHERE held.expires >= today } } AS untrained,
         z.closes_at IS NOT NULL AND clock >= z.closes_at AS closed,
         r.max_occupancy IS NOT NULL
         AND size([(other:Person)-[:IS_IN]->(r) WHERE other <> p | other]) >= r.max_occupancy AS full
    WITH b, d, p, r, at,
         CASE
           WHEN NOT badge_ok THEN 'badge not valid'
           WHEN barred THEN 'barred from the zone'
           WHEN NOT reaches_zone THEN 'no access'
           WHEN NOT in_hours THEN 'outside hours'
           WHEN untrained THEN 'training missing'
           WHEN closed THEN 'zone closed'
           WHEN full THEN 'room full'
         END AS refusal
    CREATE (s:Swipe {at: at, direction: 'in', granted: refusal IS NULL, refusal: refusal}),
           (s)-[:BY]->(b), (s)-[:AT]->(d)
    WITH p, r, at WHERE refusal IS NULL
    OPTIONAL MATCH (p)-[previous:IS_IN]->()
    DELETE previous
    CREATE (p)-[:IS_IN {since: at}]->(r)
    RETURN r.name
"""

# A refused swipe ends ENTER with no rows; the log says why.
REFUSAL = """
    MATCH (s:Swipe {at: $at, direction: 'in'})-[:BY]->(:Badge {number: $badge})
    RETURN s.refusal
"""

# The door always lets people out: the swipe is logged and the position removed.
LEAVE = """
    MATCH (b:Badge {number: $badge})-[:ISSUED_TO]->(p:Person), (d:Door {id: $door})-[:LEADS_TO]->(r:Room)
    CREATE (s:Swipe {at: $at, direction: 'out', granted: true}), (s)-[:BY]->(b), (s)-[:AT]->(d)
    WITH p, r
    OPTIONAL MATCH (p)-[here:IS_IN]->(r)
    DELETE here
"""


class DoorController:
    """Decides and records the swipes of every reader, on one database."""

    def __init__(self, db: acmedb.Database):
        self.db = db

    def enter(self, badge: int, door: str, at: datetime.datetime) -> str | None:
        """Swipes `badge` at `door` to go in: None if it opened, else why not."""
        if self.db.query(ENTER, badge=badge, door=door, at=at):
            return None
        refusal = self.db.query(REFUSAL, badge=badge, at=at)
        return refusal[0][0] if refusal else "unknown badge or door"

    def leave(self, badge: int, door: str, at: datetime.datetime) -> None:
        """Swipes `badge` at `door` to go out."""
        self.db.query(LEAVE, badge=badge, door=door, at=at)


def door_of(room: str) -> str:
    return f"D-{room}"
