# 7. Reports: counting and grouping

Lab management wants numbers: headcount per team, how many rooms of each containment level, the
total working hours of each team. These are **aggregations**: they fold many rows into one.

## Counting and grouping

An aggregate in `RETURN` — `count`, `sum`, `avg`, `min`, `max`, `collect` — folds rows together.
Every other item of the `RETURN` is a **grouping key**: one result row per distinct value.

```python
for team, people in db.query("""
    MATCH (p:Person)-[:MEMBER_OF]->(t:Team)
    RETURN t.name, count(p) ORDER BY t.name
"""):
    print(f"{team:<12} {people}")
```

```text
Animal Care  1
Biosafety    1
Genomics     1
Research     1
Sequencing   2
Virology     1
```

No grouping key means one row for everything; `count(*)` counts rows, whatever they hold:

```python
print(db.query("MATCH (r:Room) RETURN count(*), min(r.bsl), max(r.bsl), avg(r.bsl)"))
```

```text
[[8, 1, 3, 1.75]]
```

`avg` is always a float. Aggregates skip `null`s: `count(p.employee_id)` counts only the people
who have one.

## Collecting

`collect` gathers values into a list — rooms per zone, with the zone's highest containment level:

```python
for zone, rooms, highest in db.query("""
    MATCH (r:Room)-[:IN]->(z:Zone)
    RETURN z.name, collect(r.name), max(r.bsl) AS highest
    ORDER BY highest DESC, z.name
"""):
    print(f"{zone:<18} BSL-{highest}  {sorted(rooms)}")
```

```text
Containment Suite  BSL-3  ['Airlock', 'BSL-3 Lab']
Genomics Floor     BSL-2  ['Genomics Office', 'Sequencing Lab']
Vivarium           BSL-2  ['Animal Holding', 'Vivarium Control']
Common Areas       BSL-1  ['Lobby', 'Seminar Room']
```

`collect` keeps the order the rows came in, which is not defined: sort the list if order matters.

## Distinct values

`DISTINCT` inside an aggregate counts or collects each value once. How many employees are there,
in how many different roles, and on which working fractions?

```python
print(db.query("""
    MATCH (p:Employee)
    RETURN count(p) AS employees, count(DISTINCT p.role) AS roles, collect(DISTINCT p.fte) AS ftes
"""))
```

```text
[[7, 6, [1.0, 0.8]]]
```

## Sums and expressions

Aggregates can sit inside expressions. Weekly hours per team, and each team's share of the total:

```python
for team, hours in db.query("""
    MATCH (p:Employee)-[:MEMBER_OF]->(t:Team)
    RETURN t.name, sum(p.fte) * 40 AS hours ORDER BY hours DESC, t.name
"""):
    print(f"{team:<12} {hours:5.1f}")
```

```text
Sequencing    80.0
Animal Care   40.0
Biosafety     40.0
Genomics      40.0
Research      40.0
Virology      32.0
```

`ORDER BY` can sort by an aggregate. In an expression around an aggregate, the rest may use only
grouping keys and constants: `RETURN t.name, sum(p.fte) * p.fte` is an error, because `p` is not
a grouping key. And every item without an aggregate *is* a grouping key: `RETURN t.name, p.name,
count(*)` groups by both names, which is rarely what you want.

## A report in one query

Per team: its size, its average tenure in years and its members, largest teams first:

```python
for team, size, tenure, members in db.query("""
    MATCH (p:Employee)-[:MEMBER_OF]->(t:Team)
    RETURN t.name, count(p) AS size, avg(2025 - p.hired.year) AS tenure, collect(p.name) AS members
    ORDER BY size DESC, t.name LIMIT 3
"""):
    print(f"{team:<11} {size}  {tenure:4.1f} years  {', '.join(sorted(members))}")
```

```text
Sequencing  2   3.0 years  Chen Wei, Emeka Nwosu
Animal Care 1   5.0 years  Fatima Rossi
Biosafety   1   6.0 years  Ada Okafor
```

Reports read the data; the lab also has to change it — people join, badges are lost, rooms are
refitted. [Next](08-updating): updating the graph.
