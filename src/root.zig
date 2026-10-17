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

test {
    @import("std").testing.refAllDecls(@This());
}
