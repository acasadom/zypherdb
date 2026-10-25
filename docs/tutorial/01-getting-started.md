# 1. Your first database

Over this tutorial we build the access-control system of **Helix Biolabs**, a biomedical research
lab where security is not optional: who may enter which room, at what time, with which training,
and — at every moment — who is where. Each step adds one capability of ZypherDB and grows the same
database, from an empty directory to a working door controller and an alarm monitor.

This first step installs ZypherDB, opens a database, stores the lab's first building and its first
employee, and reads them back.

## Install

```bash
pip install zypherdb
```

ZypherDB is an embedded database: there is no server to start. The package carries the engine as a
native extension module and needs Python 3.10 or later. (To build it from a source checkout
instead, see [contributing](../guide/contributing).)

## Open a database

A database lives in a directory. Opening one that does not exist yet creates it:

```python
from zypherdb import Database

db = Database("helix")
```

`db` stays open for the whole tutorial: every page continues the same session. When you are done
with a database, `db.close()` releases it; `with Database(...) as db:` closes it for you.

## Store something

Data is written and read with **openCypher**, the query language of graph databases. A graph is
made of **nodes** — things — and **relationships** between them. Let us create the lab's main
building and one employee:

```python
db.query("CREATE (:Building {name: 'North Wing'})")
db.query("CREATE (:Person {name: 'Ada Okafor', role: 'Biosafety officer'})")
```

Read `(:Building {name: 'North Wing'})` as *a node with the label `Building` and a property `name`
whose value is `'North Wing'`*. Labels say what a node is; properties hold its data.

## Ask for it

`MATCH` finds the nodes that fit a pattern, and `RETURN` says what to give back:

```python
rows = db.query("MATCH (p:Person) RETURN p.name, p.role")
print(rows)
```

```text
[['Ada Okafor', 'Biosafety officer']]
```

A query returns a list of rows; each row is a list with one value per item of the `RETURN`.
Here: one person, two columns. `p` is a **variable**: `MATCH (p:Person)` binds it to every node
with the label `Person`, and `p.name` reads a property of the node it is bound to.

Every value comes back as a plain Python value. Numbers are `int` or `float`, text is `str`:

```python
for name, role in db.query("MATCH (p:Person) RETURN p.name, p.role"):
    print(f"{name} works here as {role.lower()}")
```

```text
Ada Okafor works here as biosafety officer
```

## Where the data went

Everything you wrote is in the `helix` directory, on disk. A query that writes is a transaction of
its own: when `db.query` returns, the data is stored, and it survives the process. Open the
database again — from another script, or after a restart — and it is all there.

In [the next step](02-nodes) we give the lab its people: employees, contractors and visitors, and
the kinds of values a node can hold.
