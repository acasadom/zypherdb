"""Benchmark: what replication costs, part by part. Every database runs in a
process of its own, on this machine, over the loopback interface; a real
network adds its round trip to what crosses it (a replica's lag, a forwarded
write).

1. Reads and writes on a database without replication, and on a master
   with no replica, then with one: what serving replicas costs the master.
2. Reads on a replica, and how long a write on the master takes to show
   there (its lag).
3. Reads on a replica that forwards writes (`forward_writes=True`), when it
   forwards none: what being able to forward costs.
4. Writes forwarded by a replica, one thread and several, and batches
   (`write_many`) of them.

    zig build python -Doptimize=ReleaseFast -Dpython-include=...
    python bench/replication_costs.py --durability deferred
"""

from __future__ import annotations

import argparse
import multiprocessing
import random
import statistics
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "python"))

from zypherdb import Database  # noqa: E402

TOKEN = "bench"
READS = [
    ("point lookup", "MATCH (p:Person {id: $id}) RETURN p.name"),
    ("1 hop", "MATCH (p:Person {id: $id})-[:KNOWS]->(f) RETURN count(f)"),
    ("scan + filter", "MATCH (p:Person) WHERE p.age > 60 RETURN count(*)"),
]
WRITE = "CREATE (:Event {id: $id})"
# The writes of a `write_many` measured.
BATCH = 10


# --- The process that holds a database ------------------------------------------


def serve(connection, path: str, options: dict) -> None:
    """Opens the database at `path` and runs the commands `connection` sends."""
    db = Database(path, **options)
    if "serve" in options:
        connection.send(db.replication_status()["address"])
    else:
        connection.send(None)
    watcher = None
    while True:
        command, *arguments = connection.recv()
        if command == "stop":
            break
        if command == "load":
            load(db, *arguments)
            connection.send(db.last_lsn)
        elif command == "last_lsn":
            connection.send(db.last_lsn)
        elif command == "wait_for":
            connection.send(db.wait_for(*arguments))
        elif command == "reads":
            connection.send(reads(db, *arguments))
        elif command == "writes":
            connection.send(writes(db, *arguments))
        elif command == "watch":
            watcher = Watcher(db)
            connection.send(None)
        elif command == "unwatch":
            watcher.stop()
            connection.send(watcher.seen)
    db.close()
    connection.send(None)


class Watcher:
    """Notes when each change shows on a replica: (lsn, monotonic ns)."""

    def __init__(self, db: Database):
        self.db = db
        self.seen: list[tuple[int, int]] = []
        self.running = True
        self.thread = threading.Thread(target=self.run)
        self.thread.start()

    def run(self) -> None:
        last = self.db.last_lsn
        while self.running:
            lsn = self.db.last_lsn
            if lsn != last:
                self.seen.append((lsn, time.monotonic_ns()))
                last = lsn

    def stop(self) -> None:
        self.running = False
        self.thread.join()


def load(db: Database, people: int) -> None:
    rng = random.Random(42)
    db.query("CREATE INDEX person_id FOR (p:Person) ON (p.id)")
    batch = 10_000
    for start in range(0, people, batch):
        rows = [{"id": i, "name": f"person {i}", "age": rng.randrange(18, 90)} for i in range(start, min(start + batch, people))]
        db.query("UNWIND $rows AS row CREATE (:Person {id: row.id, name: row.name, age: row.age})", rows=rows)
    for start in range(0, people, batch):
        pairs = [{"a": i, "b": rng.randrange(people)} for i in range(start, min(start + batch, people)) for _ in range(5)]
        db.query("UNWIND $pairs AS pair MATCH (a:Person {id: pair.a}), (b:Person {id: pair.b}) CREATE (a)-[:KNOWS]->(b)", pairs=pairs)


