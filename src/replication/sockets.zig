//! TCP sockets that never block, and `poll` to wait on them: the
//! operating system's own calls (libc on POSIX, Winsock on Windows), the
//! few the replication network needs. Not `std.Io`: on Windows its sockets
//! are AFD handles that `WSAPoll` does not take.

const std = @import("std");
const builtin = @import("builtin");
const IpAddress = std.Io.net.IpAddress;

const is_windows = builtin.os.tag == .windows;
const c = std.c;

pub const Error = error{NetworkFailed};

/// A socket the system gave out.
pub const Handle = if (is_windows) usize else c.fd_t;

/// One socket `poll` watches: what it is to wait for (`events`), and what
/// came (`revents`).
pub const PollEntry = if (is_windows) extern struct { handle: Handle, events: i16, revents: i16 } else c.pollfd;

pub const poll_readable: i16 = if (is_windows) winsock.POLLRDNORM else c.POLL.IN;
pub const poll_writable: i16 = if (is_windows) winsock.POLLWRNORM else c.POLL.OUT;
/// Failed or hung up: a read or a write tells which.
pub const poll_failed: i16 = if (is_windows)
    winsock.POLLERR | winsock.POLLHUP | winsock.POLLNVAL
else
    c.POLL.ERR | c.POLL.HUP | c.POLL.NVAL;

pub fn pollEntry(handle: Handle, events: i16) PollEntry {
    return if (is_windows) .{ .handle = handle, .events = events, .revents = 0 } else .{ .fd = handle, .events = events, .revents = 0 };
}

/// Waits until a socket of `entries` is ready or `timeout_ms` passes (-1:
/// no limit); the number of entries ready.
pub fn poll(entries: []PollEntry, timeout_ms: i32) Error!usize {
    while (true) {
        const result = if (is_windows)
            winsock.WSAPoll(entries.ptr, @intCast(entries.len), timeout_ms)
        else
            c.poll(entries.ptr, @intCast(entries.len), timeout_ms);
        if (result >= 0) return @intCast(result);
        if (lastFault() == .interrupted) continue;
        return error.NetworkFailed;
    }
}

/// A TCP socket for `family`'s addresses, not blocking.
pub fn open(address: *const IpAddress) Error!Handle {
    try started();
    const family: c_int = switch (address.*) {
        .ip4 => if (is_windows) winsock.AF_INET else c.AF.INET,
        .ip6 => if (is_windows) winsock.AF_INET6 else c.AF.INET6,
    };
    if (is_windows) {
        const handle = winsock.socket(family, winsock.SOCK_STREAM, winsock.IPPROTO_TCP);
        if (handle == winsock.INVALID_SOCKET) return error.NetworkFailed;
        errdefer close(handle);
        try notBlocking(handle);
        return handle;
    }
    const handle = c.socket(@intCast(family), c.SOCK.STREAM, 0);
    if (handle < 0) return error.NetworkFailed;
    errdefer close(handle);
    try notBlocking(handle);
    return handle;
}

pub fn close(handle: Handle) void {
    if (is_windows) _ = winsock.closesocket(handle) else _ = c.close(handle);
}

/// So a master restarted at once can listen at its address again.
pub fn reuseAddress(handle: Handle) Error!void {
    if (is_windows) return; // Windows' SO_REUSEADDR lets two listen at one port.
    try setOption(handle, c.SOL.SOCKET, c.SO.REUSEADDR, 1);
}

/// Small frames (acks, heartbeats) go out at once, not held for more.
pub fn noDelay(handle: Handle) Error!void {
    if (is_windows) return setOption(handle, winsock.IPPROTO_TCP, winsock.TCP_NODELAY, 1);
    try setOption(handle, c.IPPROTO.TCP, c.TCP.NODELAY, 1);
}

pub fn bind(handle: Handle, address: *const IpAddress) Error!void {
    var system_address: SystemAddress = .from(address);
    const result = if (is_windows)
        winsock.bind(handle, &system_address.bytes, system_address.length)
    else
        c.bind(handle, @ptrCast(&system_address.bytes), system_address.length);
    if (result != 0) return error.NetworkFailed;
}

