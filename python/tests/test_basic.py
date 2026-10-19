"""End-to-end tests for the Python bindings.

Requires the shared library: run `zig build` first, then
`pytest` (or `python -m pytest`) from this directory.
"""

import pytest

from acmedb import (
    AcmedbError,
    ClosedError,
    Database,
    NodeNotFoundError,
    ParseError,
    TypeMismatchError,
    UnknownVariableError,
)


@pytest.fixture
def db(tmp_path):
    with Database(str(tmp_path)) as db:
        yield db


def test_write_and_read(db):
    nid = db.allocate_node_id()
    db.add_node(nid, "Person")
    db.set_property(nid, "name", "Keanu Reeves")
    db.set_property(nid, "born", 1964)
    assert db.query("MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born") == [[1964]]


def test_edges(db):
    db.add_node(1, "Person")
    db.set_property(1, "name", "Keanu")
    db.add_node(100, "Movie")
    db.set_property(100, "title", "The Matrix")
    db.add_edge(1, 100, "ACTED_IN")
    assert db.query(
        "MATCH (p:Person {name: 'Keanu'})-[:ACTED_IN]->(m:Movie) RETURN m.title"
    ) == [["The Matrix"]]


def test_lists(db):
    assert db.query("RETURN [1, 2, 3]") == [[[1, 2, 3]]]
    assert db.query("RETURN collect('x')") == [[["x"]]]


def test_null(db):
    db.add_node(1, "Person")
    db.set_property(1, "name", "Keanu")
    rows = db.query(
        "MATCH (p:Person) OPTIONAL MATCH (p)-[:KNOWS]->(f:Person) RETURN p.name, f.name"
    )
    assert rows == [["Keanu", None]]


def test_errors(db):
    with pytest.raises(ParseError):
        db.query("MATCH (")
    with pytest.raises(UnknownVariableError):
        db.query("RETURN n.name")
    with pytest.raises(TypeMismatchError):
        db.query("RETURN size(1)")


def test_json_roundtrip(db):
    # A double quote inside a string, a boolean, and a list survive the JSON path.
    assert db.query("RETURN 'say \"hi\"', true, [1, 2, 3]") == [["say \"hi\"", True, [1, 2, 3]]]


def test_batched_write(db):
    with db.write():
        for i in range(100):
            nid = db.allocate_node_id()
            db.add_node(nid, "Person")
            db.set_property(nid, "id", nid)
    assert db.query("MATCH (n:Person) RETURN count(n)") == [[100]]


def test_write_abort(db):
    with pytest.raises(RuntimeError):
        with db.write():
            db.add_node(1, "Ghost")
            raise RuntimeError("boom")
    # Nothing survived the abort.
    assert db.query("MATCH (n:Ghost) RETURN count(n)") == [[0]]


def test_closed_database_raises(tmp_path):
    # Used to pass a NULL context into the library and segfault the interpreter.
    db = Database(str(tmp_path))
    db.close()
    db.close()  # idempotent
    with pytest.raises(ClosedError):
        db.query("RETURN 1")
    with pytest.raises(ClosedError):
        db.add_node(1, "P")
    with pytest.raises(ClosedError):
        db.allocate_node_id()


def test_int_range_is_enforced(db):
    # ctypes used to truncate silently: 2**70 was stored as 0.
    db.add_node(1, "P")
    db.set_property(1, "max", 2**63 - 1)
    db.set_property(1, "min", -(2**63))
    assert db.query("MATCH (p:P) RETURN p.max, p.min") == [[2**63 - 1, -(2**63)]]
    with pytest.raises(OverflowError):
        db.set_property(1, "big", 2**63)
    with pytest.raises(ValueError):
        db.add_node(-1, "P")
    with pytest.raises(ValueError):
        db.add_node(2**64, "P")


def test_unsupported_property_types(db):
    db.add_node(1, "P")
    for bad in (True, 1.5, None, [1]):
        with pytest.raises(TypeError):
            db.set_property(1, "x", bad)


def test_non_ascii_names_use_byte_lengths(db):
    # Lengths used to be counted in characters, truncating the UTF-8 bytes.
    db.add_node(1, "Pérsona")
    db.set_property(1, "año", 2024)
    db.set_property(1, "nombre", "Ñandú")
    db.add_node(2, "Pérsona")
    db.add_edge(1, 2, "CONOCE_Ñ")
    assert db.query(
        "MATCH (a:Pérsona)-[:CONOCE_Ñ]->(b:Pérsona) RETURN a.año, a.nombre"
    ) == [[2024, "Ñandú"]]


def test_mutators_reject_missing_nodes(db):
    db.add_node(1, "P")
    with pytest.raises(NodeNotFoundError):
        db.add_edge(1, 999, "X")
    with pytest.raises(NodeNotFoundError):
        db.set_property(999, "v", 1)
    assert db.query("MATCH (a)-[:X]->(b) RETURN count(*)") == [[0]]


def test_query_inside_write_is_refused(db):
    with pytest.raises(AcmedbError):
        with db.write():
            db.add_node(1, "P")
            db.query("RETURN 1")
    # The batch was aborted.
    assert db.query("MATCH (n) RETURN count(*)") == [[0]]
