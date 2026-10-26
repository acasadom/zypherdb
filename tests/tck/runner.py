"""Runs the openCypher TCK against ZypherDB and reports how much of it passes.

    python tests/tck/runner.py                     # run everything, print a summary
    python tests/tck/runner.py --report tests/tck/REPORT.md
    python tests/tck/runner.py --check-baseline    # fail if a baseline scenario regressed
    python tests/tck/runner.py --update-baseline   # record the scenarios that pass now
    python tests/tck/runner.py --filter clauses/match --verbose

Each scenario runs in a fresh database. Scenarios run in worker processes, so
a crash or a hang in the engine fails that one scenario (as `crash` or
`timeout`) instead of the whole run.

Side effects are checked against `Database.export_graph()`, which reads the
storage directly rather than through the query engine under test.

Run `zig build` first: the runner loads the shared library from zig-out/.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
FEATURES = HERE / "features"
GRAPHS = HERE / "graphs"
BASELINE = HERE / "baseline.txt"
DEVIATIONS = HERE / "deviations.txt"


def load_deviations() -> set[str]:
    """Scenarios ZypherDB deliberately answers differently (its extensions to
    openCypher): not run, and reported apart. One scenario id per line;
    `#` lines explain them."""
    if not DEVIATIONS.exists():
        return set()
    return {line for line in DEVIATIONS.read_text(encoding="utf-8").splitlines() if line and not line.startswith("#")}

sys.path.insert(0, str(HERE))
import cypher_values  # noqa: E402
from gherkin import Scenario, Step, load_scenarios  # noqa: E402

# TCK error classes -> the ZypherDB exception classes that count as raising it.
_ERROR_CLASSES = {
    "SyntaxError": ("ParseError", "UnknownVariableError", "InvalidExpressionError"),
    "SemanticError": ("ParseError", "UnknownVariableError", "InvalidExpressionError"),
    "TypeError": ("TypeMismatchError",),
}


class Unsupported(Exception):
    """The scenario needs a TCK step the runner cannot set up for ZypherDB."""


class Failed(Exception):
    """The scenario ran and ZypherDB's behaviour did not match."""


# ---------------------------------------------------------------------------
# Running one scenario (inside a worker process)
# ---------------------------------------------------------------------------


def _graph_state(db) -> dict[str, set]:
    """The comparable parts of the graph, as the TCK counts side effects."""
    graph = db.export_graph()
    state = {"nodes": set(), "relationships": set(), "labels": set(), "properties": set()}
    for node in graph["nodes"]:
        state["nodes"].add(node["id"])
        state["labels"].update(node["labels"])
        for key, value in node["properties"].items():
            state["properties"].add(("node", node["id"], key, repr(cypher_values.from_python(value))))
    for rel in graph["relationships"]:
        identity = rel["id"]
        state["relationships"].add(identity)
        for key, value in rel["properties"].items():
            state["properties"].add(("relationship", identity, key, repr(cypher_values.from_python(value))))
    return state


def _side_effects(before: dict, after: dict) -> dict[str, int]:
    effects = {}
    for kind in before:
        added, removed = len(after[kind] - before[kind]), len(before[kind] - after[kind])
        if added:
            effects["+" + kind] = added
        if removed:
            effects["-" + kind] = removed
    return effects


def _expected_rows(step: Step, ignore_list_order: bool) -> tuple[list[str], list[tuple]]:
    header, *rows = step.table or [[]]
    convert = cypher_values.ignoring_list_order if ignore_list_order else (lambda v: v)
    return header, [tuple(convert(cypher_values.parse(cell)) for cell in row) for row in rows]


def _actual_rows(rows: list[list], ignore_list_order: bool) -> list[tuple]:
    convert = cypher_values.ignoring_list_order if ignore_list_order else (lambda v: v)
    return [tuple(convert(cypher_values.from_python(v)) for v in row) for row in rows]


def _check_result(step: Step, outcome: dict):
    if outcome["error"] is not None:
        raise Failed(f"unexpected error: {outcome['error']}")
    rows = outcome["rows"]
    text = step.text
    if text.startswith("the result should be empty"):
        if rows:
            raise Failed(f"expected no rows, got {len(rows)}")
        return
    ignore_list_order = "ignoring element order for lists" in text
    header, expected = _expected_rows(step, ignore_list_order)
    actual = _actual_rows(rows, ignore_list_order)
    if actual and len(actual[0]) != len(header):
        raise Failed(f"expected {len(header)} columns, got {len(actual[0])}")
    if "in order" in text:
        if actual != expected:
            raise Failed(f"rows differ (in order): expected {expected[:3]}..., got {actual[:3]}...")
    elif collections.Counter(actual) != collections.Counter(expected):
        raise Failed(f"rows differ: expected {len(expected)} rows {expected[:3]}, got {len(actual)} rows {actual[:3]}")


