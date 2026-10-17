//! Raiz de la libreria `acmedb`.
//!
//! Motor de base de datos de grafos embebido (subconjunto de openCypher).
//! Primer ladrillo: la capa de storage (`KvStore` sobre LMDB).

pub const storage = @import("storage/kv_store.zig");

pub const KvStore = storage.KvStore;
pub const KvError = storage.KvError;
pub const PrefixIterator = storage.PrefixIterator;

test {
    @import("std").testing.refAllDecls(@This());
}
