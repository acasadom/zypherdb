# openCypher TCK — the oracle

The [openCypher Technology Compatibility Kit](https://github.com/opencypher/openCypher/tree/main/tck)
is the reference specification of Cypher's behaviour as executable scenarios: a starting graph, a
query, and the exact expected rows, errors and side effects. ZypherDB runs it to measure what works
against an external reference, instead of trusting its own tests.

```bash
zig build                                   # the runner loads zig-out/lib
make tck                                    # run, write REPORT.md, check the baseline
python -I tests/tck/runner.py --filter clauses/match --verbose   # one area, with reasons
python -I tests/tck/runner.py --update-baseline                  # record newly passing scenarios
```

## Files

| Path | What it is |
| --- | --- |
| `features/`, `graphs/` | The TCK scenarios and named graphs, **vendored unchanged** from openCypher tag `2024.3` (commit `677cbafabb8c3c5eed458fd3b1ec0daec8d67d23`). |
| `LICENSE`, `NOTICE` | openCypher's Apache 2.0 license and notice, which cover those files. |
| `gherkin.py` | A minimal Gherkin reader (Background, Scenario Outline + Examples, docstrings, tables). |
| `cypher_values.py` | Reads the TCK's expected values (Cypher literals, nodes, relationships, paths) into a canonical, type-tagged form. |
| `runner.py` | Runs every scenario in a fresh database, in worker processes, and reports. |
| `baseline.txt` | The scenarios that pass today. CI fails if one of them stops passing. |
| `REPORT.md` | The latest results, by area, with the most common reasons for not passing. |

## How a scenario is judged

- **Positive** scenarios expect a result; they are the headline measure. **Negative** scenarios
  expect an error, and are reported apart: ZypherDB rejects much syntax it does not implement yet,
  which can coincide with an expected `SyntaxError`, so their pass rate overstates support.
- Expected errors are matched by class: `SyntaxError`/`SemanticError` accept a parse, unknown
  variable or invalid expression error; `TypeError` a type mismatch; any other class any error.
  The TCK's error *detail* (`UndefinedVariable`, …) is not checked.
- Side effects (`+nodes`, `-properties`, …) are the difference between `Database.export_graph()`
  before and after the query. The export reads storage directly, so it checks the engine from
  outside rather than through the query engine under test.
- Each scenario gets a fresh database. A crash or a hang (`--timeout`, default 20 s) fails that one
  scenario and the run continues.

## Known limits of the runner

- ZypherDB returns rows without column names, so columns are compared by position.
- Relationships are told apart by their id (`export_graph` gives it), so parallel ones count apart.
- The TCK's test procedures (`there exists a procedure …`) are defined with the private
  `Database._define_procedure`, a procedure whose rows are the step's table.
