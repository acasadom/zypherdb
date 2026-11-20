# 21. Access reviews: vector search

Every quarter, Biosafety reviews who goes where. The rules of [step 14](14-time) say who *may*
enter a room; the review asks something the rules cannot: is the way someone *uses* their access
normal for their work? The usual answer is to compare people with their **peers**: a technician
who goes where none of their teammates go is worth a look.

A person's quarter, reduced to how often they entered each room, is a list of numbers: a
**vector**. People who work alike have vectors that point the same way, and a **vector index**
finds the closest vectors fast. The same index serves the embeddings that a machine-learning model
makes of texts or images, compared by meaning; here the vectors come from the swipe log, so every
number has a plain meaning.

## Access profiles

The profile counts each person's entries into each room last quarter, always in the same order of
rooms:

```python
ROOMS = ["Lobby", "Seminar Room", "Genomics Office", "Sequencing Lab",
         "Airlock", "BSL-3 Lab", "Animal Holding", "Vivarium Control"]
PROFILES = {
    "Ada Okafor":      [60, 10,  8, 10, 15, 15,  8,  8],
    "Bruno Lindqvist": [60, 12, 55, 30,  0,  0,  0,  0],
    "Chen Wei":        [60,  6, 20, 58,  0,  0,  0,  0],
    "Dalia Haddad":    [60,  8,  4,  2, 50, 50,  0,  0],
    "Emeka Nwosu":     [60,  2,  6, 62,  0,  0,  0,  0],
    "Fatima Rossi":    [60,  3,  0,  0,  0,  0, 55, 40],
    "Gustavo Pérez":   [60, 30, 20,  5,  0,  2,  0,  3],
    "Joon Park":       [60,  4,  2,  0, 58, 58,  0,  0],
    "Kemi Adeyemi":    [60,  2,  0,  0, 10, 10, 40, 30],
    "Lars Becker":     [60,  2,  0,  0,  0,  0, 50, 52],
}
db.query("""
    UNWIND keys($profiles) AS name
    MATCH (p:Person {name: name})
    SET p.access_profile = $profiles[name]
""", profiles=PROFILES)
```

In a real system the counts would come from the `Swipe` nodes of [step 15](15-loading), with one
query per quarter. Hiro, the contractor, and Ines, the visitor, have no profile: the review is
about staff.

## A vector index

A vector index is on one label and one property, and needs to know how many numbers each vector
has:

```python
db.query("""
    CREATE VECTOR INDEX access_profiles FOR (p:Person) ON p.access_profile
    OPTIONS {indexConfig: {`vector.dimensions`: 8, `vector.similarity_function`: 'cosine'}}
""")
db.query("CALL db.awaitIndexes()")
```

**Cosine** similarity compares directions, not lengths: someone who came in half as often, to the
same rooms in the same proportions, has the same profile. That suits a review, where a part-timer
should not look unusual. The other choice, `'euclidean'`, compares the numbers themselves.

The index reads the existing profiles in the background, so that creating it on millions of nodes
does not stop the writes meanwhile. On ten nodes it is done at once; `db.awaitIndexes()` waits for
the population to end, the safe thing to do before the first search. Nodes without the property,
like Hiro and Ines, are simply not in the index.

## The closest profiles

The procedure `db.index.vector.queryNodes` takes the index, how many nodes to return and a vector,
and returns the closest nodes, best first, each with its **score**, between 0 and 1: 1 for the same
direction, lower the further apart.

```python
for name, score in db.query("""
    MATCH (chen:Person {name: 'Chen Wei'})
    CALL db.index.vector.queryNodes('access_profiles', 4, chen.access_profile) YIELD node, score
    RETURN node.name, score
"""):
    print(f"{name:<16} {score:.3f}")
```

```text
Chen Wei         1.000
Emeka Nwosu      0.992
Bruno Lindqvist  0.932
Ada Okafor       0.884
```

Chen comes first, closest to himself; then the people who work like him.

## The closest among some

Joon will be away for a month, and someone outside Virology must cover his rounds of the
containment suite. That is not a question for the whole index: the two closest profiles to Joon's
are his own and Dalia's, both in Virology. The question is: the closest *among the people outside
his team*. The `SEARCH` clause asks exactly that. It follows a `MATCH`, and keeps the closest of
the entities that the `MATCH` gives:

```python
for name, team, score in db.query("""
    MATCH (joon:Person {name: 'Joon Park'})-[:MEMBER_OF]->(virology:Team)
    MATCH (p:Employee)-[:MEMBER_OF]->(team:Team)
    WHERE team <> virology
    SEARCH p IN (VECTOR INDEX access_profiles FOR joon.access_profile LIMIT 2) SCORE AS score
    RETURN p.name, team.name, score
"""):
    print(f"{name:<16} {team:<12} {score:.3f}")
```

