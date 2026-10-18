# 4. Returning

`RETURN` projects the result. It supports aliases, `DISTINCT`, `ORDER BY`, `SKIP` and `LIMIT`.

*Using the `ctx` and graph from [step 1](01-getting-started).*

## Aliases

```python
print(run(ctx, "MATCH (m:Movie) RETURN m.title AS movie"))
```

```text
[['The Matrix'], ['The Matrix Reloaded'], ['John Wick'], ['Forrest Gump']]
```

## ORDER BY

Sort by any expression, ascending or descending:

```python
print(run(ctx, "MATCH (m:Movie) RETURN m.title ORDER BY m.released"))
```

```text
[['Forrest Gump'], ['The Matrix'], ['The Matrix Reloaded'], ['John Wick']]
```

```python
print(run(ctx, "MATCH (m:Movie) RETURN m.title ORDER BY m.released DESC"))
```

```text
[['John Wick'], ['The Matrix Reloaded'], ['The Matrix'], ['Forrest Gump']]
```

## SKIP and LIMIT

Pagination, applied after `ORDER BY`:

```python
print(run(ctx, "MATCH (m:Movie) RETURN m.title ORDER BY m.released SKIP 1 LIMIT 2"))
```

```text
[['The Matrix'], ['The Matrix Reloaded']]
```

## DISTINCT

Collapse duplicate rows:

```python
print(run(ctx, "MATCH (p:Person)-[:ACTED_IN]->(m:Movie {title: 'The Matrix'}) RETURN DISTINCT m.title"))
```

```text
[['The Matrix']]
```

Three actors starred in `The Matrix`; without `DISTINCT` the title would appear three times.

Next, [step 5](05-aggregating) groups and reduces those rows.
