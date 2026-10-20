# openCypher TCK results

TCK 2024.3, 3896 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 3129/3202 (97.7%)** · Negative: 660/694 (95.1%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 61/63 (96.8%) | 10/15 (66.7%) | 0 | 0 |
| clauses/delete | 34/36 (94.4%) | 4/5 (80.0%) | 0 | 0 |
| clauses/match | 127/141 (90.1%) | 241/241 (100.0%) | 5 | 0 |
| clauses/match-where | 32/32 (100.0%) | 1/2 (50.0%) | 0 | 0 |
| clauses/merge | 57/62 (91.9%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 33/33 (100.0%) | – | 0 | 0 |
| clauses/return | 51/52 (98.1%) | 9/11 (81.8%) | 0 | 0 |
| clauses/return-orderby | 31/31 (100.0%) | 3/4 (75.0%) | 0 | 0 |
| clauses/return-skip-limit | 15/15 (100.0%) | 16/16 (100.0%) | 0 | 0 |
| clauses/set | 51/51 (100.0%) | 0/1 (0.0%) | 0 | 0 |
| clauses/union | 8/8 (100.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 13/14 (92.9%) | – | 0 | 0 |
| clauses/with | 24/25 (96.0%) | 3/4 (75.0%) | 0 | 0 |
| clauses/with-orderBy | 216/223 (96.9%) | 69/69 (100.0%) | 0 | 0 |
| clauses/with-skip-limit | 8/9 (88.9%) | – | 0 | 0 |
| clauses/with-where | 19/19 (100.0%) | – | 0 | 0 |
| expressions/aggregation | 28/28 (100.0%) | 7/7 (100.0%) | 0 | 0 |
| expressions/boolean | 32/32 (100.0%) | 118/118 (100.0%) | 0 | 0 |
| expressions/comparison | 71/71 (100.0%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 13/13 (100.0%) | – | 0 | 0 |
| expressions/existentialSubqueries | 8/9 (88.9%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 43/43 (100.0%) | 17/17 (100.0%) | 0 | 0 |
| expressions/list | 126/126 (100.0%) | 59/59 (100.0%) | 0 | 0 |
| expressions/literals | 106/106 (100.0%) | 25/25 (100.0%) | 0 | 0 |
| expressions/map | 35/35 (100.0%) | 9/9 (100.0%) | 0 | 0 |
| expressions/mathematical | 5/5 (100.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 44/44 (100.0%) | – | 0 | 0 |
| expressions/path | 3/5 (60.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 31/31 (100.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 121/121 (100.0%) | – | 0 | 0 |
| expressions/quantifier | 592/592 (100.0%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 32/32 (100.0%) | – | 0 | 0 |
| expressions/temporal | 1004/1004 (100.0%) | – | 0 | 0 |
| expressions/typeConversion | 25/25 (100.0%) | 22/22 (100.0%) | 0 | 0 |
| useCases/countingSubgraphMatches | 11/11 (100.0%) | – | 0 | 0 |
| useCases/triadicSelection | 19/19 (100.0%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 50 | unsupported: procedures |
| 20 | fail: expected SyntaxError, but the query succeeded |
| 19 | fail: unexpected error: unknown variable '…' |
| 5 | unsupported: then: having executed: |
| 4 | fail: unexpected error: variable '…' is a value; it cannot be used as a node |
| 3 | fail: side effects: expected other side effects |
| 3 | fail: rows differ: expected other rows |
| 1 | fail: unexpected error: a node to delete still has relationships (use DETACH DELETE) |
| 1 | fail: setup query failed: InvalidExpressionError: variable '…' is a value; it cannot be used as a node |
| 1 | fail: unexpected error: expected '}', found WITH |

1 scenarios not run: intentional deviations (acmedb extensions), listed in tests/tck/deviations.txt.
