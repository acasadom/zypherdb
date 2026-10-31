//! The network replication runs on, for an event loop: nothing blocks but
//! `Network.wait`, which waits until a connection, a listener or a wakeup
//! of those it is given is ready. A master listens for replicas, a replica
//! connects to its master, and each connection is a byte stream both ways.
//! An interface, so a simulation can run replication on a network of its
//! own (memory_network.zig); `Tcp` (tcp.zig) is the real one.

const std = @import("std");

pub const Error = error{ NetworkFailed, OutOfMemory };

/// The longest address `Listener.address` writes.
pub const max_address_bytes = 64;

/// The most a `Network.wait` watches at once.
pub const max_watched = 256;

/// A byte stream to the other end. It fails (`Closed`) once the other end
/// is gone, the connection broke, or connecting failed.
pub const Connection = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        receive: *const fn (context: *anyopaque, buffer: []u8) error{ WouldBlock, Closed }!usize,
        send: *const fn (context: *anyopaque, bytes: []const u8) error{ WouldBlock, Closed }!usize,
        close: *const fn (context: *anyopaque) void,
        peer: *const fn (context: *anyopaque, buffer: *[max_address_bytes]u8) []const u8,
    };

    /// Bytes from the other end into `buffer`: how many, never 0.
    /// `WouldBlock`: none yet.
    pub fn receive(self: Connection, buffer: []u8) error{ WouldBlock, Closed }!usize {
        return self.vtable.receive(self.context, buffer);
    }

    /// Bytes of `bytes` on their way to the other end: how many, never 0.
    /// `WouldBlock`: no room for any yet.
    pub fn send(self: Connection, bytes: []const u8) error{ WouldBlock, Closed }!usize {
        return self.vtable.send(self.context, bytes);
    }

    /// Ends the connection and frees it.
    pub fn close(self: Connection) void {
        self.vtable.close(self.context);
    }

    /// Where the other end is, "host:port"; "" if that cannot be told.
    pub fn peer(self: Connection, buffer: *[max_address_bytes]u8) []const u8 {
        return self.vtable.peer(self.context, buffer);
    }
};

pub const Listener = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (context: *anyopaque) Error!?Connection,
        address: *const fn (context: *anyopaque, buffer: *[max_address_bytes]u8) []const u8,
        close: *const fn (context: *anyopaque) void,
    };

    /// The next connection to it, or null if none waits.
    pub fn accept(self: Listener) Error!?Connection {
        return self.vtable.accept(self.context);
    }

    /// Where it listens, as `connect` takes it (the port chosen, if it
    /// was asked to choose one).
    pub fn address(self: Listener, buffer: *[max_address_bytes]u8) []const u8 {
        return self.vtable.address(self.context, buffer);
    }

    pub fn close(self: Listener) void {
        self.vtable.close(self.context);
    }
};

/// Wakes a `Network.wait` from another thread: a commit tells the master's
/// loop that there is a change set to send.
pub const Wakeup = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        raise: *const fn (context: *anyopaque) void,
        clear: *const fn (context: *anyopaque) void,
        close: *const fn (context: *anyopaque) void,
    };

    /// Makes it ready until `clear`. Callable from any thread.
    pub fn raise(self: Wakeup) void {
        self.vtable.raise(self.context);
    }

    /// Makes it not ready, after a `wait` said it was. Clear first, then
    /// look at what it was raised for: a raise after the look is not lost.
    pub fn clear(self: Wakeup) void {
        self.vtable.clear(self.context);
    }

    pub fn close(self: Wakeup) void {
        self.vtable.close(self.context);
    }
};

pub const Source = union(enum) {
    connection: Connection,
    listener: Listener,
    wakeup: Wakeup,
};

/// What a connection is ready for. A listener or a wakeup is only ever
/// readable: a connection to accept, a raise.
pub const Readiness = packed struct(u2) {
    readable: bool = false,
    writable: bool = false,

    pub fn any(self: Readiness) bool {
        return self.readable or self.writable;
    }
};

/// One source a `wait` watches: what for (`wanted`), and what it is ready
/// for once `wait` returns (`ready`; a broken connection is ready both
/// ways, so its `receive` or `send` tells it).
pub const Watched = struct {
    source: Source,
    wanted: Readiness,
    ready: Readiness = .{},
};

pub const Network = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listen: *const fn (context: *anyopaque, address: []const u8) Error!Listener,
        connect: *const fn (context: *anyopaque, address: []const u8) Error!Connection,
        wakeup: *const fn (context: *anyopaque) Error!Wakeup,
        wait: *const fn (context: *anyopaque, watched: []Watched, timeout_ns: ?u64) Error!void,
    };

    /// Listens at `address`, "host:port" (port 0: one free).
    pub fn listen(self: Network, address: []const u8) Error!Listener {
        return self.vtable.listen(self.context, address);
    }

    /// Starts connecting to the listener at `address`, "host:port". The
    /// connection is writable once connected; a failure to connect shows
    /// as `Closed`.
    pub fn connect(self: Network, address: []const u8) Error!Connection {
        return self.vtable.connect(self.context, address);
    }

    pub fn wakeup(self: Network) Error!Wakeup {
        return self.vtable.wakeup(self.context);
    }

    /// Waits until a source of `watched` (at most `max_watched`, all of
    /// this network) is ready for what it wants, or `timeout_ns` passes
    /// (null: no limit), and sets each one's `ready`. A network of a
    /// simulation may not wait at all: there time is the simulation's.
    pub fn wait(self: Network, watched: []Watched, timeout_ns: ?u64) Error!void {
        std.debug.assert(watched.len <= max_watched);
        for (watched) |*one| one.ready = .{};
        return self.vtable.wait(self.context, watched, timeout_ns);
    }
};

/// "host:port" split; error if there is no port.
pub fn splitAddress(address: []const u8) error{NetworkFailed}!struct { host: []const u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.NetworkFailed;
    const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch return error.NetworkFailed;
    return .{ .host = std.mem.trim(u8, address[0..colon], "[]"), .port = port };
}
