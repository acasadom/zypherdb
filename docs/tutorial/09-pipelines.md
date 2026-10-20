# 9. Onboarding a cohort: UNWIND and WITH

Three new people start on Monday. HR sends their details as a list; onboarding each one means
creating the person, putting them in their team and issuing a badge. One query can do it for the
whole list — and, along the way, introduce the two clauses that turn a query into a pipeline.

## One row per item: UNWIND

`UNWIND` turns a list into rows, one per element. With a list of dicts as a parameter, each row
holds one new hire:

```python
hires = [
    {"name": "Joon Park", "employee_id": 1008, "role": "Research scientist", "team": "Virology", "badge": 70008},
    {"name": "Kemi Adeyemi", "employee_id": 1009, "role": "Lab technician", "team": "Virology", "badge": 70009},
    {"name": "Lars Becker", "employee_id": 1010, "role": "Animal care technician", "team": "Animal Care", "badge": 70010},
]
db.query("""
    UNWIND $hires AS hire
    MATCH (t:Team {name: hire.team})
    CREATE (p:Person:Employee {name: hire.name, employee_id: hire.employee_id, role: hire.role,
                               hired: $start, fte: 1.0, on_call: false})-[:MEMBER_OF]->(t)
    CREATE (:Badge {number: hire.badge, active: true})-[:ISSUED_TO]->(p)
""", hires=hires, start=datetime.date(2025, 3, 10))
print(db.query("MATCH (p:Employee {hired: date('2025-03-10')})-[:MEMBER_OF]->(t) RETURN p.name, t.name ORDER BY p.name"))
```

```text
[['Joon Park', 'Virology'], ['Kemi Adeyemi', 'Virology'], ['Lars Becker', 'Animal Care']]
```

A query is a **pipeline of clauses**: each takes the rows the one before it produced and passes on
its own. Here `UNWIND` makes three rows (one per hire), `MATCH` extends each with its team, and
each `CREATE` runs once per row. `hire.team` reads a key of the map, as `p.name` reads a property.

The whole query is one transaction: if any part fails, none of the three is created. This is
also the fast way to load data — one query for many items, rather than one query each ([step
15](15-loading) returns to it).

`UNWIND` works on any list, including a list property:

```python
print(db.query("""
    MATCH (p:Employee) WHERE p.languages IS NOT NULL
    UNWIND p.languages AS language
    RETURN p.name, language
"""))
```

```text
[['Gustavo Pérez', 'es'], ['Gustavo Pérez', 'en'], ['Gustavo Pérez', 'pt']]
```

## Passing rows on: WITH

`WITH` is a `RETURN` in the middle of a query: it says which values go on to the next clauses,
and can aggregate, sort and filter. Which teams now have more than one member, and who are they?

```python
print(db.query("""
    MATCH (p:Person)-[:MEMBER_OF]->(t:Team)
    WITH t, count(p) AS members
    WHERE members > 1
    MATCH (t)<-[:MEMBER_OF]-(person)
    RETURN t.name, members, person.name ORDER BY t.name, person.name
"""))
```

```text
[['Animal Care', 2, 'Fatima Rossi'], ['Animal Care', 2, 'Lars Becker'], ['Sequencing', 2, 'Chen Wei'], ['Sequencing', 2, 'Emeka Nwosu'], ['Virology', 3, 'Dalia Haddad'], ['Virology', 3, 'Joon Park'], ['Virology', 3, 'Kemi Adeyemi']]
```

Read it in stages: match every membership; group by team, counting (the aggregation happens in
`WITH`, exactly as in `RETURN`); keep the teams with more than one; match their members again.
`WHERE` after `WITH` filters on what `WITH` produced — the SQL `HAVING`, without a separate
keyword.

After `WITH`, only the variables it passes on remain: `p` is gone, `t` and `members` are left.
That is what makes the second `MATCH` start from fresh.

## Top-N, then more

`WITH` can sort and limit, so a query can pick a few rows and continue from them. The two most
senior employees, and the teams they belong to:

```python
print(db.query("""
    MATCH (p:Employee)
    WITH p ORDER BY p.hired LIMIT 2
    MATCH (p)-[:MEMBER_OF]->(t:Team)
    RETURN p.name, p.hired.year, t.name
"""))
```

```text
[['Gustavo Pérez', 2015, 'Research'], ['Bruno Lindqvist', 2017, 'Genomics']]
```

## From lists to rows and back

`collect` (rows to a list) and `UNWIND` (a list to rows) are inverses, and together they reshape
results. The zones of the North Wing, each with its room count, as one list:

```python
(summary,), = db.query("""
    MATCH (r:Room)-[:IN]->(z:Zone)
    WITH z.name AS zone, count(r) AS rooms ORDER BY zone
    RETURN collect(zone + ' (' + toString(rooms) + ')')
""")
print(summary)
```

```text
['Common Areas (2)', 'Containment Suite (2)', 'Genomics Floor (2)', 'Vivarium (2)']
```

Pipelines let a query decide what to do with what it found. [Next](10-optional), what to do when
it finds nothing: optional matches and missing data.
