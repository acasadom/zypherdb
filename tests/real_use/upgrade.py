"""Upgrading in real use: a database written by the previous release, opened by this one. The old
version and the new one are installed in a Python each, as a user has them. See "The real use test"
in docs/guide/contributing.md.

    python -m venv old && old/bin/pip install zypherdb           # the latest on PyPI
    python -m venv new && new/bin/pip install zypherdb-*.whl
    new/bin/python -I tests/real_use/upgrade.py old/bin/python new/bin/python

REAL_TMP is where the databases go (the operating system's temporary directory by default): those
of a run that fails are kept. POSIX only, as run.py is.
"""
import hashlib
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

THIS = os.path.abspath(__file__)
TOKEN = "a-long-random-secret-for-this-test"
SETTLE_SECONDS = 60


def contents(db):
    """A digest of everything a reader sees: records, indexes, and what the indexes find."""
    views = [
        db.query("MATCH (n) RETURN id(n), labels(n), properties(n) ORDER BY id(n)"),
        db.query("MATCH (a)-[r]->(b) RETURN id(r), id(a), id(b), type(r), properties(r) ORDER BY id(r)"),
        sorted(str(row) for row in db.query("SHOW INDEXES")),
        sorted(str(row) for row in db.query("SHOW CONSTRAINTS")),
        db.query("MATCH (p:Person {name: 'person 7'}) RETURN p.age"),
        db.query("MATCH (p:Person) WHERE p.age >= 90 RETURN p.name ORDER BY p.name"),
        db.query("CALL db.index.fulltext.queryNodes('bios', 'engineer') YIELD node RETURN node.name ORDER BY node.name"),
    ]
    text = json.dumps(views, default=repr, sort_keys=True)
    return {"digest": hashlib.sha256(text.encode()).hexdigest(), "nodes": len(views[0]), "relationships": len(views[1]), "found": len(views[6])}


def fill(db):
    db.query("CREATE INDEX FOR (p:Person) ON (p.name)")
    db.query("CREATE INDEX FOR (p:Person) ON (p.age)")
    db.query("CREATE FULLTEXT INDEX bios FOR (p:Person) ON EACH [p.bio]")
    db.query("CREATE CONSTRAINT FOR (b:Badge) REQUIRE b.code IS UNIQUE")
    for number in range(100):
        db.query(
            "CREATE (p:Person {name: $name, age: $number, bio: $bio, score: $number / 7.0, tags: ['a', $name], "
            "born: date('2000-01-02'), seen: datetime('2026-03-04T05:06:07Z'), home: {city: 'Madrid', floor: $number}})"
            "-[:HOLDS {since: $number}]->(:Badge {code: $number})",
            {"name": f"person {number}", "number": number, "bio": "an engineer" if number % 2 else "a pilot"},
        )
    db.query("MATCH (a:Person {name: 'person 1'}), (b:Person {name: 'person 2'}) CREATE (a)-[:KNOWS]->(b)")
    db.query("MATCH (p:Person {name: 'person 3'}) DELETE p.gone")


def step_fill(path):
    """Old version: fills a database, tells what it holds, closes it."""
    from zypherdb import Database

    with Database(path) as db:
        fill(db)
        print(json.dumps(contents(db)))


def step_read(path):
    """New version: tells what it finds, then writes, and it must all still agree."""
    from zypherdb import Database

    with Database(path) as db:
        found = contents(db)
        found["check"] = db.check()
        db.query("CREATE (:Person {name: 'after the upgrade', age: 1000, bio: 'an engineer'})")
        found["added"] = db.query("MATCH (p:Person {name: 'after the upgrade'}) RETURN count(p)")[0][0]
        found["check_after_write"] = db.check()
        print(json.dumps(found))


def step_write_until_killed(path):
    """Old version: commits batches of two, and says so after each, until it is killed."""
    from zypherdb import Database

    with Database(path) as db:
        db.query("CREATE INDEX FOR (b:Batch) ON (b.number)")
        print("ready", flush=True)
        number = 0
        while True:
            db.query("UNWIND [1, 2] AS part CREATE (:Batch {number: $number, part: part})", {"number": number})
            print(number, flush=True)
            number += 1


def step_read_batches(path):
    """New version: what the killed process committed, and whether it all agrees."""
    from zypherdb import Database

    with Database(path) as db:
        rows = db.query("MATCH (b:Batch) RETURN b.number, count(b) ORDER BY b.number")
        check = db.check()
        db.query("CREATE (:Batch {number: -1, part: 1})")
        print(json.dumps({"batches": [list(row) for row in rows], "check": check, "check_after_write": db.check()}))


def step_serve(path, address, new_data):
    """Serves replicas on `address`, tells what it holds, until told to end on stdin."""
    from zypherdb import Database

    with Database(path, serve=address, token=TOKEN) as db:
        if new_data == "fill":
            fill(db)
        elif new_data == "more":
            db.query("CREATE (:Person {name: 'after the upgrade', age: 1000, bio: 'an engineer'})")
        print(json.dumps({"lsn": db.last_lsn, "contents": contents(db)}), flush=True)
        sys.stdin.readline()


def step_follow(path, address, lsn):
    """Follows the master at `address` up to `lsn`, tells what it then holds."""
    from zypherdb import Database

    with Database(path, replicate_from=address, token=TOKEN) as db:
        applied = db.wait_for(int(lsn), timeout=SETTLE_SECONDS)
        print(json.dumps({"applied": applied, "status": db.replication_status(), "contents": contents(db), "check": db.check()}))


