# 5. Aggregating

`count`, `sum`, `min`, `max` and `collect` reduce rows. Any projected expression that is *not* an
aggregation is an implicit grouping key.

*Using the `ctx` and graph from [step 1](01-getting-started).*

## Count

How many movies each person acted in — `p.name` groups, `count(m)` counts:

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) RETURN p.name, count(m)"))
```

```text
[['Keanu Reeves', 3], ['Carrie-Anne Moss', 1], ['Laurence Fishburne', 1], ['Tom Hanks', 1]]
```

`count(*)` counts every row of the group:

```python
print(run(ctx, "MATCH (p:Person) RETURN count(p)"))
```

```text
[[5]]
```

## min, max and sum

```python
print(run(ctx, "MATCH (m:Movie) RETURN min(m.released), max(m.released)"))
print(run(ctx, "MATCH (p:Person) RETURN sum(p.born)"))
```

```text
[[1994, 2014]]
[[9813]]
```

## Grouping by several keys

Each non-aggregated projection is a grouping key, so `p.name, m.released` groups by both:

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WHERE m.released >= 2000 RETURN m.released, count(p)"))
```

```text
[[2003, 1], [2014, 1]]
```

`collect` builds a list instead of a scalar — see [step 8](08-lists-strings).

Next, [step 6](06-pipelines) chains results through `WITH`.
