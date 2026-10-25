# 14. Time: windows, expiry and how long

Access in a lab is about *when* as much as *where*: Genomics works on weekdays from 7:00 to
20:00; the Containment Suite closes at 18:00 and must be empty after it; certificates and
visitor badges expire; and how long someone has been inside a sealed room matters. This step
brings the clock in.

## Temporal values

Cypher has six temporal types, and Python's `datetime` module has a counterpart for each:

| Cypher | Built with | In Python |
| --- | --- | --- |
| date | `date('2025-03-10')` | `datetime.date` |
| local time | `localtime('09:30')` | `datetime.time` |
| time (with offset) | `time('09:30+01:00')` | `datetime.time` with `tzinfo` |
| local date-time | `localdatetime('2025-03-10T09:30')` | `datetime.datetime` |
| date-time (with zone) | `datetime('2025-03-10T09:30[Europe/Madrid]')` | `datetime.datetime` with `ZoneInfo` |
| duration | `duration('PT8H30M')` | `datetime.timedelta` |

Each can also be built from a map (`date({year: 2025, month: 3, day: 10})`), and has
components: `d.year`, `t.hour`, `dt.dayOfWeek` (1 = Monday … 7 = Sunday), `dt.timezone`, and so
on. Python values go in as parameters and come back as the same types:

```python
from zoneinfo import ZoneInfo

MADRID = ZoneInfo("Europe/Madrid")
monday_morning = datetime.datetime(2025, 3, 10, 9, 30, tzinfo=MADRID)

print(db.query("""
    RETURN $now.dayOfWeek, $now.hour, $now.timezone, localtime($now), $now + duration('PT8H')
""", now=monday_morning))
```

```text
[[1, 9, 'Europe/Madrid', datetime.time(9, 30), datetime.datetime(2025, 3, 10, 17, 30, tzinfo=zoneinfo.ZoneInfo(key='Europe/Madrid'))]]
```

`localtime($now)` takes the wall-clock time out of a date-time; adding a duration moves it.

The lab keeps all its rules in Madrid time. A date-time with a named zone is the safe way to
carry "now" around: it knows its own offset, and daylight saving time is handled for you.

## Time windows

Each team grant gets the days and hours it applies — properties on the `MAY_ENTER`
relationships. Animal care is a 7-day job; the others are weekday jobs:

```python
db.query("""
    MATCH (:Team {name: 'Genomics'})-[g:MAY_ENTER]->()
    SET g.days = [1, 2, 3, 4, 5], g.from = localtime('07:00'), g.until = localtime('20:00')
""")
db.query("""
    MATCH (:Team {name: 'Virology'})-[g:MAY_ENTER]->()
    SET g.days = [1, 2, 3, 4, 5], g.from = localtime('08:00'), g.until = localtime('18:00')
""")
db.query("""
    MATCH (:Team {name: 'Animal Care'})-[g:MAY_ENTER]->()
    SET g.days = [1, 2, 3, 4, 5, 6, 7], g.from = localtime('06:00'), g.until = localtime('22:00')
""")
```

Biosafety's grants have no window: the biosafety officer may be called in at any hour.

Zones also close. After closing time nobody may go in, whatever their grant, and the zone must be
empty (which [step 19](19-monitoring) watches):

```python
db.query("MATCH (z:Zone {name: 'Containment Suite'}) SET z.closes_at = localtime('18:00')")
db.query("MATCH (z:Zone {name: 'Genomics Floor'}) SET z.closes_at = localtime('22:00')")
```

## The decision, with the clock

The grant rules now ask whether the grant's window covers the moment of the swipe, and a new
obstacle — *closed* — joins *banned* and *untrained*. The query computes the local time once, in a
`WITH`, and every rule uses it:

