# 8. Changing the lab: SET, REMOVE, DELETE, MERGE

Nothing in a lab stays put. Badges are lost, people get trained, contractors finish their jobs.
This step covers every way of changing the graph.

## Setting properties: SET

Chen has lost their badge. The old one must stop working at once, and Chen gets a new one:

```python
db.query("MATCH (b:Badge {number: 70003}) SET b.active = false, b.lost_on = $today", today=datetime.date(2025, 3, 3))
db.query("""
    MATCH (p:Person {name: 'Chen Wei'})
    CREATE (:Badge {number: 70013, active: true})-[:ISSUED_TO]->(p)
""")
print(holder(70003), holder(70013))
```

```text
None Chen Wei
```

The reader's query from [step 5](05-parameters) only accepts `active: true` badges, so the lost
one is refused without deleting anything: the record of what that badge did stays.

`SET` takes several assignments, separated by commas. Two forms work on a whole set of
properties at once: `SET n += {…}` adds or changes the properties in the map and leaves the
others; `SET n = {…}` replaces all of them.

```python
db.query("MATCH (r:Room {name: 'BSL-3 Lab'}) SET r += {min_occupancy: 2, max_occupancy: 4}")
db.query("MATCH (r:Room {name: 'Vivarium Control'}) SET r.staffed = true")
print(db.query("""
    MATCH (r:Room) WHERE r.min_occupancy IS NOT NULL OR r.staffed
    RETURN r.name, r.min_occupancy, r.max_occupancy, r.staffed ORDER BY r.name
"""))
```

```text
[['BSL-3 Lab', 2, 4, None], ['Vivarium Control', None, None, True]]
```

These are three of the lab's hard rules, now data: nobody works alone in the BSL-3 lab — when it
is in use, at least two people are in it — and never more than four at once; and the vivarium's
control room is *staffed*: it must never be empty, for the animals' sake. [Step
19](19-monitoring) checks them.

## Labels: SET and REMOVE

`SET n:Label` adds a label (as in [step 2](02-nodes)); `REMOVE n:Label` takes it away, and
`REMOVE n.property` removes a property. The BSL-3 lab is the lab's one high-containment room;
tagging it makes it easy to find:

```python
db.query("MATCH (r:Room) WHERE r.bsl = 3 AND r.name <> 'Airlock' SET r:HighContainment")
print(db.query("MATCH (r:HighContainment) RETURN r.name"))
db.query("MATCH (b:Badge {number: 70003}) REMOVE b.lost_on")
print(db.query("MATCH (b:Badge {number: 70003}) RETURN keys(b)"))
```

```text
[['BSL-3 Lab']]
[[['active', 'number']]]
```

Setting a property to `null` removes it too: `SET b.lost_on = null`.

## Create if missing: MERGE

Training certificates are shared things: there is *one* BSL-3 certification, which many people
hold. Creating it twice would be a mistake, and code that runs again should not do it. `MERGE`
matches a pattern, and creates it only if it is not there:

```python
for name in ["BSL-3", "BSL-3", "Animal handling"]:
    db.query("MERGE (:Certification {name: $name})", name=name)
print(db.query("MATCH (c:Certification) RETURN c.name ORDER BY c.name"))
```

```text
[['Animal handling'], ['BSL-3']]
```

`MERGE` on a relationship links two existing nodes once. `ON CREATE SET` and `ON MATCH SET` say
what to do in each case — here, a certificate granted for the first time, or renewed:

```python
def certify(person, certification, expires):
    db.query("""
        MATCH (p:Person {name: $person}), (c:Certification {name: $certification})
        MERGE (p)-[held:CERTIFIED]->(c)
        ON CREATE SET held.expires = $expires, held.renewals = 0
        ON MATCH SET held.expires = $expires, held.renewals = held.renewals + 1
    """, person=person, certification=certification, expires=expires)

certify("Ada Okafor", "BSL-3", datetime.date(2026, 1, 31))
certify("Dalia Haddad", "BSL-3", datetime.date(2025, 6, 30))
certify("Dalia Haddad", "BSL-3", datetime.date(2026, 6, 30))   # renewed
certify("Chen Wei", "BSL-3", datetime.date(2024, 11, 30))     # lapsed last year
certify("Fatima Rossi", "Animal handling", datetime.date(2026, 9, 1))
print(db.query("""
    MATCH (p:Person)-[held:CERTIFIED]->(c:Certification)
    RETURN p.name, c.name, held.expires, held.renewals ORDER BY p.name
"""))
```

```text
[['Ada Okafor', 'BSL-3', datetime.date(2026, 1, 31), 0], ['Chen Wei', 'BSL-3', datetime.date(2024, 11, 30), 0], ['Dalia Haddad', 'BSL-3', datetime.date(2026, 6, 30), 1], ['Fatima Rossi', 'Animal handling', datetime.date(2026, 9, 1), 0]]
```

The rooms say which certificates they demand — again, data rather than code:

```python
db.query("""
    MATCH (r:Room {name: 'BSL-3 Lab'}), (c:Certification {name: 'BSL-3'})
    CREATE (r)-[:REQUIRES]->(c)
""")
db.query("""
    MATCH (r:Room {name: 'Animal Holding'}), (c:Certification {name: 'Animal handling'})
    CREATE (r)-[:REQUIRES]->(c)
""")
```

## Deleting: DELETE and DETACH DELETE

A courier came in for the morning; their visit is over. `DELETE` removes nodes and relationships;
a node that still has relationships must lose them first, or be removed with `DETACH DELETE`,
which takes its relationships with it:

```python
db.query("""
    CREATE (:Badge {number: 90002, active: true})-[:ISSUED_TO]->(:Person:Visitor {name: 'Courier'})
""")
db.query("MATCH (b:Badge)-[:ISSUED_TO]->(p:Person {name: 'Courier'}) DETACH DELETE b, p")
print(db.query("MATCH (p:Person) RETURN count(p)"), db.query("MATCH (b:Badge {number: 90002}) RETURN b"))
```

```text
[[9]] []
```

Deleting a node that is still connected is an error — a guard against leaving relationships that
point nowhere:

```python
from acmedb import NodeStillConnectedError

try:
    db.query("MATCH (t:Team {name: 'Virology'}) DELETE t")
except NodeStillConnectedError as error:
    print("refused:", error)
```

```text
refused: node 't' still has relationships (use DETACH DELETE) (code 6)
```

Every write so far has been one query. [Next](09-pipelines), a query that does several things in
a row — onboarding a whole group of new hires at once.
