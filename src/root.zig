//! Root of the `zypherdb` library.
//!
//! Embedded graph database engine (a subset of openCypher).
//! First building block: the storage layer (`KeyValueStore` over the
//! storage engine of src/storage/engine.zig).

pub const key_value_store = @import("storage/key_value_store.zig");

pub const KeyValueStore = key_value_store.KeyValueStore;
pub const StorageError = key_value_store.StorageError;
pub const PrefixIterator = key_value_store.PrefixIterator;

pub const graph = @import("storage/graph.zig");

pub const Graph = graph.Graph;
pub const value_encoding = @import("storage/value_encoding.zig");
pub const NodeId = graph.NodeId;
pub const Direction = graph.Direction;
pub const EdgeKey = graph.EdgeKey;
pub const NeighbourIterator = graph.NeighbourIterator;
pub const NodeIdIterator = graph.NodeIdIterator;

/// Checks that every derived structure agrees with the primary records.
pub const integrity = @import("storage/integrity.zig");
/// Schema definitions (indexes, constraints) and the property indexes.
pub const schema_definitions = @import("storage/fulltext.zig");
pub const property_indexes = @import("storage/property_indexes.zig");

/// The layout of stored bytes, checked; and which names can be stored.
pub const layout = @import("storage/layout.zig");
pub const change_log = @import("storage/change_log.zig");
pub const replication_protocol = @import("replication/protocol.zig");
pub const replication_master = @import("replication/master.zig");
pub const replication_replica = @import("replication/replica.zig");
pub const replication_master_session = @import("replication/master_session.zig");
pub const replication_replica_session = @import("replication/replica_session.zig");
pub const replication_clock = @import("replication/clock.zig");
pub const replication_network = @import("replication/network.zig");
pub const replication_tcp = @import("replication/tcp.zig");
pub const replication_memory_network = @import("replication/memory_network.zig");
pub const replication_master_node = @import("replication/master_node.zig");
pub const replication_replica_node = @import("replication/replica_node.zig");
pub const replication_server = @import("replication/server.zig");
pub const replication_follower = @import("replication/follower.zig");
pub const replication = @import("replication/replication.zig");

/// The storage engine this build uses (`zig build -Dstorage-engine=...`).
pub const storage_engine = @tagName(@import("build_options").storage_engine);

/// True in the module build.zig makes for the fault tests and the fuzzers:
/// its engine fails when `faults.faults` says (storage/engine/faulty.zig).
pub const fault_injection = @import("build_options").fault_injection;
pub const faults = @import("storage/engine/faulty.zig");

pub const value = @import("value.zig");

pub const Value = value.Value;
pub const eqlSequences = value.eqlSequences;
pub const orderSequences = value.orderSequences;

pub const sequence_algorithms = @import("sequence_algorithms.zig");

/// Dates, times, date-times and durations (see src/temporal/).
pub const temporal = struct {
    pub const types = @import("temporal/types.zig");
    pub const parse = @import("temporal/parse.zig");
    pub const calendar = @import("temporal/calendar.zig");
    pub const zones = @import("temporal/zones.zig");
};

pub const text = struct {
    pub const analyzer = @import("text/analyzer.zig");
    pub const unicode = @import("text/unicode.zig");
    pub const query = @import("text/query.zig");
    pub const stem_english = @import("text/stem_english.zig");
    pub const stem_spanish = @import("text/stem_spanish.zig");
};

pub const ast = @import("query/ast.zig");

pub const Ast = ast.Ast;
pub const Index = ast.Index;
pub const procedures = @import("query/procedures.zig");
pub const NodeKind = ast.NodeKind;
pub const Node = ast.Node;
pub const Data = ast.Data;
pub const BinaryOperator = ast.BinaryOperator;
pub const UnaryOperator = ast.UnaryOperator;
pub const AggregateKind = ast.AggregateKind;
pub const EdgeDirection = ast.EdgeDirection;

pub const parser = @import("query/parser.zig");
/// Cypher text of an AST part (EXPLAIN's details).
pub const printer = @import("query/printer.zig");

pub const ParseError = parser.ParseError;
pub const lexer = @import("query/lexer.zig");

pub const TokenKind = lexer.TokenKind;
pub const Token = lexer.Token;

pub const Executor = @import("execution/Executor.zig");
pub const ExecutionError = Executor.ExecutionError;
pub const Row = Executor.Row;
/// The planner's switches (`Executor.plan_options`): the query fuzzer turns
/// optimizations off to compare results.
pub const PlanOptions = @import("planning/builder.zig").Options;

/// Prepared statements, and the cache of those `query` calls prepare.
pub const Statement = @import("statement/Statement.zig");
pub const StatementCache = @import("statement/Cache.zig");

pub const diagnostics = @import("diagnostics.zig");

pub const Diagnostic = diagnostics.Diagnostic;

pub const c_api = @import("c_api.zig");

comptime {
    // Force the C ABI export functions to be emitted in library builds (a
    // `pub const` import alone is analyzed lazily).
    _ = @import("c_api.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
    // Modules with unit tests that no declaration above reaches yet.
    _ = @import("storage/value_encoding.zig");
    _ = @import("storage/node_record.zig");
    _ = @import("storage/layout.zig");
    _ = @import("storage/engine/contract.zig");
    _ = @import("text/regex.zig");
    _ = @import("text/csv.zig");
    _ = @import("temporal/calendar.zig");
    _ = @import("temporal/zones.zig");
    _ = @import("temporal/types.zig");
    _ = @import("temporal/parse.zig");
    _ = @import("temporal/durations.zig");
    _ = @import("temporal/selection.zig");
}
