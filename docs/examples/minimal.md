# The smallest program

`examples/minimal/run.py` is the least a program needs to use ZypherDB: open a database, store a
small graph, and ask it a question with a parameter.

```{literalinclude} ../../examples/minimal/run.py
:language: python
:start-at: import tempfile
```

Run it from the repository root, with the package installed (`pip install zypherdb`) or built from
source (`make python`, then `PYTHONPATH=python`):

```bash
python -m examples.minimal.run
```

```text
BSL-3 Lab: Ada Okafor, Dalia Haddad
```

- `zypherdb.Database(path)` opens the database in that directory, creating it if needed, and the
  `with` block closes it. Here the directory is temporary, so the data is gone at the end; give it
  a lasting path to keep it.
- One `CREATE` stores five nodes and three relationships, in one transaction.
- `$room` is a parameter, passed as a keyword argument. Values never go into the query text.
- `query` returns a list of rows, each a list of values: here one row, with a string and a list.

The [tutorial](../tutorial/01-getting-started) starts from here.
