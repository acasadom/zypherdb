"""The access-control benchmark on several embedded graph databases, from Python.

    python bench/comparison/bench_python.py --engine zypherdb|kuzu|latticedb|sparrowdb --people N --dir DIR [--runs R]
                     [--threads T]    (kuzu: threads per query; default: Kuzu's own)

Every engine runs through its native Python binding (zypherdb: Zig module;
Kuzu: pybind11; SparrowDB: PyO3; LatticeDB: ctypes, whose overhead was
measured separately and is small). Same generated graph, same parameters,
same Cypher text, with names chosen to avoid each engine's reserved words
(Team, opens/closes, LOCATED_IN). Each engine loads by its fastest bulk path
and reuses prepared statements where it has them.

One JSON line per measurement: load, then per query the median and p95 in
microseconds and the answers for the first parameter sets.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
import shutil
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))

DEPARTMENTS = ["engineering", "sales", "support", "finance", "legal", "operations", "research", "security"]


def graph(people: int):
    rng = random.Random(7)
    teams, zones, doors = max(people // 100, 10), max(people // 500, 2), max(people // 10, 2)
    memberships = set()
    for i in range(people):
        for m in range(1 + rng.randrange(3)):
            memberships.add((i, (rng.randrange(teams) + m * 7) % teams))
    return dict(
        people=people, teams=teams, zones=zones, doors=doors,
        persons=[(i, f"person-{i}", 18 + i % 50, DEPARTMENTS[i % 8]) for i in range(people)],
        memberships=sorted(memberships),
        hierarchy=[(i, i // 10) for i in range(10, teams)],
        grants=sorted({(i, (i * 3 + z * 11) % zones) for i in range(teams) for z in range(2)}),
        door_zones=[(i, i % zones) for i in range(doors)],
    )


QUERIES = [
    ("card lookup", "MATCH (c:Card {number: $card}) RETURN c.number", ("card",), False),
    ("person's teams (1 hop)", "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g) RETURN g.name", ("person",), False),
    ("colleagues (2 hops, distinct)",
     "MATCH (p:Person {id: $person})-[:MEMBER_OF]->(g)<-[:MEMBER_OF]-(q) RETURN count(DISTINCT q)", ("person",), False),
    ("may this card open this door?",
     "MATCH (c:Card {number: $card})-[:HELD_BY]->(p)-[:MEMBER_OF*1..3]->(g)-[w:MAY_ENTER]->(z)<-[:LOCATED_IN]-(d:Door {id: $door}) "
     "WHERE 3 IN w.days AND w.opens <= 10 AND 10 < w.closes RETURN count(z)", ("card", "door"), False),
    ("same, with EXISTS",
     "MATCH (c:Card {number: $card}), (d:Door {id: $door}) "
     "RETURN EXISTS { MATCH (c)-[:HELD_BY]->()-[:MEMBER_OF*1..3]->()-[w:MAY_ENTER]->()<-[:LOCATED_IN]-(d) WHERE 3 IN w.days }",
     ("card", "door"), False),
    ("doors of a person's zones",
     "MATCH (p:Person {id: $person})-[:MEMBER_OF*1..3]->(x)-[:MAY_ENTER]->(z)<-[:LOCATED_IN]-(d) RETURN count(DISTINCT d)",
     ("person",), False),
    ("people over 60 (scan + filter)", "MATCH (p:Person) WHERE p.age > 60 RETURN count(p)", (), True),
    ("oldest 10 (ORDER BY + LIMIT)", "MATCH (p:Person) RETURN p.name ORDER BY p.age DESC, p.id LIMIT 10", (), True),
    ("team sizes (aggregate)",
     "MATCH (p:Person)-[:MEMBER_OF]->(g:Team) RETURN g.name, count(p) AS n ORDER BY n DESC, g.name LIMIT 10", (), True),
    ("department counts", "MATCH (p:Person) RETURN p.department, count(p) ORDER BY p.department", (), True),
    ("return all people (3 columns)", "MATCH (p:Person) RETURN p.id, p.name, p.age", (), True),
    ("create one node (commit)", "CREATE (:Event {card: $card})", ("card",), False),
    ("create 1000 nodes (UNWIND)", "UNWIND range(1, 1000) AS i CREATE (:Event {n: i})", (), True),
]

GRANT = {"days": [1, 2, 3, 4, 5], "opens": 9, "closes": 18}


class ZypherDB:
    def __init__(self, path, args):
        import zypherdb

        self.db = zypherdb.Database(path, durability=args.durability)

    def load(self, g):
        db, ids = self.db, {}
        with db.write():
            for i, name, age, department in g["persons"]:
                node = ids["Person", i] = db.allocate_node_id()
                db.add_node(node, "Person")
                for key, value in (("id", i), ("name", name), ("age", age), ("department", department)):
                    db.set_property(node, key, value)
                card = db.allocate_node_id()
                db.add_node(card, "Card")
                db.set_property(card, "number", 1_000_000 + i)
                db.add_edge(card, node, "HELD_BY")
            for kind, count in (("Team", g["teams"]), ("Zone", g["zones"]), ("Door", g["doors"])):
                for i in range(count):
                    node = ids[kind, i] = db.allocate_node_id()
                    db.add_node(node, kind)
                    db.set_property(node, "id", i)
                    if kind == "Team":
                        db.set_property(node, "name", f"team-{i}")
            for person, team in g["memberships"]:
                db.add_edge(ids["Person", person], ids["Team", team], "MEMBER_OF")
            for child, parent in g["hierarchy"]:
                db.add_edge(ids["Team", child], ids["Team", parent], "MEMBER_OF")
            for door, zone in g["door_zones"]:
                db.add_edge(ids["Door", door], ids["Zone", zone], "LOCATED_IN")
        db.query("UNWIND $grants AS grant MATCH (g:Team {id: grant[0]}), (z:Zone {id: grant[1]}) "
                 "CREATE (g)-[:MAY_ENTER {days: [1, 2, 3, 4, 5], opens: 9, closes: 18}]->(z)",
                 grants=[list(x) for x in g["grants"]])

    def prepare(self, text):
        return text

    def run(self, prepared, parameters):
        return self.db.query(prepared, parameters)

    def close(self):
        self.db.close()


class Kuzu:
    def __init__(self, path, args):
        import kuzu

        self.db = kuzu.Database(os.path.join(path, "db"))
        self.connection = kuzu.Connection(self.db, num_threads=args.threads) if args.threads else kuzu.Connection(self.db)
        self.csv_dir = os.path.join(path, "csv")

    def load(self, g):
        c = self.connection
        for statement in [
            "CREATE NODE TABLE Person(id INT64, name STRING, age INT64, department STRING, PRIMARY KEY(id))",
            "CREATE NODE TABLE Card(number INT64, PRIMARY KEY(number))",
            "CREATE NODE TABLE Team(id INT64, name STRING, PRIMARY KEY(id))",
            "CREATE NODE TABLE Zone(id INT64, PRIMARY KEY(id))",
            "CREATE NODE TABLE Door(id INT64, PRIMARY KEY(id))",
            "CREATE NODE TABLE Event(id SERIAL, card INT64, n INT64, PRIMARY KEY(id))",
            "CREATE REL TABLE HELD_BY(FROM Card TO Person)",
            "CREATE REL TABLE MEMBER_OF(FROM Person TO Team, FROM Team TO Team)",
            "CREATE REL TABLE MAY_ENTER(FROM Team TO Zone, days INT64[], opens INT64, closes INT64)",
            "CREATE REL TABLE LOCATED_IN(FROM Door TO Zone)",
        ]:
            c.execute(statement)
        # Kuzu's bulk path: COPY from files. Writing the files counts as load time.
        os.makedirs(self.csv_dir)
        files = {
            "Person": g["persons"],
            "Card": [(1_000_000 + i,) for i in range(g["people"])],
            "Team": [(i, f"team-{i}") for i in range(g["teams"])],
            "Zone": [(i,) for i in range(g["zones"])],
            "Door": [(i,) for i in range(g["doors"])],
            "HELD_BY": [(1_000_000 + i, i) for i in range(g["people"])],
            "MEMBER_OF_person": g["memberships"],
            "MEMBER_OF_team": g["hierarchy"],
            "MAY_ENTER": [(t, z, "[1,2,3,4,5]", 9, 18) for t, z in g["grants"]],
            "LOCATED_IN": g["door_zones"],
        }
        for name, rows in files.items():
            with open(os.path.join(self.csv_dir, name + ".csv"), "w", newline="") as f:
                csv.writer(f).writerows(rows)
        path = lambda name: os.path.join(self.csv_dir, name + ".csv")  # noqa: E731
        for table in ("Person", "Card", "Team", "Zone", "Door", "HELD_BY", "MAY_ENTER", "LOCATED_IN"):
            c.execute(f"COPY {table} FROM '{path(table)}'")
        c.execute(f"COPY MEMBER_OF FROM '{path('MEMBER_OF_person')}' (from='Person', to='Team')")
        c.execute(f"COPY MEMBER_OF FROM '{path('MEMBER_OF_team')}' (from='Team', to='Team')")

    def prepare(self, text):
        return self.connection.prepare(text)

    def run(self, prepared, parameters):
        result = self.connection.execute(prepared, parameters)
        rows = []
        while result.has_next():
            rows.append(result.get_next())
        return rows

    def close(self):
        self.connection.close()
        self.db.close()


class Lattice:
    def __init__(self, path, args):
        import latticedb

        self.db = latticedb.Database(os.path.join(path, "bench.db"), create=True)
        self.db.open()

    def load(self, g):
        ids = {}
        with self.db.write() as txn:
            for i, name, age, department in g["persons"]:
                ids["Person", i] = txn.create_node(labels=["Person"], properties={"id": i, "name": name, "age": age, "department": department}).id
                card = txn.create_node(labels=["Card"], properties={"number": 1_000_000 + i}).id
                txn.create_edge(card, ids["Person", i], "HELD_BY")
            for kind, count in (("Team", g["teams"]), ("Zone", g["zones"]), ("Door", g["doors"])):
                for i in range(count):
                    properties = {"id": i, "name": f"team-{i}"} if kind == "Team" else {"id": i}
                    ids[kind, i] = txn.create_node(labels=[kind], properties=properties).id
            for person, team in g["memberships"]:
                txn.create_edge(ids["Person", person], ids["Team", team], "MEMBER_OF")
            for child, parent in g["hierarchy"]:
                txn.create_edge(ids["Team", child], ids["Team", parent], "MEMBER_OF")
            for door, zone in g["door_zones"]:
                txn.create_edge(ids["Door", door], ids["Zone", zone], "LOCATED_IN")
            for team, zone in g["grants"]:
                txn.create_edge(ids["Team", team], ids["Zone", zone], "MAY_ENTER", properties=GRANT)
            txn.commit()
        for label, key in (("Card", "number"), ("Person", "id"), ("Door", "id"), ("Team", "id"), ("Zone", "id")):
            self.db.create_node_property_index(label, key)

    def prepare(self, text):
        return text

    def run(self, prepared, parameters):
        result = self.db.query(prepared, parameters or None)
        return [[row[c] for c in result.columns] for row in result._rows]

    def close(self):
        self.db.close()


class Sparrow:
    # Built from bench/comparison/sparrow-loader (see bench/comparison/README.md).
    LOADER = os.environ.get("SPARROW_LOADER", str(Path(__file__).parent / "sparrow-loader/target/release/sparrow-loader"))

    def __init__(self, path, args):
        self.path = os.path.join(path, "db")
        self.csv_dir = os.path.join(path, "csv")
        self.db = None

    def load(self, g):
        # SparrowDB's bulk path is its Rust BulkLoader over CSV files (the Python
        # binding has none, and no UNWIND ... CREATE). Writing the files counts.
        import subprocess
        import sparrowdb

        os.makedirs(self.csv_dir)
        files = {
            "Person": (("id", "name", "age", "department"), g["persons"]),
            "Card": (("id", "number"), [(1_000_000 + i, 1_000_000 + i) for i in range(g["people"])]),
            "Team": (("id", "name"), [(i, f"team-{i}") for i in range(g["teams"])]),
            "Zone": (("id",), [(i,) for i in range(g["zones"])]),
            "Door": (("id",), [(i,) for i in range(g["doors"])]),
            "HELD_BY": (("src", "dst"), [(1_000_000 + i, i) for i in range(g["people"])]),
            "MEMBER_OF_person": (("src", "dst"), g["memberships"]),
            "MEMBER_OF_team": (("src", "dst"), g["hierarchy"]),
            "LOCATED_IN": (("src", "dst"), g["door_zones"]),
        }
        for name, (header, rows) in files.items():
            with open(os.path.join(self.csv_dir, name + ".csv"), "w", newline="") as f:
                writer = csv.writer(f)
                writer.writerow(header)
                writer.writerows(rows)
        subprocess.run([self.LOADER, self.path, self.csv_dir], check=True, stderr=subprocess.DEVNULL)
        self.db = sparrowdb.GraphDb(self.path)
        # Relationship properties can only be set at CREATE, and MATCH ... CREATE with
        # parameters silently creates nothing: literal ids. Lists cannot be stored, so no days.
        for team, zone in g["grants"]:
            self.db.execute(f"MATCH (t:Team {{id: {team}}}), (z:Zone {{id: {zone}}}) "
                            "CREATE (t)-[:MAY_ENTER {opens: 9, closes: 18}]->(z)")
        self.load_seconds = None
        for label, key in (("Card", "number"), ("Person", "id"), ("Door", "id"), ("Team", "id"), ("Zone", "id")):
            self.db.execute(f"CREATE INDEX ON :{label}({key})")

    def prepare(self, text):
        return text

    def run(self, prepared, parameters):
        # Its index is used only for literal values, not parameters: inline them (its best case).
        for name, value in parameters.items():
            prepared = prepared.replace("$" + name, repr(value))
        return [list(row.values()) for row in self.db.execute(prepared)]

    def close(self):
        pass


ENGINES = {"zypherdb": ZypherDB, "kuzu": Kuzu, "latticedb": Lattice, "sparrowdb": Sparrow}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", required=True, choices=sorted(ENGINES))
    parser.add_argument("--people", type=int, default=10_000)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--runs", type=int, default=100)
    parser.add_argument("--durability", default="full")
    parser.add_argument("--threads", type=int, default=0)
    parser.add_argument("--only", default="")
    args = parser.parse_args()

    shutil.rmtree(args.dir, ignore_errors=True)
    os.makedirs(args.dir)
    engine = ENGINES[args.engine](args.dir, args)
    g = graph(args.people)
    start = time.perf_counter()
    engine.load(g)
    print(json.dumps({"query": "load", "seconds": round(time.perf_counter() - start, 3)}), flush=True)

    for index, (name, text, parameter_kinds, heavy) in enumerate(QUERIES):
        if args.only and args.only not in name:
            continue
        runs = max(args.runs // 20, 5) if heavy else args.runs
        rng = random.Random(1000 + index)  # the same parameters for every engine
        try:
            prepared = engine.prepare(text)
        except Exception as error:
            print(json.dumps({"query": name, "error": f"{type(error).__name__}: {error}"[:200]}), flush=True)
            continue
        times, answers, failure = [], [], None
        for run in range(runs + 1):  # run 0 warms up
            draw = {"card": 1_000_000 + rng.randrange(args.people), "person": rng.randrange(args.people), "door": rng.randrange(g["doors"])}
            parameters = {kind: draw[kind] for kind in parameter_kinds}
            try:
                start = time.perf_counter()
                rows = engine.run(prepared, parameters)
                elapsed = time.perf_counter() - start
            except Exception as error:
                failure = f"{type(error).__name__}: {error}"[:200]
                break
            if run:
                times.append(elapsed)
            if run < 3 and "create" not in name:
                answers.append(sorted(json.dumps(list(r) if not isinstance(r, dict) else list(r.values()), default=str) for r in rows)[:5])
        record = {"query": name}
        if failure:
            record["error"] = failure
        else:
            times.sort()
            record.update(median_us=round(statistics.median(times) * 1e6, 1), p95_us=round(times[int(len(times) * 0.95) - 1] * 1e6, 1),
                          runs=runs, answers=answers)
        print(json.dumps(record), flush=True)
    engine.close()


if __name__ == "__main__":
    main()
