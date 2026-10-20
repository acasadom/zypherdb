# 20. The safety manual: full-text search

Helix Biolabs has a safety manual: one protocol per situation (a spill, entering the containment
suite, a freezer alarm), written in Spanish, and each one applies to some rooms. Staff need to
find the right protocol fast, by what it says, not by its exact title: someone types *derrames*
(spills) and expects the protocol about a *derrame*, or types *contencion* without the accent.
That is **full-text search**: an index of the words in a text, ranked by relevance.

## The protocols

Each protocol is a node, linked to the rooms it applies to:

```python
PROTOCOLS = [
    ("Derrame de material biológico",
     "Ante un derrame en la cabina de seguridad, cubra el derrame con papel absorbente, "
     "aplique desinfectante y espere treinta minutos antes de limpiar.",
     ["BSL-3 Lab", "Sequencing Lab"]),
    ("Entrada al laboratorio de contención",
     "La entrada al nivel de contención 3 exige pasar por la esclusa, vestir el equipo de "
     "protección y trabajar siempre en pareja.",
     ["Airlock", "BSL-3 Lab"]),
    ("Cuidado de los animales",
     "Los animales se revisan dos veces al día; un animal enfermo se aísla y se avisa al veterinario.",
     ["Animal Holding", "Vivarium Control"]),
    ("Alarma de congelador",
     "Si suena la alarma del congelador de -80, traslade las muestras al congelador de reserva "
     "y registre la incidencia.",
     ["BSL-3 Lab", "Sequencing Lab"]),
    ("Visitas",
     "Las visitas van acompañadas en todo momento y no entran en las zonas de contención.",
     ["Lobby", "Seminar Room"]),
]
db.query("""
    UNWIND $protocols AS protocol
    CREATE (p:Protocol {title: protocol[0], body: protocol[1]})
    WITH p, protocol
    UNWIND protocol[2] AS room
    MATCH (r:Room {name: room})
    CREATE (p)-[:APPLIES_TO]->(r)
""", protocols=PROTOCOLS)
```

## A full-text index

Every property is indexed for equality and ranges already, but not word by word: that takes a
**full-text index**, declared on the labels and properties to index. The protocols are in
Spanish, so the index uses the Spanish analyzer:

```python
db.query("""
    CREATE FULLTEXT INDEX protocols FOR (p:Protocol) ON EACH [p.title, p.body]
    OPTIONS {indexConfig: {`fulltext.analyzer`: 'spanish'}}
""")
```

The index reads the protocols that exist now, and from then on follows every change to them. An
**analyzer** decides what the index's words are. All three that acmedb has split text into words,
lower-case them and remove accents. `spanish` and `english` also skip the language's most common
words (*de*, *la*, *the*) and reduce each word to its stem, so *derrames* and *derrame* are one
word:

```python
for analyzer, description in db.query("CALL db.index.fulltext.listAvailableAnalyzers()"):
    print(f"{analyzer:<9} {description}")
```

```text
standard  Unicode words, lower-cased, without accents.
english   Like standard, without English stop words, and with English stemming.
spanish   Like standard, without Spanish stop words, and with Spanish stemming.
```

## Searching

The procedure `db.index.fulltext.queryNodes` searches an index. `CALL` runs a procedure, and
`YIELD` names the columns it returns, here each matching node and its **score**: the higher, the
better the match.

```python
def search(text):
    return db.query("""
        CALL db.index.fulltext.queryNodes('protocols', $text) YIELD node, score
        RETURN node.title
    """, text=text)

print(search("derrames"))
print(search("contencion"))
```

```text
[['Derrame de material biológico']]
[['Entrada al laboratorio de contención'], ['Visitas']]
```

The results come best first. A protocol with more of the searched words, in a shorter text, scores
higher (the scoring is BM25, the one Lucene and Elasticsearch use).

The query has a syntax of its own, the one Neo4j's full-text indexes use:

```python
print(search('"equipo de protección"'))      # a phrase: the words in a row
print(search("+contención -visitas"))        # required and excluded words
print(search("congel*"))                     # a prefix
print(search("desinfetante~"))               # a typo: up to two letters off
print(search("title:animales"))              # in one property only
```

```text
[['Entrada al laboratorio de contención']]
[['Entrada al laboratorio de contención']]
[['Alarma de congelador']]
[['Derrame de material biológico']]
[['Cuidado de los animales']]
```

Several words without operators match any of them: `muestras animales` finds both protocols.

## Search, then the graph

A search is a clause like any other, so the graph goes on from its results. The protocols that
apply where someone is right now, with who is there:

```python
for title, room, people in db.query("""
    CALL db.index.fulltext.queryNodes('protocols', 'contención alarma') YIELD node
    MATCH (node)-[:APPLIES_TO]->(r:Room)<-[:IS_IN]-(p:Person)
    RETURN node.title, r.name, collect(p.name) ORDER BY node.title, r.name
"""):
    print(f"{title:<38} {room:<16} {', '.join(sorted(people))}")
```

```text
Alarma de congelador                   BSL-3 Lab        Joon Park
Alarma de congelador                   Sequencing Lab   Chen Wei
Entrada al laboratorio de contención   BSL-3 Lab        Joon Park
Visitas                                Lobby            Ada Okafor, Ines Moreau
```

And the protocols to read for each alarm still open, through the alarm's room:

```python
for kind, title in db.query("""
    MATCH (a:Alarm {open: true})
    CALL db.index.fulltext.queryNodes('protocols', 'contención') YIELD node
    MATCH (node)-[:APPLIES_TO]->(:Room {name: a.room})
    RETURN a.kind, node.title ORDER BY a.kind
"""):
    print(f"{kind:<14} {title}")
```

```text
after closing  Entrada al laboratorio de contención
alone          Entrada al laboratorio de contención
overstay       Entrada al laboratorio de contención
```

`CALL` here runs once for each open alarm, as `MATCH` would.

## Searching relationships

The security officers write notes on the alarms they handle. A note belongs to the officer and the
alarm both, so it is a relationship, with its text as a property. The notes are in English:

```python
NOTES = [
    ("Ada Okafor", "alone", "Called Dalia back into the lab; the second person returned within ten minutes."),
    ("Ada Okafor", "overstay", "Joon was running a long incubation, approved by the supervisor."),
    ("Ada Okafor", "after closing", "Incubations must not run past closing time; told Joon to stop."),
]
db.query("""
    UNWIND $notes AS note
    MATCH (officer:Person {name: note[0]}), (a:Alarm {kind: note[1], open: true})
    CREATE (officer)-[:NOTED {text: note[2]}]->(a)
""", notes=NOTES)
db.query("""
    CREATE FULLTEXT INDEX alarm_notes FOR ()-[n:NOTED]-() ON EACH [n.text]
    OPTIONS {indexConfig: {`fulltext.analyzer`: 'english'}}
""")
for kind, text in db.query("""
    CALL db.index.fulltext.queryRelationships('alarm_notes', 'incubation') YIELD relationship
    RETURN endNode(relationship).kind, relationship.text
"""):
    print(f"{kind:<14} {text}")
```

```text
overstay       Joon was running a long incubation, approved by the supervisor.
after closing  Incubations must not run past closing time; told Joon to stop.
```

*incubation* finds *Incubations* too, through the English stemmer.

## Keeping the index current

The index follows every change, in the same transaction: a protocol rewritten is found by its new
words, and no longer by its old ones.

```python
db.query("""
    MATCH (p:Protocol {title: 'Visitas'})
    SET p.body = 'Las visitas firman en recepción y llevan una tarjeta temporal.'
""")
print(search("recepción"), search("acompañadas"))
```

```text
[['Visitas']] []
```

`SHOW FULLTEXT INDEXES` lists the indexes and `DROP INDEX` removes one:

```python
for name, kind, entity, labels, properties, options in db.query("SHOW FULLTEXT INDEXES"):
    print(name, entity, labels, properties, options["indexConfig"]["fulltext.analyzer"])
```

```text
alarm_notes RELATIONSHIP ['NOTED'] ['text'] english
protocols NODE ['Protocol'] ['title', 'body'] spanish
```

## What you have built

Over twenty steps, Helix Biolabs got:

- a graph of its people, teams, buildings, rooms and doors ([1](01-getting-started)–[3](03-relationships));
- the queries to explore it, report on it and keep it current ([4](04-filtering)–[10](10-optional));
- access rules as data — team grants with hours, management reach, personal exceptions, bans,
  training — and the one query that applies them all ([11](11-hierarchies)–[14](14-time));
- an event log at volume, used safely from many threads and processes ([15](15-loading)–[17](17-performance));
- a door controller that decides, records and tracks in one transaction ([18](18-door-controller)),
  and a monitor for the rules no door can enforce ([19](19-monitoring));
- a searchable safety manual, tied to the rooms it applies to.

From here, the [Cypher reference](../guide/cypher) lists everything the language can do, the
[Python reference](../guide/python) every method, and the technical guides explain how acmedb
works inside.
