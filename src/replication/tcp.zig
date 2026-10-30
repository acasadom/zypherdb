//! The replication network over TCP (network.zig), on sockets that
//! never block (sockets.zig) and `poll`. One `Tcp` serves any number of
//! loops, each on its own thread.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const network_module = @import("network.zig");
const sockets = @import("sockets.zig");
const Error = network_module.Error;
const Connection = network_module.Connection;
const Listener = network_module.Listener;
const Wakeup = network_module.Wakeup;
const Watched = network_module.Watched;
const Network = network_module.Network;

pub const Tcp = struct {
    /// Only to resolve host names.
    io: Io,
    allocator: Allocator,

    pub fn network(self: *Tcp) Network {
        return .{ .context = self, .vtable = &.{ .listen = listen, .connect = connect, .wakeup = wakeup, .wait = wait } };
    }

    fn listen(context: *anyopaque, address: []const u8) Error!Listener {
        const self: *Tcp = @ptrCast(@alignCast(context));
        const ip = try self.resolve(address);
        const handle = try sockets.open(&ip);
        errdefer sockets.close(handle);
        try sockets.reuseAddress(handle);
        try sockets.bind(handle, &ip);
        try sockets.listen(handle);
        const listener = self.allocator.create(TcpListener) catch return error.OutOfMemory;
        listener.* = .{ .tcp = self, .handle = handle, .address = try sockets.localAddress(handle) };
        return listener.listener();
    }

    fn connect(context: *anyopaque, address: []const u8) Error!Connection {
        const self: *Tcp = @ptrCast(@alignCast(context));
        const ip = try self.resolve(address);
        const handle = try sockets.open(&ip);
        errdefer sockets.close(handle);
        try sockets.noDelay(handle);
        try sockets.connect(handle, &ip);
        return self.connection(handle, true);
    }

    fn connection(self: *Tcp, handle: sockets.Handle, connecting: bool) Error!Connection {
        const opened = self.allocator.create(TcpConnection) catch return error.OutOfMemory;
        opened.* = .{ .tcp = self, .handle = handle, .connecting = connecting };
        return opened.connection();
    }

    fn wakeup(context: *anyopaque) Error!Wakeup {
        const self: *Tcp = @ptrCast(@alignCast(context));
        const ends = try sockets.wakeupPair();
        errdefer for (ends) |end| sockets.close(end);
        const opened = self.allocator.create(TcpWakeup) catch return error.OutOfMemory;
        opened.* = .{ .tcp = self, .ends = ends };
        return opened.wakeup();
    }

    fn wait(context: *anyopaque, watched: []Watched, timeout_ns: ?u64) Error!void {
        _ = context;
        var entries: [network_module.max_watched]sockets.PollEntry = undefined;
        for (watched, entries[0..watched.len]) |one, *entry| {
            var events: i16 = 0;
            if (one.wanted.readable) events |= sockets.poll_readable;
            if (one.wanted.writable) events |= sockets.poll_writable;
            entry.* = sockets.pollEntry(handleOf(one.source), events);
        }
        const timeout_ms: i32 = if (timeout_ns) |ns|
            // Rounded up: woken before the deadline, a loop would wait again.
            @intCast(@min(std.math.divCeil(u64, ns, std.time.ns_per_ms) catch unreachable, std.math.maxInt(i32)))
        else
            -1;
        if (try sockets.poll(entries[0..watched.len], timeout_ms) == 0) return;
        for (watched, entries[0..watched.len]) |*one, entry| {
            const failed = entry.revents & sockets.poll_failed != 0;
            one.ready = .{
                .readable = one.wanted.readable and (failed or entry.revents & sockets.poll_readable != 0),
                .writable = one.wanted.writable and (failed or entry.revents & sockets.poll_writable != 0),
            };
        }
    }

    fn handleOf(source: network_module.Source) sockets.Handle {
        return switch (source) {
            .connection => |one| TcpConnection.of(one).handle,
            .listener => |one| TcpListener.of(one).handle,
            .wakeup => |one| TcpWakeup.of(one).ends[0],
        };
    }

    fn resolve(self: *Tcp, address: []const u8) Error!Io.net.IpAddress {
        const split = try network_module.splitAddress(address);
        return Io.net.IpAddress.parse(split.host, split.port) catch
            Io.net.IpAddress.resolve(self.io, split.host, split.port) catch error.NetworkFailed;
    }
};

