# 6. Pipelines: WITH and UNWIND

`WITH` projects the current rows (with grouping and aggregation, like `RETURN`) and continues the
pipeline; `UNWIND` turns a list into one row per element.

*Using the `ctx` and graph from [step 1](01-getting-started).*

## Filter on an aggregate

The classic `WITH` use: aggregate, then filter on the result — impossible to express in a single
`RETURN`:

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 RETURN p.name, cnt"))
```

```text
[['Keanu Reeves', 3]]
```

`WITH p, count(m) AS cnt` groups by `p` and binds `cnt`; the `WHERE` then drops every actor with
one movie.

## Continue matching after WITH

`WITH` can hand off to another `MATCH`. Here we find prolific actors, then follow them again:

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie) WITH p, count(m) AS cnt WHERE cnt > 1 MATCH (p)-[:ACTED_IN]->(m2:Movie) RETURN m2.title"))
```

```text
[['The Matrix'], ['The Matrix Reloaded'], ['John Wick']]
```

## Paginate mid-query

`WITH` also takes `ORDER BY`, `SKIP` and `LIMIT`:

```python
print(run(ctx, "MATCH (p:Person) WITH p ORDER BY p.name SKIP 1 LIMIT 2 RETURN p.name"))
```

```text
[['Keanu Reeves'], ['Lana Wachowski']]
```

## UNWIND

`UNWIND [1, 2, 3] AS x` emits one row per element:

```python
print(run(ctx, "UNWIND [1, 2, 3] AS x RETURN x"))
```

```text
[[1], [2], [3]]
```

Next, [step 7](07-optional-nulls) handles the case where a match finds nothing.
