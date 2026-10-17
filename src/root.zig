//! Root of the `acmedb` library.
//!
//! Embedded graph database engine (a subset of openCypher).
//! First building block: the storage layer (`KvStore` over LMDB).

pub const storage = @import("storage/kv_store.zig");

pub const KvStore = storage.KvStore;
pub const KvError = storage.KvError;
pub const PrefixIterator = storage.PrefixIterator;

test {
    @import("std").testing.refAllDecls(@This());
}
