//! The storage engine acmedb is built with, chosen at compile time
//! (`zig build -Dstorage-engine=...`): the only place that names one. Every
//! engine keeps the contract of engine/contract.zig.

const build_options = @import("build_options");

const contract = @import("engine/contract.zig");

pub const Error = contract.Error;
pub const Table = contract.Table;
pub const Entry = contract.Entry;
pub const Durability = contract.Durability;
pub const Options = contract.Options;

pub const Selected = switch (build_options.storage_engine) {
    .lmdb => @import("engine/lmdb.zig"),
};

pub const Environment = Selected.Environment;
pub const Transaction = Selected.Transaction;
pub const Cursor = Selected.Cursor;