pub fn listen(handle: Handle) Error!void {
    const backlog = 128;
    const result = if (is_windows) winsock.listen(handle, backlog) else c.listen(handle, backlog);
    if (result != 0) return error.NetworkFailed;
}

/// Where `handle` is bound (the port the system chose, if asked to).
pub fn localAddress(handle: Handle) Error!IpAddress {
    var system_address: SystemAddress = .{ .bytes = undefined, .length = @sizeOf(SystemAddress.Storage) };
    const result = if (is_windows)
        winsock.getsockname(handle, &system_address.bytes, &system_address.length)
    else
        c.getsockname(handle, @ptrCast(&system_address.bytes), &system_address.length);
    if (result != 0) return error.NetworkFailed;
    return system_address.to();
}

/// The next connection waiting on a listening `handle`, not blocking;
/// null if none waits.
pub fn accept(handle: Handle) Error!?Handle {
    while (true) {
        if (is_windows) {
            const accepted = winsock.accept(handle, null, null);
            if (accepted != winsock.INVALID_SOCKET) return try opened(accepted);
        } else {
            const accepted = c.accept(handle, null, null);
            if (accepted >= 0) return try opened(accepted);
        }
        switch (lastFault()) {
            .interrupted => continue,
            // The one who connected gave up already.
            .would_block, .aborted => return null,
            else => return error.NetworkFailed,
        }
    }
}

fn opened(accepted: Handle) Error!Handle {
    errdefer close(accepted);
    try notBlocking(accepted);
    try noDelay(accepted);
    return accepted;
}

/// Starts connecting `handle` to `address`; `connectFailed` tells, once
/// `poll` says it is writable, whether it failed.
pub fn connect(handle: Handle, address: *const IpAddress) Error!void {
    var system_address: SystemAddress = .from(address);
    while (true) {
        const result = if (is_windows)
            winsock.connect(handle, &system_address.bytes, system_address.length)
        else
            c.connect(handle, @ptrCast(&system_address.bytes), system_address.length);
        if (result == 0) return;
        switch (lastFault()) {
            .interrupted => continue,
            .would_block, .in_progress => return,
            else => return error.NetworkFailed,
        }
    }
}

/// Whether the connecting of `handle` failed.
pub fn connectFailed(handle: Handle) bool {
    var value: c_int = 0;
    if (is_windows) {
        var length: c_int = @sizeOf(c_int);
        if (winsock.getsockopt(handle, winsock.SOL_SOCKET, winsock.SO_ERROR, @ptrCast(&value), &length) != 0) return true;
    } else {
        var length: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(handle, c.SOL.SOCKET, c.SO.ERROR, &value, &length) != 0) return true;
    }
    return value != 0;
}

/// Bytes received into `buffer`, not blocking: how many (never 0).
pub fn receive(handle: Handle, buffer: []u8) error{ WouldBlock, Closed }!usize {
    const length = @min(buffer.len, std.math.maxInt(i32));
    while (true) {
        const result: isize = if (is_windows)
            winsock.recv(handle, buffer.ptr, @intCast(length), 0)
        else
            c.recv(handle, buffer.ptr, length, 0);
        if (result > 0) return @intCast(result);
        if (result == 0) return error.Closed;
        switch (lastFault()) {
            .interrupted => continue,
            .would_block => return error.WouldBlock,
            else => return error.Closed,
        }
    }
}

/// Bytes of `bytes` sent, not blocking: how many (never 0).
pub fn send(handle: Handle, bytes: []const u8) error{ WouldBlock, Closed }!usize {
    const length = @min(bytes.len, std.math.maxInt(i32));
    while (true) {
        const result: isize = if (is_windows)
            winsock.send(handle, bytes.ptr, @intCast(length), 0)
        else
            c.send(handle, bytes.ptr, length, c.MSG.NOSIGNAL);
        if (result > 0) return @intCast(result);
        switch (lastFault()) {
            .interrupted => continue,
            .would_block => return error.WouldBlock,
            else => return error.Closed,
        }
    }
}