def reads(db: Database, people: int, runs: int) -> dict[str, list[int]]:
    rng = random.Random(7)
    # A process idle for a few seconds reads 2-3 times slower at first (macOS
    # lets its core slow down, or moves it): keep it busy for a while first.
    warm_until = time.perf_counter() + 0.3
    while time.perf_counter() < warm_until:
        db.query(READS[0][1], id=rng.randrange(people))
    samples = {}
    for name, text in READS:
        count = runs if "$id" in text else max(runs // 50, 5)
        times = []
        for _ in range(count + 2):
            start = time.perf_counter_ns()
            db.query(text, id=rng.randrange(people))
            times.append(time.perf_counter_ns() - start)
        samples[name] = times[2:]
    return samples


def writes(db: Database, runs: int, threads: int, first_id: int, batch: int = 1) -> dict:
    """`runs` single-node writes from `threads` threads, `batch` to a
    transaction (`write_many` past one): each call's latency, the commit
    times on this side (lsn, monotonic ns), and the wall time."""
    latencies: list[int] = []
    commits: list[tuple[int, int]] = []
    lock = threading.Lock()
    per_thread = runs // threads // batch * batch

    def work(offset: int) -> None:
        mine, stamps = [], []
        for i in range(0, per_thread, batch):
            first = first_id + offset * per_thread + i
            start = time.perf_counter_ns()
            if batch == 1:
                db.query(WRITE, id=first)
            else:
                db.write_many([(WRITE, {"id": first + j}) for j in range(batch)])
            end = time.perf_counter_ns()
            mine.append(end - start)
            if threads == 1:
                stamps.append((db.last_lsn, time.monotonic_ns()))
        with lock:
            latencies.extend(mine)
            commits.extend(stamps)

    start = time.perf_counter_ns()
    workers = [threading.Thread(target=work, args=(t,)) for t in range(threads)]
    for worker in workers:
        worker.start()
    for worker in workers:
        worker.join()
    return {"latencies": latencies, "commits": commits, "wall_ns": time.perf_counter_ns() - start, "count": per_thread * threads}


# --- The driver -------------------------------------------------------------------


class Process:
    """A database in a process of its own."""

    def __init__(self, path: str, **options):
        context = multiprocessing.get_context("spawn")
        self.connection, theirs = context.Pipe()
        self.process = context.Process(target=serve, args=(theirs, path, options))
        self.process.start()
        self.address = self.connection.recv()

    def call(self, *command):
        self.connection.send(command)
        return self.connection.recv()

    def stop(self) -> None:
        self.call("stop")
        self.process.join()


def format_ns(ns: float) -> str:
    if ns >= 10_000_000:
        return f"{ns / 1e6:.1f} ms"
    return f"{ns / 1e3:.1f} µs"


def percentile(samples: list[int], fraction: float) -> int:
    ordered = sorted(samples)
    return ordered[min(len(ordered) - 1, int(len(ordered) * fraction))]


def print_reads(rows: list[tuple[str, dict[str, list[int]]]]) -> None:
    names = [name for name, _ in READS]
    print(f"{'reads (median)':<40}" + "".join(f"{name:>16}" for name in names))
    for label, samples in rows:
        print(f"{label:<40}" + "".join(f"{format_ns(statistics.median(samples[name])):>16}" for name in names))


def print_writes(rows: list[tuple[str, dict]]) -> None:
    print(f"{'writes':<40}{'median':>12}{'p95':>12}{'writes/s':>12}")
    for label, result in rows:
        latencies = result["latencies"]
        rate = result["count"] / (result["wall_ns"] / 1e9)
        print(f"{label:<40}{format_ns(statistics.median(latencies)):>12}{format_ns(percentile(latencies, 0.95)):>12}{rate:>12,.0f}")


def lags(commits: list[tuple[int, int]], seen: list[tuple[int, int]]) -> list[int]:
    """For each commit, how long until the replica had it."""
    result = []
    index = 0
    for lsn, committed in commits:
        while index < len(seen) and seen[index][0] < lsn:
            index += 1
        if index < len(seen):
            result.append(max(0, seen[index][1] - committed))
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--people", type=int, default=100_000)
    parser.add_argument("--reads", type=int, default=2000, help="runs per point read")
    parser.add_argument("--writes", type=int, default=0, help="writes per measure (default: 2000, 200 with full durability)")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--durability", choices=("full", "relaxed", "deferred"), default="deferred")
    parser.add_argument("--replica-durability", choices=("full", "relaxed", "deferred"), help="the replicas' (default: --durability)")
    args = parser.parse_args()
    runs = args.writes or (200 if args.durability == "full" else 2000)
    durability = args.durability
    replica_durability = args.replica_durability or durability
    next_id = iter(range(0, 1 << 62, 1 << 32))

    with tempfile.TemporaryDirectory() as root:
        print(f"{args.people:,} people, 5 relationships each; durability {durability!r}, replicas {replica_durability!r};"
              " one process per database\n")

        plain = Process(f"{root}/plain", durability=durability)
        plain.call("load", args.people)
        master = Process(f"{root}/master", durability=durability, serve="127.0.0.1:0", token=TOKEN)
        lsn = master.call("load", args.people)

        print("== 1. Serving replicas: what it costs the master")
        read_rows = [("no replication", plain.call("reads", args.people, args.reads)),
                     ("master, no replica", master.call("reads", args.people, args.reads))]
        write_rows = [("no replication", plain.call("writes", runs, 1, next(next_id))),
                      ("master, no replica", master.call("writes", runs, 1, next(next_id)))]
        replica = Process(f"{root}/replica", durability=replica_durability, replicate_from=master.address, token=TOKEN)
        assert replica.call("wait_for", lsn, 300.0), "the replica did not get its copy"
        read_rows.append(("master, one replica", master.call("reads", args.people, args.reads)))
        replica.call("watch")
        on_master = master.call("writes", runs, 1, next(next_id))
        seen = replica.call("unwatch")
        write_rows.append(("master, one replica", on_master))
        write_rows.append((f"no replication, {args.threads} threads", plain.call("writes", runs, args.threads, next(next_id))))
        write_rows.append((f"master, one replica, {args.threads} threads", master.call("writes", runs, args.threads, next(next_id))))
        print_reads(read_rows)
        print()
        print_writes(write_rows)

        print("\n== 2. On a replica")
        # Read once it has applied every write so far: reads alone, as on the others.
        assert replica.call("wait_for", master.call("last_lsn"), 300.0), "the replica fell behind"
        replica_reads = replica.call("reads", args.people, args.reads)
        print_reads([("no replication", read_rows[0][1]), ("replica", replica_reads)])
        lag = lags(on_master["commits"], seen)
        print(f"\nlag (a write on the master, until the replica has it): median {format_ns(statistics.median(lag))},"
              f" p95 {format_ns(percentile(lag, 0.95))} ({len(lag)} writes)")
        replica.stop()

        print("\n== 3. A replica that can forward writes, forwarding none")
        forwarding = Process(f"{root}/forwarding", durability=replica_durability, replicate_from=master.address, token=TOKEN, forward_writes=True)
        assert forwarding.call("wait_for", master.call("last_lsn"), 300.0), "the replica did not get its copy"
        print_reads([("no replication", read_rows[0][1]), ("replica", replica_reads),
                     ("replica, forward_writes=True", forwarding.call("reads", args.people, args.reads))])

        print("\n== 4. Writes forwarded by a replica")
        print_writes([("on the master (one replica)", write_rows[2][1]),
                      ("forwarded", forwarding.call("writes", runs, 1, next(next_id))),
                      (f"on the master, {args.threads} threads", write_rows[4][1]),
                      (f"forwarded, {args.threads} threads", forwarding.call("writes", runs, args.threads, next(next_id))),
                      (f"on the master, write_many of {BATCH} (a call)", master.call("writes", runs, 1, next(next_id), BATCH)),
                      (f"forwarded, write_many of {BATCH} (a call)", forwarding.call("writes", runs, 1, next(next_id), BATCH))])

        forwarding.stop()
        master.stop()
        plain.stop()


if __name__ == "__main__":
    main()
