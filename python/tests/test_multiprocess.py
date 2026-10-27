"""Multi-process test: two processes open the same file, both write, serialized.

Runs two `python -c` writer processes concurrently against one database and
verifies node-id allocation is disjoint (no collision) and both writes commit.
"""

import os
import subprocess
import sys
from pathlib import Path

from zypherdb import Database

_PYTHON_DIR = str(Path(__file__).resolve().parent.parent)  # .../python

_WRITER = r"""
import sys
from zypherdb import Database

path, n = sys.argv[1], int(sys.argv[2])
with Database(path) as db:
    for _ in range(n):
        nid = db.allocate_node_id()
        db.add_node(nid, "Person")
        db.set_property(nid, "id", nid)
"""


def test_two_writers_serialize(tmp_path):
    path = str(tmp_path)  # a directory: the engine creates its data and lock files inside
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


def operators(node):
    """The operator names of a plan, depth first."""
    return [node["operator"]] + [name for child in node["children"] for name in operators(child)]


def test_an_index_made_by_another_process_is_kept_current(tmp_path):
    # This process keeps the schema it has read; another process changes it.
    path = str(tmp_path)
    env = dict(os.environ)
    env["PYTHONPATH"] = _PYTHON_DIR
    maker = 'import sys\nfrom zypherdb import Database\nwith Database(sys.argv[1]) as db: db.query(sys.argv[2])'
    with Database(path) as db:
        db.query("CREATE INDEX FOR (c:Card) ON (c.number)")
        db.query("CREATE (:Card {number: 1}), (:Person {id: 1})")
        assert subprocess.run([sys.executable, "-c", maker, path, "CREATE INDEX people FOR (p:Person) ON (p.id)"], env=env).returncode == 0

        db.query("CREATE (:Person {id: 2})")
        query = "MATCH (p:Person {id: $id}) RETURN p.id"
        assert "NodeIndexSeek" in operators(db.explain(query, id=2))
        assert db.query(query, id=2) == [[2]]
        assert db.check()["ok"]

        assert subprocess.run([sys.executable, "-c", maker, path, "DROP INDEX people"], env=env).returncode == 0
        db.query("CREATE (:Person {id: 3})")
        assert "NodeIndexSeek" not in operators(db.explain(query, id=3))
        assert db.query(query, id=3) == [[3]]
        assert db.check()["ok"]
