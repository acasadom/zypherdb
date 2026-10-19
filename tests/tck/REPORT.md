# openCypher TCK results

TCK 2024.3, 3897 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 137/3202 (4.3%)** · Negative: 498/695 (71.7%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 17/63 (27.0%) | 8/15 (53.3%) | 0 | 1 |
| clauses/delete | 7/36 (19.4%) | 4/5 (80.0%) | 2 | 0 |
| clauses/match | 5/141 (3.5%) | 225/241 (93.4%) | 0 | 0 |
| clauses/match-where | 0/32 (0.0%) | 1/2 (50.0%) | 2 | 0 |
| clauses/merge | 11/62 (17.7%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 4/33 (12.1%) | – | 0 | 0 |
| clauses/return | 7/52 (13.5%) | 8/11 (72.7%) | 1 | 5 |
| clauses/return-orderby | 8/31 (25.8%) | 2/4 (50.0%) | 1 | 0 |
| clauses/return-skip-limit | 3/15 (20.0%) | 6/16 (37.5%) | 0 | 0 |
| clauses/set | 2/51 (3.9%) | 0/2 (0.0%) | 0 | 0 |
| clauses/union | 0/8 (0.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 3/14 (21.4%) | – | 2 | 0 |
| clauses/with | 0/25 (0.0%) | 3/4 (75.0%) | 1 | 0 |
| clauses/with-orderBy | 10/223 (4.5%) | 37/69 (53.6%) | 1 | 0 |
| clauses/with-skip-limit | 0/9 (0.0%) | – | 0 | 0 |
| clauses/with-where | 0/19 (0.0%) | – | 0 | 0 |
| expressions/aggregation | 2/28 (7.1%) | 0/7 (0.0%) | 0 | 0 |
| expressions/boolean | 0/32 (0.0%) | 78/118 (66.1%) | 0 | 0 |
| expressions/comparison | 7/71 (9.9%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 0/13 (0.0%) | – | 0 | 0 |
| expressions/existentialSubqueries | 0/9 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 2/43 (4.7%) | 9/17 (52.9%) | 1 | 0 |
| expressions/list | 24/126 (19.0%) | 41/59 (69.5%) | 14 | 1 |
| expressions/literals | 19/106 (17.9%) | 24/25 (96.0%) | 0 | 0 |
| expressions/map | 0/35 (0.0%) | 5/9 (55.6%) | 6 | 0 |
| expressions/mathematical | 0/5 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 0/44 (0.0%) | – | 7 | 0 |
| expressions/path | 0/5 (0.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 0/31 (0.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 6/121 (5.0%) | – | 0 | 0 |
| expressions/quantifier | 0/592 (0.0%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 0/32 (0.0%) | – | 0 | 0 |
| expressions/temporal | 0/1004 (0.0%) | – | 0 | 0 |
| expressions/typeConversion | 0/25 (0.0%) | 0/22 (0.0%) | 1 | 1 |
| useCases/countingSubgraphMatches | 0/11 (0.0%) | – | 0 | 0 |
| useCases/triadicSelection | 0/19 (0.0%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 1509 | fail: unexpected error: unexpected '(' (unsupported syntax or missing clause) |
| 486 | fail: setup query failed: ParseError: unexpected ',' (unsupported syntax or missing clause) |
| 86 | fail: unexpected error: unexpected character '\|' |
| 84 | fail: unexpected error: unexpected UNWIND (unsupported syntax or missing clause) |
| 84 | fail: setup query failed: ParseError: expected '}', found '(' |
| 81 | fail: unexpected error: expected an expression, found '{' |
| 67 | fail: unexpected error: unknown variable '…' |
| 57 | fail: expected SyntaxError, but the query succeeded |
| 50 | unsupported: procedures |
| 50 | fail: unexpected error: unexpected character '+' |
| 41 | fail: unexpected error: unexpected character '%' |
| 40 | fail: expected SyntaxError, got TypeMismatchError: query failed: TypeMismatch |
| 39 | fail: unexpected error: query failed: TypeMismatch |
| 39 | unsupported: query parameters |
| 35 | fail: unexpected error: expected an expression, found '-' |
| 27 | fail: unexpected error: expected '(', found p |
| 27 | fail: unexpected error: expected ']', found '(' |
| 27 | fail: expected TypeError, got ParseError: unexpected character '\|' |
| 24 | fail: unexpected error: unexpected IS (unsupported syntax or missing clause) |
| 23 | fail: rows differ: expected other rows |
| 22 | fail: setup query failed: ParseError: expected '}', found '.' |
| 21 | fail: unexpected error: unexpected character '/' |
| 19 | fail: unexpected error: unexpected WITH (unsupported syntax or missing clause) |
| 18 | fail: unexpected error: unexpected '[' (unsupported syntax or missing clause) |
| 17 | fail: unexpected error: expected '->', found '-' |
| 17 | fail: unexpected error: expected '.', found ':' |
| 14 | fail: unexpected error: expected ']', found '.' |
| 14 | fail: setup query failed: ParseError: unexpected character '/' |
| 12 | fail: unexpected error: expected '[', found '->' |
| 12 | fail: unexpected error: expected keyword END |
| 10 | fail: setup query failed: ParseError: expected keyword AS |
| 10 | fail: setup query failed: ParseError: expected an expression, found '-' |
| 10 | fail: unexpected error: unexpected '.' (unsupported syntax or missing clause) |
| 9 | fail: unexpected error: unexpected ',' (unsupported syntax or missing clause) |
| 9 | fail: unexpected error: query failed: UnknownVariable |
| 9 | fail: unexpected error: unexpected OPTIONAL (unsupported syntax or missing clause) |
| 8 | crash: worker exited with -N thread N panic: reached unreachable code |
| 7 | fail: side effects: expected other side effects |
| 7 | fail: unexpected error: expected keyword AS |
| 7 | fail: unexpected error: unexpected XOR (unsupported syntax or missing clause) |
