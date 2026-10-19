# openCypher TCK results

TCK 2024.3, 3897 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 660/3202 (20.6%)** · Negative: 551/695 (79.3%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 38/63 (60.3%) | 10/15 (66.7%) | 0 | 1 |
| clauses/delete | 18/36 (50.0%) | 4/5 (80.0%) | 0 | 0 |
| clauses/match | 49/141 (34.8%) | 241/241 (100.0%) | 5 | 0 |
| clauses/match-where | 19/32 (59.4%) | 1/2 (50.0%) | 0 | 0 |
| clauses/merge | 25/62 (40.3%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 17/33 (51.5%) | – | 0 | 0 |
| clauses/return | 29/52 (55.8%) | 9/11 (81.8%) | 0 | 0 |
| clauses/return-orderby | 23/31 (74.2%) | 3/4 (75.0%) | 0 | 0 |
| clauses/return-skip-limit | 13/15 (86.7%) | 13/16 (81.2%) | 0 | 0 |
| clauses/set | 13/51 (25.5%) | 0/2 (0.0%) | 0 | 0 |
| clauses/union | 0/8 (0.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 5/14 (35.7%) | – | 0 | 0 |
| clauses/with | 11/25 (44.0%) | 3/4 (75.0%) | 0 | 0 |
| clauses/with-orderBy | 81/223 (36.3%) | 69/69 (100.0%) | 0 | 0 |
| clauses/with-skip-limit | 7/9 (77.8%) | – | 0 | 0 |
| clauses/with-where | 8/19 (42.1%) | – | 0 | 0 |
| expressions/aggregation | 10/28 (35.7%) | 0/7 (0.0%) | 0 | 0 |
| expressions/boolean | 9/32 (28.1%) | 71/118 (60.2%) | 0 | 0 |
| expressions/comparison | 13/71 (18.3%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 1/13 (7.7%) | – | 0 | 0 |
| expressions/existentialSubqueries | 0/9 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 22/43 (51.2%) | 10/17 (58.8%) | 0 | 0 |
| expressions/list | 83/126 (65.9%) | 41/59 (69.5%) | 0 | 0 |
| expressions/literals | 53/106 (50.0%) | 24/25 (96.0%) | 0 | 0 |
| expressions/map | 2/35 (5.7%) | 5/9 (55.6%) | 0 | 0 |
| expressions/mathematical | 4/5 (80.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 22/44 (50.0%) | – | 0 | 0 |
| expressions/path | 0/5 (0.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 0/31 (0.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 36/121 (29.8%) | – | 0 | 0 |
| expressions/quantifier | 0/592 (0.0%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 26/32 (81.2%) | – | 0 | 0 |
| expressions/temporal | 0/1004 (0.0%) | – | 0 | 0 |
| expressions/typeConversion | 12/25 (48.0%) | 0/22 (0.0%) | 0 | 0 |
| useCases/countingSubgraphMatches | 10/11 (90.9%) | – | 0 | 0 |
| useCases/triadicSelection | 1/19 (5.3%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 585 | fail: unexpected error: expected an expression, found '{' |
| 469 | fail: unexpected error: unexpected '(' (unsupported syntax or missing clause) |
| 416 | fail: unexpected error: expected ')', found WHERE |
| 117 | fail: unexpected error: unexpected character '\|' |
| 89 | fail: unexpected error: unexpected UNWIND (unsupported syntax or missing clause) |
| 84 | fail: setup query failed: ParseError: expected an expression, found '{' |
| 69 | fail: unexpected error: expected ']', found '.' |
| 61 | fail: unexpected error: unexpected WITH (unsupported syntax or missing clause) |
| 60 | fail: unexpected error: expected '(', found p |
| 50 | unsupported: procedures |
| 47 | fail: expected SyntaxError, got TypeMismatchError: query failed: TypeMismatch |
| 43 | fail: unexpected error: unknown variable '…' |
| 35 | fail: unexpected error: unexpected MATCH (unsupported syntax or missing clause) |
| 33 | fail: unexpected error: unexpected '[' (unsupported syntax or missing clause) |
| 27 | fail: expected TypeError, got ParseError: unexpected character '\|' |
| 26 | fail: rows differ: expected other rows |
| 22 | fail: setup query failed: ParseError: expected '}', found '.' |
| 21 | fail: expected SyntaxError, but the query succeeded |
| 21 | fail: setup query failed: TypeMismatchError: property '…': lists cannot be stored as property values yet |
| 20 | fail: unexpected error: unexpected '.' (unsupported syntax or missing clause) |
| 19 | fail: unexpected error: query failed: TypeMismatch |
| 19 | fail: unexpected error: expected '.', found ':' |
| 17 | fail: unexpected error: expected an expression, found '*' |
| 17 | fail: unexpected error: expected ']', found '*' |
| 15 | fail: unexpected error: unexpected ':' (unsupported syntax or missing clause) |
| 15 | fail: unexpected error: expected an expression, found ':' |
| 14 | fail: unexpected error: unexpected OPTIONAL (unsupported syntax or missing clause) |
| 14 | fail: unexpected error: unknown function 'datetime' |
| 13 | fail: expected TypeError, got ParseError: unexpected '[' (unsupported syntax or missing clause) |
| 13 | fail: unexpected error: expected an expression, found '.' |
| 12 | fail: unexpected error: expected keyword END |
| 12 | fail: unexpected error: unknown function 'date' |
| 11 | fail: unexpected error: unexpected ASCENDING (unsupported syntax or missing clause) |
| 11 | fail: unexpected error: unexpected DESCENDING (unsupported syntax or missing clause) |
| 9 | fail: unexpected error: unexpected '{' (unsupported syntax or missing clause) |
| 9 | fail: unexpected error: unknown function 'time' |
| 8 | fail: unexpected error: unexpected UNION (unsupported syntax or missing clause) |
| 8 | fail: unexpected error: unknown function 'localtime' |
| 8 | fail: unexpected error: unknown function 'localdatetime' |
| 8 | fail: unexpected error: unknown function 'duration' |
