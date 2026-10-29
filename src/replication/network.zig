//! The network replication runs on: a master listens for replicas, a
//! replica connects to its master, and each connection is a byte stream
//! both ways (a `std.Io.Reader` and a `std.Io.Writer`). An interface, so a
//! simulation can run replication on a network of its own; `Tcp` is the
//! real one.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;

const protocol = @import("protocol.zig");

pub const Error = error{ NetworkFailed, OutOfMemory };

/// The longest address `Listener.address` writes.
pub const max_address_bytes = 64;

/// A byte stream to the other end. Its reader fails (`ReadFailed`) when
/// the other end is gone, nothing came within the network's read timeout,
/// or the connection was shut down.
pub const Connection = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reader: *const fn (context: *anyopaque) *Reader,
        writer: *const fn (context: *anyopaque) *Writer,
        shutdown: *const fn (context: *anyopaque) void,
        close: *const fn (context: *anyopaque) void,
    };

    pub fn reader(self: Connection) *Reader {
        return self.vtable.reader(self.context);
    }

    pub fn writer(self: Connection) *Writer {
        return self.vtable.writer(self.context);
    }

    /// Ends the connection both ways: a read or a write on it, blocked in
    /// another thread or to come, fails. Callable from any thread, more
    /// than once.
    pub fn shutdown(self: Connection) void {
        self.vtable.shutdown(self.context);
    }

    /// Frees the connection, once no thread uses it.
    pub fn close(self: Connection) void {
        self.vtable.close(self.context);
    }
};

pub const Listener = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        accept: *const fn (context: *anyopaque) (Error || error{ListenerShutDown})!Connection,
        address: *const fn (context: *anyopaque, buffer: *[max_address_bytes]u8) []const u8,
        shutdown: *const fn (context: *anyopaque) void,
        close: *const fn (context: *anyopaque) void,
    };

    /// Waits for the next connection. Fails with `ListenerShutDown` once
    /// `shutdown` is called.
    pub fn accept(self: Listener) (Error || error{ListenerShutDown})!Connection {
        return self.vtable.accept(self.context);
    }

    /// Where it listens, as `connect` takes it (the port chosen, if it
    /// was asked to choose one).
    pub fn address(self: Listener, buffer: *[max_address_bytes]u8) []const u8 {
        return self.vtable.address(self.context, buffer);
    }

    /// Makes an `accept`, blocked in another thread or to come, fail.
    /// Callable from any thread, more than once.
    pub fn shutdown(self: Listener) void {
        self.vtable.shutdown(self.context);
    }

    /// Frees the listener, once no thread uses it.
    pub fn close(self: Listener) void {
        self.vtable.close(self.context);
    }
};

pub const Network = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listen: *const fn (context: *anyopaque, address: []const u8) Error!Listener,
        connect: *const fn (context: *anyopaque, address: []const u8) Error!Connection,
    };

    /// Listens at `address`, "host:port" (port 0: one free).
    pub fn listen(self: Network, address: []const u8) Error!Listener {
        return self.vtable.listen(self.context, address);
    }

    /// Connects to the listener at `address`, "host:port".
    pub fn connect(self: Network, address: []const u8) Error!Connection {
        return self.vtable.connect(self.context, address);
    }
};

/// TCP, through `io` (a multithreaded `std.Io`: connections are used from
/// threads of their own).
pub const Tcp = struct {
    io: Io,
    allocator: Allocator,
    /// A read that waits longer fails; null waits forever.
    read_timeout_ns: ?u64 = null,

    const write_buffer_bytes = 64 << 10;

    pub fn network(self: *Tcp) Network {
        return .{ .context = self, .vtable = &.{ .listen = listen, .connect = connect } };
    }

    fn listen(context: *anyopaque, address: []const u8) Error!Listener {
        const self: *Tcp = @ptrCast(@alignCast(context));
        const ip = try self.resolve(address);
        const listener = self.allocator.create(TcpListener) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(listener);
        listener.* = .{
            .tcp = self,
            .server = ip.listen(self.io, .{ .reuse_address = true }) catch return error.NetworkFailed,
        };
        return listener.listener();
    }

    fn connect(context: *anyopaque, address: []const u8) Error!Connection {
        const self: *Tcp = @ptrCast(@alignCast(context));
        const ip = try self.resolve(address);
        const stream = ip.connect(self.io, .{ .mode = .stream }) catch return error.NetworkFailed;
        errdefer stream.close(self.io);
        return self.connection(stream);
    }

    fn connection(self: *Tcp, stream: Io.net.Stream) Error!Connection {
        const opened = self.allocator.create(TcpConnection) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(opened);
        const read_buffer = self.allocator.alloc(u8, protocol.max_frame_bytes) catch return error.OutOfMemory;
        errdefer self.allocator.free(read_buffer);
        const write_buffer = self.allocator.alloc(u8, write_buffer_bytes) catch return error.OutOfMemory;
        opened.* = .{
            .tcp = self,
            .stream = stream,
            .reader = .{ .vtable = &.{ .stream = TcpConnection.streamRead, .readVec = TcpConnection.readVec }, .buffer = read_buffer, .seek = 0, .end = 0 },
            .writer = stream.writer(self.io, write_buffer),
        };
        return opened.connection();
    }

    fn resolve(self: *Tcp, address: []const u8) Error!Io.net.IpAddress {
        const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.NetworkFailed;
        const port = std.fmt.parseInt(u16, address[colon + 1 ..], 10) catch return error.NetworkFailed;
        const host = std.mem.trim(u8, address[0..colon], "[]");
        return Io.net.IpAddress.parse(host, port) catch
            Io.net.IpAddress.resolve(self.io, host, port) catch error.NetworkFailed;
    }
};

