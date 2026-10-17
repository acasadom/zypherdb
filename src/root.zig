//! Root of the `acmedb` library.
//!
//! Embedded graph database engine (a subset of openCypher).
//! First building block: the storage layer (`KvStore` over LMDB).

pub const storage = @import("storage/kv_store.zig");

pub const KvStore = storage.KvStore;
pub const KvError = storage.KvError;
pub const PrefixIterator = storage.PrefixIterator;

pub const graph = @import("storage/graph.zig");

pub const Graph = graph.Graph;
pub const NodeId = graph.NodeId;
pub const Direction = graph.Direction;
pub const EdgeKey = graph.EdgeKey;
pub const NeighbourIterator = graph.NeighbourIterator;
pub const NodeIdIterator = graph.NodeIdIterator;
pub const Value = graph.Value;

pub const ast = @import("ast/ast.zig");

pub const Ast = ast.Ast;
pub const Index = ast.Index;
pub const NodeKind = ast.NodeKind;
pub const Node = ast.Node;
pub const Data = ast.Data;
pub const BinOp = ast.BinOp;
pub const UnOp = ast.UnOp;
pub const EdgeDirection = ast.EdgeDirection;

pub const parser = @import("parser/parser.zig");

pub const ParseError = parser.ParseError;
pub const TokenKind = parser.TokenKind;
pub const Token = parser.Token;

pub const exec = @import("exec/exec.zig");

pub const Executor = exec.Executor;
pub const ExecError = exec.ExecError;
pub const Row = exec.Row;

pub const diag = @import("diag.zig");

pub const Diagnostic = diag.Diagnostic;

pub const capi = @import("capi.zig");

comptime {
    // Force the C ABI export functions to be emitted in library builds (a
    // `pub const` import alone is analyzed lazily).
    _ = @import("capi.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
}
