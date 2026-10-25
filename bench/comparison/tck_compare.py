"""Runs the openCypher TCK against zypherdb or LatticeDB with the same criteria.

    python bench/comparison/tck_compare.py --engine zypherdb|latticedb [--report FILE]

Needs the zypherdb module built (`make python`) and, for LatticeDB, `pip install latticedb`.

Results-only mode, for both engines: a scenario passes when its result rows
(or its expected error) match. Side-effect steps are not checked, because
LatticeDB has no storage-level export to count them with.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests" / "tck"))
sys.path.insert(0, str(REPO / "python"))

import runner  # noqa: E402
import cypher_values  # noqa: E402

ENGINE = os.environ.get("TCK_ENGINE", "zypherdb")


class ZypherDBAdapter:
    def __init__(self, path):
        import zypherdb

        self.db = zypherdb.Database(path, temporals="iso")
        self.error_types = (zypherdb.ZypherDBError, TypeError, OverflowError)

    def query(self, text, parameters):
        return self.db.query(text, parameters)

    def close(self):
        self.db.close()


class LatticeAdapter:
    def __init__(self, path):
        import latticedb

        self.db = latticedb.Database(os.path.join(path, "tck.db"), create=True)
        self.db.open()
        self.error_types = (latticedb.LatticeError, TypeError, OverflowError, ValueError)

    def query(self, text, parameters):
        result = self.db.query(text, parameters or None)
        return [[row[column] for column in result.columns] for row in result._rows]

    def close(self):
        self.db.close()


ADAPTERS = {"zypherdb": ZypherDBAdapter, "latticedb": LatticeAdapter}


_original_from_python = cypher_values.from_python


def _from_python(value):
    """Like cypher_values.from_python, without requiring zypherdb types."""
    try:
        return _original_from_python(value)
    except (TypeError, ImportError):
        return ("opaque", repr(value))


cypher_values.from_python = _from_python


def run_scenario(scenario):
    negative = any(s.keyword == "Then" and "should be raised" in s.text for s in scenario.steps)
    with tempfile.TemporaryDirectory(prefix="tck-") as path:
        db = ADAPTERS[ENGINE](path)
        try:
            outcome = None
            parameters = {}
            for step in scenario.steps:
                text = step.text
                if step.keyword == "Given":
                    if text in ("an empty graph", "any graph"):
                        continue
                    graph = re.match(r"the ([\w-]+) graph$", text)
                    setup = None
                    if graph:
                        setup = (runner.GRAPHS / f"{graph.group(1)}.cypher").read_text().strip().rstrip(";")
                    elif text.startswith("having executed"):
                        setup = step.docstring
                    elif text.startswith("parameters are"):
                        parameters = {n: cypher_values.to_python(cypher_values.parse(v)) for n, v in step.table}
                        continue
                    else:
                        raise runner.Unsupported(f"given: {text}")
                    try:
                        db.query(setup, {})
                    except db.error_types as error:
                        raise runner.Failed(f"setup query failed: {type(error).__name__}: {error}")
                    continue
                if step.keyword == "When":
                    outcome = {"rows": None, "error": None, "error_class": None, "side_effects": None}
                    try:
                        outcome["rows"] = db.query(step.docstring, parameters)
                    except db.error_types as error:
                        outcome["error"] = str(error)
                        outcome["error_class"] = type(error).__name__
                    continue
                if text.startswith("the result should be"):
                    runner._check_result(step, outcome)
                elif "should be raised" in text:
                    # Any query error counts, for both engines: LatticeDB has one error class.
                    if outcome["error"] is None:
                        raise runner.Failed("expected an error, but the query succeeded")
                elif text.startswith(("no side effects", "the side effects should be")):
                    continue  # results-only mode
                else:
                    raise runner.Unsupported(f"then: {text}")
        except runner.Unsupported as reason:
            return {"status": "unsupported", "reason": str(reason), "negative": negative}
        except runner.Failed as reason:
            return {"status": "fail", "reason": str(reason), "negative": negative}
        finally:
            db.close()
    return {"status": "pass", "reason": "", "negative": negative}


runner.run_scenario = run_scenario
runner.__file__ = __file__  # workers re-run this file, with the patches


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--engine" in args:
        index = args.index("--engine")
        os.environ["TCK_ENGINE"] = ENGINE = args[index + 1]
        del args[index : index + 2]
    sys.argv = [sys.argv[0], *args]
    if "--worker" in args:
        runner._worker(__import__("json").loads(sys.stdin.read()))
    else:
        runner.main()
