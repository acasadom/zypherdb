"""The acmedb `Database` object: open a graph, write data, run queries."""

from __future__ import annotations

import ctypes
import json
import threading

from . import _ffi
from .errors import StorageError, error_from_code


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
        # LMDB is single-writer: serialize the mutating calls.
        self._write_lock = threading.Lock()

    def close(self) -> None:
        if self._ctx:
            _ffi.lib.acmedb_close(self._ctx)
            self._ctx = None

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
        result = _ffi.lib.acmedb_query(self._ctx, encoded, len(encoded))
        if not result:
            _raise_query_error(self._ctx)
        try:
            n = ctypes.c_size_t()
            p = _ffi.lib.acmedb_result_to_json(result, ctypes.byref(n))
            return json.loads(ctypes.string_at(p, n.value))
        finally:
            _ffi.lib.acmedb_result_free(result)

    # --- Writes --------------------------------------------------------------

    def alloc_node_id(self) -> int:
        """Allocate a fresh, never-used node id."""
        with self._write_lock:
            return _ffi.lib.acmedb_alloc_node_id(self._ctx)

    def add_node(self, id: int, label: str = "") -> None:
        with self._write_lock:
            self._check(_ffi.lib.acmedb_add_node(self._ctx, id, label.encode(), len(label)))

    def add_edge(self, src: int, dst: int, type: str) -> None:
        with self._write_lock:
            self._check(_ffi.lib.acmedb_add_edge(self._ctx, src, dst, type.encode(), len(type)))

    def set_prop(self, id: int, name: str, value) -> None:
        with self._write_lock:
            if isinstance(value, int):
                rc = _ffi.lib.acmedb_set_prop_i64(self._ctx, id, name.encode(), len(name), value)
            elif isinstance(value, str):
                enc = value.encode()
                rc = _ffi.lib.acmedb_set_prop_str(self._ctx, id, name.encode(), len(name), enc, len(enc))
            else:
                raise TypeError("property values must be int or str")
            self._check(rc)

    def _check(self, rc: int) -> None:
        if rc != 0:
            raise StorageError("write failed")