const TcpListener = struct {
    tcp: *Tcp,
    handle: sockets.Handle,
    address: Io.net.IpAddress,

    const vtable: Listener.VTable = .{ .accept = accept, .address = addressOf, .close = close };

    fn listener(self: *TcpListener) Listener {
        return .{ .context = self, .vtable = &vtable };
    }

    fn of(one: Listener) *TcpListener {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    fn accept(context: *anyopaque) Error!?Connection {
        const self: *TcpListener = @ptrCast(@alignCast(context));
        const handle = try sockets.accept(self.handle) orelse return null;
        errdefer sockets.close(handle);
        return try self.tcp.connection(handle, false);
    }

    fn addressOf(context: *anyopaque, buffer: *[network_module.max_address_bytes]u8) []const u8 {
        const self: *TcpListener = @ptrCast(@alignCast(context));
        return std.fmt.bufPrint(buffer, "{f}", .{reachable(self.address)}) catch unreachable;
    }

    fn close(context: *anyopaque) void {
        const self: *TcpListener = @ptrCast(@alignCast(context));
        sockets.close(self.handle);
        self.tcp.allocator.destroy(self);
    }

    /// Where to connect to reach `listened`: loopback for "any address".
    fn reachable(listened: Io.net.IpAddress) Io.net.IpAddress {
        return switch (listened) {
            .ip4 => |ip| if (std.mem.allEqual(u8, &ip.bytes, 0)) .{ .ip4 = .loopback(ip.port) } else listened,
            .ip6 => |ip| if (std.mem.allEqual(u8, &ip.bytes, 0)) .{ .ip6 = .loopback(ip.port) } else listened,
        };
    }
};

const TcpConnection = struct {
    tcp: *Tcp,
    handle: sockets.Handle,
    /// Connecting still, as far as it knows.
    connecting: bool,

    const vtable: Connection.VTable = .{ .receive = receive, .send = send, .close = close };

    fn connection(self: *TcpConnection) Connection {
        return .{ .context = self, .vtable = &vtable };
    }

    fn of(one: Connection) *TcpConnection {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    fn receive(context: *anyopaque, buffer: []u8) error{ WouldBlock, Closed }!usize {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        try self.connected();
        return sockets.receive(self.handle, buffer);
    }

    fn send(context: *anyopaque, bytes: []const u8) error{ WouldBlock, Closed }!usize {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        try self.connected();
        return sockets.send(self.handle, bytes);
    }

    /// Systems differ on what a read or a write does while connecting: so
    /// none is done until connecting ends, and a failure is told as one.
    fn connected(self: *TcpConnection) error{ WouldBlock, Closed }!void {
        if (!self.connecting) return;
        var entries = [_]sockets.PollEntry{sockets.pollEntry(self.handle, sockets.poll_writable)};
        const ready = sockets.poll(&entries, 0) catch return error.Closed;
        if (ready == 0) return error.WouldBlock;
        self.connecting = false;
        if (sockets.connectFailed(self.handle)) return error.Closed;
    }

    fn close(context: *anyopaque) void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        sockets.close(self.handle);
        self.tcp.allocator.destroy(self);
    }
};

const TcpWakeup = struct {
    tcp: *Tcp,
    /// Read end, write end.
    ends: [2]sockets.Handle,

    const vtable: Wakeup.VTable = .{ .raise = raise, .clear = clear, .close = close };

    fn wakeup(self: *TcpWakeup) Wakeup {
        return .{ .context = self, .vtable = &vtable };
    }

    fn of(one: Wakeup) *TcpWakeup {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    fn raise(context: *anyopaque) void {
        const self: *TcpWakeup = @ptrCast(@alignCast(context));
        sockets.wakeupSend(self.ends[1]);
    }

    fn clear(context: *anyopaque) void {
        const self: *TcpWakeup = @ptrCast(@alignCast(context));
        sockets.wakeupDrain(self.ends[0]);
    }

    fn close(context: *anyopaque) void {
        const self: *TcpWakeup = @ptrCast(@alignCast(context));
        for (self.ends) |end| sockets.close(end);
        self.tcp.allocator.destroy(self);
    }
};
