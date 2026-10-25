# 2. People: nodes, labels and values

A lab is its people, and not all of them are alike: employees, contractors from outside firms,
visitors on a one-day pass. This step adds them, and with them the two things a node carries —
**labels** and **properties** — and the kinds of values a property can hold.

## Labels: what a node is

A node can have several labels. Everyone is a `Person`; in addition, each is an `Employee`, a
`Contractor` or a `Visitor`. Ada, whom we created in the last step, is an employee — `SET` adds
the label to Ada's node (more on changing data in [step 8](08-updating)):

```python
db.query("MATCH (p:Person {name: 'Ada Okafor'}) SET p:Employee")
```

`{name: 'Ada Okafor'}` inside the pattern is a filter: only the person with that name.

Now the rest of the staff. One `CREATE` can make many nodes, separated by commas:

```python
db.query("""
    CREATE (:Person:Employee {name: 'Bruno Lindqvist', employee_id: 1002, role: 'Lab manager',
                              hired: date('2017-09-18'), fte: 1.0, on_call: true}),
           (:Person:Employee {name: 'Chen Wei', employee_id: 1003, role: 'Research scientist',
                              hired: date('2021-01-11'), fte: 1.0, on_call: false}),
           (:Person:Employee {name: 'Dalia Haddad', employee_id: 1004, role: 'Research scientist',
                              hired: date('2022-06-01'), fte: 0.8, on_call: false}),
           (:Person:Employee {name: 'Emeka Nwosu', employee_id: 1005, role: 'Lab technician',
                              hired: date('2023-02-20'), fte: 1.0, on_call: true}),
           (:Person:Employee {name: 'Fatima Rossi', employee_id: 1006, role: 'Animal care technician',
                              hired: date('2020-10-05'), fte: 1.0, on_call: true}),
           (:Person:Employee {name: 'Gustavo Pérez', employee_id: 1007, role: 'Head of Research',
                              hired: date('2015-04-13'), fte: 1.0, on_call: false,
                              languages: ['es', 'en', 'pt']})
""")
db.query("MATCH (p:Person {name: 'Ada Okafor'}) SET p.employee_id = 1001, p.hired = date('2019-03-04'), p.fte = 1.0, p.on_call = true")
```

And the people from outside: a contractor who services the ventilation, and an inspector who
visits for the day.

```python
db.query("""
    CREATE (:Person:Contractor {name: 'Hiro Tanaka', company: 'CleanAir Services', role: 'HVAC technician'}),
           (:Person:Visitor {name: 'Ines Moreau', organisation: 'EU Biosafety Agency'})
""")
```

A label in a pattern selects by it. `Person` matches all nine; `Employee` only the staff:

```python
print(db.query("MATCH (p:Person) RETURN count(p)"))
print(db.query("MATCH (e:Employee) RETURN count(e)"))
print(db.query("MATCH (v:Person:Visitor) RETURN v.name"))
```

```text
[[9]]
[[7]]
[['Ines Moreau']]
```

`count(p)` counts the rows — the first of the aggregations of [step 7](07-aggregating).
`(v:Person:Visitor)` asks for both labels.

## Properties and their types

Properties are named values. The ones above already use several kinds:

| Cypher | Example | In Python |
| --- | --- | --- |
| integer (64-bit) | `1002` | `int` |
| float | `0.8` | `float` |
| string | `'Lab manager'` | `str` |
| boolean | `true` | `bool` |
| date | `date('2017-09-18')` | `datetime.date` |
| list of one type | `['es', 'en', 'pt']` | `list` |

There are times, date-times and durations too ([step 14](14-time)), and ZypherDB also stores maps
as documents ([step 13](13-documents)). A node does not need every property: the contractor has a
`company`, the employees an `employee_id`. Reading one a node lacks gives `null` — `None` in
Python:

```python
for name, employee_id in db.query("MATCH (p:Person) RETURN p.name, p.employee_id ORDER BY p.name"):
    print(name, employee_id)
```

```text
Ada Okafor 1001
Bruno Lindqvist 1002
Chen Wei 1003
Dalia Haddad 1004
Emeka Nwosu 1005
Fatima Rossi 1006
Gustavo Pérez 1007
Hiro Tanaka None
Ines Moreau None
```

`ORDER BY` sorts the rows ([step 6](06-returning) covers it with the rest of `RETURN`).

## Whole nodes

`RETURN p` gives back the node itself, as a `zypherdb.Node` with its labels and properties:

```python
(gustavo,), = db.query("MATCH (p:Person {employee_id: 1007}) RETURN p")
print(gustavo.labels)
print(gustavo.properties["role"], gustavo.properties["languages"])
print(gustavo.properties["hired"].year)
```

```text
('Employee', 'Person')
Head of Research ['es', 'en', 'pt']
2015
```

`(gustavo,), = …` unpacks the single row of one column. The node's `id` is ZypherDB's own number
for it; it identifies the node, but your data should carry its own identifiers, as
`employee_id` does — ids are an internal detail.

Cypher functions read the same parts inside a query:

```python
print(db.query("MATCH (p:Person {name: 'Hiro Tanaka'}) RETURN labels(p), keys(p)"))
```

```text
[[['Contractor', 'Person'], ['company', 'name', 'role']]]
```

People alone do not make a lab. [Next](03-relationships), they join teams and the building gets
its rooms — and the graph its edges.