def _check_error(step: Step, outcome: dict):
    match = re.match(r"an? (\w+) should be raised at ([a-z ]+?)(?:: (\w+|\*))?$", step.text)
    if not match:
        raise Unsupported(f"error step: {step.text}")
    expected_class = match.group(1)
    if outcome["error"] is None:
        raise Failed(f"expected {expected_class}, but the query succeeded")
    accepted = _ERROR_CLASSES.get(expected_class)
    if accepted is not None and outcome["error_class"] not in accepted:
        raise Failed(f"expected {expected_class}, got {outcome['error_class']}: {outcome['error']}")


def _check_side_effects(step: Step, outcome: dict):
    if outcome["side_effects"] is None:
        raise Failed("no side effects to check (the query did not run)")
    if step.text.startswith("no side effects"):
        expected = {}
    else:
        expected = {kind: int(count) for kind, count in step.table if int(count) != 0}
    if outcome["side_effects"] != expected:
        raise Failed(f"side effects: expected {expected}, got {outcome['side_effects']}")


def _execute(db, query: str, parameters: dict, measure: bool) -> dict:
    from zypherdb import ZypherDBError

    before = _graph_state(db) if measure else None
    outcome = {"rows": None, "error": None, "error_class": None, "side_effects": None}
    try:
        outcome["rows"] = db.query(query, parameters)
    except (ZypherDBError, TypeError, OverflowError) as error:  # Python-side refusals count too
        outcome["error"] = str(error)
        outcome["error_class"] = type(error).__name__
    if measure:
        outcome["side_effects"] = _side_effects(before, _graph_state(db))
    return outcome


def _setup(db, query: str):
    """Runs a setup query; its failure fails the scenario."""
    from zypherdb import ZypherDBError

    try:
        db.query(query)
    except ZypherDBError as error:
        raise Failed(f"setup query failed: {type(error).__name__}: {error}")


_PROCEDURE = re.compile(r"there exists a procedure ([\w.]+)\((.*?)\) :: \((.*?)\)\s*:$")


def _define_procedure(db, text: str, table) -> None:
    """`there exists a procedure test.my.proc(in :: INTEGER?) :: (out :: STRING?):`
    with its rows as the step's table (the argument columns, then the output
    columns)."""
    match = _PROCEDURE.match(text)
    if not match:
        raise Unsupported(f"procedure signature: {text}")

    def declared(part: str) -> list[tuple[str, str]]:
        return [tuple(s.strip() for s in item.split("::")) for item in part.split(",") if item.strip()]

    arguments, columns = declared(match.group(2)), declared(match.group(3))
    # A table with no columns at all reads as one empty row.
    rows = [row for row in (table or [])[1:] if row != [""]]
    values = [[cypher_values.to_python(cypher_values.parse(cell)) for cell in row] for row in rows]
    db._define_procedure(match.group(1), arguments, columns, values)


def run_scenario(scenario: Scenario) -> dict:
    """Runs one scenario in a fresh database; returns its status and reason."""
    from zypherdb import Database

    negative = any(s.keyword == "Then" and "should be raised" in s.text for s in scenario.steps)
    # Temporal values as their exact ISO text: the TCK writes them that way,
    # with nanoseconds the datetime module cannot hold.
    with tempfile.TemporaryDirectory(prefix="zypherdb-tck-") as path, Database(path, temporals="iso") as db:
        outcome = None
        parameters = {}
        try:
            for step in scenario.steps:
                text = step.text
                if step.keyword == "Given":
                    if text in ("an empty graph", "any graph"):
                        continue
                    graph = re.match(r"the ([\w-]+) graph$", text)
                    if graph:
                        _setup(db, (GRAPHS / f"{graph.group(1)}.cypher").read_text(encoding="utf-8").strip().rstrip(";"))
                        continue
                    if text.startswith("having executed"):
                        _setup(db, step.docstring)
                        continue
                    if text.startswith("parameters are"):
                        parameters = {name: cypher_values.to_python(cypher_values.parse(value)) for name, value in step.table}
                        continue
                    if text.startswith("there exists a procedure"):
                        _define_procedure(db, text, step.table)
                        continue
                    raise Unsupported(f"given: {text}")
                if step.keyword == "When":
                    if text.startswith("executing query"):
                        outcome = _execute(db, step.docstring, parameters, measure=True)
                    elif text.startswith("executing control query"):
                        outcome = _execute(db, step.docstring, parameters, measure=False)
                    else:
                        raise Unsupported(f"when: {text}")
                    continue
                if text.startswith("the result should be"):
                    _check_result(step, outcome)
                elif "should be raised" in text:
                    _check_error(step, outcome)
                elif text.startswith(("no side effects", "the side effects should be")):
                    _check_side_effects(step, outcome)
                else:
                    raise Unsupported(f"then: {text}")
        except Unsupported as reason:
            return {"status": "unsupported", "reason": str(reason), "negative": negative}
        except Failed as reason:
            return {"status": "fail", "reason": str(reason), "negative": negative}
    return {"status": "pass", "reason": "", "negative": negative}


