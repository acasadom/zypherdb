# openCypher TCK results

TCK 2024.3, 3897 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 1362/3202 (42.5%)** · Negative: 617/695 (88.8%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 46/63 (73.0%) | 10/15 (66.7%) | 0 | 0 |
| clauses/delete | 25/36 (69.4%) | 4/5 (80.0%) | 0 | 0 |
| clauses/match | 61/141 (43.3%) | 241/241 (100.0%) | 5 | 0 |
| clauses/match-where | 21/32 (65.6%) | 1/2 (50.0%) | 0 | 0 |
| clauses/merge | 35/62 (56.5%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 29/33 (87.9%) | – | 0 | 0 |
| clauses/return | 31/52 (59.6%) | 9/11 (81.8%) | 0 | 0 |
| clauses/return-orderby | 24/31 (77.4%) | 3/4 (75.0%) | 0 | 0 |
| clauses/return-skip-limit | 13/15 (86.7%) | 13/16 (81.2%) | 0 | 0 |
| clauses/set | 45/51 (88.2%) | 1/2 (50.0%) | 0 | 0 |
| clauses/union | 0/8 (0.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 11/14 (78.6%) | – | 0 | 0 |
| clauses/with | 15/25 (60.0%) | 3/4 (75.0%) | 0 | 0 |
| clauses/with-orderBy | 94/223 (42.2%) | 69/69 (100.0%) | 0 | 0 |
| clauses/with-skip-limit | 7/9 (77.8%) | – | 0 | 0 |
| clauses/with-where | 8/19 (42.1%) | – | 0 | 0 |
| expressions/aggregation | 10/28 (35.7%) | 1/7 (14.3%) | 0 | 0 |
| expressions/boolean | 17/32 (53.1%) | 118/118 (100.0%) | 0 | 0 |
| expressions/comparison | 24/71 (33.8%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 1/13 (7.7%) | – | 0 | 0 |
| expressions/existentialSubqueries | 0/9 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 35/43 (81.4%) | 11/17 (64.7%) | 0 | 0 |
| expressions/list | 107/126 (84.9%) | 55/59 (93.2%) | 0 | 0 |
| expressions/literals | 70/106 (66.0%) | 24/25 (96.0%) | 0 | 0 |
| expressions/map | 35/35 (100.0%) | 7/9 (77.8%) | 0 | 0 |
| expressions/mathematical | 4/5 (80.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 44/44 (100.0%) | – | 0 | 0 |
| expressions/path | 0/5 (0.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 0/31 (0.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 41/121 (33.9%) | – | 0 | 0 |
| expressions/quantifier | 459/592 (77.5%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 26/32 (81.2%) | – | 0 | 0 |
| expressions/temporal | 0/1004 (0.0%) | – | 0 | 0 |
| expressions/typeConversion | 13/25 (52.0%) | 0/22 (0.0%) | 0 | 0 |
| useCases/countingSubgraphMatches | 10/11 (90.9%) | – | 0 | 0 |
| useCases/triadicSelection | 1/19 (5.3%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 463 | fail: unexpected error: RETURN must be the last clause, found '(' after it |
| 187 | fail: unexpected error: unknown function 'datetime' |
| 169 | fail: unexpected error: expected an identifier, found N |
| 122 | fail: unexpected error: unknown function 'localdatetime' |
| 81 | fail: unexpected error: unknown function 'date' |
| 66 | fail: unexpected error: expected '(', found p |
| 50 | unsupported: procedures |
| 49 | fail: unexpected error: unknown function 'time' |
| 47 | fail: unexpected error: unknown variable '…' |
| 43 | fail: unexpected error: expected ']', found '*' |
| 42 | fail: rows differ: expected other rows |
| 39 | fail: unexpected error: query failed: TypeMismatch |
| 38 | fail: unexpected error: unknown function 'localtime' |
| 35 | fail: unexpected error: unknown function 'duration' |
| 32 | fail: setup query failed: ParseError: expected an identifier, found N |
| 27 | fail: expected TypeError, got ParseError: expected '(', found p |
| 25 | fail: unexpected error: expected an expression, found '*' |
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
| 12 | fail: unexpected error: expected ')', found IS |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'localtime' |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'time' |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'localdatetime' |
| 11 | fail: setup query failed: InvalidExpressionError: unknown function 'datetime' |
| 9 | fail: unexpected error: unexpected '{' (unsupported syntax or missing clause) |
| 8 | fail: unexpected error: RETURN must be the last clause, found UNION after it |
| 7 | fail: side effects: expected other side effects |
| 7 | fail: unexpected error: unexpected character '^' |
| 7 | fail: unexpected error: RETURN must be the last clause, found '=' after it |
| 7 | fail: unexpected error: RETURN must be the last clause, found XOR after it |
| 7 | fail: unexpected error: RETURN must be the last clause, found IN after it |
