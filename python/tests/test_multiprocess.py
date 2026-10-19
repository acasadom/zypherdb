"""Multi-process test: two processes open the same file, both write, serialized.

Runs two `python -c` writer processes concurrently against one database and
verifies node-id allocation is disjoint (no collision) and both writes commit.
"""

import os
import subprocess
import sys
from pathlib import Path

from acmedb import Database

_PYTHON_DIR = str(Path(__file__).resolve().parent.parent)  # .../python

_WRITER = r"""
import sys
from acmedb import Database

path, n = sys.argv[1], int(sys.argv[2])
with Database(path) as db:
    for _ in range(n):
        nid = db.allocate_node_id()
        db.add_node(nid, "Person")
        db.set_property(nid, "id", nid)
"""


def test_two_writers_serialize(tmp_path):
    path = str(tmp_path)  # a directory: LMDB creates data.mdb/lock.mdb inside
    with Database(path):
        pass  # create the file

    env = dict(os.environ)
    env["PYTHONPATH"] = _PYTHON_DIR

    procs = [
        subprocess.Popen([sys.executable, "-c", _WRITER, path, "100"], env=env),
        subprocess.Popen([sys.executable, "-c", _WRITER, path, "100"], env=env),
    ]
    for p in procs:
        assert p.wait() == 0

    with Database(path) as db:
        # 200 nodes, ids 0..199 — disjoint, gapless: the counter was serialized.
        assert db.query("MATCH (n:Person) RETURN count(n), min(n.id), max(n.id)") == [[200, 0, 199]]