def _worker(scenario_ids: list[str]):
    """Worker process: runs the given scenarios, one JSON line per scenario."""
    sys.path.insert(0, str(REPO / "python"))
    by_id = {s.id: s for s in load_scenarios(FEATURES)}
    for scenario_id in scenario_ids:
        try:
            result = run_scenario(by_id[scenario_id])
        except Exception as error:  # a runner bug must not look like an engine crash
            result = {"status": "fail", "reason": f"runner error: {type(error).__name__}: {error}", "negative": False}
        print(json.dumps({"id": scenario_id, **result}), flush=True)


# ---------------------------------------------------------------------------
# Supervising workers
# ---------------------------------------------------------------------------


def _supervise(scenario_ids: list[str], timeout: float, results: dict, lock: threading.Lock):
    """Runs `scenario_ids` in a worker, restarting it after a crash or hang."""
    remaining = list(scenario_ids)
    while remaining:
        process = subprocess.Popen(
            [sys.executable, "-I", __file__, "--worker"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8",
        )
        process.stdin.write(json.dumps(remaining))
        process.stdin.close()
        lines: queue.Queue = queue.Queue()
        errors: list[str] = []
        threading.Thread(target=lambda: [lines.put(l) for l in process.stdout] + [lines.put(None)], daemon=True).start()
        threading.Thread(target=lambda: errors.extend(process.stderr), daemon=True).start()
        while remaining:
            try:
                line = lines.get(timeout=timeout)
            except queue.Empty:
                process.kill()
                status = {"status": "timeout", "reason": f"no result within {timeout:.0f}s", "negative": False}
                break
            if line is None:
                code = process.wait()
                panic = next((e.strip() for e in errors if "panic" in e), "")
                status = {"status": "crash", "reason": f"worker exited with {code} {panic}".strip(), "negative": False}
                break
            result = json.loads(line)
            with lock:
                results[result.pop("id")] = result
            remaining.pop(0)
        else:
            process.wait()
            break
        # The scenario at the head of `remaining` crashed or hung: record it, go on.
        with lock:
            results[remaining.pop(0)] = status
        process.wait()


def run_all(scenarios: list[Scenario], jobs: int, timeout: float) -> dict[str, dict]:
    ids = [s.id for s in scenarios]
    chunks = [ids[i::jobs] for i in range(jobs)]
    results: dict[str, dict] = {}
    lock = threading.Lock()
    threads = [threading.Thread(target=_supervise, args=(chunk, timeout, results, lock)) for chunk in chunks if chunk]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def _area(scenario_id: str) -> str:
    """`clauses/match` for `clauses/match/Match1.feature: ...`."""
    return "/".join(scenario_id.split(":", 1)[0].split("/")[:2])


def _normalized_reason(reason: str) -> str:
    """A reason with its data removed, so similar failures group together. The
    syntax a message names (`unexpected '+'`) is kept: it says what is missing."""
    reason = re.sub(r"(rows differ.*?: expected).*", r"\1 other rows", reason)
    reason = re.sub(r"(side effects: expected).*", r"\1 other side effects", reason)
    reason = re.sub(r"\(code \d+\)", "", reason)
    reason = re.sub(r"(variable|property|node) '[^']*'", r"\1 '…'", reason)
    reason = re.sub(r"0x[0-9a-f]+", lambda m: repr(chr(int(m.group(0), 16))), reason)
    reason = re.sub(r"(?<![\w'])\d+(?![\w'])", "N", reason)
    return reason[:110].strip()


def summarize(scenarios: list[Scenario], results: dict[str, dict]) -> str:
    total = collections.Counter()
    by_area: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    reasons = collections.Counter()
    for scenario in scenarios:
        result = results[scenario.id]
        kind = "negative" if result["negative"] else "positive"
        for counter in (total, by_area[_area(scenario.id)]):
            counter[kind] += 1
            counter[f"{kind} {result['status']}"] += 1
        if result["status"] != "pass":
            reasons[f"{result['status']}: {_normalized_reason(result['reason'])}"] += 1

    def rate(counter, kind):
        n = counter[kind]
        return f"{counter[kind + ' pass']}/{n} ({100 * counter[kind + ' pass'] / n:.1f}%)" if n else "–"

    lines = [
        "# openCypher TCK results",
        "",
        f"TCK 2024.3, {len(scenarios)} scenarios (outlines expanded; `@ignore` scenarios excluded).",
        "",
        "- **Positive** scenarios expect a result: the headline measure of what works.",
        "- **Negative** scenarios expect an error. Their pass rate overstates support: ZypherDB rejects",
        "  much syntax it does not implement yet, which can coincide with an expected SyntaxError.",
        "",
        f"**Positive: {rate(total, 'positive')}** · Negative: {rate(total, 'negative')}",
        "",
        "| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |",
        "| --- | --- | --- | --- | --- |",
    ]
    for area in sorted(by_area):
        c = by_area[area]
        unsupported = c["positive unsupported"] + c["negative unsupported"]
        broken = sum(c[f"{k} {s}"] for k in ("positive", "negative") for s in ("crash", "timeout"))
        lines.append(f"| {area} | {rate(c, 'positive')} | {rate(c, 'negative')} | {unsupported} | {broken} |")
    lines += ["", "## Most common reasons for not passing", "", "| Scenarios | Reason |", "| --- | --- |"]
    for reason, count in reasons.most_common(40):
        lines.append(f"| {count} | {reason.replace('|', '\\|')} |")
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--filter", default="", help="only scenarios whose id contains this text")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    parser.add_argument("--timeout", type=float, default=20.0, help="seconds per scenario")
    parser.add_argument("--report", type=Path, help="write the Markdown report here")
    parser.add_argument("--check-baseline", action="store_true", help="exit 1 if a baseline scenario no longer passes")
    parser.add_argument("--update-baseline", action="store_true", help="record the passing scenarios")
    parser.add_argument("--verbose", action="store_true", help="print every scenario that does not pass")
    args = parser.parse_args()

    if args.worker:
        _worker(json.loads(sys.stdin.read()))
        return

    deviations = load_deviations()
    selected = [s for s in load_scenarios(FEATURES) if "@ignore" not in s.tags and args.filter in s.id]
    scenarios = [s for s in selected if s.id not in deviations]
    results = run_all(scenarios, args.jobs, args.timeout)
    summary = summarize(scenarios, results)
    excluded = len(selected) - len(scenarios)
    if excluded:
        summary += f"\n{excluded} scenarios not run: intentional deviations (ZypherDB extensions), listed in tests/tck/deviations.txt.\n"
    print(summary)
    if args.verbose:
        for scenario in scenarios:
            result = results[scenario.id]
            if result["status"] != "pass":
                print(f"{result['status']:<11} {scenario.id}\n            {result['reason']}")
    if args.report:
        args.report.write_text(summary, encoding="utf-8")

    passing = sorted(s.id for s in scenarios if results[s.id]["status"] == "pass")
    if args.update_baseline:
        BASELINE.write_text("\n".join(passing) + "\n", encoding="utf-8")
        print(f"baseline: {len(passing)} passing scenarios recorded in {BASELINE.relative_to(REPO)}")
    if args.check_baseline:
        baseline = {line for line in BASELINE.read_text(encoding="utf-8").splitlines() if line and args.filter in line and line not in deviations}
        regressed = sorted(baseline - set(passing))
        newly_passing = sorted(set(passing) - baseline)
        for scenario_id in regressed:
            print(f"REGRESSED {scenario_id}: {results[scenario_id]['reason']}")
        print(f"baseline: {len(baseline)} scenarios, {len(regressed)} regressed, {len(newly_passing)} newly passing")
        if newly_passing:
            print("run with --update-baseline to record the newly passing scenarios")
        if regressed:
            sys.exit(1)


if __name__ == "__main__":
    main()
