#!/usr/bin/env python3
"""Minimal Python demo of the acmedb C ABI via ctypes.

Build the shared library first, then run from the project root:

    zig build
    python3 examples/demo.py
"""

import ctypes
import os
import platform
import tempfile

# --- Load the library -------------------------------------------------------

_HERE = os.path.dirname(os.path.abspath(__file__))
_LIBNAME = "libacmedb.dylib" if platform.system() == "Darwin" else "libacmedb.so"
_LIBPATH = os.path.join(_HERE, "..", "zig-out", "lib", _LIBNAME)

lib = ctypes.CDLL(_LIBPATH)

lib.acmedb_open.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_open.restype = ctypes.c_void_p
lib.acmedb_close.argtypes = [ctypes.c_void_p]

lib.acmedb_add_node.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_add_node.restype = ctypes.c_int
lib.acmedb_add_edge.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_add_edge.restype = ctypes.c_int
lib.acmedb_set_prop_i64.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int64]
lib.acmedb_set_prop_i64.restype = ctypes.c_int
lib.acmedb_set_prop_str.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t]
lib.acmedb_set_prop_str.restype = ctypes.c_int

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

_TYPE_INT, _TYPE_STR, _TYPE_BOOL = 0, 1, 2


def _b(s: str) -> bytes:
    return s.encode()


def _cell(result, row: int, col: int):
    t = lib.acmedb_result_type(result, row, col)
    if t == _TYPE_INT:
        return lib.acmedb_result_int(result, row, col)
    if t == _TYPE_STR:
        n = ctypes.c_size_t(0)
        p = lib.acmedb_result_str(result, row, col, ctypes.byref(n))
        return ctypes.string_at(p, n.value).decode()
    if t == _TYPE_BOOL:
        return lib.acmedb_result_bool(result, row, col)
    raise ValueError(f"unknown cell type {t}")


def run_query(ctx, query: str):
    result = lib.acmedb_query(ctx, _b(query), len(query))
    if not result:
        raise RuntimeError(f"query failed: {query}")
    try:
        rows = lib.acmedb_result_rows(result)
        cols = lib.acmedb_result_cols(result)
        return [[_cell(result, r, c) for c in range(cols)] for r in range(rows)]
    finally:
        lib.acmedb_result_free(result)


def main() -> None:
    path = tempfile.mkdtemp()
    ctx = lib.acmedb_open(_b(path), len(path))
    if not ctx:
        raise RuntimeError("acmedb_open failed")

    people = [(1, "Keanu Reeves", 1964), (2, "Carrie-Anne Moss", 1967), (3, "Laurence Fishburne", 1961),
              (4, "Lana Wachowski", 1965), (5, "Tom Hanks", 1956)]
    movies = [(100, "The Matrix", 1999), (101, "The Matrix Reloaded", 2003),
              (102, "John Wick", 2014), (103, "Forrest Gump", 1994)]
    acted_in = [(1, 100), (1, 101), (1, 102), (2, 100), (3, 100), (5, 103)]
    directed = [(4, 100), (4, 101)]

    for pid, name, born in people:
        lib.acmedb_add_node(ctx, pid, _b("Person"), 6)
        lib.acmedb_set_prop_str(ctx, pid, _b("name"), 4, _b(name), len(name))
        lib.acmedb_set_prop_i64(ctx, pid, _b("born"), 4, born)
    for mid, title, released in movies:
        lib.acmedb_add_node(ctx, mid, _b("Movie"), 5)
        lib.acmedb_set_prop_str(ctx, mid, _b("title"), 5, _b(title), len(title))
        lib.acmedb_set_prop_i64(ctx, mid, _b("released"), 8, released)
    for a, m in acted_in:
        lib.acmedb_add_edge(ctx, a, m, _b("ACTED_IN"), 8)
    for a, m in directed:
        lib.acmedb_add_edge(ctx, a, m, _b("DIRECTED"), 8)

    queries = [
        "MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born",
        "MATCH (p:Person {name: 'Keanu Reeves'})-[:ACTED_IN]->(m:Movie) RETURN m.title",
        "MATCH (d:Person)-[:DIRECTED]->(m:Movie)<-[:ACTED_IN]-(a:Person) WHERE m.title = 'The Matrix' RETURN a.name",
    ]
    for q in queries:
        print(f"QUERY: {q}")
        for row in run_query(ctx, q):
            print("  ", row)

    lib.acmedb_close(ctx)
    print("OK")


if __name__ == "__main__":
    main()
