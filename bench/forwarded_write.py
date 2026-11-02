"""Benchmark: the latency of a write a replica forwards to its master, next to
the same write made on the master, and on the master then waited for on the
replica (read-your-writes by hand). Master and replica run in this process,
over the loopback interface, so the round trip is the shortest a network gives.

    zig build python -Doptimize=ReleaseFast -Dpython-include=...
    python bench/forwarded_write.py --durability full
"""

from __future__ import annotations

import argparse
import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))

from zypherdb import Database  # noqa: E402

TOKEN = "bench"
WRITE = "CREATE (:Event {id: $id}) RETURN 1"


def format_ns(ns: float) -> str:
    return f"{ns / 1e6:.1f} ms" if ns >= 10_000_000 else f"{ns / 1e3:.1f} µs"


def measure(name: str, runs: int, write) -> None:
    samples = []
    for i in range(runs + 2):
        start = time.perf_counter_ns()
        write(i)
        samples.append(time.perf_counter_ns() - start)
    samples = sorted(samples[2:])
    p95 = samples[min(len(samples) - 1, len(samples) * 95 // 100)]
    print(f"{name:<32} {runs:>6} {format_ns(statistics.median(samples)):>10} {format_ns(p95):>10}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--runs", type=int, default=500)
    parser.add_argument("--durability", choices=("full", "relaxed", "deferred"), default="full")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as root:
        master = Database(f"{root}/master", durability=args.durability, serve="127.0.0.1:0", token=TOKEN)
        address = master.replication_status()["address"]
        replica = Database(f"{root}/replica", durability=args.durability, replicate_from=address, token=TOKEN, forward_writes=True)
        master.query("CREATE (:Seed)")
        if not replica.wait_for(master.last_lsn, timeout=30):
            sys.exit("the replica did not get its first copy")
        ids = iter(range(1 << 62))

        print(f"{'write':<32} {'runs':>6} {'median':>10} {'p95':>10}")
        measure("on the master", args.runs, lambda _: master.query(WRITE, id=next(ids)))

        def master_then_wait(_):
            master.query(WRITE, id=next(ids))
            if not replica.wait_for(master.last_lsn, timeout=30):
                sys.exit("the replica fell behind")

        measure("on the master + wait_for", args.runs, master_then_wait)

        def forwarded(_):
            if not replica.query(WRITE, id=next(ids)).visible:
                sys.exit("a forwarded write was not visible in time")

        measure("forwarded by the replica", args.runs, forwarded)
        replica.close()
        master.close()


if __name__ == "__main__":
    main()
