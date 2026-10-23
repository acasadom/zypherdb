"""EXPLAIN and PROFILE from Python: the plan as a tree of operators."""

import pytest

from acmedb import AcmedbError, Database, Node, ParseError


@pytest.fixture
def db(tmp_path):
    with Database(str(tmp_path)) as database:
        database.query("UNWIND range(1, 10) AS i CREATE (:Person {id: i})")
        database.query("MATCH (a:Person), (b:Person) WHERE b.id = a.id + 1 CREATE (a)-[:KNOWS]->(b)")
        yield database


def operators(node):
    """The operator names of a plan, depth first."""
    return [node["operator"]] + [name for child in node["children"] for name in operators(child)]


def test_explain_returns_the_plan_as_a_tree(db):
    plan = db.explain("MATCH (p:Person {id: $id}) OPTIONAL MATCH (p)-[:KNOWS]->(f) RETURN f.id", id=3)
    assert plan["operator"] == "Return"
    assert plan["details"] == "f.id"
    assert plan["rows"] is None and plan["time_ms"] is None
    optional = plan["children"][0]
    assert optional["operator"] == "Optional"
    # Its input first, then the chain it runs.
    assert [child["operator"] for child in optional["children"]] == ["NodeIndexSeek", "Expand(All)"]
    assert optional["children"][0]["details"] == "(p:Person {id: $id})"
    assert optional["children"][0]["estimated_rows"] == 1
    assert operators(plan) == ["Return", "Optional", "NodeIndexSeek", "Expand(All)", "BoundNode"]


def test_explain_does_not_run_the_query(db):
    db.explain("CREATE (:Event)")
    assert db.query("MATCH (e:Event) RETURN count(e)") == [[0]]


def test_profile_returns_the_rows_and_what_each_operator_did(db):
    rows, plan = db.profile("MATCH (p:Person) WHERE p.id <= 3 RETURN p ORDER BY p.id")
    assert [row[0].properties["id"] for row in rows] == [1, 2, 3]
    assert isinstance(rows[0][0], Node)
    assert plan["operator"] == "Return" and plan["rows"] == 3
    scan = plan["children"][0]["children"][0]
    assert scan["operator"] == "NodeIndexRangeSeek"
    assert scan["rows"] == 3
    assert scan["time_ms"] >= 0


def test_profile_commits_writes(db):
    rows, plan = db.profile("UNWIND [1, 2] AS n CREATE (:Event {n: n}) RETURN n")
    assert rows == [[1], [2]]
    assert db.query("MATCH (e:Event) RETURN count(e)") == [[2]]


def test_union_plans_have_one_child_per_part(db):
    plan = db.explain("MATCH (p:Person) RETURN p.id AS x UNION MATCH (p:Person) RETURN p.id + 1 AS x")
    assert plan["operator"] == "Union"
    assert [child["operator"] for child in plan["children"]] == ["Return", "Return"]


def test_explain_and_profile_as_rows(db):
    rows = db.query("EXPLAIN MATCH (p:Person) RETURN count(*)")
    assert rows == [[0, "Return", "count(*)", 1, None, None], [0, "NodeByLabelScan", "(p:Person)", 10, None, None]]
    rows = db.query("PROFILE MATCH (p:Person) RETURN count(*)")
    assert [row[4] for row in rows] == [1, 10]


def test_plan_errors(db):
    with pytest.raises(ParseError):
        db.explain("SHOW INDEXES")
    with db.write():
        with pytest.raises(AcmedbError):
            db.explain("MATCH (n) RETURN n")
