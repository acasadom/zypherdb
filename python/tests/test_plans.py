"""EXPLAIN and PROFILE from Python: the plan as a tree of operators."""

import pytest

from zypherdb import ZypherDBError, Database, Node, ParseError


@pytest.fixture
def db(tmp_path):
    with Database(str(tmp_path)) as database:
        database.query("CREATE INDEX FOR (p:Person) ON (p.id)")
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
    sort = plan["children"][0]
    assert sort["operator"] == "Sort" and sort["details"] == "ORDER BY p.id"
    projection = sort["children"][0]
    assert projection["operator"] == "Projection" and projection["children"][0]["operator"] == "Filter"
    scan = projection["children"][0]["children"][0]
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
    assert rows == [
        [0, "Return", "count(*)", 1, None, None],
        [0, "Aggregation", "count(*)", 1, None, None],
        [0, "NodeByLabelScan", "(p:Person)", 10, None, None],
    ]
    rows = db.query("PROFILE MATCH (p:Person) RETURN count(*)")
    assert [row[4] for row in rows] == [1, 1, 10]


def test_plan_errors(db):
    with pytest.raises(ParseError):
        db.explain("SHOW INDEXES")
    with db.write():
        with pytest.raises(ZypherDBError):
            db.explain("MATCH (n) RETURN n")


def test_prepared_query_runs_with_new_parameters(db):
    lookup = db.prepare("MATCH (p:Person {id: $id})-[:KNOWS]->(f) RETURN f.id AS friend")
    assert lookup.parameters == ("id",)
    assert lookup.columns == ("friend",)
    assert lookup.query(id=1) == [[2]]
    assert lookup.query({"id": 5}) == [[6]]
    assert lookup.query(id=10) == []
    assert "MATCH" in repr(lookup)


def test_show_commands_name_their_columns(db):
    assert db.prepare("SHOW INDEXES").columns == (
        "name", "type", "entityType", "labelsOrTypes", "properties", "owningConstraint", "options")
    assert db.prepare("SHOW CONSTRAINTS").columns == (
        "name", "type", "entityType", "labelsOrTypes", "properties", "ownedIndex")


def test_prepared_query_sees_later_writes(db):
    count = db.prepare("MATCH (e:Event) RETURN count(e)")
    create = db.prepare("CREATE (:Event {n: $n})")
    for n in range(3):
        create.query(n=n)
    assert count.query() == [[3]]


def test_prepare_fails_on_a_bad_query(db):
    with pytest.raises(ParseError):
        db.prepare("MATCH (n RETURN n")


def test_prepared_query_after_close(tmp_path):
    database = Database(str(tmp_path))
    lookup = database.prepare("RETURN 1")
    database.close()
    with pytest.raises(ZypherDBError):
        lookup.query()


def test_query_reuses_statements_and_their_plans_stay_right(db):
    # The same text, run again after the graph grew: the cached plan is
    # planned again when its counts drift, and the rows stay right.
    text = "MATCH (p:Person)-[:KNOWS]->(q:Person) WHERE p.id = $id RETURN q.id"
    assert db.query(text, id=3) == [[4]]
    db.query("UNWIND range(100, 400) AS i CREATE (:Person {id: i})")
    assert db.query(text, id=3) == [[4]]
    assert db.query(text, id=100) == []
