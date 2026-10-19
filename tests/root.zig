//! Test suite root: every file here exercises acmedb through its public API.
//! Unit tests of private helpers stay next to their code in src/.

test {
    _ = @import("storage/key_value_store_test.zig");
    _ = @import("storage/graph_test.zig");
    _ = @import("query/ast_test.zig");
    _ = @import("query/parser_test.zig");
    _ = @import("end_to_end/matching_test.zig");
    _ = @import("end_to_end/writing_test.zig");
    _ = @import("end_to_end/projection_test.zig");
    _ = @import("end_to_end/aggregation_test.zig");
    _ = @import("end_to_end/pipelines_test.zig");
    _ = @import("end_to_end/functions_test.zig");
    _ = @import("c_api_test.zig");
}