```text
Ada Okafor       Biosafety    0.898
Gustavo Pérez    Research     0.771
```

The pattern and its `WHERE` choose the candidates, and the search keeps the two closest of them,
so two come out whenever at least two people match. Searching first and removing the Virology
people afterwards would have left none. The vector can come from any earlier variable, here
Joon's own profile, or from a parameter.

## Outliers

Now the review itself: for each employee, the teammate with the closest profile. `SEARCH` runs once
for each row of the clauses before its `MATCH`, here once per employee, with that employee's
profile as the vector:

```python
for name, team, mate, score in db.query("""
    MATCH (p:Employee)-[:MEMBER_OF]->(team:Team)
    MATCH (mate:Employee)-[:MEMBER_OF]->(team)
    WHERE mate <> p
    SEARCH mate IN (VECTOR INDEX access_profiles FOR p.access_profile LIMIT 1) SCORE AS score
    RETURN p.name, team.name, mate.name, score ORDER BY score, p.name
"""):
    print(f"{name:<16} {team:<12} {mate:<16} {score:.3f}")
```

```text
Kemi Adeyemi     Virology     Dalia Haddad     0.812
Chen Wei         Sequencing   Emeka Nwosu      0.992
Emeka Nwosu      Sequencing   Chen Wei         0.992
Fatima Rossi     Animal Care  Lars Becker      0.995
Lars Becker      Animal Care  Fatima Rossi     0.995
Dalia Haddad     Virology     Joon Park        0.998
Joon Park        Virology     Dalia Haddad     0.998
```

The people alone in their team have no row: their `MATCH` finds no teammate. (With
`OPTIONAL MATCH`, they would have one row, with `null` for the teammate.)

A `WHERE` written after `SCORE AS` is different from the one before `SEARCH`: it runs after the
search, on its results, and can use the score. It keeps only the employees whose closest teammate
is not close:

```python
print(db.query("""
    MATCH (p:Employee)-[:MEMBER_OF]->(team:Team)
    MATCH (mate:Employee)-[:MEMBER_OF]->(team)
    WHERE mate <> p
    SEARCH mate IN (VECTOR INDEX access_profiles FOR p.access_profile LIMIT 1) SCORE AS score
    WHERE score < 0.9
    RETURN p.name, mate.name
"""))
```

```text
[['Kemi Adeyemi', 'Dalia Haddad']]
```

Kemi is a Virology technician who spends her days in the vivarium. Maybe she supports the
infection studies with animals and all is well; maybe she has access she no longer needs. Either
way, the review now has a name to ask about, found without writing a rule for it.

## A wrong vector is an error

The index checks every write to the property. A profile with the wrong number of rooms is not a
vector the index takes, and the write fails, so the mistake shows up at once, not as missing search
results later:

```python
from zypherdb import ConstraintViolationError

try:
    db.query("MATCH (p:Person {name: 'Kemi Adeyemi'}) SET p.access_profile = [60, 2, 0]")
except ConstraintViolationError as error:
    print(error)
```

```text
node 51 cannot have this access_profile: vector index 'access_profiles' takes a list of 8 numbers, and this one has 3 elements (code 10)
```

A correct write, on the other hand, moves the node in the index in the same transaction, as with
every other index. `SHOW VECTOR INDEXES` lists the vector indexes, with three more columns than
`SHOW INDEXES`: the state, how much of the population is done, and why it failed, if it did:

```python
for name, kind, entity, labels, properties, owning_constraint, options, state, percent, failure in db.query("SHOW VECTOR INDEXES"):
    print(name, labels, properties, state, percent, options["indexConfig"]["vector.dimensions"])
```

```text
access_profiles ['Person'] ['access_profile'] ONLINE 100.0 8
```

## What you have built

Over twenty-one steps, Helix Biolabs got:

- a graph of its people, teams, buildings, rooms and doors ([1](01-getting-started)–[3](03-relationships));
- the queries to explore it, report on it and keep it current ([4](04-filtering)–[10](10-optional));
- access rules as data — team grants with hours, management reach, personal exceptions, bans,
  training — and the one query that applies them all ([11](11-hierarchies)–[14](14-time));
- an event log at volume, used safely from many threads and processes ([15](15-loading)–[17](17-performance));
- a door controller that decides, records and tracks in one transaction ([18](18-door-controller)),
  and a monitor for the rules no door can enforce ([19](19-monitoring));
- a searchable safety manual, tied to the rooms it applies to ([20](20-searching));
- access reviews that compare each person with their peers.

From here, the [Cypher reference](../guide/cypher) lists everything the language can do, the
[Python reference](../guide/python) every method, and the technical guides explain how ZypherDB
works inside.
