"""Replication through the Python API: a database opened to serve replicas,
another opened to replicate from it."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

from zypherdb import Database
from zypherdb.errors import StorageError, ZypherDBError

TOKEN = "the master's token"


@pytest.fixture
def master(tmp_path):
    with Database(str(tmp_path / "master"), serve="127.0.0.1:0", token=TOKEN) as db:
        yield db


def address_of(master):
    return master.replication_status()["address"]


def test_a_replica_reads_a_write_made_on_the_master(master, tmp_path):
    with Database(str(tmp_path / "replica"), replicate_from=address_of(master), token=TOKEN) as replica:
        master.query("CREATE (:Person {name: 'Ada'})")
        lsn = master.last_lsn
        assert lsn > 0
        assert replica.wait_for(lsn, timeout=20)
        assert replica.last_lsn == lsn
        assert replica.query("MATCH (p:Person) RETURN p.name") == [["Ada"]]


def test_a_replica_refuses_writes(master, tmp_path):
    with Database(str(tmp_path / "replica"), replicate_from=address_of(master), token=TOKEN) as replica:
        with pytest.raises(ZypherDBError, match="is a replica"):
            replica.query("CREATE (:Person)")


def test_both_tell_how_replication_goes(master, tmp_path):
    with Database(str(tmp_path / "replica"), replicate_from=address_of(master), token=TOKEN) as replica:
        master.query("CREATE (:Person)")
        lsn = master.last_lsn
        assert replica.wait_for(lsn, timeout=20)
        status = replica.replication_status()
        assert status["role"] == "replica"
        assert status["applied_lsn"] == lsn
        assert status["halted"] is None
        status = master.replication_status()
        assert status["role"] == "master"
        assert status["last_lsn"] == lsn
        assert len(status["replicas"]) == 1
        assert status["replicas"][0]["phase"] in ("introducing", "copying", "streaming")


def test_a_replica_told_the_wrong_token_halts_and_says_why(master, tmp_path):
    with Database(str(tmp_path / "replica"), replicate_from=address_of(master), token="another") as replica:
        assert not replica.wait_for(1, timeout=20)
        assert replica.replication_status()["halted"] == "token"


def test_without_replication(tmp_path):
    with Database(str(tmp_path / "db")) as db:
        db.query("CREATE ()")
        assert db.last_lsn == 0
        assert db.wait_for(10, timeout=0)
        assert db.replication_status() is None


def test_a_master_cannot_become_a_replica(master, tmp_path):
    path = str(tmp_path / "other")
    with Database(path, serve="127.0.0.1:0", token=TOKEN):
        pass
    with pytest.raises(StorageError, match="is a master"):
        Database(path, replicate_from=address_of(master), token=TOKEN)


def test_the_role_needs_a_token_and_only_one_role(tmp_path):
    with pytest.raises(ValueError, match="token"):
        Database(str(tmp_path / "db"), serve="127.0.0.1:0")
    with pytest.raises(ValueError, match="not both"):
        Database(str(tmp_path / "db"), serve="127.0.0.1:0", replicate_from="127.0.0.1:1", token=TOKEN)


def test_closing_stops_serving(tmp_path):
    path = str(tmp_path / "master")
    with Database(path, serve="127.0.0.1:0", token=TOKEN) as db:
        address = address_of(db)
    with Database(path, serve=address, token=TOKEN) as db:
        assert address_of(db) == address


_STANDBY = r"""
import sys, time
from zypherdb import Database

path, address = sys.argv[1], sys.argv[2]
with Database(path, serve=address, token="the master's token") as db:
    print(db.replication_status()["standby"], flush=True)
    sys.stdin.readline()  # the parent's master closed
    deadline = time.monotonic() + 20
    while db.replication_status()["standby"] and time.monotonic() < deadline:
        time.sleep(0.01)
    print(db.replication_status()["standby"], flush=True)
    db.query("CREATE (:Person {name: 'Grace'})")
    print(db.last_lsn, flush=True)
    sys.stdin.readline()  # the parent read it on the replica
"""


def test_a_process_standing_by_takes_over_and_a_reader_without_a_role_waits(tmp_path):
    path = str(tmp_path / "master")
    environment = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent.parent))
    master = Database(path, serve="127.0.0.1:0", token=TOKEN)
    address = address_of(master)
    standby = subprocess.Popen(
        [sys.executable, "-c", _STANDBY, path, address],
        env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    try:
        with Database(str(tmp_path / "replica"), replicate_from=address, token=TOKEN) as replica:
            assert standby.stdout.readline().strip() == "True"
            master.query("CREATE (:Person {name: 'Ada'})")
            assert replica.wait_for(master.last_lsn, timeout=20)
            master.close()
            standby.stdin.write("closed\n")
            standby.stdin.flush()
            assert standby.stdout.readline().strip() == "False"
            lsn = int(standby.stdout.readline())
            assert replica.wait_for(lsn, timeout=20)
            assert replica.query("MATCH (p:Person) RETURN p.name ORDER BY p.name") == [["Ada"], ["Grace"]]
            # A reader without a role on the replica waits for it too.
            output = subprocess.run(
                [sys.executable, "-c", _READER, str(tmp_path / "replica"), str(lsn)],
                env=environment, capture_output=True, text=True, timeout=60, check=True,
            ).stdout.splitlines()
            assert output == ["True", "[['Ada'], ['Grace']]", "False"]
            standby.stdin.write("done\n")
            standby.stdin.flush()
        assert standby.wait(timeout=60) == 0
    finally:
        master.close()
        if standby.poll() is None:
            standby.kill()


_READER = r"""
import sys
from zypherdb import Database

path, lsn = sys.argv[1], int(sys.argv[2])
with Database(path) as db:
    print(db.wait_for(lsn, timeout=20))
    print(db.query("MATCH (p:Person) RETURN p.name ORDER BY p.name"))
    print(db.wait_for(lsn + 1, timeout=0.2))
"""
