# 12. May this badge open this door? EXISTS

Every swipe asks one question: *may this person enter this room, now?* The answer is a
combination of rules, each about whether some pattern exists in the graph: a permission through
a team, a manager's reach, a personal exception, the right training, no ban. This step writes those
rules as data and the decision as one query.

## The access rules, as relationships

Teams are granted zones. Members of a team inherit its parent team's grants (Sequencing works on
the Genomics Floor because Genomics does), and Biosafety goes everywhere:

```python
db.query("""
    MATCH (genomics:Team {name: 'Genomics'}), (virology:Team {name: 'Virology'}),
          (animals:Team {name: 'Animal Care'}), (biosafety:Team {name: 'Biosafety'}),
          (floor:Zone {name: 'Genomics Floor'}), (suite:Zone {name: 'Containment Suite'}),
          (vivarium:Zone {name: 'Vivarium'})
    CREATE (genomics)-[:MAY_ENTER]->(floor),
           (virology)-[:MAY_ENTER]->(suite),
           (animals)-[:MAY_ENTER]->(vivarium),
           (biosafety)-[:MAY_ENTER]->(floor), (biosafety)-[:MAY_ENTER]->(suite),
           (biosafety)-[:MAY_ENTER]->(vivarium)
""")
db.query("MATCH (z:Zone {name: 'Common Areas'}) SET z.public = true")
```

The HVAC contractor may enter one room, the Genomics Office, where the ventilation units are; and
Gustavo, who as head of Research would reach the Containment Suite, is barred from it until he
completes this year's medical check — a ban overrides any permission:

```python
db.query("""
    MATCH (hiro:Person {name: 'Hiro Tanaka'}), (office:Room {name: 'Genomics Office'}),
          (gustavo:Person {name: 'Gustavo Pérez'}), (suite:Zone {name: 'Containment Suite'})
    CREATE (hiro)-[:MAY_ENTER]->(office),
           (gustavo)-[:DENIED {reason: 'annual medical check pending'}]->(suite)
""")
```

## A pattern as a condition: EXISTS

`EXISTS { pattern }` is true when the pattern has at least one match, starting from the variables
already bound. Does Chen's team, or a team above it, have a grant to the Genomics Floor?

```python
print(db.query("""
    MATCH (p:Person {name: 'Chen Wei'}), (z:Zone {name: 'Genomics Floor'})
    RETURN EXISTS { (p)-[:MEMBER_OF]->(:Team)-[:PART_OF*0..]->(:Team)-[:MAY_ENTER]->(z) }
"""))
```

```text
[[True]]
```

The pattern inside can name new variables and filter them with its own `WHERE`. The shorter form
used in [step 10](10-optional), a bare pattern in a `WHERE` — `WHERE (p)-[:IS_IN]->()` — asks
the same, but may only use variables that are already bound.

## The decision, rule by rule

The door's question in full. The badge must be active and in date; then the person is let in
when **any** grant applies and **none** of the obstacles do:

```python
DECISION = """
    MATCH (b:Badge {number: $badge, active: true})-[:ISSUED_TO]->(p:Person),
          (:Door {id: $door})-[:LEADS_TO]->(r:Room)-[:IN]->(z:Zone)
    WHERE b.valid_until IS NULL OR b.valid_until >= $today
    WITH p, r, z,
         z.public = true
         OR EXISTS { (p)-[:MEMBER_OF]->(:Team)-[:PART_OF*0..]->(:Team)-[:MAY_ENTER]->(z) }
         OR EXISTS { (p)-[:MANAGES]->(:Team)<-[:PART_OF*0..]-(:Team)-[:MAY_ENTER]->(z) }
         OR EXISTS { (p)-[:MAY_ENTER]->(r) } AS granted,
         EXISTS { (p)-[:DENIED]->(z) } AS banned,
         EXISTS { (r)-[:REQUIRES]->(c:Certification)
                  WHERE NOT EXISTS { (p)-[held:CERTIFIED]->(c) WHERE held.expires >= $today } } AS untrained
    RETURN granted AND NOT banned AND NOT untrained
"""

def may_enter(badge, door, today=datetime.date(2025, 3, 10)):
    rows = db.query(DECISION, badge=badge, door=door, today=today)
    return bool(rows) and rows[0][0]
```

Reading the parts:

- **granted** — the zone is public, or a team of theirs (or one above it) has a grant, or they
  manage a team (or one above a granted one) with a grant, or they have a personal grant to the
  room;
- **banned** — a `DENIED` relationship to the zone;
- **untrained** — the room requires some certification for which the person holds no certificate
  valid today. Two `EXISTS` nest: *there is a requirement for which there is no valid
  certificate*.

An unknown or inactive badge matches nothing, so `rows` is empty and the answer is no. Now the
doors:

```python
cases = [
    (70013, "D-Sequencing Lab"),   # Chen: Sequencing, inherits Genomics' grant
    (70013, "D-BSL-3 Lab"),        # Chen: no grant to the suite (and his certificate lapsed)
    (70004, "D-BSL-3 Lab"),        # Dalia: Virology's grant, valid BSL-3 certificate
    (70008, "D-BSL-3 Lab"),        # Joon: Virology, but not certified yet
    (70002, "D-Sequencing Lab"),   # Bruno: manages Genomics
    (70007, "D-Sequencing Lab"),   # Gustavo: manages Research, above Genomics
    (70007, "D-Airlock"),          # Gustavo: banned from the Containment Suite
    (80001, "D-Genomics Office"),  # Hiro: personal grant
    (80001, "D-Sequencing Lab"),   # Hiro: nothing else
    (90001, "D-Lobby"),            # Ines: public zone
    (70003, "D-Lobby"),            # Chen's lost badge
]
for badge, door in cases:
    print(badge, f"{door:<18}", "open" if may_enter(badge, door) else "DENIED")
```

```text
70013 D-Sequencing Lab   open
70013 D-BSL-3 Lab        DENIED
70004 D-BSL-3 Lab        open
70008 D-BSL-3 Lab        DENIED
70002 D-Sequencing Lab   open
70007 D-Sequencing Lab   open
70007 D-Airlock          DENIED
80001 D-Genomics Office  open
80001 D-Sequencing Lab   DENIED
90001 D-Lobby            open
70003 D-Lobby            DENIED
```

Each rule is a few relationships in the graph, and changing who may go where is a write, not a
code change: grant Virology's newcomer a certificate and the BSL-3 door opens for him.

```python
certify("Joon Park", "BSL-3", datetime.date(2026, 3, 1))
print(may_enter(70008, "D-BSL-3 Lab"))
```

```text
True
```

## Lists from patterns

When a door refuses someone, the guard wants to know which rule did it. A **pattern
comprehension** collects something for every match of a pattern — here, the certificates a room
requires that the person lacks:

```python
print(db.query("""
    MATCH (p:Person {name: 'Chen Wei'}), (r:Room {name: 'BSL-3 Lab'})
    RETURN [(r)-[:REQUIRES]->(c) WHERE NOT EXISTS { (p)-[h:CERTIFIED]->(c) WHERE h.expires >= $today } | c.name]
""", today=datetime.date(2025, 3, 10)))
```

```text
[[['BSL-3']]]
```

The decision ignores time so far: Genomics may enter its floor at 3 a.m. on a Sunday. [Step
13](13-documents) adds structured data to the graph; [step 14](14-time) adds the clock.
