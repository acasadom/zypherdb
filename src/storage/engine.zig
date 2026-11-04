//! The storage engine ZypherDB is built with, chosen at compile time
//! (`zig build -Dstorage-engine=...`): the only place that names one. Every
//! engine keeps the contract of engine/contract.zig. In the module built for
//! the fault tests (build option `fault_injection`, set by build.zig), the
//! engine is wrapped by engine/faulty.zig.

const build_options = @import("build_options");

const contract = @import("engine/contract.zig");

pub const Error = contract.Error;
pub const Table = contract.Table;
pub const Entry = contract.Entry;
pub const Durability = contract.Durability;
pub const Options = contract.Options;

const chosen = switch (build_options.storage_engine) {
    .lmdb => @import("engine/lmdb.zig"),
    .mdbx => @import("engine/mdbx.zig"),
};

pub const Selected = if (build_options.fault_injection) @import("engine/faulty.zig").Wrap(chosen) else chosen;

pub const Environment = Selected.Environment;
pub const Transaction = Selected.Transaction;
pub const Cursor = Selected.Cursor;
