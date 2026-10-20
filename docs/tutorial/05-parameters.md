# 5. Badges and parameters

Every door has a card reader. When someone swipes, the reader asks the database the same question
with a different badge number: *whose badge is this?* Writing the number into the query text, as
we have done so far, is the wrong tool for that. **Parameters** are the right one.

## Issuing badges

A badge is a node of its own, `ISSUED_TO` a person. A badge has a number and, for people from
outside, an expiry date:

```python
badges = [
    ("Ada Okafor", 70001), ("Bruno Lindqvist", 70002), ("Chen Wei", 70003),
    ("Dalia Haddad", 70004), ("Emeka Nwosu", 70005), ("Fatima Rossi", 70006),
    ("Gustavo Pérez", 70007), ("Hiro Tanaka", 80001), ("Ines Moreau", 90001),
]
for name, number in badges:
    db.query(
        "MATCH (p:Person {name: $name}) CREATE (:Badge {number: $number, active: true})-[:ISSUED_TO]->(p)",
        name=name, number=number,
    )
```

`$name` and `$number` are parameters: placeholders in the query whose values travel separately,
here as keyword arguments. The query text is the same every time; only the values change.

That is why parameters are the rule, not a nicety:

- **Safety.** A value is never parsed as Cypher, so a name like `O'Brien` just works, and text that
  came from outside cannot change what the query does (the injection attacks of SQL).
- **Types.** Values keep their Python type: an `int` stays an integer, a `datetime.date` a date.
  No formatting, no quoting.
- **Clarity.** The query reads as what it asks.

So the `join` helper of step 3 becomes:

```python
def join(person, team):
    db.query(
        "MATCH (p:Person {name: $person}), (t:Team {name: $team}) CREATE (p)-[:MEMBER_OF]->(t)",
        person=person, team=team,
    )
```

## The reader's question

A swipe of badge 70003 at a reader:

```python
def holder(badge):
    rows = db.query(
        "MATCH (:Badge {number: $badge, active: true})-[:ISSUED_TO]->(p:Person) RETURN p.name",
        badge=badge,
    )
    return rows[0][0] if rows else None

print(holder(70003))
print(holder(12345))
```

```text
Chen Wei
None
```

An unknown badge simply matches nothing: no rows.

## Values of every kind

A parameter can be any value a query handles: numbers, strings, booleans, `None`, dates and times,
lists, and dicts. The visitor's and the contractor's badges expire — a `datetime.date` goes in as a
date:

```python
import datetime

db.query(
    "MATCH (b:Badge) WHERE b.number IN $numbers SET b.valid_until = $until",
    numbers=[80001, 90001], until=datetime.date(2025, 3, 14),
)
print(db.query("MATCH (b:Badge) WHERE b.valid_until IS NOT NULL RETURN b.number, b.valid_until ORDER BY b.number"))
```

```text
[[80001, datetime.date(2025, 3, 14)], [90001, datetime.date(2025, 3, 14)]]
```

Parameters can also be passed as a dict, which helps when the names are not valid Python
identifiers or come from elsewhere:

```python
print(db.query("MATCH (p:Person {employee_id: $id}) RETURN p.name", {"id": 1004}))
```

```text
[['Dalia Haddad']]
```

A query that uses a parameter you did not pass fails, with an error naming it:

```python
from acmedb import ParameterMissingError

try:
    db.query("MATCH (p:Person {employee_id: $id}) RETURN p.name")
except ParameterMissingError as error:
    print(error)
```

```text
missing parameter '$id' (code 8)
```

Parameters are values only: a label, a relationship type or a property *name* cannot be a
parameter, because they shape the query rather than fill it in.

From now on every query that takes input uses parameters. [Next](06-returning), we look closer at
the other end: shaping what a query returns.
