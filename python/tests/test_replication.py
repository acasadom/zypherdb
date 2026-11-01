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
    with Database(str(tmp_path / "replica"), replicate_from=address_of(master), token=TOKEN, name="eu-1 ñ") as replica:
        master.query("CREATE (:Person)")
        lsn = master.last_lsn
        assert replica.wait_for(lsn, timeout=20)
        status = replica.replication_status()
        assert status["role"] == "replica"
        assert status["name"] == "eu-1 ñ"
        assert status["master_address"] == address_of(master)
        assert status["phase"] in ("copying", "streaming")
        assert status["last_contact_ms"] >= 0
        assert status["applied_lsn"] == lsn
        assert status["halted"] is None
        status = master.replication_status()
        assert status["role"] == "master"
        assert status["last_lsn"] == lsn
        assert len(status["replicas"]) == 1
        served = status["replicas"][0]
        assert served["phase"] in ("introducing", "copying", "streaming")
        assert served["address"].startswith("127.0.0.1:")
        assert served["connected_ms"] >= 0


def test_a_replica_is_named_after_its_host_unless_told(master, tmp_path):
    with Database(str(tmp_path / "replica"), replicate_from=address_of(master), token=TOKEN) as replica:
        assert replica.replication_status()["name"]
    with pytest.raises(ValueError, match="at most 255 bytes"):
        Database(str(tmp_path / "other"), replicate_from=address_of(master), token=TOKEN, name="n" * 256)
    with pytest.raises(ValueError, match="only a replica"):
        Database(str(tmp_path / "another"), serve="127.0.0.1:0", token=TOKEN, name="eu-1")


def test_a_replica_told_the_wrong_token_halts_and_says_why(master, tmp_path):
    with Database(str(tmp_path / "replica"), replicate_from=address_of(master), token="another") as replica:
        assert not replica.wait_for(1, timeout=20)
        status = replica.replication_status()
        assert status["halted"] == "token"
        assert status["phase"] == "halted"


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


def forwarding_replica(master, tmp_path, name="replica", **options):
    replica = Database(str(tmp_path / name), replicate_from=address_of(master), token=TOKEN, forward_writes=True, **options)
    # Its first copy: a write before it has no master's database to name.
    master.query("CREATE (:Seed)")
    assert replica.wait_for(master.last_lsn, timeout=20)
    return replica


def test_a_replica_that_forwards_writes_sends_them_to_its_master(master, tmp_path):
    with forwarding_replica(master, tmp_path) as replica:
        [[ada]] = replica.query("CREATE (p:Person {name: $name}) RETURN p", {"name": "Ada"})
        assert ada.labels == ("Person",)
        assert ada.properties == {"name": "Ada"}
        # Read-your-writes, and the master has it.
        assert replica.query("MATCH (p:Person) RETURN p.name") == [["Ada"]]
        assert master.query("MATCH (p:Person) RETURN p.name") == [["Ada"]]
        replica.query("CREATE CONSTRAINT person_name FOR (p:Person) REQUIRE p.name IS UNIQUE")
        with pytest.raises(ZypherDBError, match="constraint .person_name."):
            replica.query("CREATE (:Person {name: 'Ada'})")
        assert replica.query("MATCH (p:Person) RETURN count(p)") == [[1]]


def test_a_replica_refuses_what_it_cannot_forward(master, tmp_path):
    with forwarding_replica(master, tmp_path) as replica:
        replica._define_procedure("test.names", [], [("name", "STRING?")], [["Ada"]])
        with pytest.raises(ZypherDBError, match="defined in this process"):
            replica.query("CALL test.names() YIELD name CREATE (:Person {name: name})")
        assert replica.query("CALL test.names() YIELD name RETURN name") == [["Ada"]]
        with pytest.raises(ZypherDBError, match="LOAD CSV"):
            replica.query("LOAD CSV FROM 'file:///people.csv' AS row CREATE (:Person)")
        with pytest.raises(ZypherDBError, match="PROFILE"):
            replica.profile("CREATE (:Person)")
        with pytest.raises(ZypherDBError, match="write blocks"):
            with replica.write():
                pass
        assert master.query("MATCH (p:Person) RETURN count(p)") == [[0]]


def test_a_forwarded_write_to_a_master_gone_did_not_run(tmp_path):
    master = Database(str(tmp_path / "master"), serve="127.0.0.1:0", token=TOKEN)
    try:
        replica = forwarding_replica(master, tmp_path, forward_timeout=1.0)
    finally:
        master.close()
    with replica:
        with pytest.raises(ZypherDBError, match="did not run"):
            replica.query("CREATE (:Person)")


def test_a_process_standing_by_on_a_replica_forwards_writes_too(master, tmp_path):
    environment = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parent.parent))
    with forwarding_replica(master, tmp_path) as replica:
        output = subprocess.run(
            [sys.executable, "-c", _FORWARDING_STANDBY, str(tmp_path / "replica"), address_of(master)],
            env=environment, capture_output=True, text=True, timeout=60, check=True,
        ).stdout.splitlines()
        assert output == ["True", "[['Grace']]"]
        assert replica.wait_for(master.last_lsn, timeout=20)
        assert replica.query("MATCH (p:Person) RETURN p.name") == [["Grace"]]


_FORWARDING_STANDBY = r"""
import sys
from zypherdb import Database

path, address = sys.argv[1], sys.argv[2]
with Database(path, replicate_from=address, token="the master's token", forward_writes=True) as db:
    print(db.replication_status()["standby"])
    print(db.query("CREATE (p:Person {name: 'Grace'}) RETURN p.name"))
"""
