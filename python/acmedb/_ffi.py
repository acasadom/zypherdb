"""ctypes bindings for the acmedb C ABI, declared once.

Every signature and constant lives here, so the rest of the package never touches
ctypes. The shared library is located once at import time (see `load`).
"""

from __future__ import annotations

import ctypes
import os
import platform
import sys
from pathlib import Path

_LIBNAME = "libacmedb.dylib" if platform.system() == "Darwin" else "libacmedb.so"

# Result cell type tags (src/c_api.zig).
TYPE_INT = 0
TYPE_STR = 1
TYPE_BOOL = 2
TYPE_NULL = 3
TYPE_LIST = 4


def _candidates():
    env = os.environ.get("ACMEDB_LIB")
    if env:
        yield Path(env)

    here = Path(__file__).resolve().parent  # .../python/acmedb
    repo = here.parent.parent  # .../ (repo root)
    yield repo / "zig-out" / "lib" / _LIBNAME
    yield Path.cwd() / "zig-out" / "lib" / _LIBNAME
    # A standard install location (e.g. /usr/local/lib).
    yield Path("/usr/local/lib") / _LIBNAME


def _load() -> ctypes.CDLL:
    for path in _candidates():
        if path.is_file():
            return ctypes.CDLL(str(path))
    raise OSError(
        f"libacmedb not found; run `zig build` or set ACMEDB_LIB "
        f"(looked in: {', '.join(str(p) for p in _candidates())})"
    )


lib = _load()

# --- Lifecycle ---------------------------------------------------------------
lib.acmedb_open.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_open.restype = ctypes.c_void_p
lib.acmedb_close.argtypes = [ctypes.c_void_p]
lib.acmedb_last_error.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
lib.acmedb_last_error.restype = ctypes.c_void_p
lib.acmedb_error_code.argtypes = [ctypes.c_void_p]
lib.acmedb_error_code.restype = ctypes.c_int

# --- Writes ------------------------------------------------------------------
lib.acmedb_alloc_node_id.argtypes = [ctypes.c_void_p]
lib.acmedb_alloc_node_id.restype = ctypes.c_uint64
lib.acmedb_begin_write.argtypes = [ctypes.c_void_p]
lib.acmedb_begin_write.restype = ctypes.c_int
lib.acmedb_commit_write.argtypes = [ctypes.c_void_p]
lib.acmedb_commit_write.restype = ctypes.c_int
lib.acmedb_abort_write.argtypes = [ctypes.c_void_p]
lib.acmedb_add_node.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_add_node.restype = ctypes.c_int
lib.acmedb_add_edge.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_add_edge.restype = ctypes.c_int
lib.acmedb_set_prop_i64.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int64]
lib.acmedb_set_prop_i64.restype = ctypes.c_int
lib.acmedb_set_prop_str.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_set_prop_str.restype = ctypes.c_int

# --- Queries -----------------------------------------------------------------
lib.acmedb_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_query.restype = ctypes.c_void_p
lib.acmedb_result_free.argtypes = [ctypes.c_void_p]
lib.acmedb_result_rows.argtypes = [ctypes.c_void_p]
lib.acmedb_result_rows.restype = ctypes.c_size_t
lib.acmedb_result_cols.argtypes = [ctypes.c_void_p]
lib.acmedb_result_cols.restype = ctypes.c_size_t
lib.acmedb_result_type.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_type.restype = ctypes.c_int
lib.acmedb_result_int.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_int.restype = ctypes.c_int64
lib.acmedb_result_bool.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_bool.restype = ctypes.c_bool
lib.acmedb_result_str.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
lib.acmedb_result_str.restype = ctypes.c_void_p
lib.acmedb_result_to_json.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
lib.acmedb_result_to_json.restype = ctypes.c_void_p

# --- List cells (flat lists) -------------------------------------------------
lib.acmedb_result_list_len.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_list_len.restype = ctypes.c_size_t
lib.acmedb_result_list_item_type.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_list_item_type.restype = ctypes.c_int
lib.acmedb_result_list_item_int.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_list_item_int.restype = ctypes.c_int64
lib.acmedb_result_list_item_bool.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t]
lib.acmedb_result_list_item_bool.restype = ctypes.c_bool
lib.acmedb_result_list_item_str.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
lib.acmedb_result_list_item_str.restype = ctypes.c_void_p
