"""The acmedb `Database` object: open a graph, write data, run queries."""

from __future__ import annotations

import contextlib
import ctypes
import json
import math
import threading

from . import _ffi, entities
from .errors import AcmedbError, ClosedError, NodeNotFoundError, StorageError, error_from_code

# Value ranges the C ABI accepts; ctypes would silently truncate anything wider.
_I64_MIN, _I64_MAX = -(2**63), 2**63 - 1
_U64_MAX = 2**64 - 1
# `acmedb_allocate_node_id` returns this on failure.
_ALLOC_FAILED = _U64_MAX

# Mutator return codes (src/c_api.zig `RETURN_*`).
_RETURN_OK = 0
_RETURN_NODE_NOT_FOUND = 2


def _check_parameter(name: str, value):
    """Rejects values the engine cannot take, before they cross into C."""
    if value is None or isinstance(value, (bool, str)):
        return
    if isinstance(value, int):
        if not _I64_MIN <= value <= _I64_MAX:
            raise OverflowError(f"parameter {name!r}: {value} does not fit in 64 bits")
        return
    if isinstance(value, float):
        # JSON, which carries the parameters, has no NaN or infinity.
        if not math.isfinite(value):
            raise ValueError(f"parameter {name!r}: {value} is not a finite float")
        return
    if isinstance(value, (list, tuple)):
        for item in value:
            _check_parameter(name, item)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise TypeError(f"parameter {name!r}: map keys must be str, not {type(key).__name__}")
            _check_parameter(name, item)
        return
    raise TypeError(f"parameter {name!r}: {type(value).__name__} values are not supported")


def _encode_parameters(values: dict) -> bytes:
    for name, value in values.items():
        _check_parameter(name, value)
    return json.dumps(values).encode()


def _check_node_id(id: int) -> int:
    if isinstance(id, bool) or not isinstance(id, int):
        raise TypeError(f"node ids must be int, not {type(id).__name__}")
    if not 0 <= id < _U64_MAX:
        raise ValueError(f"node id {id} out of range [0, 2**64 - 1)")
    return id


def _raise_query_error(ctx) -> None:
    code = _ffi.lib.acmedb_error_code(ctx)
    n = ctypes.c_size_t()
    p = _ffi.lib.acmedb_last_error(ctx, ctypes.byref(n))
    message = ctypes.string_at(p, n.value).decode() if n.value else "query failed"
    raise error_from_code(code, message)


