"""The ZypherDB `Database` object: open a graph, write data, run queries."""

from __future__ import annotations

import contextlib
import json
import os
import threading
import time
import weakref

from ._engine import native
from .errors import ZypherDBError, ClosedError
from .rows import Rows

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


class _Session:
    """A thread's native session on the database."""

    __slots__ = ("handle", "in_write", "depth", "__weakref__")

    def __init__(self, handle):
        self.handle = handle
        self.in_write = False
        self.depth = 0  # calls under way, one within another (a write block's)


class _Calls:
    """The calls under way into a database, each through its thread's
    session: ``with calls as session:``. `close` waits for them; the lock is
    held only to count them, never during a call."""

    def __init__(self, handle):
        self._handle = handle  # the opening thread's session: it holds the database open
        self._local = threading.local()
        self._local.session = _Session(handle)
        self._sessions = weakref.WeakSet([self._local.session])
        self._count = 0
        self._ended = threading.Condition(threading.Lock())
        self._closed = False

    def __enter__(self) -> _Session:
        session = getattr(self._local, "session", None)
        with self._ended:
            # A call within one under way goes on while closing: close waits for both.
            if self._closed and (session is None or not session.depth):
                raise ClosedError("database is closed")
            self._count += 1
        if session is None:
            try:
                session = _Session(native.open_session(self._handle))
            except BaseException:
                self._end()
                raise
            self._local.session = session
            with self._ended:
                self._sessions.add(session)
        session.depth += 1
        return session

    def __exit__(self, *exc) -> None:
        self._local.session.depth -= 1
        self._end()

    def _end(self) -> None:
        with self._ended:
            self._count -= 1
            if not self._count:
                self._ended.notify_all()

    def close(self) -> None:
        session = getattr(self._local, "session", None)
        if session is not None and session.in_write:
            raise ZypherDBError("close() cannot run inside a write() block")
        with self._ended:
            if self._closed:
                return
            self._closed = True
            while self._count:
                self._ended.wait()
            sessions = list(self._sessions)
        # Each thread's session; a thread gone took its own along.
        for session in sessions:
            if session.handle is not self._handle:
                native.close(session.handle)
        native.close(self._handle)


class PreparedQuery:
    """A query prepared by :meth:`Database.prepare`: run it with :meth:`query`."""

    def __init__(self, database: "Database", text: str):
        self._database = database
        self.text = text
        # A statement per thread: running one replans it when the graph changed.
        self._statements = threading.local()
        with database._calls as session:
            self._statements.statement, self.parameters, self.columns = native.prepare(session.handle, text)

    def query(self, parameters: dict | None = None, /, **named) -> Rows:
        """Run the query with these parameters; the rows are as :meth:`Database.query` returns them."""
        values = {**parameters, **named} if parameters else named
        database = self._database
        with database._calls as session:
            if session.in_write:
                raise ZypherDBError("query() cannot run inside a write() block")
            statement = getattr(self._statements, "statement", None)
            if statement is None:
                statement = self._statements.statement = native.prepare(session.handle, self.text)[0]
            result = native.statement_query(session.handle, statement, values)
            if type(result) is Rows:
                return result
            return database._forward(session, result)

    def __repr__(self) -> str:
        return f"PreparedQuery({self.text!r})"


