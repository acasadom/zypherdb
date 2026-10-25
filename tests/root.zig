//! Test suite root: every file here exercises ZypherDB through its public API.
//! Unit tests of private helpers stay next to their code in src/.

test {
    _ = @import("snapshot.zig");
    _ = @import("storage/key_value_store_test.zig");
    _ = @import("storage/graph_test.zig");
    _ = @import("storage/integrity_test.zig");
    _ = @import("storage/fuzz_test.zig");
    _ = @import("query/ast_test.zig");
    _ = @import("text/analyzer_test.zig");
    _ = @import("text/case_test.zig");
    _ = @import("text/query_test.zig");
    _ = @import("text/stemmer_test.zig");
    _ = @import("query/parser_test.zig");
    _ = @import("query/printer_test.zig");
    _ = @import("end_to_end/matching_test.zig");
    _ = @import("end_to_end/writing_test.zig");
    _ = @import("end_to_end/projection_test.zig");
    _ = @import("end_to_end/aggregation_test.zig");
    _ = @import("end_to_end/pipelines_test.zig");
    _ = @import("end_to_end/functions_test.zig");
    _ = @import("end_to_end/arithmetic_test.zig");
    _ = @import("end_to_end/floats_test.zig");
    _ = @import("end_to_end/temporal_test.zig");
    _ = @import("end_to_end/language_test.zig");
    _ = @import("end_to_end/subquery_test.zig");
    _ = @import("end_to_end/foreach_test.zig");
    _ = @import("end_to_end/shortest_paths_test.zig");
    _ = @import("end_to_end/constraints_test.zig");
    _ = @import("end_to_end/load_csv_test.zig");
    _ = @import("end_to_end/maps_test.zig");
    _ = @import("end_to_end/comprehensions_test.zig");
    _ = @import("end_to_end/paths_test.zig");
    _ = @import("end_to_end/procedures_test.zig");
    _ = @import("end_to_end/explain_test.zig");
    _ = @import("end_to_end/statement_test.zig");
    _ = @import("end_to_end/query_fuzz_test.zig");
    _ = @import("c_api_test.zig");
    _ = @import("error_messages_test.zig");
}