/// Two ends of a channel to wake a `poll`: what is sent to `ends[1]`
/// makes `ends[0]` readable. A pipe on POSIX; Windows polls only sockets,
/// so there a connection to itself on the loopback.
pub fn wakeupPair() Error![2]Handle {
    if (!is_windows) {
        var ends: [2]c.fd_t = undefined;
        if (c.pipe(&ends) != 0) return error.NetworkFailed;
        errdefer for (ends) |end| close(end);
        for (ends) |end| try notBlocking(end);
        return ends;
    }
    const loopback: IpAddress = .{ .ip4 = .loopback(0) };
    const listener = try open(&loopback);
    defer close(listener);
    try bind(listener, &loopback);
    try listen(listener);
    const listened = try localAddress(listener);
    const sender = try open(&listened);
    errdefer close(sender);
    try connect(sender, &listened);
    var entries = [_]PollEntry{pollEntry(listener, poll_readable)};
    if (try poll(&entries, 5_000) == 0) return error.NetworkFailed;
    const receiver = try accept(listener) orelse return error.NetworkFailed;
    return .{ receiver, sender };
}

/// Makes the read end readable (once is enough: a full channel already is).
pub fn wakeupSend(end: Handle) void {
    const byte = [1]u8{1};
    if (is_windows) _ = send(end, &byte) catch {} else _ = c.write(end, &byte, 1);
}

/// Empties the read end.
pub fn wakeupDrain(end: Handle) void {
    var buffer: [64]u8 = undefined;
    if (is_windows) {
        while (receive(end, &buffer)) |_| {} else |_| {}
    } else {
        while (c.read(end, &buffer, buffer.len) > 0) {}
    }
}