const TcpListener = struct {
    tcp: *Tcp,
    server: Io.net.Server,
    shut_down: std.atomic.Value(bool) = .init(false),

    fn listener(self: *TcpListener) Listener {
        return .{ .context = self, .vtable = &.{ .accept = accept, .address = address, .shutdown = shutdown, .close = close } };
    }

    fn accept(context: *anyopaque) (Error || error{ListenerShutDown})!Connection {
        const self: *TcpListener = @ptrCast(@alignCast(context));
        while (true) {
            if (self.shut_down.load(.acquire)) return error.ListenerShutDown;
            const stream = self.server.accept(self.tcp.io) catch |err| switch (err) {
                // The one who connected gave up already.
                error.ConnectionAborted => continue,
                else => return if (self.shut_down.load(.acquire)) error.ListenerShutDown else error.NetworkFailed,
            };
            if (self.shut_down.load(.acquire)) {
                stream.close(self.tcp.io);
                return error.ListenerShutDown;
            }
            errdefer stream.close(self.tcp.io);
            return self.tcp.connection(stream);
        }
    }

    fn address(context: *anyopaque, buffer: *[max_address_bytes]u8) []const u8 {
        const self: *TcpListener = @ptrCast(@alignCast(context));
        return std.fmt.bufPrint(buffer, "{f}", .{self.server.socket.address}) catch unreachable;
    }

    /// Not every system wakes an `accept` when its socket is shut down:
    /// a connection of its own wakes it.
    fn shutdown(context: *anyopaque) void {
        const self: *TcpListener = @ptrCast(@alignCast(context));
        if (self.shut_down.swap(true, .acq_rel)) return;
        const to = reachable(self.server.socket.address);
        const stream = to.connect(self.tcp.io, .{ .mode = .stream }) catch return;
        stream.close(self.tcp.io);
    }

    fn close(context: *anyopaque) void {
        const self: *TcpListener = @ptrCast(@alignCast(context));
        self.server.deinit(self.tcp.io);
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
    stream: Io.net.Stream,
    reader: Reader,
    writer: Io.net.Stream.Writer,
    shut_down: std.atomic.Value(bool) = .init(false),

    fn connection(self: *TcpConnection) Connection {
        return .{ .context = self, .vtable = &.{ .reader = readerOf, .writer = writerOf, .shutdown = shutdown, .close = close } };
    }

    fn readerOf(context: *anyopaque) *Reader {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        return &self.reader;
    }

    fn writerOf(context: *anyopaque) *Writer {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        return &self.writer.interface;
    }

    fn shutdown(context: *anyopaque) void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        if (self.shut_down.swap(true, .acq_rel)) return;
        self.stream.shutdown(self.tcp.io, .both) catch {};
    }

    fn close(context: *anyopaque) void {
        const self: *TcpConnection = @ptrCast(@alignCast(context));
        self.stream.close(self.tcp.io);
        self.tcp.allocator.free(self.reader.buffer);
        self.tcp.allocator.free(self.writer.interface.buffer);
        self.tcp.allocator.destroy(self);
    }

    fn streamRead(reader: *Reader, writer: *Writer, limit: Io.Limit) Reader.StreamError!usize {
        const destination = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{destination};
        const length = try readVec(reader, &data);
        writer.advance(length);
        return length;
    }

    /// Reads what came, waiting at most the network's read timeout.
    fn readVec(reader: *Reader, data: [][]u8) Reader.Error!usize {
        const self: *TcpConnection = @alignCast(@fieldParentPtr("reader", reader));
        var vectors_buffer: [8][]u8 = undefined;
        const vector_count, const data_size = try reader.writableVector(&vectors_buffer, data);
        const timeout: Io.Timeout = if (self.tcp.read_timeout_ns) |ns| .{ .duration = .{ .raw = .fromNanoseconds(ns), .clock = .awake } } else .none;
        const result = self.tcp.io.operateTimeout(.{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = vectors_buffer[0..vector_count] } }, timeout) catch return error.ReadFailed;
        const read = result.net_read catch return error.ReadFailed;
        if (read.data_len == 0) return error.EndOfStream;
        if (read.data_len > data_size) {
            reader.end += read.data_len - data_size;
            return data_size;
        }
        return read.data_len;
    }
};
