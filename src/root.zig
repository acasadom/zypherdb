//! Root of the `acmedb` library.
//!
//! Embedded graph database engine (a subset of openCypher).
//! First building block: the storage layer (`KvStore` over LMDB).

pub const key_value_store = @import("storage/key_value_store.zig");

pub const KvStore = key_value_store.KvStore;
pub const KvError = key_value_store.KvError;
pub const PrefixIterator = key_value_store.PrefixIterator;

pub const graph = @import("storage/graph.zig");

pub const Graph = graph.Graph;
pub const NodeId = graph.NodeId;
pub const Direction = graph.Direction;
pub const EdgeKey = graph.EdgeKey;
pub const NeighbourIterator = graph.NeighbourIterator;
pub const NodeIdIterator = graph.NodeIdIterator;

pub const value = @import("value.zig");

pub const Value = value.Value;
pub const eqlSequences = value.eqlSequences;
pub const orderSequences = value.orderSequences;

pub const ast = @import("query/ast.zig");

pub const Ast = ast.Ast;
pub const Index = ast.Index;
pub const NodeKind = ast.NodeKind;
pub const Node = ast.Node;
pub const Data = ast.Data;
pub const BinOp = ast.BinOp;
pub const UnOp = ast.UnOp;
pub const AggKind = ast.AggKind;
pub const EdgeDirection = ast.EdgeDirection;

pub const parser = @import("query/parser.zig");

pub const ParseError = parser.ParseError;
pub const TokenKind = parser.TokenKind;
pub const Token = parser.Token;

pub const executor = @import("execution/executor.zig");

pub const Executor = executor.Executor;
pub const ExecError = executor.ExecError;
pub const Row = executor.Row;

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
}
