# openCypher TCK results

TCK 2024.3, 3897 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 2893/3202 (90.3%)** · Negative: 660/695 (95.0%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 46/63 (73.0%) | 10/15 (66.7%) | 0 | 0 |
| clauses/delete | 27/36 (75.0%) | 4/5 (80.0%) | 0 | 0 |
| clauses/match | 124/141 (87.9%) | 241/241 (100.0%) | 5 | 0 |
| clauses/match-where | 27/32 (84.4%) | 1/2 (50.0%) | 0 | 0 |
| clauses/merge | 37/62 (59.7%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 29/33 (87.9%) | – | 0 | 0 |
| clauses/return | 44/52 (84.6%) | 9/11 (81.8%) | 0 | 0 |
| clauses/return-orderby | 30/31 (96.8%) | 3/4 (75.0%) | 0 | 0 |
| clauses/return-skip-limit | 15/15 (100.0%) | 16/16 (100.0%) | 0 | 0 |
| clauses/set | 48/51 (94.1%) | 1/2 (50.0%) | 0 | 0 |
| clauses/union | 8/8 (100.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 11/14 (78.6%) | – | 0 | 0 |
| clauses/with | 18/25 (72.0%) | 3/4 (75.0%) | 0 | 0 |
| clauses/with-orderBy | 160/223 (71.7%) | 69/69 (100.0%) | 0 | 0 |
| clauses/with-skip-limit | 7/9 (77.8%) | – | 0 | 0 |
| clauses/with-where | 14/19 (73.7%) | – | 0 | 0 |
| expressions/aggregation | 16/28 (57.1%) | 7/7 (100.0%) | 0 | 0 |
| expressions/boolean | 32/32 (100.0%) | 118/118 (100.0%) | 0 | 0 |
| expressions/comparison | 71/71 (100.0%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 13/13 (100.0%) | – | 0 | 0 |
| expressions/existentialSubqueries | 8/9 (88.9%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 35/43 (81.4%) | 17/17 (100.0%) | 0 | 0 |
| expressions/list | 121/126 (96.0%) | 59/59 (100.0%) | 0 | 0 |
| expressions/literals | 94/106 (88.7%) | 24/25 (96.0%) | 0 | 0 |
| expressions/map | 35/35 (100.0%) | 9/9 (100.0%) | 0 | 0 |
| expressions/mathematical | 5/5 (100.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 44/44 (100.0%) | – | 0 | 0 |
| expressions/path | 3/5 (60.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 31/31 (100.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 64/121 (52.9%) | – | 0 | 0 |
| expressions/quantifier | 592/592 (100.0%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 29/32 (90.6%) | – | 0 | 0 |
| expressions/temporal | 1004/1004 (100.0%) | – | 0 | 0 |
| expressions/typeConversion | 22/25 (88.0%) | 22/22 (100.0%) | 0 | 0 |
| useCases/countingSubgraphMatches | 10/11 (90.9%) | – | 0 | 0 |
| useCases/triadicSelection | 19/19 (100.0%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 69 | fail: rows differ: expected other rows |
| 50 | unsupported: procedures |
| 37 | fail: unexpected error: unknown variable '…' |
| 28 | fail: unexpected error: unexpected ASCENDING (unsupported syntax or missing clause) |
| 28 | fail: unexpected error: unexpected DESCENDING (unsupported syntax or missing clause) |
| 26 | fail: unexpected error: expected an expression, found '*' |
| 21 | fail: expected SyntaxError, but the query succeeded |
| 12 | fail: unexpected error: unexpected ':' (unsupported syntax or missing clause) |
| 7 | fail: side effects: expected other side effects |
| 7 | fail: unexpected error: query failed: UnknownVariable |
| 7 | fail: unexpected error: expected an expression, found '.' |
| 5 | fail: unexpected error: unexpected '.' (unsupported syntax or missing clause) |
| 5 | unsupported: then: having executed: |
| 4 | fail: unexpected error: unexpected character '"' |
| 4 | fail: unexpected error: variable '…' is a value; it cannot be used as a node |
| 3 | fail: unexpected error: query failed: TypeMismatch |
| 3 | fail: unexpected error: expected ')', found '{' |
| 3 | fail: unexpected error: unknown function 'percentileDisc' |
| 3 | fail: unexpected error: unknown function 'percentileCont' |
| 3 | fail: unexpected error: RETURN must be the last clause, found ':' after it |
| 2 | fail: unexpected error: unexpected '[' (unsupported syntax or missing clause) |
| 2 | fail: unexpected error: expected ')', found ':' |
| 2 | fail: unexpected error: unexpected ON (unsupported syntax or missing clause) |
| 2 | fail: unexpected error: expected an identifier, found '(' |
| 2 | fail: unexpected error: expected ')', found a |
| 2 | fail: unexpected error: expected ')', found x |
| 1 | fail: unexpected error: DELETE needs a node or a relationship, 'p' is neither |
| 1 | fail: setup query failed: ParseError: expected an expression, found '*' |
| 1 | fail: unexpected error: expected ')', found p |
| 1 | fail: unexpected error: expected ')', found r1 |
| 1 | fail: unexpected error: expected ')', found n |
| 1 | fail: unexpected error: expected '}', found WITH |
| 1 | fail: unexpected error: expected ')', found r |
