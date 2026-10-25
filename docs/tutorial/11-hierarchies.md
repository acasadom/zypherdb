# 11. Hierarchies: paths of any length

Organisations and buildings are trees. Sequencing is part of Genomics, which is part of Research;
a room is in a zone, which is in a building. A manager is responsible for a team *and everything
below it*, however deep. Questions like these follow relationships an unknown number of times —
which is where a graph database is at its best.

## Managers

Gustavo heads Research; Bruno manages Genomics:

```python
db.query("""
    MATCH (gustavo:Person {name: 'Gustavo Pérez'}), (research:Team {name: 'Research'}),
          (bruno:Person {name: 'Bruno Lindqvist'}), (genomics:Team {name: 'Genomics'})
    CREATE (gustavo)-[:MANAGES]->(research), (bruno)-[:MANAGES]->(genomics)
""")
```

## Variable-length relationships

`-[:PART_OF*]->` follows `PART_OF` one or more times. Every team inside Research, at any depth:

```python
print(db.query("""
    MATCH (t:Team)-[:PART_OF*]->(:Team {name: 'Research'})
    RETURN t.name ORDER BY t.name
"""))
```

```text
[['Genomics'], ['Sequencing'], ['Virology']]
```

The bounds can be given: `*2` exactly two hops, `*1..3` from one to three, `*..2` up to two, and
`*0..` zero or more — which includes the start node itself. That is what a manager's scope needs:
the team they manage *and* every team below it.

```python
def reports(manager):
    return db.query("""
        MATCH (:Person {name: $manager})-[:MANAGES]->(:Team)<-[:PART_OF*0..]-(t:Team)<-[:MEMBER_OF]-(p:Person)
        RETURN p.name, t.name ORDER BY t.name, p.name
    """, manager=manager)

print(reports("Bruno Lindqvist"))
print(len(reports("Gustavo Pérez")))
```

```text
[['Bruno Lindqvist', 'Genomics'], ['Chen Wei', 'Sequencing'], ['Emeka Nwosu', 'Sequencing']]
7
```

Read the pattern from the manager: the team they `MANAGES`, then `PART_OF` backwards zero or
more times (the team itself and its subteams), then the members of each. Gustavo's seven are the
members of Research, Genomics, Sequencing and Virology.

The same works for the building: rooms are `IN` zones, which are `IN` the building, so
`-[:IN*]->` reaches the building from a room whatever the nesting:

```python
print(db.query("MATCH (r:Room {name: 'Airlock'})-[:IN*]->(b:Building) RETURN b.name"))
```

```text
[['North Wing']]
```

## Paths as values

A pattern can be given a name, `path = (...)`, and returned or inspected whole. `length` is its
number of relationships, `nodes` and `relationships` its parts:

```python
for path in db.query("""
    MATCH path = (:Team {name: 'Sequencing'})-[:PART_OF*]->(top:Team)
    WHERE NOT (top)-[:PART_OF]->()
    RETURN path
"""):
    (p,) = path
    print(len(p.relationships), " -> ".join(node.properties["name"] for node in p.nodes))
```

```text
2 Sequencing -> Genomics -> Research
```

`WHERE NOT (top)-[:PART_OF]->()` keeps only the path that reaches the top of the tree. In Python a
path is a `zypherdb.Path`, with `nodes` and `relationships` tuples. Inside a query, functions
take it apart:

```python
print(db.query("""
    MATCH path = (:Team {name: 'Sequencing'})-[:PART_OF*]->(:Team {name: 'Research'})
    RETURN length(path), [team IN nodes(path) | team.name]
"""))
```

```text
[[2, ['Sequencing', 'Genomics', 'Research']]]
```

`[team IN nodes(path) | team.name]` is a **list comprehension**: for each element of the list, an
expression — Python's `[team.name for team in …]`. It can filter too: `[x IN list WHERE x > 0 | x
* 2]`.

## How far is too far

A variable-length pattern without an upper bound explores every path; on a large, densely
connected graph that is a lot of paths. Hierarchies like these are fine — they are trees. On a
graph with many cross-links, give a bound (`*1..4`) or ask for existence ([next step](12-exists))
rather than for every path.

Managers now have a scope. [Next](12-exists), the question every door asks: *may this person come
in?*
