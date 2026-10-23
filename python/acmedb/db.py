"""The acmedb `Database` object: open a graph, write data, run queries."""

from __future__ import annotations

import contextlib
import os
import threading

from ._engine import native
from .errors import AcmedbError, ClosedError

_U64_MAX = 2**64 - 1

_DURABILITY = {"full": 0, "relaxed": 1, "deferred": 2}
_TEMPORALS = {"python": 0, "iso": 1}


def _check_node_id(id: int) -> int:
    if isinstance(id, bool) or not isinstance(id, int):
        raise TypeError(f"node ids must be int, not {type(id).__name__}")
    if not 0 <= id < _U64_MAX:
        raise ValueError(f"node id {id} out of range [0, 2**64 - 1)")
    return id


def _plan_tree(lines: list[list], parents: list) -> dict:
    """The plan's lines (`[depth, operator, details, estimated_rows, rows, time_ms]`) as a tree."""
    nodes = [
        {"operator": operator, "details": details, "estimated_rows": estimated, "rows": rows, "time_ms": time_ms, "children": []}
        for _, operator, details, estimated, rows, time_ms in lines
    ]
    root = nodes[0]
    for index, parent in enumerate(parents):
        if parent is None:
            continue
        # An operator's input is at its own depth, and goes first; the chains
        # it runs are one level deeper.
        children = nodes[parent]["children"]
        if lines[index][0] == lines[parent][0]:
            children.insert(0, nodes[index])
        else:
            children.append(nodes[index])
    return root


