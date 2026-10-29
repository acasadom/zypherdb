//! The replication network (event_network.zig) in memory, for tests and
//! simulations: deterministic, on one thread. `wait` never waits: in a
//! simulation time is the simulation's to move. Each direction of a
//! connection holds `capacity` bytes; past them a send would block.

const std = @import("std");
const Allocator = std.mem.Allocator;

const event_network = @import("event_network.zig");
const Error = event_network.Error;
const Connection = event_network.Connection;
const Listener = event_network.Listener;
const Wakeup = event_network.Wakeup;
const Watched = event_network.Watched;
const Network = event_network.Network;

pub const MemoryNetwork = struct {
    allocator: Allocator,
    capacity: usize = 64 << 10,
    listeners: std.ArrayList(*MemoryListener) = .empty,
    /// The port the next `listen` at port 0 gets.
    next_port: u16 = 1,

    /// Once every listener is closed.
    pub fn deinit(self: *MemoryNetwork) void {
        std.debug.assert(self.listeners.items.len == 0);
        self.listeners.deinit(self.allocator);
    }

    pub fn network(self: *MemoryNetwork) Network {
        return .{ .context = self, .vtable = &.{ .listen = listen, .connect = connect, .wakeup = wakeup, .wait = wait } };
    }

    fn listen(context: *anyopaque, address: []const u8) Error!Listener {
        const self: *MemoryNetwork = @ptrCast(@alignCast(context));
        const split = try event_network.splitAddress(address);
        const port = if (split.port != 0) split.port else self.choosePort();
        if (self.find(split.host, port) != null) return error.NetworkFailed;
        const listener = try self.allocator.create(MemoryListener);
        errdefer self.allocator.destroy(listener);
        listener.* = .{ .network = self, .host = try self.allocator.dupe(u8, split.host), .port = port };
        errdefer self.allocator.free(listener.host);
        try self.listeners.append(self.allocator, listener);
        return listener.listener();
    }

    fn choosePort(self: *MemoryNetwork) u16 {
        defer self.next_port +%= 1;
        return self.next_port;
    }

    fn find(self: *MemoryNetwork, host: []const u8, port: u16) ?*MemoryListener {
        for (self.listeners.items) |listener| {
            if (listener.port == port and std.mem.eql(u8, listener.host, host)) return listener;
        }
        return null;
    }

    /// Nobody listening there: a connection whose other end is gone, as a
    /// refused TCP connect shows.
    fn connect(context: *anyopaque, address: []const u8) Error!Connection {
        const self: *MemoryNetwork = @ptrCast(@alignCast(context));
        const split = try event_network.splitAddress(address);
        const link = try Link.create(self);
        const listener = self.find(split.host, split.port) orelse {
            link.end(1).close();
            return link.end(0);
        };
        listener.waiting.append(self.allocator, link) catch {
            link.end(1).close();
            link.end(0).close();
            return error.OutOfMemory;
        };
        return link.end(0);
    }

    fn wakeup(context: *anyopaque) Error!Wakeup {
        const self: *MemoryNetwork = @ptrCast(@alignCast(context));
        const opened = try self.allocator.create(MemoryWakeup);
        opened.* = .{ .network = self };
        return opened.wakeup();
    }

    fn wait(context: *anyopaque, watched: []Watched, timeout_ns: ?u64) Error!void {
        _ = context;
        _ = timeout_ns;
        for (watched) |*one| {
            const ready: event_network.Readiness = switch (one.source) {
                .connection => |connection| Link.readiness(connection),
                .listener => |listener| .{ .readable = MemoryListener.of(listener).waiting.items.len != 0 },
                .wakeup => |raised| .{ .readable = MemoryWakeup.of(raised).raised },
            };
            one.ready = .{
                .readable = one.wanted.readable and ready.readable,
                .writable = one.wanted.writable and ready.writable,
            };
        }
    }
};

