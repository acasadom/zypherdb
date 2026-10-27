# 13. Documents: lists and maps as properties

Some data is naturally structured: an emergency contact has a name, a relationship and phone
numbers; a lab's equipment is a list of instruments, each with its own details. Modelling every
such piece as nodes and relationships would be correct but heavy. ZypherDB lets a property hold a
**map** — a document, like a JSON object — and query inside it.

Storing maps is an extension of ZypherDB: standard openCypher allows only numbers, strings,
booleans, temporal values and lists of them as properties. Nested lists and maps, and `null`s
inside them, are all allowed in a document.

## Writing documents

A Python `dict` is a map. Emergency contacts for two employees:

```python
db.query("MATCH (p:Person {name: $name}) SET p.emergency = $contact", name="Dalia Haddad", contact={
    "name": "Samir Haddad", "relation": "spouse",
    "phones": ["+34 600 111 222", "+34 911 333 444"],
})
db.query("MATCH (p:Person {name: $name}) SET p.emergency = $contact", name="Emeka Nwosu", contact={
    "name": "Grace Nwosu", "relation": "sister", "phones": ["+44 7700 900123"],
    "address": {"city": "Leeds", "country": "UK"},
})
```

And each lab's equipment, as a list of maps:

```python
db.query("MATCH (r:Room {name: 'BSL-3 Lab'}) SET r.equipment = $items", items=[
    {"kind": "biosafety cabinet", "class": "II", "certified_until": datetime.date(2025, 11, 1)},
    {"kind": "autoclave", "capacity_litres": 120},
    {"kind": "freezer", "temperature": -80, "alarm": True},
])
db.query("MATCH (r:Room {name: 'Sequencing Lab'}) SET r.equipment = $items", items=[
    {"kind": "sequencer", "model": "NovaSeq"},
    {"kind": "freezer", "temperature": -20, "alarm": False},
])
```

Values keep their types inside documents — the date stays a date, the booleans booleans.

## Reading inside them

`.key` reads a map's entry, `[index]` a list's element (negative indices count from the end), and
both chain:

```python
print(db.query("""
    MATCH (p:Person) WHERE p.emergency IS NOT NULL
    RETURN p.name, p.emergency.name, p.emergency.phones[0], p.emergency.address.city
    ORDER BY p.name
"""))
```

```text
[['Dalia Haddad', 'Samir Haddad', '+34 600 111 222', None], ['Emeka Nwosu', 'Grace Nwosu', '+44 7700 900123', 'Leeds']]
```

A missing key reads as `null`, like a missing property.

## Querying lists of documents

List functions and comprehensions work on documents. Which rooms have an alarmed -80 °C freezer?
`any` is true when some element of a list satisfies a condition:

```python
print(db.query("""
    MATCH (r:Room)
    WHERE any(item IN r.equipment WHERE item.kind = 'freezer' AND item.temperature <= -80 AND item.alarm)
    RETURN r.name
"""))
```

```text
[['BSL-3 Lab']]
```

`all`, `none` and `single` work the same way. A comprehension picks and reshapes elements — the
equipment kinds per room:

```python
print(db.query("""
    MATCH (r:Room) WHERE r.equipment IS NOT NULL
    RETURN r.name, size(r.equipment), [item IN r.equipment | item.kind]
    ORDER BY r.name
"""))
```

```text
[['BSL-3 Lab', 3, ['biosafety cabinet', 'autoclave', 'freezer']], ['Sequencing Lab', 2, ['sequencer', 'freezer']]]
```

Certificates inside documents expire like any date. The equipment whose certification runs out
before the end of the year:

```python
print(db.query("""
    MATCH (r:Room)
    UNWIND r.equipment AS item
    WITH r, item WHERE item.certified_until < date('2026-01-01')
    RETURN r.name, item.kind, item.certified_until
"""))
```

```text
[['BSL-3 Lab', 'biosafety cabinet', datetime.date(2025, 11, 1)]]
```

## Changing documents

A document is one value: to change part of it, write the whole new value. In Python that is
natural — read, modify, write back:

```python
(contact,), = db.query("MATCH (p:Person {name: 'Dalia Haddad'}) RETURN p.emergency")
contact["phones"].append("+34 622 555 666")
db.query("MATCH (p:Person {name: 'Dalia Haddad'}) SET p.emergency = $contact", contact=contact)
print(db.query("MATCH (p:Person {name: 'Dalia Haddad'}) RETURN size(p.emergency.phones)"))
```

```text
[[3]]
```

## Documents or nodes?

Use a document for data that belongs to one node and is read with it: contact details, settings,
measurements, an equipment list. Use nodes and relationships when the parts have identity of
their own and connect to other things: if instruments were booked by people, serviced by
contractors or moved between rooms, they should be `(:Instrument)` nodes. A field that queries look
nodes up by can have an index of its own, like a property ([step 17](17-performance)):
`CREATE INDEX FOR (p:Person) ON (p.emergency.relation)` makes
`WHERE p.emergency.relation = 'spouse'` an index lookup instead of a read of every `Person`.

Next, the dimension a security system cannot do without: [time](14-time).