class Database:
    """A handle to one ZypherDB database (a storage-engine environment in directory `path`).

    The directory must exist. Use it as a context manager to close on exit::

        with Database("/tmp/movies") as db:
            db.query("CREATE (n:Movie {title: 'The Matrix'})")
    """

    def __init__(
        self,
        path: str,
        durability: str = "full",
        temporals: str = "python",
        import_directory: str | None = None,
        serve: str | None = None,
        replicate_from: str | None = None,
        token: str | None = None,
        name: str | None = None,
        forward_writes: bool = False,
        forward_timeout: float = 30.0,
        encrypted: bool = True,
    ):
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

        `serve` makes the database a master that serves replicas at that
        address ("host:port", the host an IP address or a name; "0.0.0.0:7000"
        for every interface).
        `replicate_from` makes it a replica of the master at that address: it
        gets a copy of the master's database, then each change committed
        there, reconnecting on its own, and refuses writes. Either needs
        `token`, the secret master and replicas share. The conversation is
        encrypted with it, and it never travels, so it must be hard to guess.
        `encrypted=False`, on the master and on its replicas alike, sends the
        token and the data in clear: only on a trusted network or a tunnel.
        While another process runs replication on the
        database this one stands by, and takes over when that one closes it or
        dies; give a master a fixed port so its replicas find whichever runs.
        `name` is what a replica calls itself in its master's status (at
        most 255 bytes in UTF-8; by default the host's name).

        `forward_writes` makes a replica send the statements that write to its
        master instead of refusing them; each takes at most `forward_timeout`
        seconds, from sending it to having applied what it wrote here.
        """
        if durability not in _DURABILITY:
            raise ValueError(f"durability must be one of {', '.join(_DURABILITY)}, not {durability!r}")
        self.path = path
        os.makedirs(path, exist_ok=True)
        if temporals not in _TEMPORALS:
            raise ValueError(f"temporals must be one of {', '.join(_TEMPORALS)}, not {temporals!r}")
        if serve is not None and replicate_from is not None:
            raise ValueError("a database either serves replicas or replicates from a master, not both")
        role = (0, serve) if serve is not None else (1, replicate_from) if replicate_from is not None else None
        if role is not None and not token:
            raise ValueError("replication needs a token")
        if name is not None and replicate_from is None:
            raise ValueError("only a replica has a name")
        if forward_writes and replicate_from is None:
            raise ValueError("only a replica forwards writes")
        if not forward_timeout > 0:
            raise ValueError("forward_timeout must be positive")
        self._db = native.open(path, _DURABILITY[durability], _TEMPORALS[temporals])
        if role is not None:
            try:
                native.start_replication(self._db, path, role[0], role[1], token, name, forward_writes, max(1, round(forward_timeout * 1000)), encrypted)
            except BaseException:
                native.close(self._db)
                raise
        if import_directory is not None:
            if not os.path.isdir(import_directory):
                native.close(self._db)
                raise ValueError(f"import_directory {import_directory!r} is not a directory")
            native.set_import_directory(self._db, os.path.abspath(import_directory))
        # A native session holds its thread's transaction state: each thread
        # calls through a session of its own, so threads hold up no one but
        # a write waits for the write under way.
        self._calls = _Calls(self._db)

    def sync(self) -> None:
        """Writes every commit so far to disk (for "deferred" durability)."""
        with self._calls as session:
            native.sync(session.handle)

    # --- Replication ---------------------------------------------------------

    @property
    def last_lsn(self) -> int:
        """The number (LSN) of the last change this database has.

        On a master, the last write committed: read it after a write and pass
        it to a replica's `wait_for` to read that write there. On a replica,
        the last change applied. Also in a process that opened the database
        without a role; 0 on a database that is neither.
        """
        with self._calls as session:
            return native.last_lsn(session.handle)

    def wait_for(self, lsn: int, timeout: float = 5.0) -> bool:
        """Waits until the master's change `lsn` is applied here, at most
        `timeout` seconds; returns whether it is.

        A replica runs behind its master by the time a change takes to
        arrive. To read on a replica a write just made on the master, take
        the master's `last_lsn` after the write and call this on the replica
        before reading, also in a process that opened the replica without a
        role. True at once on a database that is no replica.
        """
        if lsn < 0 or timeout < 0:
            raise ValueError("lsn and timeout must not be negative")
        with self._calls as session:
            return native.wait_for(session.handle, lsn, int(timeout * 1000))

    def replication_status(self) -> dict | None:
        """How replication goes, for monitoring; None without replication.

        A master::

            {"role": "master", "standby": False, "address": "0.0.0.0:7000", "last_lsn": 120,
             "replicas": [{"name": "eu-1", "address": "10.0.0.7:51234", "connected_ms": 86400000,
                           "phase": "streaming", "acked_lsn": 118, "lag": 2}]}

        Each replica's `name` is the one it gave (its host's by default),
        `address` where it connected from, `connected_ms` how long ago.
        `phase` is "introducing", "copying" (a copy of the database is made,
        sent or loaded) or "streaming"; `lag` is how many changes the replica
        has yet to apply, as it last told. A replica::

            {"role": "replica", "standby": False, "name": "eu-1", "master_address": "10.0.0.5:7000",
             "phase": "streaming", "last_contact_ms": 120, "applied_lsn": 118, "master_lsn": 120,
             "lag": 2, "master_unresolved": False, "last_refusal": None, "halted": None}

        Its `phase` is "connecting" (also while waiting to connect again, and
        while standing by), "copying", "streaming" or "halted";
        `last_contact_ms` is how long ago its master was last heard from
        (None if never).

        `standby` is True in a process that opened the database with a role
        while another process runs replication on it: it takes over when
        that one closes the database or dies. `halted` names why the replica stopped following for good (e.g.
        "database_id": it is a replica of another master); `last_refusal` why
        the master last turned it away (e.g. "token": it holds another token,
        and the replica keeps asking); `master_unresolved` whether its last
        try found no address for the master's host name.
        """
        with self._calls as session:
            text = native.replication_status(session.handle)
        return None if text is None else json.loads(text)

    def close(self) -> None:
        """Closes the database once the calls of other threads under way end;
        later calls raise :class:`ClosedError`."""
        self._calls.close()

    def __enter__(self) -> "Database":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    # --- Querying ------------------------------------------------------------

    def query(self, text: str, parameters: dict | None = None, /, **named) -> Rows:
        """Run one openCypher query and return the rows as Python values.

        Query parameters (`$name` in the query) come as a dict, as keyword
        arguments, or both::

            db.query("MATCH (c:Card {id: $card}) RETURN c", card=123)
            db.query("MATCH (z:Zone) WHERE z.name IN $zones RETURN z", {"zones": ["A", "B"]})

        Parameter values may be `int` (64-bit), `float`, `str`, `bool`, `None`,
        lists, tuples and dicts (with `str` keys) of those, and temporal values
        (`datetime.date`, `time`, `datetime`, `timedelta`, or ZypherDB's own).

        Cells become `int`, `float`, `str`, `bool`, `None` (null), a `list`, a
        `dict`, a whole :class:`Node` / :class:`Relationship` / :class:`Path`,
        or a temporal value; rows are lists of cells, in a :class:`Rows` (a
        list; on a replica that forwards writes, see its `visible`). Raises a typed
        :class:`QueryError` subclass on failure. The query runs with the GIL
        released, so other threads go on meanwhile.
        """
        values = {**parameters, **named} if parameters else named
        with self._calls as session:
            if session.in_write:
                raise ZypherDBError("query() cannot run inside a write() block")
            result = native.query(session.handle, text, values)
            if type(result) is Rows:
                return result
            return self._forward(session, result)

    def write_many(self, statements) -> list[Rows]:
        """Run several queries in one transaction and return the rows of each.

        Each item is a query's text, or its text and parameters::

            doors, counted = db.write_many([
                ("CREATE (d:Door {name: $name}) RETURN d", {"name": "B7"}),
                "MATCH (d:Door) RETURN count(d)",
            ])

        They run in order, each seeing what the ones before it wrote, and
        commit together: if one fails, none does, and the :class:`QueryError`
        raised has its index in ``statement`` (None when no query failed: the
        commit did). On a replica that forwards writes, a batch that writes
        goes to the master as one request. A batch holds no schema command,
        EXPLAIN, PROFILE, LOAD CSV or procedure from `define_procedure`.
        """
        pairs = []
        for statement in statements:
            if isinstance(statement, str):
                pairs.append((statement, None))
            else:
                text, parameters = statement
                pairs.append((text, parameters))
        if not pairs:
            return []
        with self._calls as session:
            if session.in_write:
                raise ZypherDBError("write_many() cannot run inside a write() block")
            results = native.write_many(session.handle, pairs)
            if type(results) is list:
                return results
            return self._forward(session, results, native.forward_results)

    def _forward(self, session: "_Session", pending, results=native.forward_rows):
        """Sends a write (or a batch, `results` then `native.forward_results`)
        to the master and returns its rows once this replica has it: only the
        thread that wrote waits."""
        lsn, visible, left_ms = native.forward_send(pending)
        if visible is None:  # standing by: no follower to wait on here
            visible = self._applied(session, lsn, left_ms / 1000)
        return results(pending, visible)

    def _applied(self, session: "_Session", lsn: int, timeout: float) -> bool:
        """Whether this replica applies change `lsn` within `timeout` seconds,
        looking every millisecond."""
        deadline = time.monotonic() + timeout
        while True:
            if native.last_lsn(session.handle) >= lsn:
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.001)

    def prepare(self, text: str) -> "PreparedQuery":
        """Parse, check and plan a query once, to run it again and again with new parameters.

        ::

            lookup = db.prepare("MATCH (c:Card {number: $number}) RETURN c.holder")
            lookup.query(number=123)
            lookup.parameters   # ('number',)
            lookup.columns      # ('c.holder',)

        `query` keeps the queries it prepares too, by their text (the 64 used
        most recently), so a query run again is not planned again; `prepare`
        saves the lookup and keeps the statement as long as the object lives.
        Either way, a plan is made again when the graph's label or
        relationship-type counts it was made on have changed a lot.
        """
        return PreparedQuery(self, text)

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
        with self._calls as session:
            if session.in_write:
                raise ZypherDBError("explain() cannot run inside a write() block")
            _, lines, parents = native.plan(session.handle, "EXPLAIN " + text, values)
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
        with self._calls as session:
            if session.in_write:
                raise ZypherDBError("profile() cannot run inside a write() block")
            rows, lines, parents = native.plan(session.handle, "PROFILE " + text, values)
        return rows, _plan_tree(lines, parents)

    def export_graph(self) -> dict:
        """Return the whole graph, read straight from storage (not through the
        query engine)::

            {"nodes": [{"id": 0, "labels": ["Person"], "properties": {"name": "Ana"}}],
             "relationships": [{"id": 0, "source": 0, "target": 1, "type": "KNOWS", "properties": {}}]}

        Nodes come in id order. Reads one consistent snapshot; O(size of the graph).
        """
        with self._calls as session:
            return native.export_graph(session.handle)

    def check(self) -> dict:
        """Check that every index and counter agrees with the stored records.

        **A diagnostic, not a routine call.** Use it when you suspect ZypherDB
        itself has a bug (a query that misses nodes it should find, counts
        that do not add up), after a crash if you want to be sure, or to
        attach its output to a bug report. It reads the whole database and
        holds memory in proportion to it, so it is slow on a large one; it
        repairs nothing. Returns::

            {"ok": True, "problem_count": 0, "problems": []}

        ``problems`` describes the first 32 problems found.
        """
        with self._calls as session:
            return native.check(session.handle)

    def _define_procedure(self, name: str, arguments: list, columns: list, rows: list) -> None:
        """For the openCypher TCK: a procedure, for this open database only,
        whose rows are a table. ``arguments`` and ``columns`` are ``(name,
        type)`` pairs (``("in", "INTEGER?")``); each row has a value per
        argument, then per column. A call emits the rows whose arguments
        equal its own."""
        with self._calls as session:
            native.define_procedure(session.handle, name, list(arguments), list(columns), [list(row) for row in rows])

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
        with self._calls as session:
            if session.in_write:
                raise ZypherDBError("write() blocks cannot be nested")
            native.begin_write(session.handle)
            session.in_write = True
            try:
                yield self
            except BaseException:
                native.abort_write(session.handle)
                raise
            else:
                native.commit_write(session.handle)
            finally:
                session.in_write = False

    def allocate_node_id(self) -> int:
        """Allocate a fresh, never-used node id."""
        with self._calls as session:
            return native.allocate_node_id(session.handle)

    def add_node(self, id: int, label: str = "") -> None:
        _check_node_id(id)
        with self._calls as session:
            native.add_node(session.handle, id, label)

    def add_edge(self, src: int, dst: int, type: str) -> int:
        """Add a directed relationship and return its id; both endpoints must
        already exist. Each call adds one, even between nodes already joined
        by a relationship of that type."""
        _check_node_id(src)
        _check_node_id(dst)
        with self._calls as session:
            return native.add_edge(session.handle, src, dst, type)

    def set_property(self, id: int, name: str, value) -> None:
        """Set a property on an existing node: any value a query can store
        (numbers, `str`, `bool`, temporal values, lists of one type, and dicts
        as documents). `None` removes the property."""
        _check_node_id(id)
        with self._calls as session:
            native.set_property(session.handle, id, name, value)
