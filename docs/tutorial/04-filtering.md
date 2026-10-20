# 4. Asking precise questions: WHERE

A security system is mostly questions with conditions: which rooms are high-containment, who was
hired this year, who is on call. Inline properties (`{name: 'Chen Wei'}`) only test equality;
`WHERE` takes any condition.

## Comparisons

```python
print(db.query("MATCH (r:Room) WHERE r.bsl >= 2 RETURN r.name, r.bsl ORDER BY r.bsl DESC, r.name"))
```

```text
[['Airlock', 3], ['BSL-3 Lab', 3], ['Animal Holding', 2], ['Sequencing Lab', 2]]
```

The comparison operators are `=`, `<>` (not equal), `<`, `<=`, `>` and `>=`. They work on
numbers, strings (alphabetically), booleans and dates. Comparisons chain, as in mathematics:

```python
print(db.query("""
    MATCH (p:Employee)
    WHERE date('2020-01-01') <= p.hired < date('2023-01-01')
    RETURN p.name, p.hired ORDER BY p.hired
"""))
```

```text
[['Fatima Rossi', datetime.date(2020, 10, 5)], ['Chen Wei', datetime.date(2021, 1, 11)], ['Dalia Haddad', datetime.date(2022, 6, 1)]]
```

## Combining conditions

`AND`, `OR`, `NOT` and `XOR` combine conditions; parentheses group them:

```python
print(db.query("""
    MATCH (p:Employee)
    WHERE p.on_call AND (p.role = 'Lab technician' OR p.role = 'Animal care technician')
    RETURN p.name ORDER BY p.name
"""))
print(db.query("MATCH (p:Employee) WHERE NOT p.on_call RETURN count(p)"))
```

```text
[['Emeka Nwosu'], ['Fatima Rossi']]
[[3]]
```

`p.on_call` is already a boolean, so it is a condition on its own.

## Text

```python
print(db.query("MATCH (r:Room) WHERE r.name STARTS WITH 'Animal' OR r.name ENDS WITH 'Lab' RETURN r.name ORDER BY r.name"))
print(db.query("MATCH (p:Person) WHERE p.role CONTAINS 'scientist' RETURN p.name ORDER BY p.name"))
print(db.query("MATCH (p:Person) WHERE toLower(p.name) STARTS WITH 'd' RETURN p.name"))
```

```text
[['Animal Holding'], ['BSL-3 Lab'], ['Sequencing Lab']]
[['Chen Wei'], ['Dalia Haddad']]
[['Dalia Haddad']]
```

String comparisons are exact (case matters); `toLower` and `toUpper` make a test ignore case.

## Lists: IN

`IN` tests whether a value is in a list — the natural way to ask for one of several:

```python
print(db.query("MATCH (r:Room) WHERE r.name IN ['Lobby', 'Seminar Room', 'Gym'] RETURN r.name ORDER BY r.name"))
print(db.query("MATCH (p:Employee) WHERE 'pt' IN p.languages RETURN p.name"))
```

```text
[['Lobby'], ['Seminar Room']]
[['Gustavo Pérez']]
```

The second query turns `IN` around: a value in a list property.

## Missing values: null

The contractor and the visitor have no `employee_id`. A missing property reads as `null`, and
`null` is *unknown*: comparing it to anything gives `null`, not `true` or `false`, and `WHERE`
keeps only the rows where the condition is `true`. So neither of these finds them:

```python
print(db.query("MATCH (p:Person) WHERE p.employee_id > 0 RETURN count(p)"))
print(db.query("MATCH (p:Person) WHERE NOT p.employee_id > 0 RETURN count(p)"))
```

```text
[[7]]
[[0]]
```

`NOT null` is still `null`. To ask about a missing value, use `IS NULL` and `IS NOT NULL`, which
are always true or false:

```python
print(db.query("MATCH (p:Person) WHERE p.employee_id IS NULL RETURN p.name ORDER BY p.name"))
```

```text
[['Hiro Tanaka'], ['Ines Moreau']]
```

[Step 10](10-optional) comes back to `null`, where it matters most: data that may not be there.

## Conditions across a pattern

`WHERE` can use every variable of the pattern. The scientists of the Research division's teams,
excluding Genomics:

```python
print(db.query("""
    MATCH (p:Person)-[:MEMBER_OF]->(t:Team)
    WHERE p.role = 'Research scientist' AND t.name <> 'Genomics'
    RETURN p.name, t.name ORDER BY p.name
"""))
```

```text
[['Chen Wei', 'Sequencing'], ['Dalia Haddad', 'Virology']]
```

The lab now answers precise questions — about values written into the query itself. A door
reader, though, asks the same question each time with a different badge. [Next](05-parameters):
parameters.
