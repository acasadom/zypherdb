# 2. Matching

`MATCH` binds variables to parts of the graph. The simplest form — a node — you already saw; this
page adds edges, direction, and `WHERE`.

*Using the `ctx` and graph from [step 1](01-getting-started).*

## Follow an edge

A pattern chains nodes through edges. `(p)-[:ACTED_IN]->(m)` reads: `p` has an `ACTED_IN` edge
**out** to `m`:

```python
print(run(ctx, "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title"))
```

```text
[['The Matrix'], ['The Matrix Reloaded'], ['John Wick']]
```

The arrow `->` is direction: `<-` would match an edge pointing *into* the node. The type
(`ACTED_IN`) is optional; `-[…]->` with no type matches any edge.

## Filter with WHERE

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.title"))
```

```text
[['The Matrix Reloaded'], ['John Wick']]
```

`WHERE` supports `=`, `<>`, `<`, `>`, `<=`, `>=`, and `AND`/`OR`/`NOT`:

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE p.name = 'Keanu Reeves' AND m.released > 2000 RETURN m.title"))
```

```text
[['The Matrix Reloaded'], ['John Wick']]
```

## Longer paths

Chain more than one edge. Here a director of `The Matrix`, then the actors of that same movie:

```python
print(run(ctx, "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name"))
```

```text
[['Keanu Reeves'], ['Carrie-Anne Moss'], ['Laurence Fishburne']]
```

The middle `m` appears in both edges, so the two hops meet on the same movie.

## Multiple patterns

A `MATCH` can hold comma-separated patterns, joined together. A variable shared across patterns
is the join key:

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie), (d:Person)-[:DIRECTED]->(m) WHERE m.title = 'The Matrix' RETURN p.name, d.name"))
```

```text
[['Keanu Reeves', 'Lana Wachowski'],
 ['Carrie-Anne Moss', 'Lana Wachowski'],
 ['Laurence Fishburne', 'Lana Wachowski']]
```

Both patterns share `m`, so they join on the same movie. Note the multiplicities: the graph has
one row per matching pair — the same person or movie can appear in several rows.

Next, [step 3](03-writing) writes data instead of reading it.
