# 8. Lists, strings and CASE

Lists (`collect`, `size`, literals), string predicates, and the `CASE` expression round out the
query language.

*Using the `ctx` and graph from [step 1](01-getting-started).*

## collect

`collect` aggregates a group into a list:

```python
print(run(ctx, "MATCH (m:Movie) RETURN collect(m.title)"))
```

```text
[['The Matrix', 'The Matrix Reloaded', 'John Wick', 'Forrest Gump']]
```

`size` measures a list — or a string:

```python
print(run(ctx, "MATCH (m:Movie) WITH collect(m.title) AS titles RETURN size(titles)"))
print(run(ctx, "MATCH (p:Person {name: 'Keanu Reeves'}) RETURN size(p.name)"))
```

```text
[[4]]
[[12]]
```

## String predicates

```python
print(run(ctx, "MATCH (m:Movie) WHERE m.title STARTS WITH 'The' RETURN m.title"))
print(run(ctx, "MATCH (m:Movie) WHERE m.title ENDS WITH 'Wick' RETURN m.title"))
print(run(ctx, "MATCH (m:Movie) WHERE m.title CONTAINS 'Matrix' RETURN m.title"))
```

```text
[['The Matrix'], ['The Matrix Reloaded']]
[['John Wick']]
[['The Matrix'], ['The Matrix Reloaded']]
```

## IN

```python
print(run(ctx, "MATCH (p:Person) WHERE p.name IN ['Keanu Reeves', 'Tom Hanks'] RETURN p.name"))
```

```text
[['Keanu Reeves'], ['Tom Hanks']]
```

## CASE

```python
print(run(ctx, "MATCH (m:Movie) RETURN m.title, CASE WHEN m.released >= 2000 THEN 'new' ELSE 'old' END"))
```

```text
[['The Matrix', 'old'], ['The Matrix Reloaded', 'new'], ['John Wick', 'new'], ['Forrest Gump', 'old']]
```

That is the whole language. For the reference, see [the openCypher subset](../guide/cypher); for how
it works inside, [the architecture](../guide/architecture).
