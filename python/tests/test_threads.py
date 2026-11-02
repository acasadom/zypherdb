"""Several threads on one Database: each calls through a session of its own."""

import threading
import time

import pytest

from zypherdb import ClosedError, Database, ZypherDBError


def run_threads(count, target):
    """Runs `target(index)` on `count` threads; re-raises the first failure."""
    failures = []

    def guarded(index):
        try:
            target(index)
        except BaseException as failure:  # noqa: BLE001 - handed to the test
            failures.append(failure)

    threads = [threading.Thread(target=guarded, args=(index,)) for index in range(count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if failures:
        raise failures[0]


def test_threads_write_and_read_at_once_each_reading_its_own_writes(tmp_path):
    with Database(str(tmp_path / "db")) as db:
        writes = 50

        def write_and_read_back(thread):
            for written in range(writes):
                db.query("CREATE (:T {thread: $thread})", thread=thread)
                assert db.query("MATCH (n:T {thread: $thread}) RETURN count(n)", thread=thread) == [[written + 1]]

        run_threads(8, write_and_read_back)
        assert db.query("MATCH (n:T) RETURN count(n)") == [[8 * writes]]


def test_a_write_block_of_one_thread_holds_up_no_read_of_another(tmp_path):
    with Database(str(tmp_path / "db")) as db:
        db.query("CREATE (:T)")
        read = {}
        reader = threading.Thread(target=lambda: read.setdefault("rows", db.query("MATCH (n:T) RETURN count(n)")))
        with db.write():
            db.add_node(db.allocate_node_id(), "T")
            reader.start()
            reader.join(timeout=5)
            read_while_writing = not reader.is_alive()
        reader.join()
        assert read_while_writing, "a read waited for another thread's write block"
        assert read["rows"] == [[1]]
        assert db.query("MATCH (n:T) RETURN count(n)") == [[2]]


def test_writes_wait_for_another_threads_write_block(tmp_path):
    # A write waits for the writer without the GIL: the block's thread needs it to end.
    with Database(str(tmp_path / "db")) as db:
        order = []

        def write():
            with db.write():
                db.add_node(db.allocate_node_id(), "T")
            db.add_node(db.allocate_node_id(), "T")
            db.query("CREATE (:T)")
            order.append("writes")

        writer = threading.Thread(target=write)
        with db.write():
            writer.start()
            time.sleep(0.2)
            order.append("block")
        writer.join(timeout=5)
        assert not writer.is_alive()
        assert order == ["block", "writes"]
        assert db.query("MATCH (n:T) RETURN count(n)") == [[3]]


def test_a_prepared_query_runs_on_several_threads(tmp_path):
    with Database(str(tmp_path / "db")) as db:
        db.query("UNWIND range(1, 10) AS i CREATE (:T {i: i})")
        lookup = db.prepare("MATCH (n:T {i: $i}) RETURN n.i")

        def look_up(thread):
            for _ in range(100):
                assert lookup.query(i=thread + 1) == [[thread + 1]]

        run_threads(8, look_up)


def test_close_waits_for_the_calls_under_way_and_refuses_later_ones(tmp_path):
    db = Database(str(tmp_path / "db"))
    db.query("CREATE (:T)")
    blocking = threading.Event()
    done = {}

    def write_slowly():
        with db.write():
            blocking.set()
            time.sleep(0.3)
            db.add_node(db.allocate_node_id(), "T")
        try:
            db.query("MATCH (n:T) RETURN count(n)")
        except ClosedError:
            done["closed"] = True

    writer = threading.Thread(target=write_slowly)
    writer.start()
    blocking.wait()
    db.close()
    writer.join()
    # The block ended and committed; the query after it came once the database was closing.
    assert done == {"closed": True}
    with pytest.raises(ClosedError):
        db.query("MATCH (n) RETURN n")
    with Database(str(tmp_path / "db")) as again:
        assert again.query("MATCH (n:T) RETURN count(n)") == [[2]]


def test_close_inside_a_write_block_is_refused(tmp_path):
    with Database(str(tmp_path / "db")) as db:
        with db.write():
            with pytest.raises(ZypherDBError, match="write"):
                db.close()
