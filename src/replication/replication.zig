//! Replication as a database opened with a role runs it: a master serves
//! replicas (server.zig), a replica follows its master (follower.zig).
//! `Replication` owns what they run on (threads, the system clock, TCP),
//! starts with the database and stops before it closes. One process runs
//! it on a database; the others opened with a role stand by and take over
//! when it stops or dies. What it tells
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
const follower_module = @import("follower.zig");
const Follower = follower_module.Follower;
const Instant = @import("clock.zig").Instant;
const sockets = @import("sockets.zig");
const KeyValueStore = @import("../storage/key_value_store.zig").KeyValueStore;
const Signal = @import("clock.zig").Signal;
const network = @import("network.zig");

const log = std.log.scoped(.replication);

pub const ReplicaState = server_module.ReplicaState;
pub const Refusal = protocol.Refusal;
pub const Phase = follower_module.Phase;

/// The directory, inside the database's, where copies for or from other
/// nodes are kept while they are sent or loaded.
pub const copies_directory_name = "replication-copies";

/// The file, inside the database's directory, that the process running
/// replication holds locked: one process runs it; the others opened with a
/// role stand by to take over.
pub const lock_file_name = "replication.lock";

/// How often a process standing by tries to take over replication.
pub const takeover_interval_ns = 200 * std.time.ns_per_ms;

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
        /// What the replica calls itself in its master's status, at most
        /// `protocol.max_name_bytes`; null: this host's name.
        name: ?[]const u8 = null,
    };
};

