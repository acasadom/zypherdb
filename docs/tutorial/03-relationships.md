# 3. Teams and rooms: relationships

So far the graph is a list of people. What makes it a graph is **relationships**: a person *is a
member of* a team, a room *is in* a zone, a door *leads to* a room. This step builds the lab's
organisation and its floor plan, and queries across them.

## The floor plan

The North Wing has four zones, and each zone its rooms. A relationship is written as an arrow
between two nodes, `(a)-[:TYPE]->(b)`, with a type in capitals by convention. A single `CREATE`
can build a whole structure; the variables (`north`, `genomics`, …) tie its parts together:

```python
db.query("""
    MATCH (north:Building {name: 'North Wing'})
    CREATE (genomics:Zone {name: 'Genomics Floor'})-[:IN]->(north),
           (containment:Zone {name: 'Containment Suite'})-[:IN]->(north),
           (vivarium:Zone {name: 'Vivarium'})-[:IN]->(north),
           (common:Zone {name: 'Common Areas'})-[:IN]->(north),

           (:Room {name: 'Lobby', bsl: 1})-[:IN]->(common),
           (:Room {name: 'Seminar Room', bsl: 1})-[:IN]->(common),
           (:Room {name: 'Sequencing Lab', bsl: 2})-[:IN]->(genomics),
           (:Room {name: 'Genomics Office', bsl: 1})-[:IN]->(genomics),
           (:Room {name: 'Airlock', bsl: 3})-[:IN]->(containment),
           (:Room {name: 'BSL-3 Lab', bsl: 3})-[:IN]->(containment),
           (:Room {name: 'Animal Holding', bsl: 2})-[:IN]->(vivarium),
           (:Room {name: 'Vivarium Control', bsl: 1})-[:IN]->(vivarium)
""")
```

`MATCH` finds the existing building first; `CREATE` then adds the zones and rooms around it.
`bsl` is each room's **biosafety level**, from 1 (ordinary lab practice) to 3 (serious airborne
pathogens: sealed rooms, an airlock, trained staff only).

Each room has a door with a card reader. Rather than writing eight doors by hand, one query makes
a door for every room — `MATCH` finds each room, and `CREATE` runs once per room found:

```python
db.query("""
    MATCH (r:Room)
    CREATE (:Door {id: 'D-' + r.name})-[:LEADS_TO]->(r)
""")
print(db.query("MATCH (d:Door)-[:LEADS_TO]->(r:Room {name: 'Airlock'}) RETURN d.id"))
```

```text
[['D-Airlock']]
```

## The organisation

Teams form a hierarchy: Sequencing is part of Genomics, which is part of Research.

```python
db.query("""
    CREATE (research:Team {name: 'Research'}),
           (genomics:Team {name: 'Genomics'})-[:PART_OF]->(research),
           (:Team {name: 'Sequencing'})-[:PART_OF]->(genomics),
           (:Team {name: 'Virology'})-[:PART_OF]->(research),
           (:Team {name: 'Animal Care'}),
           (:Team {name: 'Biosafety'})
""")
```

People join teams. To connect two nodes that already exist, `MATCH` both, then `CREATE` the
relationship between them:

```python
def join(person, team):
    db.query(f"""
        MATCH (p:Person {{name: '{person}'}}), (t:Team {{name: '{team}'}})
        CREATE (p)-[:MEMBER_OF]->(t)
    """)

for person, team in [
    ("Ada Okafor", "Biosafety"),
    ("Bruno Lindqvist", "Genomics"),
    ("Chen Wei", "Sequencing"),
    ("Dalia Haddad", "Virology"),
    ("Emeka Nwosu", "Sequencing"),
    ("Fatima Rossi", "Animal Care"),
    ("Gustavo Pérez", "Research"),
]:
    join(person, team)
```

Building a query out of strings like this works for a tutorial, but it is the wrong habit: a name
with a quote in it breaks the query, and text from users could change what it does. [Step
5](05-parameters) replaces it with **parameters**.

## Patterns across relationships

A pattern can follow relationships. Who is in which team:

```python
for name, team in db.query("MATCH (p:Person)-[:MEMBER_OF]->(t:Team) RETURN p.name, t.name ORDER BY t.name, p.name"):
    print(f"{team:<12} {name}")
```

```text
Animal Care  Fatima Rossi
Biosafety    Ada Okafor
Genomics     Bruno Lindqvist
Research     Gustavo Pérez
Sequencing   Chen Wei
Sequencing   Emeka Nwosu
Virology     Dalia Haddad
```

Patterns chain. The rooms of the Containment Suite, and the doors into them:

```python
print(db.query("""
    MATCH (d:Door)-[:LEADS_TO]->(r:Room)-[:IN]->(:Zone {name: 'Containment Suite'})
    RETURN r.name, d.id ORDER BY r.name
"""))
```

```text
[['Airlock', 'D-Airlock'], ['BSL-3 Lab', 'D-BSL-3 Lab']]
```

A node in the middle of a pattern needs no variable when nothing reads it: `(:Zone {…})` only
constrains the path.

## Direction

Relationships have a direction, set when they are created: `(p)-[:MEMBER_OF]->(t)` points from
the person to the team. A pattern can follow it either way round, or ignore it:

```python
print(db.query("MATCH (t:Team {name: 'Sequencing'})<-[:MEMBER_OF]-(p) RETURN p.name ORDER BY p.name"))
print(db.query("MATCH (:Team {name: 'Genomics'})-[:PART_OF]-(other) RETURN other.name ORDER BY other.name"))
```

```text
[['Chen Wei'], ['Emeka Nwosu']]
[['Research'], ['Sequencing']]
```

`-[:PART_OF]-` without an arrowhead matches both directions: Genomics' parent and its child.

## Relationships as values

A relationship can have a variable too, and be returned whole, as a `zypherdb.Relationship` with
its own id, its endpoints (`source` and `target`, node ids), type and properties. The id tells
apart two relationships that share their endpoints and type:

```python
(edge,), = db.query("MATCH (:Person {name: 'Chen Wei'})-[m:MEMBER_OF]->() RETURN m")
print(edge.type, edge.properties)
print(db.query("MATCH (:Person {name: 'Chen Wei'})-[m]->(t) RETURN type(m), t.name"))
```

```text
MEMBER_OF {}
[['MEMBER_OF', 'Sequencing']]
```

`-[m]->` with no type matches a relationship of any type; `type(m)` says which it is.
Relationships can carry properties of their own, which [step 11](11-hierarchies) and [step
12](12-exists) put to work for access rules.

We now have people, teams and rooms, joined up. [Next](04-filtering), `WHERE`: asking for exactly
the nodes and paths you want.