fn notBlocking(handle: Handle) Error!void {
    if (is_windows) {
        var on: u32 = 1;
        if (winsock.ioctlsocket(handle, winsock.FIONBIO, &on) != 0) return error.NetworkFailed;
        return;
    }
    const flags = c.fcntl(handle, c.F.GETFL);
    if (flags < 0) return error.NetworkFailed;
    const nonblocking: c_int = 1 << @bitOffsetOf(c.O, "NONBLOCK");
    if (c.fcntl(handle, c.F.SETFL, flags | nonblocking) < 0) return error.NetworkFailed;
    if (c.fcntl(handle, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.NetworkFailed;
}

fn setOption(handle: Handle, level: i32, option: u32, value: c_int) Error!void {
    const result = if (is_windows)
        winsock.setsockopt(handle, level, @intCast(option), @ptrCast(&value), @sizeOf(c_int))
    else
        c.setsockopt(handle, level, option, &value, @sizeOf(c_int));
    if (result != 0) return error.NetworkFailed;
}

const Fault = enum { interrupted, would_block, in_progress, aborted, other };

/// Why the last call on this thread failed.
fn lastFault() Fault {
    if (is_windows) return switch (winsock.WSAGetLastError()) {
        winsock.WSAEINTR => .interrupted,
        winsock.WSAEWOULDBLOCK => .would_block,
        winsock.WSAEINPROGRESS => .in_progress,
        winsock.WSAECONNABORTED => .aborted,
        else => .other,
    };
    return switch (c.errno(@as(c_int, -1))) {
        .INTR => .interrupted,
        .AGAIN => .would_block,
        .INPROGRESS => .in_progress,
        .CONNABORTED => .aborted,
        else => .other,
    };
}

/// An address as the system's calls take it (`sockaddr_in`/`sockaddr_in6`).
const SystemAddress = struct {
    bytes: Storage align(8),
    length: Length,

    const Storage = [128]u8;
    const Length = if (is_windows) c_int else c.socklen_t;
    const af_inet: u16 = if (is_windows) winsock.AF_INET else c.AF.INET;
    const af_inet6: u16 = if (is_windows) winsock.AF_INET6 else c.AF.INET6;
    /// BSD systems lead with a length byte and a one-byte family.
    const has_length_byte = builtin.os.tag.isDarwin() or builtin.os.tag.isBSD();

    fn from(address: *const IpAddress) SystemAddress {
        var result: SystemAddress = .{ .bytes = @splat(0), .length = 0 };
        switch (address.*) {
            .ip4 => |ip| {
                result.length = 16;
                result.putFamily(af_inet, 16);
                std.mem.writeInt(u16, result.bytes[2..4], ip.port, .big);
                @memcpy(result.bytes[4..8], &ip.bytes);
            },
            .ip6 => |ip| {
                result.length = 28;
                result.putFamily(af_inet6, 28);
                std.mem.writeInt(u16, result.bytes[2..4], ip.port, .big);
                std.mem.writeInt(u32, result.bytes[4..8], ip.flow, .big);
                @memcpy(result.bytes[8..24], &ip.bytes);
                std.mem.writeInt(u32, result.bytes[24..28], ip.interface.index, .little);
            },
        }
        return result;
    }

    fn putFamily(self: *SystemAddress, family: u16, length: u8) void {
        if (has_length_byte) {
            self.bytes[0] = length;
            self.bytes[1] = @intCast(family);
        } else {
            std.mem.writeInt(u16, self.bytes[0..2], family, builtin.cpu.arch.endian());
        }
    }

    fn to(self: *const SystemAddress) Error!IpAddress {
        const family: u16 = if (has_length_byte) self.bytes[1] else std.mem.readInt(u16, self.bytes[0..2], builtin.cpu.arch.endian());
        const port = std.mem.readInt(u16, self.bytes[2..4], .big);
        if (family == af_inet) return .{ .ip4 = .{ .bytes = self.bytes[4..8].*, .port = port } };
        if (family == af_inet6) return .{ .ip6 = .{
            .port = port,
            .bytes = self.bytes[8..24].*,
            .flow = std.mem.readInt(u32, self.bytes[4..8], .big),
            .interface = .{ .index = std.mem.readInt(u32, self.bytes[24..28], .little) },
        } };
        return error.NetworkFailed;
    }
};

var winsock_started: std.atomic.Value(bool) = .init(false);

/// Winsock needs `WSAStartup` before its first socket.
fn started() Error!void {
    if (!is_windows or winsock_started.load(.acquire)) return;
    var data: winsock.WSADATA = undefined;
    if (winsock.WSAStartup(0x0202, &data) != 0) return error.NetworkFailed;
    winsock_started.store(true, .release);
}

/// The Winsock calls and constants used, declared here: `std` has none.
const winsock = struct {
    const SOCKET = usize;
    const INVALID_SOCKET: SOCKET = std.math.maxInt(usize);
    const AF_INET = 2;
    const AF_INET6 = 23;
    const SOCK_STREAM = 1;
    const IPPROTO_TCP = 6;
    const TCP_NODELAY = 1;
    const SOL_SOCKET = 0xffff;
    const SO_ERROR = 0x1007;
    const FIONBIO: i32 = @bitCast(@as(u32, 0x8004667e));
    const POLLRDNORM: i16 = 0x0100;
    const POLLWRNORM: i16 = 0x0010;
    const POLLERR: i16 = 0x0001;
    const POLLHUP: i16 = 0x0002;
    const POLLNVAL: i16 = 0x0004;
    const WSAEINTR = 10004;
    const WSAEWOULDBLOCK = 10035;
    const WSAEINPROGRESS = 10036;
    const WSAECONNABORTED = 10053;

    const WSADATA = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        // The 64-bit layout (iMaxSockets and lpVendorInfo before the descriptions).
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?[*]u8,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
    };

    extern "ws2_32" fn WSAStartup(version: u16, data: *WSADATA) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
    extern "ws2_32" fn WSAPoll(entries: [*]PollEntry, count: u32, timeout_ms: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn closesocket(socket: SOCKET) callconv(.winapi) c_int;
    extern "ws2_32" fn ioctlsocket(socket: SOCKET, command: i32, argument: *u32) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(socket: SOCKET, level: c_int, option: c_int, value: [*]const u8, length: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockopt(socket: SOCKET, level: c_int, option: c_int, value: [*]u8, length: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn bind(socket: SOCKET, address: *const anyopaque, length: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(socket: SOCKET, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(socket: SOCKET, address: *anyopaque, length: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(socket: SOCKET, address: ?*anyopaque, length: ?*c_int) callconv(.winapi) SOCKET;
    extern "ws2_32" fn connect(socket: SOCKET, address: *const anyopaque, length: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(socket: SOCKET, buffer: [*]u8, length: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(socket: SOCKET, buffer: [*]const u8, length: c_int, flags: c_int) callconv(.winapi) c_int;
};
