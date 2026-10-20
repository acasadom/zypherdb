# 18. The door controller

Everything so far comes together in the program that sits behind every card reader. On each swipe
it must, in one go:

1. decide whether the door opens — the badge, the grants and their hours, bans, training, closing
   time, and now the room's capacity;
2. record the swipe, granted or not;
3. if it opened, move the person: they are now in that room, and no longer wherever they were.

Doing all three in **one query** makes them one transaction: the log and the positions can never
disagree, whatever fails and whenever.

## Entering

The query below is the decision of [step 14](14-time) with two changes: the badge's `active` flag
and expiry move into the decision (so a swipe with a revoked badge is *logged* as refused rather
than ignored), and a full room refuses entry. Then come the writes.

```python
ENTER = """
    WITH datetime({datetime: $at, timezone: 'Europe/Madrid'}) AS at
    WITH at, localtime(at) AS clock, date(at) AS today
    MATCH (b:Badge {number: $badge})-[:ISSUED_TO]->(p:Person),
          (d:Door {id: $door})-[:LEADS_TO]->(r:Room)-[:IN]->(z:Zone)
    WITH b, d, p, r, z, at,
         b.active AND (b.valid_until IS NULL OR b.valid_until >= today) AS badge_ok,
         z.public = true
         OR EXISTS { (p)-[:MEMBER_OF]->(:Team)-[:PART_OF*0..]->(:Team)-[g:MAY_ENTER]->(z)
                     WHERE g.days IS NULL OR (at.dayOfWeek IN g.days AND g.from <= clock < g.until) }
         OR EXISTS { (p)-[:MANAGES]->(:Team)<-[:PART_OF*0..]-(:Team)-[g:MAY_ENTER]->(z)
                     WHERE g.days IS NULL OR (at.dayOfWeek IN g.days AND g.from <= clock < g.until) }
         OR EXISTS { (p)-[:MAY_ENTER]->(r) } AS granted,
         EXISTS { (p)-[:DENIED]->(z) } AS banned,
         EXISTS { (r)-[:REQUIRES]->(c:Certification)
                  WHERE NOT EXISTS { (p)-[held:CERTIFIED]->(c) WHERE held.expires >= today } } AS untrained,
         z.closes_at IS NOT NULL AND clock >= z.closes_at AS closed,
         r.max_occupancy IS NOT NULL
         AND size([(other:Person)-[:IS_IN]->(r) WHERE other <> p | other]) >= r.max_occupancy AS full
    WITH b, d, p, r, at, badge_ok AND granted AND NOT banned AND NOT untrained AND NOT closed AND NOT full AS opens
    CREATE (s:Swipe {at: at, direction: 'in', granted: opens}), (s)-[:BY]->(b), (s)-[:AT]->(d)
    WITH p, r, at, opens WHERE opens
    OPTIONAL MATCH (p)-[previous:IS_IN]->()
    DELETE previous
    CREATE (p)-[:IS_IN {since: at}]->(r)
    RETURN r.name
"""
```

The writes read as a pipeline: create the swipe (every row has one); keep going only if the door
opens (`WITH … WHERE opens`); delete the person's previous position, if they had one (`DELETE` of
a `null` does nothing); record the new one. A refused swipe leaves the query with no rows — that is
how the controller learns the answer.

## Leaving

Leaving a room is simpler: the door always lets people out. The swipe is logged and the position
removed:

```python
LEAVE = """
    MATCH (b:Badge {number: $badge})-[:ISSUED_TO]->(p:Person), (d:Door {id: $door})-[:LEADS_TO]->(r:Room)
    CREATE (s:Swipe {at: $at, direction: 'out', granted: true}), (s)-[:BY]->(b), (s)-[:AT]->(d)
    WITH p, r
    OPTIONAL MATCH (p)-[here:IS_IN]->(r)
    DELETE here
"""

class DoorController:
    def __init__(self, db):
        self.db = db

    def enter(self, badge, door, at):
        return bool(self.db.query(ENTER, badge=badge, door=door, at=at))

    def leave(self, badge, door, at):
        self.db.query(LEAVE, badge=badge, door=door, at=at)

doors = DoorController(db)
```

## A Tuesday

The night is over and nobody is inside. Through the morning, the readers report these swipes:

```python
db.query("MATCH ()-[i:IS_IN]->() DELETE i")
tuesday = lambda hour, minute: datetime.datetime(2025, 3, 11, hour, minute, tzinfo=MADRID)

def swipe(time, badge, door):
    who = holder(badge) or f"badge {badge}"
    result = "open" if doors.enter(badge, door, time) else "REFUSED"
    print(f"{time:%H:%M} {who:<16} {door:<20} {result}")

swipe(tuesday(8, 5), 70006, "D-Vivarium Control")
swipe(tuesday(8, 20), 70004, "D-BSL-3 Lab")
swipe(tuesday(8, 25), 70008, "D-BSL-3 Lab")
swipe(tuesday(8, 40), 70009, "D-BSL-3 Lab")      # Kemi is not BSL-3 certified
db.query("MATCH (r:Room {name: 'BSL-3 Lab'}) SET r.max_occupancy = 2")   # a cabinet is being serviced
swipe(tuesday(9, 0), 70001, "D-BSL-3 Lab")       # Ada: the lab is at its (lowered) limit
db.query("MATCH (r:Room {name: 'BSL-3 Lab'}) SET r.max_occupancy = 4")   # service done
swipe(tuesday(9, 30), 70001, "D-BSL-3 Lab")
swipe(tuesday(9, 35), 90001, "D-Lobby")
swipe(tuesday(9, 40), 70007, "D-Airlock")        # Gustavo is barred from the suite
swipe(tuesday(9, 45), 70013, "D-Sequencing Lab")
```

```text
08:05 Fatima Rossi     D-Vivarium Control   open
08:20 Dalia Haddad     D-BSL-3 Lab          open
08:25 Joon Park        D-BSL-3 Lab          open
08:40 Kemi Adeyemi     D-BSL-3 Lab          REFUSED
09:00 Ada Okafor       D-BSL-3 Lab          REFUSED
09:30 Ada Okafor       D-BSL-3 Lab          open
09:35 Ines Moreau      D-Lobby              open
09:40 Gustavo Pérez    D-Airlock            REFUSED
09:45 Chen Wei         D-Sequencing Lab     open
```

The capacity rule is just another condition of the decision, and changing a room's limit is one
`SET`: no code was touched to close the lab to a third person during the service.

## Where is everyone?

The positions are always current, so the occupancy board is the query of [step 10](10-optional):

```python
for room, people in db.query("""
    MATCH (p:Person)-[i:IS_IN]->(r:Room)
    RETURN r.name, collect(p.name) ORDER BY r.name
"""):
    print(f"{room:<17} {', '.join(sorted(people))}")
```

```text
BSL-3 Lab         Ada Okafor, Dalia Haddad, Joon Park
Lobby             Ines Moreau
Sequencing Lab    Chen Wei
Vivarium Control  Fatima Rossi
```

Late morning, Joon and Ada come out of the BSL-3 lab, and Ada goes to meet the inspector:

```python
doors.leave(70008, "D-BSL-3 Lab", tuesday(11, 50))
doors.leave(70001, "D-BSL-3 Lab", tuesday(11, 55))
swipe(tuesday(12, 0), 70001, "D-Lobby")
print(db.query("MATCH (p:Person)-[:IS_IN]->(:Room {name: 'BSL-3 Lab'}) RETURN p.name"))
```

```text
12:00 Ada Okafor       D-Lobby              open
[['Dalia Haddad']]
```

Dalia is now alone in the BSL-3 lab — which the lab's rules forbid. Nothing in the controller
stops it (the door lets people out), so something must notice: [the monitor](19-monitoring).

## The log

Every swipe is in the log, refused ones included. The day's refusals, for the security office:

```python
for at, name, door in db.query("""
    MATCH (s:Swipe {granted: false})-[:BY]->(:Badge)-[:ISSUED_TO]->(p:Person), (s)-[:AT]->(d:Door)
    WHERE date(s.at) = date('2025-03-11')
    RETURN s.at, p.name, d.id ORDER BY s.at
"""):
    print(f"{at:%H:%M} {name:<14} {door}")
```

```text
08:40 Kemi Adeyemi   D-BSL-3 Lab
09:00 Ada Okafor     D-BSL-3 Lab
09:40 Gustavo Pérez  D-Airlock
```