class Database:
    """A handle to one acmedb database (a storage-engine environment in directory `path`).

    The directory must exist. Use it as a context manager to close on exit::

        with Database("/tmp/movies") as db:
            db.query("CREATE (n:Movie {title: 'The Matrix'})")
    """

    def __init__(self, path: str, durability: str = "full", temporals: str = "python", import_directory: str | None = None):
        """Opens (or creates) the database in directory `path`.

        `durability` is how much a commit waits for the disk: "full" (each
        commit is on disk when it returns), "relaxed" (a power failure can lose
        the last commit, never corrupt the database) or "deferred" (commits are
        written by the operating system or by `sync()`; a power failure can lose
        the recent ones, hundreds of times faster for many small writes).
        With the libmdbx engine, processes that have the database open at
        once must agree on "deferred": one cannot open it "deferred" while
        another has it open "full" or "relaxed", nor the reverse.

        `temporals` is how query results return dates, times and durations:
        "python" as `datetime`-module values (microsecond precision, years
        1-9999), or "iso" as their exact ISO 8601 text.

        `import_directory` is the directory LOAD CSV reads from: a query's
        `file:///name.csv` is `name.csv` in it, and nothing outside it can be
        read. Without one, LOAD CSV is off.
        """
        if durability not in _DURABILITY:
            raise ValueError(f"durability must be one of {', '.join(_DURABILITY)}, not {durability!r}")
        self.path = path
        os.makedirs(path, exist_ok=True)
        if temporals not in _TEMPORALS:
            raise ValueError(f"temporals must be one of {', '.join(_TEMPORALS)}, not {temporals!r}")
        self._db = native.open(path, _DURABILITY[durability], _TEMPORALS[temporals])
        if import_directory is not None:
            if not os.path.isdir(import_directory):
                native.close(self._db)
                raise ValueError(f"import_directory {import_directory!r} is not a directory")
            native.set_import_directory(self._db, os.path.abspath(import_directory))
        # The native context holds per-handle transaction state, so every call
        # into it is serialized. Reentrant, so a `write()` block can call the
        # mutators that themselves take the lock.
        self._lock = threading.RLock()
        self._in_write = False

    def sync(self) -> None:
        """Writes every commit so far to disk (for "deferred" durability)."""
        with self._lock:
            native.sync(self._handle())

    def close(self) -> None:
        with self._lock:
            if self._db is not None:
                native.close(self._db)
                self._db = None

    def _handle(self):
        """The native database; raises instead of using a closed one."""
        if self._db is None:
            raise ClosedError("database is closed")
        return self._db

    def __enter__(self) -> "Database":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # --- Querying ------------------------------------------------------------

    def query(self, text: str, parameters: dict | None = None, /, **named) -> list[list]:
        """Run one openCypher query and return the rows as Python values.

        Query parameters (`$name` in the query) come as a dict, as keyword
        arguments, or both::

            db.query("MATCH (c:Card {id: $card}) RETURN c", card=123)
            db.query("MATCH (z:Zone) WHERE z.name IN $zones RETURN z", {"zones": ["A", "B"]})

        Parameter values may be `int` (64-bit), `float`, `str`, `bool`, `None`,
        lists, tuples and dicts (with `str` keys) of those, and temporal values
        (`datetime.date`, `time`, `datetime`, `timedelta`, or acmedb's own).

        Cells become `int`, `float`, `str`, `bool`, `None` (null), a `list`, a
        `dict`, a whole :class:`Node` / :class:`Relationship` / :class:`Path`,
        or a temporal value; rows are lists of cells. Raises a typed
        :class:`QueryError` subclass on failure. The query runs with the GIL
        released, so other threads go on meanwhile.
        """
        values = {**parameters, **named} if parameters else named
        with self._lock:
            db = self._handle()
            if self._in_write:
                raise AcmedbError("query() cannot run inside a write() block")
            return native.query(db, text, values)

    def explain(self, text: str, parameters: dict | None = None, /, **named) -> dict:
        """Return the plan of a query, without running it, as a tree of operators.

        Each operator is a dict: ``operator`` (its name), ``details`` (what it
        works on, as Cypher), ``estimated_rows`` (how many rows it makes per
        run of its chain, a guess from the label and relationship-type counts;
        None when they say nothing), ``rows`` and ``time_ms`` (None here; see
        :meth:`profile`) and ``children``: the operator whose rows it gets
        first, then the chains it runs (an OPTIONAL MATCH's, a subquery's, a
        pattern's inside an expression)::

            plan = db.explain("MATCH (p:Person {id: $id})-[:KNOWS]->(f) RETURN f.name", id=1)
            plan["operator"]                 # 'Return'
            plan["children"][0]["operator"]  # 'Expand(All)'

        The same plan as rows comes from ``db.query("EXPLAIN " + text)``.
        """
        values = {**parameters, **named} if parameters else named
        with self._lock:
            db = self._handle()
            if self._in_write:
                raise AcmedbError("explain() cannot run inside a write() block")
            _, lines, parents = native.plan(db, "EXPLAIN " + text, values)
        return _plan_tree(lines, parents)

    def profile(self, text: str, parameters: dict | None = None, /, **named) -> tuple[list[list], dict]:
        """Run a query and return its rows and its plan, with what each operator did.

        The plan is the tree :meth:`explain` returns, with ``rows`` (how many
        rows each operator made) and ``time_ms`` (the time spent in the
        operator itself, in milliseconds) filled in. The query runs as
        :meth:`query` runs it: its writes commit. ``db.query("PROFILE " +
        text)`` gives the plan as rows, without the query's own.
        """
        values = {**parameters, **named} if parameters else named
        with self._lock:
            db = self._handle()
            if self._in_write:
                raise AcmedbError("profile() cannot run inside a write() block")
            rows, lines, parents = native.plan(db, "PROFILE " + text, values)
        return rows, _plan_tree(lines, parents)

    def export_graph(self) -> dict:
        """Return the whole graph, read straight from storage (not through the
        query engine)::

            {"nodes": [{"id": 0, "labels": ["Person"], "properties": {"name": "Ana"}}],
             "relationships": [{"id": 0, "source": 0, "target": 1, "type": "KNOWS", "properties": {}}]}

        Nodes come in id order. Reads one consistent snapshot; O(size of the graph).
        """
        with self._lock:
            return native.export_graph(self._handle())

    def _define_procedure(self, name: str, arguments: list, columns: list, rows: list) -> None:
        """For the openCypher TCK: a procedure, for this open database only,
        whose rows are a table. ``arguments`` and ``columns`` are ``(name,
        type)`` pairs (``("in", "INTEGER?")``); each row has a value per
        argument, then per column. A call emits the rows whose arguments
        equal its own."""
        with self._lock:
            native.define_procedure(self._handle(), name, list(arguments), list(columns), [list(row) for row in rows])

    # --- Writes --------------------------------------------------------------

    @contextlib.contextmanager
    def write(self):
        """Batch mutators into one write transaction (one commit on exit).

        Every `add_node`/`add_edge`/`set_property`/`allocate_node_id` inside the block
        commits atomically when the block exits; an exception aborts it::

            with db.write():
                for i in range(100_000):
                    nid = db.allocate_node_id()
                    db.add_node(nid, "Person")
                    db.set_property(nid, "name", f"p{i}")

        This is the bulk-ingestion path (one sync instead of one per write). Do
        not run `query()` inside the block — reads use their own transaction.
        """
        with self._lock:
            db = self._handle()
            if self._in_write:
                raise AcmedbError("write() blocks cannot be nested")
            native.begin_write(db)
            self._in_write = True
            try:
                yield self
            except BaseException:
                native.abort_write(db)
                raise
            else:
                native.commit_write(db)
            finally:
                self._in_write = False

    def allocate_node_id(self) -> int:
        """Allocate a fresh, never-used node id."""
        with self._lock:
            return native.allocate_node_id(self._handle())

    def add_node(self, id: int, label: str = "") -> None:
        _check_node_id(id)
        with self._lock:
            native.add_node(self._handle(), id, label)

    def add_edge(self, src: int, dst: int, type: str) -> int:
        """Add a directed relationship and return its id; both endpoints must
        already exist. Each call adds one, even between nodes already joined
        by a relationship of that type."""
        _check_node_id(src)
        _check_node_id(dst)
        with self._lock:
            return native.add_edge(self._handle(), src, dst, type)

    def set_property(self, id: int, name: str, value) -> None:
        """Set a property on an existing node: any value a query can store
        (numbers, `str`, `bool`, temporal values, lists of one type, and dicts
        as documents). `None` removes the property."""
        _check_node_id(id)
        with self._lock:
            native.set_property(self._handle(), id, name, value)
