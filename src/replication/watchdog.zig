//! Ends a connection that went quiet: a thread that shuts it down when
//! nothing was read from it or written to it within a timeout, measured on
//! the replication `Clock` (the network has no timeouts of its own, so a
//! simulation controls them too). Whoever uses the connection feeds it.
//!
//! TEMPORARY, with the thread per connection it needs: an event-driven
//! design checks the deadlines in its loop.

const std = @import("std");
const Writer = std.Io.Writer;

const Clock = @import("clock.zig").Clock;
const Signal = @import("clock.zig").Signal;
const Connection = @import("network.zig").Connection;

pub const Watchdog = struct {
    clock: Clock,
    connection: Connection,
    timeout_ns: u64,
    /// How many times it was fed, raised by each feeding.
    feedings: Signal = .{},
    /// The time allowed until the next feeding.
    allowed_ns: std.atomic.Value(u64) = .init(0),
    thread: ?std.Thread = null,

    /// Starts watching the connection; `self` must stay in place until
    /// `stop`.
    pub fn start(self: *Watchdog) std.Thread.SpawnError!void {
        self.allowed_ns.store(self.timeout_ns, .release);
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    /// Something was read or written: the next must come within the
    /// timeout.
    pub fn fed(self: *Watchdog) void {
        self.allow(self.timeout_ns);
    }

    /// Something that takes long starts (making or loading a copy): the
    /// next feeding must come within `ns`.
    pub fn allow(self: *Watchdog, ns: u64) void {
        self.allowed_ns.store(ns, .release);
        self.clock.raise(&self.feedings, self.feedings.value + 1);
    }

    pub fn stop(self: *Watchdog) void {
        self.clock.stop(&self.feedings);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn watch(self: *Watchdog) void {
        var seen: u64 = 0;
        while (true) {
            const deadline = self.clock.now() + self.allowed_ns.load(.acquire);
            const feedings = self.clock.wait(&self.feedings, seen, deadline) orelse return;
            if (feedings == seen) break;
            seen = feedings;
        }
        self.connection.shutdown();
    }

    /// A writer to `inner` that feeds the watchdog each time a write to
    /// it goes through, for long sends (a copy).
    pub fn feedingWriter(self: *Watchdog, inner: *Writer) FeedingWriter {
        return .{ .watchdog = self, .inner = inner, .interface = .{ .vtable = &.{ .drain = FeedingWriter.drain }, .buffer = &.{} } };
    }
};

pub const FeedingWriter = struct {
    watchdog: *Watchdog,
    inner: *Writer,
    interface: Writer,

    fn drain(writer: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *FeedingWriter = @alignCast(@fieldParentPtr("interface", writer));
        const written = try self.inner.writeSplat(data, splat);
        self.watchdog.fed();
        return written;
    }
};
