"""End-to-end tests for the Python bindings.

Requires the shared library: run `zig build` first, then
`pytest` (or `python -m pytest`) from this directory.
"""

import math

import pytest

from acmedb import (
    AcmedbError,
    ArithmeticQueryError,
    ClosedError,
    Database,
    Duration,
    NodeNotFoundError,
    Node,
    ParameterMissingError,
    ParseError,
    Path,
    Relationship,
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


def test_property_types(db):
    db.add_node(1, "P")
    db.set_property(1, "flag", True)
    db.set_property(1, "tags", ["a", "b"])
    db.set_property(1, "doc", {"city": "Madrid", "floors": [1, None]})
    assert db.query("MATCH (p:P) RETURN p.flag, p.tags, p.doc.city") == [[True, ["a", "b"], "Madrid"]]
    db.set_property(1, "flag", None)  # removes it
    assert db.query("MATCH (p:P) RETURN p.flag") == [[None]]
    for bad in ([1, "a"], object()):
        with pytest.raises(TypeError):
            db.set_property(1, "x", bad)


def test_floats(db):
    db.add_node(1, "Sensor")
    db.set_property(1, "reading", 21.5)
    db.set_property(1, "offset", 2.0)
    rows = db.query("MATCH (s:Sensor) RETURN s.reading, s.offset, s.reading + 1, 7 / 2, 2 ^ 10, avg(s.reading)")
    assert rows == [[21.5, 2.0, 22.5, 3, 1024.0, 21.5]]
    assert isinstance(rows[0][1], float)
    # An integral float matches the integer it equals.
    assert db.query("MATCH (s:Sensor {offset: 2}) RETURN s.reading") == [[21.5]]
    nan, inf = db.query("RETURN 0.0 / 0.0, 1.0 / 0")[0]
    assert math.isnan(nan) and inf == math.inf


def test_durability_modes(tmp_path):
    with Database(str(tmp_path / "deferred"), durability="deferred") as fast:
        fast.query("UNWIND range(1, 10) AS i CREATE (:Event {n: i})")
        fast.sync()
        assert fast.query("MATCH (e:Event) RETURN count(*)") == [[10]]
    with Database(str(tmp_path / "deferred")) as reopened:
        assert reopened.query("MATCH (e:Event) RETURN count(*)") == [[10]]
    with pytest.raises(ValueError):
        Database(str(tmp_path), durability="sometimes")


def test_temporal_values(db):
    import datetime as dt
    from zoneinfo import ZoneInfo

    (d, t, ldt, zoned, offset, short, long), = db.query(
        "RETURN date('2024-07-02'), time('09:30:00.123456789+02:00'), localdatetime('2024-07-02T09:30'),"
        " datetime('2024-07-02T09:30[Europe/Madrid]'), datetime('2024-07-02T09:30-03:00'),"
        " duration('P1DT2H'), duration('P1M2D')"
    )
    assert d == dt.date(2024, 7, 2) and type(d) is dt.date
    # Microseconds: the nanoseconds are truncated.
    assert t == dt.time(9, 30, 0, 123456, tzinfo=dt.timezone(dt.timedelta(hours=2)))
    assert ldt == dt.datetime(2024, 7, 2, 9, 30) and ldt.tzinfo is None
    assert zoned == dt.datetime(2024, 7, 2, 9, 30, tzinfo=ZoneInfo("Europe/Madrid"))
    assert zoned.tzinfo == ZoneInfo("Europe/Madrid")
    assert offset.utcoffset() == dt.timedelta(hours=-3)
    assert short == dt.timedelta(days=1, hours=2)
    assert long == Duration(months=1, days=2) and str(long) == "P1M2D"

    # datetime-module values go in as parameters, keeping their zone.
    madrid = dt.datetime(2024, 7, 2, 7, 30, tzinfo=dt.timezone.utc).astimezone(ZoneInfo("Europe/Madrid"))
    rows = db.query(
        "RETURN $d + duration('P1D'), $at.hour, $at.timezone, $wait * 2, $month + $month, $local",
        d=dt.date(2024, 7, 2), at=madrid, wait=dt.timedelta(minutes=90), month=Duration(months=1),
        local=dt.time(8, 15),
    )
    assert rows == [[dt.date(2024, 7, 3), 9, "Europe/Madrid", dt.timedelta(hours=3), Duration(months=2), dt.time(8, 15)]]
    # An ambiguous wall-clock time keeps the instant (fold) across the round trip.
    later = dt.datetime(2024, 10, 27, 2, 30, fold=1, tzinfo=ZoneInfo("Europe/Madrid"))
    (back,), = db.query("RETURN $t", t=later)
    assert back.utcoffset() == dt.timedelta(hours=1) and back == later
    # Temporal values are stored as properties.
    db.query("CREATE (:Badge {issued: date('2024-03-01'), shifts: [localtime('09:00'), localtime('18:00')]})")
    (issued, shifts), = db.query("MATCH (b:Badge) RETURN b.issued, b.shifts")
    assert issued == dt.date(2024, 3, 1) and shifts == [dt.time(9), dt.time(18)]
    # Years Python cannot represent are an error; the exact text is available.
    with pytest.raises(ValueError):
        db.query("RETURN date('+20000-01-01')")


def test_iso_temporals(tmp_path):
    with Database(str(tmp_path), temporals="iso") as db:
        assert db.query("RETURN time('09:30:00.123456789+02:00'), date('+20000-01-01')") == [
            ["09:30:00.123456789+02:00", "+20000-01-01"]
        ]


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


def test_export_graph(db):
    db.query("CREATE (a:Person {name: 'Ana'})-[:KNOWS {since: 2020}]->(:Person {name: 'Bo'})")
    assert db.export_graph() == {
        "nodes": [
            {"id": 0, "labels": ["Person"], "properties": {"name": "Ana"}},
            {"id": 1, "labels": ["Person"], "properties": {"name": "Bo"}},
        ],
        "relationships": [
            {"id": 0, "source": 0, "target": 1, "type": "KNOWS", "properties": {"since": 2020}},
        ],
    }


def test_returns_whole_nodes_and_relationships(db):
    db.query("CREATE (:Person:Admin {name: 'Ana'})-[:KNOWS {since: 2020}]->(:Person {name: 'Bo'})")
    rows = db.query("MATCH (a {name: 'Ana'})-[r]->(b) RETURN a, r, [b]")
    (a, r, [b]), = rows
    assert a == Node(0, ("Admin", "Person"), {"name": "Ana"})
    assert r == Relationship(0, 0, 1, "KNOWS", {"since": 2020})
    assert b == Node(1, ("Person",), {"name": "Bo"})
    # A node the query deleted keeps its id but has no data left to show.
    (gone,), = db.query("MATCH (n {name: 'Bo'}) DETACH DELETE n RETURN n")
    assert gone == Node(1, (), {})


def test_query_parameters(db):
    db.query("CREATE (:Card {id: 123, holder: 'Ana'}), (:Card {id: 456, holder: 'Bo'})")
    assert db.query("MATCH (c:Card {id: $card}) RETURN c.holder", card=123) == [["Ana"]]
    assert db.query("MATCH (c:Card) WHERE c.id IN $ids RETURN c.holder", {"ids": (456,)}) == [["Bo"]]
    # A Cypher parameter may be called `text` or `parameters`: no clash.
    assert db.query("RETURN $text, $parameters", text="t", parameters=1) == [["t", 1]]
    with pytest.raises(ParameterMissingError):
        db.query("RETURN $absent")
    assert db.query("RETURN $x, $x * 2", x=1.5) == [[1.5, 3.0]]
    # No JSON in between: NaN and infinities travel as they are.
    nan, inf = db.query("RETURN $nan, $inf", nan=float("nan"), inf=float("inf"))[0]
    assert math.isnan(nan) and inf == math.inf
    with pytest.raises(OverflowError):
        db.query("RETURN $x", x=[2**64])


def test_arithmetic(db):
    assert db.query("RETURN 1 + 2 * 3, -7 / 2, 'n' + 1") == [[7, -3, "n1"]]
    with pytest.raises(ArithmeticError):  # ArithmeticQueryError is one
        db.query("RETURN 1 / 0")
    with pytest.raises(ArithmeticQueryError):
        db.query("RETURN 9223372036854775807 + 1")


def test_maps(db):
    assert db.query("RETURN {b: 1, a: [true]}") == [[{"a": [True], "b": 1}]]
    assert db.query("RETURN $m.zone, $m['floors'][0]", m={"zone": "Z1", "floors": [3]}) == [["Z1", 3]]
    with pytest.raises(TypeError):
        db.query("RETURN $m", m={1: "x"})


def test_paths(db):
    db.query("CREATE (:G {n: 'a'})-[:IN]->(:G {n: 'b'})-[:IN]->(:G {n: 'c'})")
    (path,), = db.query("MATCH p = (:G {n: 'a'})-[:IN*]->(:G {n: 'c'}) RETURN p")
    assert isinstance(path, Path)
    assert [n.properties["n"] for n in path.nodes] == ["a", "b", "c"]
    assert [r.type for r in path.relationships] == ["IN", "IN"]


def test_table_procedures(db):
    # The hook the openCypher TCK runner defines its test procedures with.
    db._define_procedure("test.city", [("name", "STRING?"), ("id", "INTEGER?")], [("city", "STRING?")],
                         [["Ana", 1, "Madrid"], ["Ana", 2, "Lyon"], [None, 1, "Nowhere"]])
    db._define_procedure("test.nothing", [], [], [])
    assert db.query("CALL test.city('Ana', 2)") == [["Lyon"]]
    assert db.query("CALL test.city(null, 1) YIELD city RETURN city") == [["Nowhere"]]
    assert db.query("CALL test.city", name="Ana", id=1) == [["Madrid"]]
    db.query("CREATE (:P), (:P)")
    assert db.query("MATCH (p:P) CALL test.nothing() RETURN count(p)") == [[2]]
    with pytest.raises(AcmedbError):
        db.query("CALL test.city(true, 1)")
    with pytest.raises(AcmedbError):
        db.query("CALL test.city YIELD city RETURN city", name="Ana", id=1)
