"""Benchmark: queries through the Python package, on the graph
bench/access_control.zig built, to compare with the engine's own times.

    zig build bench -Doptimize=ReleaseFast -- --people 100000 --dir .bench-data
    zig build python -Doptimize=ReleaseFast -Dpython-include=...
    python bench/python_overhead.py --dir .bench-data --people 100000

The database file is read first, so its pages are in the OS cache (as in a
process that has been running a while); `--cold` skips that.
"""

from __future__ import annotations

import argparse
import random
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))

from acmedb import Database  # noqa: E402

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
        print(f"{'query':<32} {'runs':>6} {'median':>10} {'p95':>10}")
        for name, text, kinds in QUERIES:
            runs = args.runs if not text.startswith("MATCH (p:Person)") else max(args.runs // 20, 3)
            samples = []
            for _ in range(runs + 2):
                parameters = {kind: parameter_value(kind, args.people, rng) for kind in kinds}
                start = time.perf_counter_ns()
                db.query(text, parameters)
                samples.append(time.perf_counter_ns() - start)
            samples = sorted(samples[2:])
            p95 = samples[min(len(samples) - 1, len(samples) * 95 // 100)]
            print(f"{name:<32} {runs:>6} {format_ns(statistics.median(samples)):>10} {format_ns(p95):>10}")


if __name__ == "__main__":
    main()
