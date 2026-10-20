# 6. The staff directory: shaping results

The front desk wants a staff directory: names and roles, sorted, a page at a time, with a column
saying who is staff and who is from outside. Everything about the *shape* of a result is said in
`RETURN`.

## Expressions and aliases

`RETURN` takes any expression, not just properties, and `AS` names a column:

```python
print(db.query("""
    MATCH (p:Employee)
    RETURN p.name AS name, 2025 - p.hired.year AS years, p.fte * 40 AS hours_a_week
    ORDER BY years DESC LIMIT 3
"""))
```

```text
[['Gustavo Pérez', 10, 40.0], ['Bruno Lindqvist', 8, 40.0], ['Ada Okafor', 6, 40.0]]
```

`p.hired.year` reads the year of a date ([step 14](14-time) has the rest). An alias can be used in
`ORDER BY`. Note `40.0`: a float times an integer is a float.

## Sorting and pages

`ORDER BY` sorts by one or more expressions, each ascending (the default, `ASC`) or descending
(`DESC`). `SKIP` and `LIMIT` cut the sorted rows into pages:

```python
def directory(page, size=4):
    return db.query(
        "MATCH (p:Person) RETURN p.name, p.role ORDER BY p.name SKIP $skip LIMIT $size",
        skip=page * size, size=size,
    )

for page in range(3):
    print(page, directory(page))
```

```text
0 [['Ada Okafor', 'Biosafety officer'], ['Bruno Lindqvist', 'Lab manager'], ['Chen Wei', 'Research scientist'], ['Dalia Haddad', 'Research scientist']]
1 [['Emeka Nwosu', 'Lab technician'], ['Fatima Rossi', 'Animal care technician'], ['Gustavo Pérez', 'Head of Research'], ['Hiro Tanaka', 'HVAC technician']]
2 [['Ines Moreau', None]]
```

Without `ORDER BY`, rows come in no defined order: always sort what you page through.

## Conditional values: CASE

The directory's "kind" column depends on the labels. `CASE` picks a value by condition:

```python
for name, kind in db.query("""
    MATCH (p:Person)
    RETURN p.name,
           CASE WHEN 'Employee' IN labels(p) THEN 'staff'
                WHEN 'Contractor' IN labels(p) THEN 'contractor: ' + p.company
                ELSE 'visitor' END
    ORDER BY p.name SKIP 6
"""):
    print(f"{name:<14} {kind}")
```

```text
Gustavo Pérez  staff
Hiro Tanaka    contractor: CleanAir Services
Ines Moreau    visitor
```

`+` joins strings. A *simple* `CASE` compares one value with several:

```python
print(db.query("""
    MATCH (r:Room)
    RETURN r.name, CASE r.bsl WHEN 3 THEN 'restricted' WHEN 2 THEN 'controlled' ELSE 'open' END AS access
    ORDER BY r.bsl DESC, r.name LIMIT 4
"""))
```

```text
[['Airlock', 'restricted'], ['BSL-3 Lab', 'restricted'], ['Animal Holding', 'controlled'], ['Sequencing Lab', 'controlled']]
```

## Unique rows: DISTINCT

Which roles are there among the members of the Research teams? Several people share a role;
`DISTINCT` keeps one of each row:

```python
print(db.query("MATCH (p:Person)-[:MEMBER_OF]->(:Team) RETURN DISTINCT p.role ORDER BY p.role"))
```

```text
[['Animal care technician'], ['Biosafety officer'], ['Head of Research'], ['Lab manager'], ['Lab technician'], ['Research scientist']]
```

## Maps and lists as values

A column can be a map — a Python `dict` — or a list, which is handy for handing results straight
to something else (a template, an API response):

```python
(card,), = db.query("""
    MATCH (b:Badge)-[:ISSUED_TO]->(p:Person {name: 'Chen Wei'})-[:MEMBER_OF]->(t:Team)
    RETURN {name: p.name, badge: b.number, team: t.name, since: p.hired}
""")
print(card)
```

```text
{'badge': 70003, 'name': 'Chen Wei', 'since': datetime.date(2021, 1, 11), 'team': 'Sequencing'}
```

Map keys come back sorted by name. Whole nodes and relationships ([step 2](02-nodes), [step
3](03-relationships)) are values too, and so are paths, which [step 11](11-hierarchies)
introduces.

A directory lists rows; reports summarise them. [Next](07-aggregating): counting, summing and
grouping.
