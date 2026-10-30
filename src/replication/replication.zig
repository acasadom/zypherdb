//! Replication as a database opened with a role runs it: a master serves
//! replicas (server.zig), a replica follows its master (follower.zig).
//! `Replication` owns what they run on (threads, the system clock, TCP),
//! starts with the database and stops before it closes. What it tells
//! (`status`, `waitFor`) is for the application: how far behind each
//! replica is, and a read on a replica that must see a write on the master.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");
const SystemClock = @import("clock.zig").SystemClock;
const Tcp = @import("tcp.zig").Tcp;
const server_module = @import("server.zig");
const Server = server_module.Server;
const Follower = @import("follower.zig").Follower;
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;

pub const ReplicaState = server_module.ReplicaState;
pub const Refusal = protocol.Refusal;

/// The directory, inside the database's, where copies for or from other
/// nodes are kept while they are sent or loaded.
pub const copies_directory_name = "replication-copies";

/// The file, inside the database's directory, that the process running
/// replication holds locked: one process runs it, the others only read
/// (on a replica) or write (on a master) the database.
pub const lock_file_name = "replication.lock";

/// The most replicas a master serves.
pub const max_replicas = 16;

pub const Role = union(enum) {
    master: Master,
    replica: Replica,

    pub const Master = struct {
        /// Where to listen for replicas, "host:port" (port 0: any).
        address: []const u8,
        /// What a replica must send to be served.
        token: []const u8,
        heartbeat_ns: u64 = std.time.ns_per_s,
        timeout_ns: u64 = 5 * std.time.ns_per_s,
    };

    pub const Replica = struct {
        /// The master's address, "host:port".
        master_address: []const u8,
        token: []const u8,
        timeout_ns: u64 = 5 * std.time.ns_per_s,
    };
};

pub const Status = union(enum) {
    master: Master,
    replica: Replica,

    pub const Master = struct {
        /// The LSN of the last change set committed.
        last_lsn: u64,
        /// The replicas served now (the rest of the buffer given is unused).
        replicas: []ReplicaState,
    };

    pub const Replica = struct {
        /// The last change set applied (0 before the first copy).
        applied_lsn: u64,
        /// The master's last LSN, as its last heartbeat told (0 before one).
        master_lsn: u64,
        /// Why the master last turned the replica away, if it did since
        /// the replica last followed it.
        last_refusal: ?Refusal,
        /// The refusal that stopped the replica following for good.
        halted: ?Refusal,
    };
};

