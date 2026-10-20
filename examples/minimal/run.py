"""The smallest acmedb program: open a database, store a little graph, ask it a question.

    python -m examples.minimal.run
"""

import tempfile

import acmedb


def main() -> None:
    with tempfile.TemporaryDirectory() as path, acmedb.Database(path) as db:
        db.query("""
            CREATE (ada:Person {name: 'Ada Okafor'}), (dalia:Person {name: 'Dalia Haddad'}),
                   (lab:Room {name: 'BSL-3 Lab'}), (office:Room {name: 'Genomics Office'}),
                   (ada)-[:MAY_ENTER]->(lab), (ada)-[:MAY_ENTER]->(office),
                   (dalia)-[:MAY_ENTER]->(lab)
        """)
        for room, people in db.query("""
            MATCH (p:Person)-[:MAY_ENTER]->(r:Room {name: $room})
            RETURN r.name, collect(p.name)
        """, room="BSL-3 Lab"):
            print(f"{room}: {', '.join(sorted(people))}")


if __name__ == "__main__":
    main()
