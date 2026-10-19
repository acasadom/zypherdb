# openCypher TCK results

TCK 2024.3, 3897 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 385/3202 (12.0%)** · Negative: 525/695 (75.5%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 38/63 (60.3%) | 10/15 (66.7%) | 0 | 1 |
| clauses/delete | 17/36 (47.2%) | 4/5 (80.0%) | 2 | 0 |
| clauses/match | 43/141 (30.5%) | 241/241 (100.0%) | 5 | 0 |
| clauses/match-where | 14/32 (43.8%) | 1/2 (50.0%) | 3 | 0 |
| clauses/merge | 23/62 (37.1%) | 8/13 (61.5%) | 0 | 0 |
| clauses/remove | 10/33 (30.3%) | – | 0 | 0 |
| clauses/return | 17/52 (32.7%) | 9/11 (81.8%) | 1 | 0 |
| clauses/return-orderby | 17/31 (54.8%) | 2/4 (50.0%) | 1 | 0 |
| clauses/return-skip-limit | 10/15 (66.7%) | 10/16 (62.5%) | 8 | 0 |
| clauses/set | 11/51 (21.6%) | 0/2 (0.0%) | 0 | 0 |
| clauses/union | 0/8 (0.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 4/14 (28.6%) | – | 2 | 0 |
| clauses/with | 11/25 (44.0%) | 3/4 (75.0%) | 1 | 0 |
| clauses/with-orderBy | 16/223 (7.2%) | 47/69 (68.1%) | 1 | 0 |
| clauses/with-skip-limit | 6/9 (66.7%) | – | 1 | 0 |
| clauses/with-where | 7/19 (36.8%) | – | 1 | 0 |
| expressions/aggregation | 7/28 (25.0%) | 0/7 (0.0%) | 0 | 0 |
| expressions/boolean | 9/32 (28.1%) | 71/118 (60.2%) | 0 | 0 |
| expressions/comparison | 13/71 (18.3%) | 0/1 (0.0%) | 0 | 0 |
| expressions/conditional | 0/13 (0.0%) | – | 0 | 0 |
| expressions/existentialSubqueries | 0/9 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 6/43 (14.0%) | 10/17 (58.8%) | 1 | 0 |
| expressions/list | 35/126 (27.8%) | 41/59 (69.5%) | 14 | 0 |
| expressions/literals | 27/106 (25.5%) | 24/25 (96.0%) | 0 | 0 |
| expressions/map | 1/35 (2.9%) | 5/9 (55.6%) | 6 | 0 |
| expressions/mathematical | 0/5 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 3/44 (6.8%) | – | 7 | 0 |
| expressions/path | 0/5 (0.0%) | 2/2 (100.0%) | 0 | 0 |
| expressions/pattern | 0/31 (0.0%) | 17/19 (89.5%) | 0 | 0 |
| expressions/precedence | 6/121 (5.0%) | – | 0 | 0 |
| expressions/quantifier | 0/592 (0.0%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 23/32 (71.9%) | – | 0 | 0 |
| expressions/temporal | 0/1004 (0.0%) | – | 0 | 0 |
| expressions/typeConversion | 0/25 (0.0%) | 0/22 (0.0%) | 1 | 0 |
| useCases/countingSubgraphMatches | 10/11 (90.9%) | – | 0 | 0 |
| useCases/triadicSelection | 1/19 (5.3%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 1517 | fail: unexpected error: unexpected '(' (unsupported syntax or missing clause) |
| 109 | fail: unexpected error: unexpected character '\|' |
| 86 | fail: unexpected error: expected an expression, found '{' |
| 86 | fail: unexpected error: unexpected character '+' |
| 86 | fail: unexpected error: unexpected UNWIND (unsupported syntax or missing clause) |
| 84 | fail: setup query failed: ParseError: expected '}', found '(' |
| 56 | fail: unexpected error: expected '(', found p |
| 52 | fail: unexpected error: unexpected IS (unsupported syntax or missing clause) |
| 50 | unsupported: procedures |
| 50 | unsupported: query parameters |
| 48 | fail: setup query failed: ParseError: expected an expression, found '-' |
| 47 | fail: expected SyntaxError, got TypeMismatchError: query failed: TypeMismatch |
| 45 | fail: unexpected error: unexpected character '%' |
| 42 | fail: expected SyntaxError, but the query succeeded |
| 37 | fail: unexpected error: unexpected WITH (unsupported syntax or missing clause) |
| 35 | fail: unexpected error: unexpected MATCH (unsupported syntax or missing clause) |
| 35 | fail: unexpected error: expected an expression, found '-' |
| 33 | fail: rows differ: expected other rows |
| 27 | fail: unexpected error: expected ']', found '(' |
| 27 | fail: expected TypeError, got ParseError: unexpected character '\|' |
| 22 | fail: unexpected error: unexpected character '/' |
| 22 | fail: setup query failed: ParseError: expected '}', found '.' |
| 20 | fail: unexpected error: unknown variable '…' |
| 18 | fail: unexpected error: unexpected '-' (unsupported syntax or missing clause) |
| 18 | fail: unexpected error: expected '.', found ':' |
| 18 | fail: unexpected error: unexpected '[' (unsupported syntax or missing clause) |
| 17 | fail: unexpected error: expected ']', found '*' |
| 17 | fail: unexpected error: expected ']', found '.' |
| 15 | fail: unexpected error: expected an expression, found '*' |
| 15 | fail: unexpected error: unexpected ':' (unsupported syntax or missing clause) |
| 14 | fail: unexpected error: unexpected OPTIONAL (unsupported syntax or missing clause) |
| 14 | fail: unexpected error: query failed: TypeMismatch |
| 14 | fail: setup query failed: ParseError: unexpected character '/' |
| 12 | fail: unexpected error: expected keyword END |
| 11 | fail: setup query failed: TypeMismatchError: property '…': lists cannot be stored as property values yet |
| 11 | fail: unexpected error: expected keyword AS |
| 10 | fail: setup query failed: ParseError: expected keyword AS |
| 10 | fail: unexpected error: unexpected '.' (unsupported syntax or missing clause) |
| 9 | fail: unexpected error: unexpected '{' (unsupported syntax or missing clause) |
| 8 | fail: unexpected error: unexpected UNION (unsupported syntax or missing clause) |
