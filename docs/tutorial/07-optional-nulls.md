# 7. OPTIONAL MATCH and nulls

`MATCH` *requires* a match — a person with no movie simply produces no row. `OPTIONAL MATCH`
outer-joins instead: the person still appears, with the unmatched parts bound to `null`.

*Using the `ctx` and graph from [step 1](01-getting-started).*

## The outer join

Lana directed movies but acted in none, so a plain `MATCH` drops her:

```python
print(run(ctx, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) RETURN p.name, m.title"))
```

```text
[['Keanu Reeves', 'The Matrix'], ['Keanu Reeves', 'The Matrix Reloaded'], ['Keanu Reeves', 'John Wick'],
 ['Carrie-Anne Moss', 'The Matrix'], ['Laurence Fishburne', 'The Matrix'], ['Tom Hanks', 'Forrest Gump'],
 ['Lana Wachowski', None]]
```

Everyone appears — Lana once, with `None` where `m.title` would be.

## Count with nulls

Aggregations skip nulls, so `count(m)` is `0` for a person with no match:

```python
print(run(ctx, "MATCH (p:Person) OPTIONAL MATCH (p)-[:DIRECTED]->(m:Movie) RETURN p.name, count(m)"))
```

```text
[['Keanu Reeves', 0], ['Carrie-Anne Moss', 0], ['Laurence Fishburne', 0], ['Tom Hanks', 0], ['Lana Wachowski', 2]]
```

## Nulls in expressions

A null propagates: `null >= 2010` is `null`, and a null `WHERE` filters the row out. So filtering
after the join drops the null rows:

```python
print(run(ctx, "MATCH (p:Person) OPTIONAL MATCH (p)-[:ACTED_IN]->(m:Movie) WITH p, m WHERE m.released >= 2010 RETURN p.name, m.title"))
```

```text
[['Keanu Reeves', 'John Wick']]
```

(A `WHERE` *inside* `OPTIONAL MATCH`, by contrast, still yields one null row per person whose
matches are all filtered out.)

Next, [step 8](08-lists-strings) covers lists and string predicates.
