# 3. Writing

`CREATE`, `MERGE`, `SET`, `DELETE`, and `REMOVE` mutate the graph. Writes to a query run in one
transaction: either all of them commit, or none.

*Using the `ctx` and graph from [step 1](01-getting-started).*

## CREATE

```python
run(ctx, "CREATE (n:Person {name: 'Neo', born: 1964})")
print(run(ctx, "MATCH (n:Person {name: 'Neo'}) RETURN n.born"))
```

```text
[[1964]]
```

`CREATE` allocates the node id itself; here the node is addressed later by its `name`. Two nodes
plus an edge in one statement:

```python
run(ctx, "CREATE (a:Person {name: 'X'})-[:KNOWS]->(b:Person {name: 'Y'})")
print(run(ctx, "MATCH (a:Person {name: 'X'})-[:KNOWS]->(b:Person) RETURN b.name"))
```

```text
[['Y']]
```

## SET and REMOVE

`SET` assigns a property; `REMOVE` deletes one (or a label):

```python
run(ctx, "MATCH (n:Person {name: 'Neo'}) SET n.born = 1970")
run(ctx, "MATCH (n:Person {name: 'Neo'}) REMOVE n.born")
```

## MERGE (create-or-match)

`MERGE` creates the node if none matches, or reuses the matching one. Run it twice — the second
time is a no-op:

```python
run(ctx, "MERGE (n:Person {name: 'Zorg'})")
run(ctx, "MERGE (n:Person {name: 'Zorg'})")
print(run(ctx, "MATCH (n:Person {name: 'Zorg'}) RETURN count(n)"))
```

```text
[[1]]
```

`MERGE` can take `ON CREATE SET` and `ON MATCH SET`, which run on exactly one of the two paths:

```python
run(ctx, "MERGE (n:Person {name: 'Zorg'}) ON CREATE SET n.created = 1 ON MATCH SET n.seen = 1")
print(run(ctx, "MATCH (n:Person {name: 'Zorg'}) RETURN n.seen"))   # matched, so `seen` was set
```

```text
[[1]]
```

## DELETE

`DELETE` removes a node, but only if it has no edges left:

```python
run(ctx, "MATCH (n:Person {name: 'X'}) DELETE n")            # fails: X still has a KNOWS edge
run(ctx, "MATCH (n:Person {name: 'X'}) DETACH DELETE n")     # removes the edge too
print(run(ctx, "MATCH (n:Person {name: 'X'}) RETURN n.name"))
```

```text
[]
```

Next, [step 4](04-returning) shapes the result of a query.