```python
DECISION = """
    WITH datetime({datetime: $at, timezone: 'Europe/Madrid'}) AS at
    WITH at, localtime(at) AS clock, date(at) AS today
    MATCH (b:Badge {number: $badge, active: true})-[:ISSUED_TO]->(p:Person),
          (:Door {id: $door})-[:LEADS_TO]->(r:Room)-[:IN]->(z:Zone)
    WHERE b.valid_until IS NULL OR b.valid_until >= today
    WITH p, r, z, at, clock, today,
         z.public = true
         OR EXISTS { (p)-[:MEMBER_OF]->(:Team)-[:PART_OF*0..]->(:Team)-[g:MAY_ENTER]->(z)
                     WHERE g.days IS NULL OR (at.dayOfWeek IN g.days AND g.from <= clock < g.until) }
         OR EXISTS { (p)-[:MANAGES]->(:Team)<-[:PART_OF*0..]-(:Team)-[g:MAY_ENTER]->(z)
                     WHERE g.days IS NULL OR (at.dayOfWeek IN g.days AND g.from <= clock < g.until) }
         OR EXISTS { (p)-[:MAY_ENTER]->(r) } AS granted,
         EXISTS { (p)-[:DENIED]->(z) } AS banned,
         EXISTS { (r)-[:REQUIRES]->(c:Certification)
                  WHERE NOT EXISTS { (p)-[held:CERTIFIED]->(c) WHERE held.expires >= today } } AS untrained,
         z.closes_at IS NOT NULL AND clock >= z.closes_at AS closed
    RETURN granted AND NOT banned AND NOT untrained AND NOT closed
"""

def may_enter(badge, door, at):
    rows = db.query(DECISION, badge=badge, door=door, at=at)
    return bool(rows) and rows[0][0]

saturday_night = datetime.datetime(2025, 3, 15, 23, 0, tzinfo=MADRID)
monday_evening = datetime.datetime(2025, 3, 10, 18, 30, tzinfo=MADRID)
for badge, door, at in [
    (70013, "D-Sequencing Lab", monday_morning),   # Chen, a weekday morning
    (70013, "D-Sequencing Lab", saturday_night),   # Chen, outside the window
    (70004, "D-BSL-3 Lab", monday_evening),        # Dalia, after the suite closed
    (70006, "D-Animal Holding", saturday_night),   # Fatima: animal care, 7 days... until 22:00
    (70001, "D-BSL-3 Lab", saturday_night),        # Ada: no window, but the suite is closed
    (70001, "D-Animal Holding", saturday_night),   # Ada: no window, the vivarium never closes
]:
    print(badge, f"{door:<17}", f"{at:%a %H:%M}", "open" if may_enter(badge, door, at) else "DENIED")
```

```text
70013 D-Sequencing Lab  Mon 09:30 open
70013 D-Sequencing Lab  Sat 23:00 DENIED
70004 D-BSL-3 Lab       Mon 18:30 DENIED
70006 D-Animal Holding  Sat 23:00 DENIED
70001 D-BSL-3 Lab       Sat 23:00 DENIED
70001 D-Animal Holding  Sat 23:00 DENIED
```

The last line is a surprise: Ada has a grant to the Vivarium with no window, and the Vivarium
never closes — yet the door refuses Ada. The reason is a rule from the last step: Animal Holding
requires an animal-handling certificate, and Ada has none. The rules compose, and the query
explains itself if you ask it the parts (`RETURN granted, banned, untrained, closed`).

## How long: durations

Since this morning the positions have had no times. Each `IS_IN` gets the moment the person
entered:

```python
db.query("MATCH (:Person)-[i:IS_IN]->() SET i.since = $at", at=datetime.datetime(2025, 3, 10, 8, 45, tzinfo=MADRID))
db.query("""
    MATCH (:Person {name: 'Joon Park'})-[i:IS_IN]->()
    SET i.since = datetime('2025-03-10T09:10[Europe/Madrid]')
""")
```

`duration.between(a, b)` is the duration from one moment to another; `.minutes` and friends read
it in a unit:

```python
for name, room, minutes in db.query("""
    MATCH (p:Person)-[i:IS_IN]->(r:Room {name: 'BSL-3 Lab'})
    RETURN p.name, r.name, duration.between(i.since, $now).minutes
    ORDER BY p.name
""", now=monday_morning):
    print(f"{name} has been in the {room} for {minutes} minutes")
```

```text
Dalia Haddad has been in the BSL-3 Lab for 45 minutes
Joon Park has been in the BSL-3 Lab for 20 minutes
```

## Expiry dates

Dates and durations add up, so "expires within the next 90 days" is arithmetic. The certificates
due for renewal:

```python
print(db.query("""
    MATCH (p:Person)-[held:CERTIFIED]->(c:Certification)
    WHERE $today <= held.expires < $today + duration('P90D')
    RETURN p.name, c.name, held.expires, duration.inDays($today, held.expires).days AS days_left
    ORDER BY days_left
""", today=datetime.date(2025, 11, 15)))
```

```text
[['Ada Okafor', 'BSL-3', datetime.date(2026, 1, 31), 77]]
```

`duration.inDays` counts whole days; `duration.inMonths` and `duration.inSeconds` count in their
units. Durations with months behave like calendars do: `date('2025-01-31') + duration('P1M')` is
the 28th of February.

The lab's data is all in place: people, rooms, rules, the clock. [Next](15-loading), volume — a
month of door events, loaded fast.
