"""Benchmark: what the Python bindings add to the engine's own time.

Runs the queries of bench/access_control.zig through `acmedb.Database` on the
graph that benchmark built, and splits each call into its parts:

- parameters: encoding them as JSON (`json.dumps`);
- native call: `acmedb_query_with_parameters`, i.e. the engine plus writing
  the result as JSON (compare with the engine's own time from `zig build bench`);
- copy: `ctypes.string_at`, the JSON into a Python `bytes`;
- decode: `json.loads` into Python objects.

    zig build bench -Doptimize=ReleaseFast -- --people 100000 --dir .bench-data
    zig build -Doptimize=ReleaseFast
    python bench/python_overhead.py --dir .bench-data --people 100000
"""

from __future__ import annotations

import argparse
import ctypes
import json
import random
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))

from acmedb import Database  # noqa: E402
from acmedb import _ffi, entities  # noqa: E402
from acmedb.db import _encode_parameters  # noqa: E402

QUERIES = [
    ("card lookup", "MATCH (c:Card {number: $card}) RETURN c.number", ("card",)),
    ("person's groups (1 hop)", "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g) RETURN g.name", ("person",)),
    ("colleagues (2 hops, distinct)", "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g)<-[:MEMBER_OF]-(q) RETURN count(DISTINCT q)", ("person",)),
    (
        "may this card open this door?",
        "MATCH (:Card {number: $card})-[:HELD_BY]->(p)-[:MEMBER_OF*1..3]->(g)-[w:MAY_ENTER]->(z)<-[:IN]-(:Door {id: $door})\n"
        "WHERE 3 IN w.days AND w.from <= localtime('10:30') AND localtime('10:30') < w.until\n"
        "RETURN count(*) > 0",
        ("card", "door"),
    ),
    ("people over 60 (scan + filter)", "MATCH (p:Person) WHERE p.age > 60 RETURN count(*)", ()),
    ("return 100k rows (3 columns)", "MATCH (p:Person) RETURN p.id, p.name, p.age", ()),
    ("return 10k whole nodes", "MATCH (p:Person) RETURN p LIMIT 10000", ()),
]


def parameter_value(kind: str, people: int, rng: random.Random) -> int:
    if kind == "person":
        return rng.randrange(people)
    if kind == "card":
        return 1_000_000 + rng.randrange(people)
    return rng.randrange(people // 10)  # door


def run_once(db: Database, text: str, parameters: dict) -> dict[str, float]:
    """One query, timed part by part (the steps of Database.query)."""
    timings = {}
    start = time.perf_counter_ns()
    encoded = text.encode()
    encoded_parameters = _encode_parameters(parameters) if parameters else b"{}"
    timings["parameters"] = time.perf_counter_ns() - start

    ctx = db._handle()
    start = time.perf_counter_ns()
    result = _ffi.lib.acmedb_query_with_parameters(ctx, encoded, len(encoded), encoded_parameters, len(encoded_parameters))
    timings["native call"] = time.perf_counter_ns() - start
    if not result:
        raise RuntimeError("query failed")
    try:
        start = time.perf_counter_ns()
        n = ctypes.c_size_t()
        p = _ffi.lib.acmedb_result_to_json(result, ctypes.byref(n))
        raw = ctypes.string_at(p, n.value)
        timings["copy"] = time.perf_counter_ns() - start
        start = time.perf_counter_ns()
        json.loads(raw, object_hook=entities.decode)
        timings["decode"] = time.perf_counter_ns() - start
    finally:
        _ffi.lib.acmedb_result_free(result)
    return timings


def format_ns(ns: float) -> str:
    return f"{ns / 1e6:.1f} ms" if ns >= 10_000_000 else f"{ns / 1e3:.1f} µs"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dir", default=".bench-data")
    parser.add_argument("--people", type=int, default=100_000)
    parser.add_argument("--runs", type=int, default=200)
    parser.add_argument("--cold", action="store_true", help="do not read the database file first")
    args = parser.parse_args()
    if not args.cold:
        # Bring the file into the OS page cache, as in a process that has been
        # running a while: otherwise the first reads of each page go to disk,
        # which measures the disk, not acmedb.
        with open(Path(args.dir) / "data.mdb", "rb") as data:
            while data.read(1 << 24):
                pass

    rng = random.Random(42)
    with Database(args.dir) as db:
        parts = ("parameters", "native call", "copy", "decode")
        print(f"{'query':<32} {'total':>10} " + " ".join(f"{p:>12}" for p in parts) + "   python share")
        for name, text, kinds in QUERIES:
            runs = args.runs if not text.startswith("MATCH (p:Person)") else max(args.runs // 20, 3)
            samples = []
            for _ in range(runs + 2):
                parameters = {kind: parameter_value(kind, args.people, rng) for kind in kinds}
                samples.append(run_once(db, text, parameters))
            samples = samples[2:]
            medians = {p: statistics.median(s[p] for s in samples) for p in parts}
            total = sum(medians.values())
            python_share = (medians["parameters"] + medians["copy"] + medians["decode"]) / total
            print(f"{name:<32} {format_ns(total):>10} " + " ".join(f"{format_ns(medians[p]):>12}" for p in parts) + f"   {python_share:6.0%}")


if __name__ == "__main__":
    main()
