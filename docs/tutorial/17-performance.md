# 17. Fast queries

A door must decide in the time it takes to swipe a card — a few milliseconds at most, and the
database's share should be a small part of that. This step explains what ZypherDB does with a
query, which shapes are fast and which are not, and how to write the ones that matter.

## How a query finds its data

Every query starts somewhere: a node pattern that the engine can find without looking at the
rest of the graph — the **anchor** — and follows relationships from there. Choosing a good anchor
is most of what makes a query fast. In order of preference:

1. **An equality on a property**, written inline (`{number: $badge}`) or in `WHERE`
   (`b.number = $badge`) with a constant or a parameter. Every property is indexed for equality,
   so this finds the matching nodes directly, whatever the size of the graph.
2. **A label** (`(r:Room)`): the nodes with that label, one after another. Cost grows with the
   number of such nodes.
3. **Nothing** (`(n)`): every node of the database.

From the anchor, each relationship in the pattern is a step to the neighbours, which is cheap: a
node's relationships of a type are stored together.

The decision query of [step 14](14-time) anchors on the badge (an equality) and finds the door
by its id (another equality). When the expansion reaches the door's end of the pattern, the engine
does not look through every door of the zone: it already knows which door it wants, and checks for
the relationship to it directly. That is why it takes tens of microseconds.

```python
import time

def timed(function, repeat=200):
    start = time.perf_counter()
    for _ in range(repeat):
        function()
    return (time.perf_counter() - start) / repeat * 1e6   # microseconds per call

print(f"decision: {timed(lambda: may_enter(70004, 'D-BSL-3 Lab', monday_morning)):.0f} µs")
print(f"badge lookup: {timed(lambda: holder(70013)):.0f} µs")
```

On a laptop this prints figures in the tens of microseconds for the decision and a few
microseconds for the lookup. (Measurements on a graph of 100,000 people are in `bench/RESULTS.md`
in the repository.)

## Asking the same question all day

Before a query runs, ZypherDB reads its text, checks it, and makes its **plan**: which node to start
from, which steps to take. For a badge lookup that work costs about as much as the lookup itself.
A door asks the same few questions all day, only with other badges, so it should not be done again
each time.

`db.query` already keeps the plans of the last 64 texts it ran: the second time the same text
comes, only the parameters are new. That is one more reason to pass values as parameters
(`$badge`): a value pasted into the text makes a new text, and a new plan, for every badge.

A program that knows its questions can also prepare them once, by name, and keep them:

```python
lookup = db.prepare("MATCH (:Badge {number: $badge, active: true})-[:ISSUED_TO]->(p:Person) RETURN p.name")
print(lookup.parameters, lookup.columns)
print(lookup.query(badge=70013), lookup.query(badge=70003))
```

```text
('badge',) ('p.name',)
[['Chen Wei']] []
```

A prepared query runs as `db.query` would, without even looking its text up:

```python
print(f"prepared lookup: {timed(lambda: lookup.query(badge=70013)):.0f} µs")
```

A plan is made for the graph as it is: from how many nodes each label has and how many
relationships each type has. When those counts grow or shrink a lot (twofold, and by 100 or more),
the next run plans the query again first, so a query prepared on an empty lab still runs well when
the building is full.

## What scans

An equality uses the property's index, and so does a range of numbers or dates (`<`, `<=`, `>`,
`>=`) against a constant or a parameter: the engine reads the part of the index in range. A date
written as `date('2025-03-01')` is a function call, not a constant, so pass dates as parameters
in the queries that must be fast. Other conditions — `STARTS WITH`,
`CONTAINS`, `IN` a list, a range of strings — do not use the index: they are checked node by node
on whatever the anchor produced. So:

```python
fast = "MATCH (p:Person {employee_id: $id}) RETURN p.name"            # index seek
slow = "MATCH (p:Person) WHERE p.name STARTS WITH $prefix RETURN p"   # every Person
```

Both are right; the second costs time in proportion to the number of `Person` nodes — fine for the
lab's dozens, noticeable for millions. When such a query must be fast on a large set, give it a
better anchor: start from something selective and filter what it reaches.

## Rules of thumb

- **Anchor on an equality** with a parameter. Put the most selective one first in mind: the engine
  chooses the anchor, but it can only choose among what the pattern gives it.
- **Ask for existence with `EXISTS`, not by counting.** `EXISTS { … }` and pattern predicates
  answer yes or no; `count(*) > 0` over a `MATCH` makes every row first.
- **Bound variable-length patterns** on graphs with many cross-links (`*1..4`); hierarchies are
  fine unbounded.
- **`ORDER BY … LIMIT k`** keeps only the best k rows while sorting, but every row is still found
  and computed first: a top-10 of a million nodes reads a million nodes.
- **Return what you need.** Whole nodes (`RETURN p`) bring all their properties into Python; `RETURN
  p.name` brings one value. Each value crossing into Python costs a little, which adds up on large
  results.
- **Write in batches** (`UNWIND $rows`, `write()`), and choose the durability the data needs
  ([step 15](15-loading)).
- **Expect a slow start.** The first queries after the process starts may read from disk, until
  the parts of the database they use are in memory; after that, they are served from memory.

## Watching it

`db.explain(query)` shows what the engine will do, without running the query: its **plan**, a tree
of operators, each getting its rows from its first child. A small helper prints it:

```python
def show(plan, depth=0):
    made = "" if plan["rows"] is None else f"  ({plan['rows']} rows)"
    print("  " * depth + f"{plan['operator']} {plan['details']}{made}")
    for child in plan["children"]:
        show(child, depth + 1)

show(db.explain("MATCH (b:Badge {number: $badge})-[:ISSUED_TO]->(p:Person) RETURN p.name", badge=70013))
```

```text
Return p.name
  Expand(All) (b:Badge {number: $badge})-[:ISSUED_TO]->(p:Person)
    NodeIndexSeek (b:Badge {number: $badge})
```

Read it from the bottom: an index seek finds the badge (the anchor), one step reaches the person,
and the result projects the name. `NodeByLabelScan` or `AllNodesScan` at the bottom means the
query reads every node of a label, or of the database.

`db.profile(query)` runs the query and returns its rows with the plan, each operator showing how
many rows it made (and, in `time_ms`, the time spent in it):

```python
rows, plan = db.profile("MATCH (b:Badge) WHERE b.number > 70010 RETURN count(b)")
show(plan)
```

An operator that makes many more rows than the ones above it keep is where a query does more work
than it needs. The [performance notes](../guide/performance) list what the engine does not do
well yet.

All the pieces are in place. [Next](18-door-controller), they come together: the door controller.
