# 10. Who is where: OPTIONAL MATCH and missing data

The lab must know, at every moment, who is in which room. That is one relationship per person
present: `(:Person)-[:IS_IN]->(:Room)`. With it come the questions that are about *absence* —
which rooms are empty, who is not in the building — and those need a pattern that may match
nothing.

## The morning's positions

It is 9:30 on a Monday. The door readers have recorded who went where (we build that machinery in
[step 18](18-door-controller)); for now we set the positions directly:

```python
positions = {
    "Ada Okafor": "Lobby", "Ines Moreau": "Lobby",
    "Chen Wei": "Sequencing Lab", "Emeka Nwosu": "Sequencing Lab",
    "Dalia Haddad": "BSL-3 Lab", "Joon Park": "BSL-3 Lab",
    "Fatima Rossi": "Vivarium Control", "Lars Becker": "Animal Holding",
}
db.query("""
    UNWIND keys($positions) AS name
    MATCH (p:Person {name: name}), (r:Room {name: $positions[name]})
    CREATE (p)-[:IS_IN]->(r)
""", positions=positions)
```

`keys($positions)` lists the map's keys; `$positions[name]` looks one up.

## A pattern that may not match: OPTIONAL MATCH

Everyone, with the room they are in. With `MATCH`, the people who are not in the building would
simply be missing from the result. `OPTIONAL MATCH` keeps them, with `null` for what it could not
find — like an outer join in SQL:

```python
for name, room in db.query("""
    MATCH (p:Person)
    OPTIONAL MATCH (p)-[:IS_IN]->(r:Room)
    RETURN p.name, r.name ORDER BY p.name
"""):
    print(f"{name:<16} {room}")
```

```text
Ada Okafor       Lobby
Bruno Lindqvist  None
Chen Wei         Sequencing Lab
Dalia Haddad     BSL-3 Lab
Emeka Nwosu      Sequencing Lab
Fatima Rossi     Vivarium Control
Gustavo Pérez    None
Hiro Tanaka      None
Ines Moreau      Lobby
Joon Park        BSL-3 Lab
Kemi Adeyemi     None
Lars Becker      Animal Holding
```

## Occupancy, empty rooms included

The occupancy board shows every room, with the number of people in it. Counting an optional
match counts only what was found — `count` skips `null` — so empty rooms show 0:

```python
for room, people in db.query("""
    MATCH (r:Room)
    OPTIONAL MATCH (p:Person)-[:IS_IN]->(r)
    RETURN r.name, count(p) AS people ORDER BY people DESC, r.name
"""):
    print(f"{room:<17} {people}")
```

```text
BSL-3 Lab         2
Lobby             2
Sequencing Lab    2
Animal Holding    1
Vivarium Control  1
Airlock           0
Genomics Office   0
Seminar Room      0
```

`count(*)` here would count the rows, and an empty room still has one row (with `p` null): it
would say 1. When counting an optional match, count the variable.

## Missing values in expressions: coalesce

`coalesce` returns its first argument that is not `null` — a default for missing data:

```python
print(db.query("""
    MATCH (p:Person) WHERE p.employee_id IS NULL
    OPTIONAL MATCH (p)-[:IS_IN]->(r)
    RETURN p.name, coalesce(r.name, 'not on site'), coalesce(p.company, p.organisation)
    ORDER BY p.name
"""))
```

```text
[['Hiro Tanaka', 'not on site', 'CleanAir Services'], ['Ines Moreau', 'Lobby', 'EU Biosafety Agency']]
```

## Visitors and their escorts

A visitor may only be in the building with an employee who answers for them. Ada escorts the
inspector:

```python
db.query("""
    MATCH (v:Person {name: 'Ines Moreau'}), (e:Person {name: 'Ada Okafor'})
    CREATE (v)-[:ESCORTED_BY]->(e)
""")
print(db.query("""
    MATCH (v:Visitor)-[:IS_IN]->(r:Room)
    OPTIONAL MATCH (v)-[:ESCORTED_BY]->(e:Employee)-[:IS_IN]->(r)
    RETURN v.name, r.name, e.name
"""))
```

```text
[['Ines Moreau', 'Lobby', 'Ada Okafor']]
```

The optional part asks for an escort *in the same room* — `(r)` appears in both patterns, so it is
the same room. Had Ada gone elsewhere, `e.name` would be `null`: a visitor alone, which [step
19](19-monitoring) turns into an alarm.

## When OPTIONAL MATCH is not enough

`OPTIONAL MATCH` answers "what is there, if anything". To *filter* on absence — "the employees who
are not on site" — test for the pattern directly:

```python
print(db.query("MATCH (p:Employee) WHERE NOT (p)-[:IS_IN]->() RETURN p.name ORDER BY p.name"))
```

```text
[['Bruno Lindqvist'], ['Gustavo Pérez'], ['Kemi Adeyemi']]
```

A pattern in a `WHERE` is true when it has a match. Patterns as conditions are the subject of
[step 12](12-exists); first, [step 11](11-hierarchies) follows paths of any length.