STEPS = {
    "fill": step_fill,
    "read": step_read,
    "write-until-killed": step_write_until_killed,
    "read-batches": step_read_batches,
    "serve": step_serve,
    "follow": step_follow,
}
failures = []


def check(condition, text):
    print(f"    {'ok' if condition else 'FAIL'} {text}", flush=True)
    if not condition:
        failures.append(text)


def run_step(python, *arguments):
    """The JSON a step printed last, in a process of its own."""
    done = subprocess.run([python, "-I", THIS, "--step", *arguments], capture_output=True, text=True, timeout=SETTLE_SECONDS * 3)
    if done.returncode != 0:
        raise RuntimeError(f"step {arguments[0]} ended with {done.returncode}: {done.stderr[-800:]}")
    return json.loads(done.stdout.splitlines()[-1])


def free_address():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return f"127.0.0.1:{probe.getsockname()[1]}"


def healthy(report):
    return report["ok"] and report["problem_count"] == 0


def clean_close(old, new, tmp):
    print("== a database the old version closed", flush=True)
    path = os.path.join(tmp, "clean")
    before = run_step(old, "fill", path)
    after = run_step(new, "read", path)
    check(before["nodes"] == 200 and before["relationships"] == 101 and before["found"] == 50, f"the old version wrote what it should: {before}")
    check(before["digest"] == after["digest"], "the new version reads the same records and indexes")
    check(healthy(after["check"]), f"integrity: {after['check']['problems'][:3]}")
    check(after["added"] == 1 and healthy(after["check_after_write"]), "the new version writes, and it still agrees")


def killed(old, new, tmp):
    print("== a database the old version was killed writing to", flush=True)
    path = os.path.join(tmp, "killed")
    writer = subprocess.Popen([old, "-I", THIS, "--step", "write-until-killed", path], stdout=subprocess.PIPE, text=True)
    last = None
    deadline = time.monotonic() + 3
    assert writer.stdout.readline().strip() == "ready"
    while time.monotonic() < deadline:
        last = int(writer.stdout.readline())
    writer.send_signal(signal.SIGKILL)
    writer.wait()
    print(f"    killed after batch {last} was answered", flush=True)
    found = run_step(new, "read-batches", path)
    batches = found["batches"]
    check(all(count == 2 for _, count in batches), "no batch is there in part")
    check([number for number, _ in batches] == list(range(len(batches))), "the batches have no gaps")
    check(len(batches) > last, f"every answered batch is there ({len(batches)} found, up to {last} answered)")
    check(healthy(found["check"]), f"integrity: {found['check']['problems'][:3]}")
    check(healthy(found["check_after_write"]), "the new version writes, and it still agrees")


def start_master(python, path, address, new_data):
    master = subprocess.Popen([python, "-I", THIS, "--step", "serve", path, address, new_data], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    return master, json.loads(master.stdout.readline())


def stop_master(master):
    master.stdin.close()
    master.wait(timeout=SETTLE_SECONDS)


def plain_database_serves(old, new, tmp):
    print("== a database the old version wrote, served to a new replica", flush=True)
    path = os.path.join(tmp, "plain")
    run_step(old, "fill", path)
    address = free_address()
    master, told = start_master(new, path, address, "none")
    try:
        replica = run_step(new, "follow", os.path.join(tmp, "plain-replica"), address, str(told["lsn"]))
    finally:
        stop_master(master)
    check(replica["applied"], "the replica got a copy")
    check(replica["contents"]["digest"] == told["contents"]["digest"], "the replica holds what the master does")
    check(healthy(replica["check"]), f"integrity: {replica['check']['problems'][:3]}")


def replicated_pair(old, new, tmp):
    print("== a master and a replica of the old version, both upgraded", flush=True)
    master_path = os.path.join(tmp, "pair-master")
    replica_path = os.path.join(tmp, "pair-replica")
    address = free_address()
    master, told = start_master(old, master_path, address, "fill")
    try:
        replica = run_step(old, "follow", replica_path, address, str(told["lsn"]))
    finally:
        stop_master(master)
    check(replica["applied"], "the old replica caught up")
    master, told = start_master(new, master_path, address, "more")
    try:
        upgraded = run_step(new, "follow", replica_path, address, str(told["lsn"]))
    finally:
        stop_master(master)
    check(upgraded["applied"], "the upgraded replica got what the upgraded master wrote")
    check(upgraded["contents"]["digest"] == told["contents"]["digest"], "they hold the same")
    check(healthy(upgraded["check"]), f"integrity: {upgraded['check']['problems'][:3]}")


def version_of(python):
    code = "from importlib.metadata import version; import zypherdb; print(version('zypherdb'), zypherdb.__file__)"
    return subprocess.run([python, "-I", "-c", code], capture_output=True, text=True, check=True, cwd=os.path.dirname(THIS)).stdout.strip()


def main():
    old, new = sys.argv[1], sys.argv[2]
    print("old:", version_of(old), flush=True)
    print("new:", version_of(new), flush=True)
    tmp = tempfile.mkdtemp(prefix="upgrade-", dir=os.environ.get("REAL_TMP"))
    for scenario in (clean_close, killed, plain_database_serves, replicated_pair):
        try:
            scenario(old, new, tmp)
        except Exception as error:
            check(False, f"{scenario.__name__}: {error}")
    if failures:
        print(f"{len(failures)} FAILED, kept {tmp}", flush=True)
        sys.exit(1)
    shutil.rmtree(tmp, ignore_errors=True)
    print("all passed", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "--step":
        STEPS[sys.argv[2]](*sys.argv[3:])
    else:
        main()