pub const Status = union(enum) {
    master: Master,
    replica: Replica,

    pub const Master = struct {
        /// Another process runs replication; this one takes over when it
        /// stops.
        standby: bool,
        /// The LSN of the last change set committed.
        last_lsn: u64,
        /// The replicas served now (the rest of the buffer given is unused).
        replicas: []ReplicaState,
        /// When the status was taken: a replica connected `now -
        /// connected_at` nanoseconds ago.
        now: Instant,
    };

    pub const Replica = struct {
        standby: bool,
        /// What the replica calls itself to its master.
        name: []const u8,
        master_address: []const u8,
        /// Where it is in following its master (`connecting` while
        /// standing by).
        phase: Phase,
        /// When the master was last heard from; null if never.
        last_heard: ?Instant,
        /// When the status was taken: the master was last heard from `now
        /// - last_heard` nanoseconds ago.
        now: Instant,
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
    /// Replication's own store on the database: the server or follower
    /// starts from it, on whichever thread takes over.
    own_store: KeyValueStore,
    /// The role, its address and token kept here (the caller's may go once
    /// `start` returns).
    role: Role,
    role_address: []u8,
    role_token: []u8,
    /// A replica's name (its host's, if not given); empty on a master.
    role_name: []u8,
    copies_directory: []u8,
    /// `lock_file_name`, locked while this process runs replication.
    lock_file: Io.File,
    /// Set once this process runs replication, as master or replica.
    server: std.atomic.Value(?*Server) = .init(null),
    follower: std.atomic.Value(?*Follower) = .init(null),
    /// Stopped by `stop`, waking the thread waiting to take over.
    stopping: Signal = .{},
    /// While another process runs replication: the thread that takes over
    /// once it stops.
    standby_thread: ?std.Thread = null,

    /// Starts replication for the database of `store`, in directory
    /// `path`, in `role`. A master's change log starts if it is not
    /// started; a replica's store refuses writes from now on. While
    /// another process runs replication on the database this one stands
    /// by, and takes over (within `takeover_interval_ns`) when it stops.
    pub fn start(allocator: Allocator, store: *KeyValueStore, path: []const u8, role: Role) !*Replication {
        const self = try allocator.create(Replication);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .clock = undefined,
            .tcp = undefined,
            .store = store,
            .own_store = undefined,
            .role = role,
            .role_address = &.{},
            .role_token = &.{},
            .role_name = &.{},
            .copies_directory = try std.fmt.allocPrint(allocator, "{s}/" ++ copies_directory_name, .{path}),
            .lock_file = undefined,
        };
        errdefer self.threaded.deinit();
        errdefer allocator.free(self.copies_directory);
        switch (self.role) {
            .master => |*master| {
                self.role_address = try allocator.dupe(u8, master.address);
                master.address = self.role_address;
            },
            .replica => |*replica| {
                self.role_address = try allocator.dupe(u8, replica.master_address);
                replica.master_address = self.role_address;
            },
        }
        errdefer allocator.free(self.role_address);
        switch (self.role) {
            inline else => |*either| {
                self.role_token = try allocator.dupe(u8, either.token);
                either.token = self.role_token;
            },
        }
        errdefer allocator.free(self.role_token);
        if (self.role == .replica) {
            const replica = &self.role.replica;
            var host_buffer: [256]u8 = undefined;
            const name = replica.name orelse host: {
                const host = sockets.hostName(&host_buffer) catch "";
                break :host host[0..@min(host.len, protocol.max_name_bytes)];
            };
            if (name.len > protocol.max_name_bytes) return error.NameTooLong;
            self.role_name = try allocator.dupe(u8, name);
            replica.name = self.role_name;
        }
        errdefer allocator.free(self.role_name);
        const io = self.threaded.io();
        self.clock = .{ .io = io };
        self.tcp = .{ .io = io, .allocator = allocator };
        self.lock_file = try openLockFile(io, path);
        errdefer self.lock_file.close(io);
        try Io.Dir.cwd().createDirPath(io, self.copies_directory);
        self.own_store = try store.share();
        errdefer self.own_store.deinit();
        switch (self.role) {
            .master => store.commit_listener = .{ .context = self, .committed = committed },
            .replica => store.follows_master = true,
        }
        errdefer store.commit_listener = null;
        errdefer store.follows_master = false;
        if (try self.lock_file.tryLock(io, .exclusive)) {
            try self.activate();
        } else {
            self.standby_thread = try std.Thread.spawn(.{}, waitToTakeOver, .{self});
        }
        return self;
    }

    /// Stops replication and frees it; the store stays open.
    pub fn stop(self: *Replication) void {
        const io = self.threaded.io();
        self.clock.clock().stop(&self.stopping);
        if (self.standby_thread) |thread| thread.join();
        self.store.commit_listener = null;
        self.store.follows_master = false;
        if (self.server.swap(null, .acq_rel)) |server| server.stop();
        if (self.follower.swap(null, .acq_rel)) |follower| follower.stop();
        self.own_store.deinit();
        // Closing the file lets the lock go, to a process standing by.
        self.lock_file.close(io);
        self.threaded.deinit();
        self.allocator.free(self.copies_directory);
        self.allocator.free(self.role_address);
        self.allocator.free(self.role_token);
        self.allocator.free(self.role_name);
        self.allocator.destroy(self);
    }

    /// Starts the server or the follower; the lock is held.
    fn activate(self: *Replication) !void {
        const io = self.threaded.io();
        switch (self.role) {
            .master => |master| {
                try self.own_store.startChangeLog();
                self.server.store(try Server.start(self.allocator, io, self.clock.clock(), self.tcp.network(), &self.own_store, .{
                    .address = master.address,
                    .token = master.token,
                    .copies_directory = self.copies_directory,
                    .heartbeat_ns = master.heartbeat_ns,
                    .timeout_ns = master.timeout_ns,
                    .max_replicas = max_replicas,
                }), .release);
            },
            .replica => |replica| {
                self.follower.store(try Follower.start(self.allocator, io, self.clock.clock(), self.tcp.network(), &self.own_store, .{
                    .master_address = replica.master_address,
                    .token = replica.token,
                    .copies_directory = self.copies_directory,
                    .timeout_ns = replica.timeout_ns,
                    .name = self.role_name,
                }), .release);
            },
        }
    }

    /// The standby thread: tries the lock every `takeover_interval_ns`
    /// until it gets it, then runs replication, or until `stop`.
    fn waitToTakeOver(self: *Replication) void {
        const io = self.threaded.io();
        const clock = self.clock.clock();
        while (clock.wait(&self.stopping, 0, clock.now() +| takeover_interval_ns) != null) {
            const locked = self.lock_file.tryLock(io, .exclusive) catch |err| {
                log.warn("trying the replication lock failed: {t}", .{err});
                continue;
            };
            if (!locked) continue;
            self.activate() catch |err| {
                log.warn("taking over replication failed: {t}", .{err});
                self.lock_file.unlock(io);
                continue;
            };
            log.info("this process took over replication", .{});
            return;
        }
    }

    /// The commit listener of a master's store: wakes the server, once
    /// this process runs it.
    fn committed(context: *anyopaque, lsn: u64) void {
        const self: *Replication = @ptrCast(@alignCast(context));
        const server = self.server.load(.acquire) orelse return;
        const listener = server.commitListener();
        listener.committed(listener.context, lsn);
    }

    /// Where a master listens (the port chosen, if asked to choose); null
    /// on a replica, or while standing by.
    pub fn address(self: *Replication, buffer: *[network.max_address_bytes]u8) ?[]const u8 {
        const server = self.server.load(.acquire) orelse return null;
        return server.address(buffer);
    }

    /// How replication goes now; a master's replicas go in `buffer`, at
    /// most its length of them.
    pub fn status(self: *Replication, buffer: []ReplicaState) !Status {
        switch (self.role) {
            .master => {
                const server = self.server.load(.acquire);
                return .{ .master = .{
                    .standby = server == null,
                    .last_lsn = try lastLsn(self.store),
                    .replicas = if (server) |running| running.replicaStates(buffer) else buffer[0..0],
                    .now = self.clock.clock().now(),
                } };
            },
            .replica => {
                const follower = self.follower.load(.acquire);
                return .{ .replica = .{
                    .standby = follower == null,
                    .name = self.role_name,
                    .master_address = self.role_address,
                    .phase = if (follower) |running| running.phase() else .connecting,
                    .last_heard = if (follower) |running| running.lastHeard() else null,
                    .now = self.clock.clock().now(),
                    .applied_lsn = try self.store.appliedLsn() orelse 0,
                    .master_lsn = if (follower) |running| running.masterLsn() else 0,
                    .last_refusal = if (follower) |running| running.lastRefusal() else null,
                    .halted = if (follower) |running| running.halted() else null,
                } };
            },
        }
    }

    /// `status` as JSON, owned by the caller: a master's
    /// {"role", "standby", "address", "last_lsn", "replicas": [{"name",
    /// "address", "connected_ms", "phase", "acked_lsn", "lag"}]}, a
    /// replica's {"role", "standby", "name", "master_address", "phase",
    /// "last_contact_ms" (ago, or null), "applied_lsn", "master_lsn", "lag",
    /// "last_refusal", "halted"} (a refusal's name, or null).
    pub fn statusJson(self: *Replication, allocator: Allocator) ![]u8 {
        var out: Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        self.writeStatusJson(&out.writer) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |other| return other,
        };
        return out.toOwnedSlice();
    }

    fn writeStatusJson(self: *Replication, json: *Io.Writer) !void {
        var buffer: [max_replicas]ReplicaState = undefined;
        switch (try self.status(&buffer)) {
            .master => |master| {
                var address_buffer: [network.max_address_bytes]u8 = undefined;
                const listening = self.address(&address_buffer) orelse self.role_address;
                try json.print("{{\"role\":\"master\",\"standby\":{},\"address\":", .{master.standby});
                try writeString(json, listening);
                try json.print(",\"last_lsn\":{d},\"replicas\":[", .{master.last_lsn});
                for (master.replicas, 0..) |*replica, index| {
                    if (index > 0) try json.writeByte(',');
                    try json.writeAll("{\"name\":");
                    try writeString(json, replica.name());
                    try json.writeAll(",\"address\":");
                    try writeString(json, replica.address());
                    try json.print(",\"connected_ms\":{d},\"phase\":\"{t}\",\"acked_lsn\":{d},\"lag\":{d}}}", .{
                        (master.now -| replica.connected_at) / std.time.ns_per_ms,
                        replica.phase,
                        replica.acked_lsn,
                        master.last_lsn -| replica.acked_lsn,
                    });
                }
                try json.writeAll("]}");
            },
            .replica => |replica| {
                try json.print("{{\"role\":\"replica\",\"standby\":{},\"name\":", .{replica.standby});
                try writeString(json, replica.name);
                try json.writeAll(",\"master_address\":");
                try writeString(json, replica.master_address);
                try json.print(",\"phase\":\"{t}\",\"last_contact_ms\":", .{replica.phase});
                if (replica.last_heard) |at| try json.print("{d}", .{(replica.now -| at) / std.time.ns_per_ms}) else try json.writeAll("null");
                try json.print(",\"applied_lsn\":{d},\"master_lsn\":{d},\"lag\":{d},\"last_refusal\":", .{ replica.applied_lsn, replica.master_lsn, replica.master_lsn -| replica.applied_lsn });
                try writeRefusal(json, replica.last_refusal);
                try json.writeAll(",\"halted\":");
                try writeRefusal(json, replica.halted);
                try json.writeByte('}');
            },
        }
    }

    /// Waits until change set `lsn` of the master is applied here, at most
    /// `timeout_ns`; whether it is. A master has every change set it made.
    pub fn waitFor(self: *Replication, lsn: u64, timeout_ns: u64) bool {
        const follower = self.follower.load(.acquire) orelse return waitApplied(self.store, lsn, timeout_ns) catch false;
        const clock = self.clock.clock();
        const applied = follower.waitApplied(lsn, clock.now() +| timeout_ns) orelse return false;
        return applied >= lsn;
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

fn writeRefusal(json: *Io.Writer, refusal: ?Refusal) Io.Writer.Error!void {
    const reason = refusal orelse return json.writeAll("null");
    try writeString(json, std.enums.tagName(Refusal, reason) orelse "unknown");
}

fn writeString(json: *Io.Writer, string: []const u8) Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(string, .{}, json);
}

/// Opens (or creates) the database's `lock_file_name`.
fn openLockFile(io: Io, path: []const u8) !Io.File {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = try std.fmt.bufPrint(&buffer, "{s}/" ++ lock_file_name, .{path});
    return Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false });
}
