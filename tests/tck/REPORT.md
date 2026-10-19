# openCypher TCK results

TCK 2024.3, 3897 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 1449/3202 (45.3%)** · Negative: 636/695 (91.5%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 46/63 (73.0%) | 10/15 (66.7%) | 0 | 0 |
| clauses/delete | 27/36 (75.0%) | 4/5 (80.0%) | 0 | 0 |
| clauses/match | 124/141 (87.9%) | 241/241 (100.0%) | 5 | 0 |
| clauses/match-where | 23/32 (71.9%) | 1/2 (50.0%) | 0 | 0 |
| clauses/merge | 35/62 (56.5%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 29/33 (87.9%) | – | 0 | 0 |
| clauses/return | 34/52 (65.4%) | 9/11 (81.8%) | 0 | 0 |
| clauses/return-orderby | 25/31 (80.6%) | 3/4 (75.0%) | 0 | 0 |
| clauses/return-skip-limit | 13/15 (86.7%) | 13/16 (81.2%) | 0 | 0 |
| clauses/set | 45/51 (88.2%) | 1/2 (50.0%) | 0 | 0 |
| clauses/union | 0/8 (0.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 11/14 (78.6%) | – | 0 | 0 |
| clauses/with | 17/25 (68.0%) | 3/4 (75.0%) | 0 | 0 |
| clauses/with-orderBy | 94/223 (42.2%) | 69/69 (100.0%) | 0 | 0 |
| clauses/with-skip-limit | 7/9 (77.8%) | – | 0 | 0 |
| clauses/with-where | 8/19 (42.1%) | – | 0 | 0 |
| expressions/aggregation | 10/28 (35.7%) | 1/7 (14.3%) | 0 | 0 |
| expressions/boolean | 17/32 (53.1%) | 118/118 (100.0%) | 0 | 0 |
| expressions/comparison | 25/71 (35.2%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 1/13 (7.7%) | – | 0 | 0 |
| expressions/existentialSubqueries | 0/9 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 35/43 (81.4%) | 15/17 (88.2%) | 0 | 0 |
| expressions/list | 109/126 (86.5%) | 55/59 (93.2%) | 0 | 0 |
| expressions/literals | 70/106 (66.0%) | 24/25 (96.0%) | 0 | 0 |
| expressions/map | 35/35 (100.0%) | 7/9 (77.8%) | 0 | 0 |
| expressions/mathematical | 4/5 (80.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 44/44 (100.0%) | – | 0 | 0 |
| expressions/path | 3/5 (60.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 0/31 (0.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 41/121 (33.9%) | – | 0 | 0 |
| expressions/quantifier | 467/592 (78.9%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 26/32 (81.2%) | – | 0 | 0 |
| expressions/temporal | 0/1004 (0.0%) | – | 0 | 0 |
| expressions/typeConversion | 13/25 (52.0%) | 15/22 (68.2%) | 0 | 0 |
| useCases/countingSubgraphMatches | 10/11 (90.9%) | – | 0 | 0 |
| useCases/triadicSelection | 1/19 (5.3%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 463 | fail: unexpected error: RETURN must be the last clause, found '(' after it |
| 187 | fail: unexpected error: unknown function 'datetime' |
| 177 | fail: unexpected error: expected an identifier, found N |
| 122 | fail: unexpected error: unknown function 'localdatetime' |
| 81 | fail: unexpected error: unknown function 'date' |
| 57 | fail: unexpected error: unknown variable '…' |
| 50 | unsupported: procedures |
| 49 | fail: unexpected error: unknown function 'time' |
| 42 | fail: rows differ: expected other rows |
| 39 | fail: unexpected error: query failed: TypeMismatch |
| 38 | fail: unexpected error: unknown function 'localtime' |
| 35 | fail: unexpected error: unknown function 'duration' |
| 32 | fail: setup query failed: ParseError: expected an identifier, found N |
| 27 | fail: unexpected error: expected an expression, found '*' |
| 21 | fail: expected SyntaxError, but the query succeeded |
| 21 | fail: unexpected error: expected an expression, found ':' |
| 21 | fail: setup query failed: TypeMismatchError: property '…': only integers, strings and booleans can be stored (not li |
| 18 | fail: setup query failed: InvalidExpressionError: unknown function 'duration' |
| 17 | fail: unexpected error: expected ')', found XOR |
| 14 | fail: unexpected error: unexpected ASCENDING (unsupported syntax or missing clause) |
| 14 | fail: unexpected error: unexpected DESCENDING (unsupported syntax or missing clause) |
| 14 | fail: unexpected error: expected an expression, found '.' |
| 12 | fail: unexpected error: unexpected ':' (unsupported syntax or missing clause) |
| 12 | fail: setup query failed: InvalidExpressionError: unknown function 'date' |
| 12 | fail: unexpected error: expected keyword END |
| 12 | fail: expected TypeError, got ParseError: expected an identifier, found N |
| 12 | fail: unexpected error: expected ')', found IS |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'localtime' |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'time' |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'localdatetime' |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'datetime' |
| 9 | fail: unexpected error: unexpected '{' (unsupported syntax or missing clause) |
| 8 | fail: unexpected error: RETURN must be the last clause, found UNION after it |
| 7 | fail: side effects: expected other side effects |
| 7 | fail: unexpected error: query failed: UnknownVariable |
| 7 | fail: unexpected error: unexpected character '^' |
| 7 | fail: unexpected error: RETURN must be the last clause, found '=' after it |
| 7 | fail: unexpected error: RETURN must be the last clause, found XOR after it |
| 7 | fail: unexpected error: RETURN must be the last clause, found IN after it |
| 6 | fail: unexpected error: expected an expression, found '->' |
