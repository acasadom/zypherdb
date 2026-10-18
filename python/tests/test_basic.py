"""End-to-end tests for the Python bindings.

Requires the shared library: run `zig build` first, then
`pytest` (or `python -m pytest`) from this directory.
"""

import pytest

from acmedb import (
    Database,
    ParseError,
    TypeMismatchError,
    UnknownVariableError,
)


@pytest.fixture
def db(tmp_path):
    with Database(str(tmp_path)) as db:
        yield db


def test_write_and_read(db):
    nid = db.alloc_node_id()
    db.add_node(nid, "Person")
    db.set_prop(nid, "name", "Keanu Reeves")
    db.set_prop(nid, "born", 1964)
    assert db.query("MATCH (p:Person {name: 'Keanu Reeves'}) RETURN p.born") == [[1964]]


def test_edges(db):
    db.add_node(1, "Person")
    db.set_prop(1, "name", "Keanu")
    db.add_node(100, "Movie")
    db.set_prop(100, "title", "The Matrix")
    db.add_edge(1, 100, "ACTED_IN")
    assert db.query(
        "MATCH (p:Person {name: 'Keanu'})-[:ACTED_IN]->(m:Movie) RETURN m.title"
    ) == [["The Matrix"]]


def test_lists(db):
    assert db.query("RETURN [1, 2, 3]") == [[[1, 2, 3]]]
    assert db.query("RETURN collect('x')") == [[["x"]]]


def test_null(db):
    db.add_node(1, "Person")
    db.set_prop(1, "name", "Keanu")
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
            nid = db.alloc_node_id()
            db.add_node(nid, "Person")
            db.set_prop(nid, "id", nid)
    assert db.query("MATCH (n:Person) RETURN count(n)") == [[100]]


def test_write_abort(db):
    with pytest.raises(RuntimeError):
        with db.write():
            db.add_node(1, "Ghost")
            raise RuntimeError("boom")
    # Nothing survived the abort.
    assert db.query("MATCH (n:Ghost) RETURN count(n)") == []
