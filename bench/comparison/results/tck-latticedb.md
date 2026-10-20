# openCypher TCK results

TCK 2024.3, 3896 scenarios (outlines expanded; `@ignore` scenarios excluded).

- **Positive** scenarios expect a result: the headline measure of what works.
- **Negative** scenarios expect an error. Their pass rate overstates support: acmedb rejects
  much syntax it does not implement yet, which can coincide with an expected SyntaxError.

**Positive: 210/3202 (6.6%)** · Negative: 657/694 (94.7%)

| Area | Positive passing | Negative passing | Unsupported | Crash/timeout |
| --- | --- | --- | --- | --- |
| clauses/call | 0/36 (0.0%) | 2/16 (12.5%) | 50 | 0 |
| clauses/create | 15/63 (23.8%) | 8/15 (53.3%) | 0 | 0 |
| clauses/delete | 8/36 (22.2%) | 4/5 (80.0%) | 0 | 0 |
| clauses/match | 5/141 (3.5%) | 241/241 (100.0%) | 5 | 0 |
| clauses/match-where | 1/32 (3.1%) | 1/2 (50.0%) | 0 | 0 |
| clauses/merge | 26/62 (41.9%) | 9/13 (69.2%) | 0 | 0 |
| clauses/remove | 20/33 (60.6%) | – | 0 | 0 |
| clauses/return | 16/52 (30.8%) | 7/11 (63.6%) | 0 | 0 |
| clauses/return-orderby | 14/31 (45.2%) | 2/4 (50.0%) | 0 | 0 |
| clauses/return-skip-limit | 7/15 (46.7%) | 16/16 (100.0%) | 0 | 0 |
| clauses/set | 17/51 (33.3%) | 1/1 (100.0%) | 0 | 0 |
| clauses/union | 0/8 (0.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/unwind | 4/14 (28.6%) | – | 0 | 0 |
| clauses/with | 2/25 (8.0%) | 4/4 (100.0%) | 0 | 0 |
| clauses/with-orderBy | 23/223 (10.3%) | 68/69 (98.6%) | 0 | 0 |
| clauses/with-skip-limit | 0/9 (0.0%) | – | 0 | 0 |
| clauses/with-where | 0/19 (0.0%) | – | 0 | 0 |
| expressions/aggregation | 3/28 (10.7%) | 7/7 (100.0%) | 0 | 0 |
| expressions/boolean | 11/32 (34.4%) | 118/118 (100.0%) | 0 | 0 |
| expressions/comparison | 7/71 (9.9%) | 1/1 (100.0%) | 0 | 0 |
| expressions/conditional | 1/13 (7.7%) | – | 0 | 0 |
| expressions/existentialSubqueries | 0/9 (0.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/graph | 13/43 (30.2%) | 16/17 (94.1%) | 0 | 0 |
| expressions/list | 2/126 (1.6%) | 59/59 (100.0%) | 0 | 0 |
| expressions/literals | 0/106 (0.0%) | 25/25 (100.0%) | 0 | 0 |
| expressions/map | 0/35 (0.0%) | 9/9 (100.0%) | 0 | 0 |
| expressions/mathematical | 1/5 (20.0%) | 1/1 (100.0%) | 0 | 0 |
| expressions/null | 2/44 (4.5%) | – | 0 | 0 |
| expressions/path | 0/5 (0.0%) | 0/2 (0.0%) | 0 | 0 |
| expressions/pattern | 0/31 (0.0%) | 19/19 (100.0%) | 0 | 0 |
| expressions/precedence | 0/121 (0.0%) | – | 0 | 0 |
| expressions/quantifier | 0/592 (0.0%) | 12/12 (100.0%) | 0 | 0 |
| expressions/string | 10/32 (31.2%) | – | 0 | 0 |
| expressions/temporal | 0/1004 (0.0%) | – | 0 | 0 |
| expressions/typeConversion | 1/25 (4.0%) | 22/22 (100.0%) | 0 | 0 |
| useCases/countingSubgraphMatches | 0/11 (0.0%) | – | 0 | 0 |
| useCases/triadicSelection | 1/19 (5.3%) | – | 0 | 0 |

## Most common reasons for not passing

| Scenarios | Reason |
| --- | --- |
| 825 | fail: unexpected error: Plan error: could not create execution plan |
| 736 | fail: unexpected error: Expected MATCH, WHERE, RETURN, CREATE, DELETE, SET, REMOVE, WITH, MERGE, UNWIND, ORDER BY, L |
| 583 | fail: unexpected error: Expected ')' after arguments |
| 204 | fail: rows differ: expected other rows |
| 112 | fail: unexpected error: Expected expression |
| 84 | fail: setup query failed: LatticeQueryError: Execution error: query failed |
| 75 | fail: unexpected error: Execution error: query failed |
| 69 | fail: unexpected error: Expected ']' after list |
| 60 | fail: unexpected error: Expected '(' to start node pattern |
| 47 | fail: expected no rows, got N |
| 36 | fail: unexpected error: Variable 'a' is already defined |
| 25 | fail: unexpected error: Operator not valid for these types |
| 23 | fail: expected an error, but the query succeeded |
| 23 | fail: rows differ (in order): expected other rows |
| 15 | unsupported: given: there exists a procedure test.my.proc(in :: INTEGER?) :: (a :: INTEGER?, b :: INTEGER?) : |
| 7 | fail: unexpected error: Variable-length relationships do not support edge variables |
| 6 | unsupported: given: there exists a procedure test.my.proc(in :: INTEGER?) :: (out :: INTEGER?): |
| 6 | unsupported: given: there exists a procedure test.my.proc(in :: INTEGER?) :: (out :: STRING?): |
| 5 | unsupported: given: there exists a procedure test.my.proc(name :: STRING?, id :: INTEGER?) :: (city :: STRING?, country_cod |
| 5 | fail: unexpected error: Variable 'n' is already defined |
| 5 | unsupported: then: having executed: |
| 5 | fail: unexpected error: Expected ')' after expression |
| 4 | unsupported: given: there exists a procedure test.doNothing() :: (): |
| 4 | unsupported: given: there exists a procedure test.labels() :: (label :: STRING?): |
| 4 | unsupported: given: there exists a procedure test.my.proc(in :: NUMBER?) :: (out :: STRING?): |
| 4 | fail: unexpected error: Variable 'a1' is already defined |
| 4 | fail: unexpected error: ON CREATE SET currently supports only property assignments |
| 4 | fail: unexpected error: ON MATCH SET currently supports only property assignments |
| 4 | fail: unexpected error: Variable 'a' is not defined |
| 4 | fail: unexpected error: Invalid token |
| 4 | fail: unexpected error: Expected property name |
| 3 | unsupported: given: there exists a procedure test.my.proc(name :: STRING?, in :: INTEGER?) :: (out :: INTEGER?): |
| 3 | fail: unexpected error: MERGE does not support undirected relationship patterns (<-[]->) |
| 2 | unsupported: given: there exists a procedure test.my.proc(in :: FLOAT?) :: (out :: STRING?): |
| 2 | fail: unexpected error: DELETE requires variable references |
| 2 | fail: unexpected error: Variable 'b' is already defined |
| 2 | fail: setup query failed: LatticeQueryError: Expected relationship type after ':' |
| 2 | fail: unexpected error: Variable 'first' is already defined |
| 2 | fail: unexpected error: Variable 'message' is not defined |
| 2 | fail: unexpected error: Expected variable name in SET |

1 scenarios not run: intentional deviations (acmedb extensions), listed in tests/tck/deviations.txt.
