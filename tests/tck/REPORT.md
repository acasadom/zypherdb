# openCypher TCK results

TCK 2024.3, 3897 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 197/3202 (6.2%)** · Negative: 510/695 (73.4%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 23/63 (36.5%) | 10/15 (66.7%) | 0 | 1 |
| clauses/delete | 7/36 (19.4%) | 4/5 (80.0%) | 2 | 0 |
| clauses/match | 6/141 (4.3%) | 227/241 (94.2%) | 5 | 1 |
| clauses/match-where | 0/32 (0.0%) | 1/2 (50.0%) | 3 | 0 |
| clauses/merge | 18/62 (29.0%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 4/33 (12.1%) | – | 0 | 0 |
| clauses/return | 8/52 (15.4%) | 8/11 (72.7%) | 1 | 0 |
| clauses/return-orderby | 13/31 (41.9%) | 2/4 (50.0%) | 1 | 0 |
| clauses/return-skip-limit | 5/15 (33.3%) | 10/16 (62.5%) | 8 | 0 |
| clauses/set | 2/51 (3.9%) | 0/2 (0.0%) | 0 | 0 |
| clauses/union | 0/8 (0.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 4/14 (28.6%) | – | 2 | 0 |
| clauses/with | 3/25 (12.0%) | 3/4 (75.0%) | 1 | 0 |
| clauses/with-orderBy | 12/223 (5.4%) | 47/69 (68.1%) | 1 | 0 |
| clauses/with-skip-limit | 0/9 (0.0%) | – | 1 | 0 |
| clauses/with-where | 0/19 (0.0%) | – | 1 | 0 |
| expressions/aggregation | 4/28 (14.3%) | 0/7 (0.0%) | 0 | 0 |
| expressions/boolean | 8/32 (25.0%) | 71/118 (60.2%) | 0 | 0 |
| expressions/comparison | 11/71 (15.5%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 0/13 (0.0%) | – | 0 | 0 |
| expressions/existentialSubqueries | 0/9 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 2/43 (4.7%) | 10/17 (58.8%) | 1 | 0 |
| expressions/list | 35/126 (27.8%) | 41/59 (69.5%) | 14 | 0 |
| expressions/literals | 22/106 (20.8%) | 24/25 (96.0%) | 0 | 0 |
| expressions/map | 1/35 (2.9%) | 5/9 (55.6%) | 6 | 0 |
| expressions/mathematical | 0/5 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 3/44 (6.8%) | – | 7 | 0 |
| expressions/path | 0/5 (0.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 0/31 (0.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 6/121 (5.0%) | – | 0 | 0 |
| expressions/quantifier | 0/592 (0.0%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 0/32 (0.0%) | – | 0 | 0 |
| expressions/temporal | 0/1004 (0.0%) | – | 0 | 0 |
| expressions/typeConversion | 0/25 (0.0%) | 0/22 (0.0%) | 1 | 0 |
| useCases/countingSubgraphMatches | 0/11 (0.0%) | – | 0 | 0 |
| useCases/triadicSelection | 0/19 (0.0%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 1515 | fail: unexpected error: unexpected '(' (unsupported syntax or missing clause) |
| 109 | fail: unexpected error: unexpected character '\|' |
| 92 | fail: unexpected error: query failed: TypeMismatch |
| 86 | fail: unexpected error: expected an expression, found '{' |
| 86 | fail: unexpected error: unexpected character '+' |
| 86 | fail: unexpected error: unexpected UNWIND (unsupported syntax or missing clause) |
| 84 | fail: setup query failed: ParseError: expected '}', found '(' |
| 56 | fail: expected SyntaxError, but the query succeeded |
| 56 | fail: unexpected error: expected '(', found p |
| 56 | fail: unexpected error: expected '[', found '->' |
| 53 | fail: rows differ: expected other rows |
| 50 | unsupported: procedures |
| 50 | unsupported: query parameters |
| 48 | fail: setup query failed: ParseError: expected an expression, found '-' |
| 47 | fail: expected SyntaxError, got TypeMismatchError: query failed: TypeMismatch |
| 45 | fail: unexpected error: unexpected character '%' |
| 35 | fail: unexpected error: expected an expression, found '-' |
| 34 | fail: unexpected error: unexpected WITH (unsupported syntax or missing clause) |
| 33 | fail: unexpected error: unexpected MATCH (unsupported syntax or missing clause) |
| 30 | fail: unexpected error: unexpected IS (unsupported syntax or missing clause) |
| 28 | fail: unexpected error: expected '->', found '-' |
| 27 | fail: unexpected error: expected ']', found '(' |
| 27 | fail: expected TypeError, got ParseError: unexpected character '\|' |
| 22 | fail: unexpected error: node has no property '…' |
| 22 | fail: unexpected error: unexpected character '/' |
| 22 | fail: setup query failed: ParseError: expected '}', found '.' |
| 20 | fail: unexpected error: query failed: UnknownVariable |
| 18 | fail: unexpected error: unexpected '-' (unsupported syntax or missing clause) |
| 18 | fail: unexpected error: expected '.', found ':' |
| 18 | fail: unexpected error: unexpected '[' (unsupported syntax or missing clause) |
| 17 | fail: unexpected error: expected ']', found '*' |
| 17 | fail: unexpected error: expected ']', found '.' |
| 14 | fail: setup query failed: ParseError: unexpected character '/' |
| 12 | fail: unexpected error: unexpected OPTIONAL (unsupported syntax or missing clause) |
| 12 | fail: unexpected error: expected keyword END |
| 11 | fail: unexpected error: expected an expression, found '*' |
| 11 | fail: setup query failed: TypeMismatchError: property '…': lists cannot be stored as property values yet |
| 10 | fail: unexpected error: unknown variable '…' |
| 10 | fail: setup query failed: ParseError: expected keyword AS |
| 10 | fail: unexpected error: expected '[', found '-' |