pub const Replication = struct {
    allocator: Allocator,
    threaded: Io.Threaded,
    clock: SystemClock,
    tcp: Tcp,
    /// The store the application writes and reads with.
    store: *KeyValueStore,
    running: union(enum) { master: *Server, replica: *Follower },
    copies_directory: []u8,
    /// The role's address and token, kept as long as the threads use them
    /// (the caller's may go once `start` returns).
    role_address: []u8,
    role_token: []u8,
    /// `lock_file_name`, locked while replication runs.
    lock_file: Io.File,

    /// Starts replication for the database of `store`, in directory
    /// `path`, in `role`. A master's change log starts if it is not
    /// started; a replica's store refuses writes from now on. Fails with
    /// `ReplicationRunsElsewhere` while another process runs it.
    pub fn start(allocator: Allocator, store: *KeyValueStore, path: []const u8, role: Role) !*Replication {
        const self = try allocator.create(Replication);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .clock = undefined,
            .tcp = undefined,
            .store = store,
            .running = undefined,
            .copies_directory = try std.fmt.allocPrint(allocator, "{s}/" ++ copies_directory_name, .{path}),
            .role_address = &.{},
            .role_token = &.{},
            .lock_file = undefined,
        };
        errdefer self.threaded.deinit();
        errdefer allocator.free(self.copies_directory);
        self.role_address = try allocator.dupe(u8, switch (role) {
            .master => |master| master.address,
            .replica => |replica| replica.master_address,
        });
        errdefer allocator.free(self.role_address);
        self.role_token = try allocator.dupe(u8, switch (role) {
            .master => |master| master.token,
            .replica => |replica| replica.token,
        });
        errdefer allocator.free(self.role_token);
        const io = self.threaded.io();
        self.clock = .{ .io = io };
        self.tcp = .{ .io = io, .allocator = allocator };
        self.lock_file = try lock(io, path);
        errdefer self.lock_file.close(io);
        try Io.Dir.cwd().createDirPath(io, self.copies_directory);
        switch (role) {
            .master => |master| {
                try store.startChangeLog();
                const server = try Server.start(allocator, io, self.clock.clock(), self.tcp.network(), store, .{
                    .address = self.role_address,
                    .token = self.role_token,
                    .copies_directory = self.copies_directory,
                    .heartbeat_ns = master.heartbeat_ns,
                    .timeout_ns = master.timeout_ns,
                    .max_replicas = max_replicas,
                });
                store.commit_listener = server.commitListener();
                self.running = .{ .master = server };
            },
            .replica => |replica| {
                store.follows_master = true;
                errdefer store.follows_master = false;
                self.running = .{ .replica = try Follower.start(allocator, io, self.clock.clock(), self.tcp.network(), store, .{
                    .master_address = self.role_address,
                    .token = self.role_token,
                    .copies_directory = self.copies_directory,
                    .timeout_ns = replica.timeout_ns,
                }) };
            },
        }
        return self;
    }

    /// Stops replication and frees it; the store stays open.
    pub fn stop(self: *Replication) void {
        switch (self.running) {
            .master => |server| {
                self.store.commit_listener = null;
                server.stop();
            },
            .replica => |follower| {
                follower.stop();
                self.store.follows_master = false;
            },
        }
        // Closing the file lets the lock go.
        self.lock_file.close(self.threaded.io());
        self.threaded.deinit();
        self.allocator.free(self.copies_directory);
        self.allocator.free(self.role_address);
        self.allocator.free(self.role_token);
        self.allocator.destroy(self);
    }

    /// Where a master listens (the port chosen, if asked to choose); null
    /// on a replica.
    pub fn address(self: *Replication, buffer: *[@import("network.zig").max_address_bytes]u8) ?[]const u8 {
        return switch (self.running) {
            .master => |server| server.address(buffer),
            .replica => null,
        };
    }

    /// How replication goes now; a master's replicas go in `buffer`, at
    /// most its length of them.
    pub fn status(self: *Replication, buffer: []ReplicaState) !Status {
        return switch (self.running) {
            .master => |server| .{ .master = .{
                .last_lsn = if (try self.store.changeLogState()) |state| state.next_lsn - 1 else 0,
                .replicas = server.replicaStates(buffer),
            } },
            .replica => |follower| .{ .replica = .{
                .applied_lsn = try self.store.appliedLsn() orelse 0,
                .master_lsn = follower.masterLsn(),
                .last_refusal = follower.lastRefusal(),
                .halted = follower.halted(),
            } },
        };
    }

    /// `status` as JSON, owned by the caller: a master's
    /// {"role", "address", "last_lsn", "replicas": [{"phase", "acked_lsn",
    /// "lag"}]}, a replica's {"role", "applied_lsn", "master_lsn", "lag",
    /// "last_refusal", "halted"} (a refusal's name, or null).
    pub fn statusJson(self: *Replication, allocator: Allocator) ![]u8 {
        var buffer: [max_replicas]ReplicaState = undefined;
        var json: std.ArrayList(u8) = .empty;
        errdefer json.deinit(allocator);
        switch (try self.status(&buffer)) {
            .master => |master| {
                var address_buffer: [@import("network.zig").max_address_bytes]u8 = undefined;
                try json.print(allocator, "{{\"role\":\"master\",\"address\":\"{s}\",\"last_lsn\":{d},\"replicas\":[", .{ self.address(&address_buffer).?, master.last_lsn });
                for (master.replicas, 0..) |replica, index| {
                    if (index > 0) try json.append(allocator, ',');
                    try json.print(allocator, "{{\"phase\":\"{t}\",\"acked_lsn\":{d},\"lag\":{d}}}", .{ replica.phase, replica.acked_lsn, master.last_lsn -| replica.acked_lsn });
                }
                try json.appendSlice(allocator, "]}");
            },
            .replica => |replica| {
                try json.print(allocator, "{{\"role\":\"replica\",\"applied_lsn\":{d},\"master_lsn\":{d},\"lag\":{d},\"last_refusal\":", .{ replica.applied_lsn, replica.master_lsn, replica.master_lsn -| replica.applied_lsn });
                try appendRefusal(&json, allocator, replica.last_refusal);
                try json.appendSlice(allocator, ",\"halted\":");
                try appendRefusal(&json, allocator, replica.halted);
                try json.append(allocator, '}');
            },
        }
        return json.toOwnedSlice(allocator);
    }

    /// Waits until change set `lsn` of the master is applied here, at most
    /// `timeout_ns`; whether it is. A master has every change set it made.
    pub fn waitFor(self: *Replication, lsn: u64, timeout_ns: u64) bool {
        return switch (self.running) {
            .master => true,
            .replica => |follower| {
                const clock = self.clock.clock();
                const applied = follower.waitApplied(lsn, clock.now() +| timeout_ns) orelse return false;
                return applied >= lsn;
            },
        };
    }
};

/// The LSN of the last change set the database of `store` has: on a master
/// the last committed, on a replica the last applied, 0 on neither; in any
/// process, whether or not it runs replication.
pub fn lastLsn(store: *KeyValueStore) !u64 {
    if (try store.changeLogState()) |state| return state.next_lsn - 1;
    return try store.appliedLsn() orelse 0;
}

/// On a process that does not run replication: waits until the database,
/// if it is a replica, has applied change set `lsn` of its master, at most
/// `timeout_ns`, looking at it every millisecond; whether it has. True at
/// once on a database that is no replica.
pub fn waitApplied(store: *KeyValueStore, lsn: u64, timeout_ns: u64) !bool {
    const io = Io.Threaded.global_single_threaded.io();
    const deadline = Io.Clock.awake.now(io).nanoseconds +| timeout_ns;
    while (true) {
        const applied = try store.appliedLsn() orelse return true;
        if (applied >= lsn) return true;
        if (Io.Clock.awake.now(io).nanoseconds >= deadline) return false;
        io.sleep(.fromMilliseconds(1), .awake) catch return false;
    }
}

fn appendRefusal(json: *std.ArrayList(u8), allocator: Allocator, refusal: ?Refusal) Allocator.Error!void {
    const reason = refusal orelse return json.appendSlice(allocator, "null");
    const name = std.enums.tagName(Refusal, reason) orelse "unknown";
    try json.print(allocator, "\"{s}\"", .{name});
}

/// Opens the database's `lock_file_name` and locks it; the operating system
/// lets the lock go when the file is closed or the process ends.
fn lock(io: Io, path: []const u8) !Io.File {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&buffer, "{s}/" ++ lock_file_name, .{path});
    const file = try Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false });
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.ReplicationRunsElsewhere;
    return file;
}