const MemoryListener = struct {
    network: *MemoryNetwork,
    host: []const u8,
    port: u16,
    /// Connections not accepted yet, oldest first.
    waiting: std.ArrayList(*Link) = .empty,

    const vtable: Listener.VTable = .{ .accept = accept, .address = address, .close = close };

    fn listener(self: *MemoryListener) Listener {
        return .{ .context = self, .vtable = &vtable };
    }

    fn of(one: Listener) *MemoryListener {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    fn accept(context: *anyopaque) Error!?Connection {
        const self: *MemoryListener = @ptrCast(@alignCast(context));
        if (self.waiting.items.len == 0) return null;
        return self.waiting.orderedRemove(0).end(1);
    }

    fn address(context: *anyopaque, buffer: *[event_network.max_address_bytes]u8) []const u8 {
        const self: *MemoryListener = @ptrCast(@alignCast(context));
        return std.fmt.bufPrint(buffer, "{s}:{d}", .{ self.host, self.port }) catch unreachable;
    }

    fn close(context: *anyopaque) void {
        const self: *MemoryListener = @ptrCast(@alignCast(context));
        for (self.waiting.items) |link| link.end(1).close();
        self.waiting.deinit(self.network.allocator);
        const listeners = &self.network.listeners;
        _ = listeners.swapRemove(std.mem.indexOfScalar(*MemoryListener, listeners.items, self).?);
        self.network.allocator.free(self.host);
        self.network.allocator.destroy(self);
    }
};

/// The bytes on their way one direction of a link.
const Pipe = struct {
    bytes: []u8,
    /// The bytes waiting are `bytes[start..][0..length]`.
    start: usize = 0,
    length: usize = 0,
    /// The end that sends into it closed.
    sender_closed: bool = false,
    /// The end that receives from it closed.
    receiver_closed: bool = false,

    fn room(self: *const Pipe) usize {
        return self.bytes.len - self.length;
    }

    fn put(self: *Pipe, from: []const u8) usize {
        if (self.start + self.length + from.len > self.bytes.len) {
            std.mem.copyForwards(u8, self.bytes, self.bytes[self.start..][0..self.length]);
            self.start = 0;
        }
        const count = @min(from.len, self.room());
        @memcpy(self.bytes[self.start + self.length ..][0..count], from[0..count]);
        self.length += count;
        return count;
    }

    fn take(self: *Pipe, into: []u8) usize {
        const count = @min(into.len, self.length);
        @memcpy(into[0..count], self.bytes[self.start..][0..count]);
        self.start += count;
        self.length -= count;
        if (self.length == 0) self.start = 0;
        return count;
    }
};

/// A connection's two ends: end `side` receives from `pipes[side]` and
/// sends into the other pipe. End 0 connected, end 1 was accepted.
const Link = struct {
    network: *MemoryNetwork,
    pipes: [2]Pipe,
    ends: [2]End,
    open_ends: u2 = 2,

    const End = struct {
        link: *Link,
        side: u1,

        fn incoming(self: *End) *Pipe {
            return &self.link.pipes[self.side];
        }

        fn outgoing(self: *End) *Pipe {
            return &self.link.pipes[1 - self.side];
        }
    };

    const vtable: Connection.VTable = .{ .receive = receive, .send = send, .close = close };

    fn create(network: *MemoryNetwork) Error!*Link {
        const allocator = network.allocator;
        const link = try allocator.create(Link);
        errdefer allocator.destroy(link);
        const bytes = try allocator.alloc(u8, 2 * network.capacity);
        link.* = .{
            .network = network,
            .pipes = .{ .{ .bytes = bytes[0..network.capacity] }, .{ .bytes = bytes[network.capacity..] } },
            .ends = .{ .{ .link = link, .side = 0 }, .{ .link = link, .side = 1 } },
        };
        return link;
    }

    fn end(self: *Link, side: u1) Connection {
        return .{ .context = &self.ends[side], .vtable = &vtable };
    }

    fn of(one: Connection) *End {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    fn readiness(one: Connection) event_network.Readiness {
        const self = of(one);
        const in = self.incoming();
        const out = self.outgoing();
        return .{
            .readable = in.length != 0 or in.sender_closed,
            .writable = out.room() != 0 or out.receiver_closed,
        };
    }

    fn receive(context: *anyopaque, buffer: []u8) error{ WouldBlock, Closed }!usize {
        const self: *End = @ptrCast(@alignCast(context));
        const in = self.incoming();
        if (in.length == 0) return if (in.sender_closed) error.Closed else error.WouldBlock;
        return in.take(buffer);
    }

    fn send(context: *anyopaque, bytes: []const u8) error{ WouldBlock, Closed }!usize {
        const self: *End = @ptrCast(@alignCast(context));
        const out = self.outgoing();
        if (out.receiver_closed) return error.Closed;
        if (out.room() == 0) return error.WouldBlock;
        return out.put(bytes);
    }

    fn close(context: *anyopaque) void {
        const self: *End = @ptrCast(@alignCast(context));
        self.incoming().receiver_closed = true;
        self.outgoing().sender_closed = true;
        const link = self.link;
        link.open_ends -= 1;
        if (link.open_ends != 0) return;
        const allocator = link.network.allocator;
        allocator.free(link.pipes[0].bytes.ptr[0 .. 2 * link.pipes[0].bytes.len]);
        allocator.destroy(link);
    }
};

const MemoryWakeup = struct {
    network: *MemoryNetwork,
    raised: bool = false,

    const vtable: Wakeup.VTable = .{ .raise = raise, .clear = clear, .close = close };

    fn wakeup(self: *MemoryWakeup) Wakeup {
        return .{ .context = self, .vtable = &vtable };
    }

    fn of(one: Wakeup) *MemoryWakeup {
        std.debug.assert(one.vtable == &vtable);
        return @ptrCast(@alignCast(one.context));
    }

    fn raise(context: *anyopaque) void {
        const self: *MemoryWakeup = @ptrCast(@alignCast(context));
        self.raised = true;
    }

    fn clear(context: *anyopaque) void {
        const self: *MemoryWakeup = @ptrCast(@alignCast(context));
        self.raised = false;
    }

    fn close(context: *anyopaque) void {
        const self: *MemoryWakeup = @ptrCast(@alignCast(context));
        self.network.allocator.destroy(self);
    }
};