class Database:
    """A handle to one acmedb database (an LMDB environment at `path`).

    The directory must exist. Use it as a context manager to close on exit::

        with Database("/tmp/movies") as db:
            db.query("CREATE (n:Movie {title: 'The Matrix'})")
    """

    def __init__(self, path: str):
        self.path = path
        encoded = path.encode()
        self._ctx = _ffi.lib.acmedb_open(encoded, len(encoded))
        if not self._ctx:
            raise StorageError(f"could not open database at {path!r}")
        # The native context holds per-handle transaction state, so every call
        # into it is serialized. Reentrant, so a `write()` block can call the
        # mutators that themselves take the lock.
        self._lock = threading.RLock()
        self._in_write = False

    def close(self) -> None:
        with self._lock:
            if self._ctx:
                _ffi.lib.acmedb_close(self._ctx)
                self._ctx = None

    def _handle(self):
        """The native context; raises instead of passing NULL into the library."""
        if not self._ctx:
            raise ClosedError("database is closed")
        return self._ctx

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

        Parameter values may be `int` (64-bit), `str`, `bool`, `None`, and
        lists, tuples and dicts (with `str` keys) of those. Maps in results
        come back as dicts.

        Cells become `int`, `str`, `bool`, `None` (null), a `list`, or a whole
        :class:`Node` / :class:`Relationship`; rows are lists of cells. Raises a
        typed :class:`QueryError` subclass on failure.

        The whole result is read in one call (serialized to JSON), so a large
        result costs one FFI call plus a `json.loads`, not one call per cell.
        """
        encoded = text.encode()
        values = {**(parameters or {}), **named}
        encoded_parameters = _encode_parameters(values) if values else None
        with self._lock:
            ctx = self._handle()
            if self._in_write:
                raise AcmedbError("query() cannot run inside a write() block")
            if encoded_parameters is None:
                result = _ffi.lib.acmedb_query(ctx, encoded, len(encoded))
            else:
                result = _ffi.lib.acmedb_query_with_parameters(
                    ctx, encoded, len(encoded), encoded_parameters, len(encoded_parameters)
                )
            if not result:
                _raise_query_error(ctx)
            try:
                n = ctypes.c_size_t()
                p = _ffi.lib.acmedb_result_to_json(result, ctypes.byref(n))
                return json.loads(ctypes.string_at(p, n.value), object_hook=entities.decode)
            finally:
                _ffi.lib.acmedb_result_free(result)

    def export_graph(self) -> dict:
        """Return the whole graph, read straight from storage (not through the
        query engine)::

            {"nodes": [{"id": 0, "labels": ["Person"], "properties": {"name": "Ana"}}],
             "relationships": [{"source": 0, "target": 1, "type": "KNOWS", "properties": {}}]}

        Nodes come in id order. Reads one consistent snapshot; O(size of the graph).
        """
        with self._lock:
            n = ctypes.c_size_t()
            p = _ffi.lib.acmedb_export_json(self._handle(), ctypes.byref(n))
            if not p:
                raise StorageError("graph export failed")
            return json.loads(ctypes.string_at(p, n.value))

    # --- Writes --------------------------------------------------------------

    @contextlib.contextmanager
    def write(self):
        """Batch mutators into one write transaction (one fsync on exit).

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
            ctx = self._handle()
            if self._in_write:
                raise AcmedbError("write() blocks cannot be nested")
            self._check(_ffi.lib.acmedb_begin_write(ctx))
            self._in_write = True
            try:
                yield self
            except BaseException:
                _ffi.lib.acmedb_abort_write(ctx)
                raise
            else:
                self._check(_ffi.lib.acmedb_commit_write(ctx))
            finally:
                self._in_write = False

    def allocate_node_id(self) -> int:
        """Allocate a fresh, never-used node id."""
        with self._lock:
            nid = _ffi.lib.acmedb_allocate_node_id(self._handle())
        if nid == _ALLOC_FAILED:
            raise StorageError("could not allocate a node id")
        return nid

    def add_node(self, id: int, label: str = "") -> None:
        enc = label.encode()
        _check_node_id(id)
        with self._lock:
            self._check(_ffi.lib.acmedb_add_node(self._handle(), id, enc, len(enc)))

    def add_edge(self, src: int, dst: int, type: str) -> None:
        """Add a directed edge; both endpoints must already exist."""
        enc = type.encode()
        _check_node_id(src)
        _check_node_id(dst)
        with self._lock:
            self._check(_ffi.lib.acmedb_add_edge(self._handle(), src, dst, enc, len(enc)), src, dst)

    def set_property(self, id: int, name: str, value) -> None:
        """Set an `int` (64-bit signed), `float` or `str` property on an existing node."""
        _check_node_id(id)
        name_enc = name.encode()
        # bool is an int subclass, but booleans are not a storable type yet.
        if isinstance(value, bool) or not isinstance(value, (int, float, str)):
            raise TypeError(f"property values must be int, float or str, not {type(value).__name__}")
        if isinstance(value, int) and not _I64_MIN <= value <= _I64_MAX:
            raise OverflowError(f"int property {value} does not fit in 64 bits")
        with self._lock:
            ctx = self._handle()
            if isinstance(value, int):
                rc = _ffi.lib.acmedb_set_property_int64(ctx, id, name_enc, len(name_enc), value)
            elif isinstance(value, float):
                rc = _ffi.lib.acmedb_set_property_float64(ctx, id, name_enc, len(name_enc), value)
            else:
                enc = value.encode()
                rc = _ffi.lib.acmedb_set_property_string(ctx, id, name_enc, len(name_enc), enc, len(enc))
            self._check(rc, id)

    def _check(self, rc: int, *ids: int) -> None:
        if rc == _RETURN_NODE_NOT_FOUND:
            raise NodeNotFoundError(f"node does not exist (ids: {', '.join(map(str, ids))})")
        if rc != _RETURN_OK:
            raise StorageError("write failed")

