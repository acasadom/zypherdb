"""Several processes on one database, one of them killed: the others go on."""

from __future__ import annotations

import os
import subprocess
import sys
import threading

from zypherdb import Database

HOLDING_THE_WRITE_LOCK = """
import sys
from zypherdb import Database
database = Database(sys.argv[1], durability="deferred")
with database.write():
    database.add_node(database.allocate_node_id(), "Unfinished")
    print("holding", flush=True)
    sys.stdin.read()
"""

IN_A_LONG_READ = """
import sys
from zypherdb import Database
database = Database(sys.argv[1], durability="deferred")
print("reading", flush=True)
database.query("UNWIND range(1, 100000000000) AS i WITH i MATCH (s:Spot) RETURN count(*)")
"""


def killed_while(code, path, told):
    process = subprocess.Popen([sys.executable, "-c", code, path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env={**os.environ, "PYTHONPATH": os.pathsep.join(sys.path)})
    assert process.stdout.readline().strip() == told
    return process


def test_a_process_killed_holding_the_write_lock_does_not_stop_the_others(tmp_path):
    path = str(tmp_path)
    with Database(path, durability="deferred") as survivor:
        survivor.query("CREATE (:Before)")
        process = killed_while(HOLDING_THE_WRITE_LOCK, path, "holding")
        process.kill()
        process.wait()
        done = []

        def write():
            survivor.query("CREATE (:After)")
            done.append(True)

        # A thread that may never return: as a daemon, it cannot hold up the tests' end.
        thread = threading.Thread(target=write, daemon=True)
        thread.start()
        thread.join(30)
        if not done:
            print("the write never finished", flush=True)
            os._exit(1)
        assert survivor.query("MATCH (n) RETURN labels(n)[0] ORDER BY labels(n)[0]") == [["After"], ["Before"]]
        assert survivor.check()["ok"]


def test_a_process_killed_during_a_read_does_not_make_the_file_grow(tmp_path):
    path = str(tmp_path)
    with Database(path, durability="deferred") as survivor:
        survivor.query("CREATE INDEX spot_i FOR (s:Spot) ON (s.i)")
        survivor.query("UNWIND range(0, 99) AS i CREATE (:Spot {i: i})")
        process = killed_while(IN_A_LONG_READ, path, "reading")
        # Well into the query: it holds its snapshot for as long as it runs.
        survivor.query("UNWIND range(1, 2000000) AS i RETURN count(i)")
        process.kill()
        process.wait()
        value = "x" * 4000

        def update_all():
            for update in range(6000):
                survivor.query("MATCH (s:Spot {i: $i}) SET s.value = $value", i=update % 100, value=value)
            return sum(entry.stat().st_size for entry in os.scandir(path) if entry.is_file())

        update_all()
        settled = update_all()
        # Pages kept for the dead reader would take about 30 KB per update: 180 MB more.
        assert update_all() < settled + (40 << 20)
        assert survivor.check()["ok"]
