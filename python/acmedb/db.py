"""The acmedb `Database` object: open a graph, write data, run queries."""

from __future__ import annotations

import contextlib
import ctypes
import json
import threading

from . import _ffi
from .errors import AcmedbError, ClosedError, NodeNotFoundError, StorageError, error_from_code

# Value ranges the C ABI accepts; ctypes would silently truncate anything wider.
_I64_MIN, _I64_MAX = -(2**63), 2**63 - 1
_U64_MAX = 2**64 - 1
# `acmedb_alloc_node_id` returns this on failure.
_ALLOC_FAILED = _U64_MAX

# Mutator return codes (src/capi.zig `RC_*`).
_RC_OK = 0
_RC_NO_NODE = 2


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

    def query(self, text: str) -> list[list]:
        """Run one openCypher query and return the rows as Python values.

        Cells become `int`, `str`, `bool`, `None` (null) or a `list`; rows are
        lists of cells. Raises a typed :class:`QueryError` subclass on failure.

        The whole result is read in one call (serialized to JSON), so a large
        result costs one FFI call plus a `json.loads`, not one call per cell.
        """
        encoded = text.encode()
        with self._lock:
            ctx = self._handle()
            if self._in_write:
                raise AcmedbError("query() cannot run inside a write() block")
            result = _ffi.lib.acmedb_query(ctx, encoded, len(encoded))
            if not result:
                _raise_query_error(ctx)
            try:
                n = ctypes.c_size_t()
                p = _ffi.lib.acmedb_result_to_json(result, ctypes.byref(n))
                return json.loads(ctypes.string_at(p, n.value))
            finally:
                _ffi.lib.acmedb_result_free(result)

    # --- Writes --------------------------------------------------------------

    @contextlib.contextmanager
    def write(self):
        """Batch mutators into one write transaction (one fsync on exit).

        Every `add_node`/`add_edge`/`set_prop`/`alloc_node_id` inside the block
        commits atomically when the block exits; an exception aborts it::

            with db.write():
                for i in range(100_000):
                    nid = db.alloc_node_id()
                    db.add_node(nid, "Person")
                    db.set_prop(nid, "name", f"p{i}")

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

    def alloc_node_id(self) -> int:
        """Allocate a fresh, never-used node id."""
        with self._lock:
            nid = _ffi.lib.acmedb_alloc_node_id(self._handle())
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

    def set_prop(self, id: int, name: str, value) -> None:
        """Set an `int` (64-bit signed) or `str` property on an existing node."""
        _check_node_id(id)
        name_enc = name.encode()
        # bool is an int subclass, but booleans are not a storable type yet.
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            raise TypeError(f"property values must be int or str, not {type(value).__name__}")
        if isinstance(value, int) and not _I64_MIN <= value <= _I64_MAX:
            raise OverflowError(f"int property {value} does not fit in 64 bits")
        with self._lock:
            ctx = self._handle()
            if isinstance(value, int):
                rc = _ffi.lib.acmedb_set_prop_i64(ctx, id, name_enc, len(name_enc), value)
            else:
                enc = value.encode()
                rc = _ffi.lib.acmedb_set_prop_str(ctx, id, name_enc, len(name_enc), enc, len(enc))
            self._check(rc, id)

    def _check(self, rc: int, *ids: int) -> None:
        if rc == _RC_NO_NODE:
            raise NodeNotFoundError(f"node does not exist (ids: {', '.join(map(str, ids))})")
        if rc != _RC_OK:
            raise StorageError("write failed")

