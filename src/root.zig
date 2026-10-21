//! Root of the `acmedb` library.
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

pub const ParseError = parser.ParseError;
pub const lexer = @import("query/lexer.zig");

pub const TokenKind = lexer.TokenKind;
pub const Token = lexer.Token;

pub const Executor = @import("execution/Executor.zig");
pub const ExecutionError = Executor.ExecutionError;
pub const Row = Executor.Row;

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
    _ = @import("storage/engine/contract.zig");
    _ = @import("temporal/calendar.zig");
    _ = @import("temporal/zones.zig");
    _ = @import("temporal/types.zig");
    _ = @import("temporal/parse.zig");
    _ = @import("temporal/durations.zig");
    _ = @import("temporal/selection.zig");
}
