//! The six temporal types of openCypher, as regular values: each has a
//! total order consistent with its equality, a hash, and its ISO 8601 text.
//!
//! | Type            | Holds                                          |
//! | --------------- | ---------------------------------------------- |
//! | `Date`          | a day                                          |
//! | `LocalTime`     | a time of day                                  |
//! | `Time`          | a time of day at a UTC offset                  |
//! | `LocalDateTime` | a day and a time of day                        |
//! | `DateTime`      | an instant, with the offset and zone to show it in |
//! | `Duration`      | months, days, seconds and nanoseconds          |
//!
//! Precision is the nanosecond; years range over ±999,999,999.

const std = @import("std");
const Order = std.math.Order;
const Writer = std.Io.Writer;
const calendar = @import("calendar.zig");
const zones = @import("zones.zig");

const nanoseconds_per_second = calendar.nanoseconds_per_second;
const seconds_per_day = calendar.seconds_per_day;

/// Any temporal value in parts: the wall-clock day and time of day, and the
/// zone (an offset, with the name of the zone that gave it, if any); each
/// present or not. The common form construction, truncation and `between`
/// work on.
pub const Parts = struct {
    days: ?i64 = null,
    nanoseconds: ?i64 = null,
    offset: ?i32 = null,
    zone: []const u8 = "",

    pub fn hasZone(self: Parts) bool {
        return self.offset != null or self.zone.len > 0;
    }
};

pub const Date = struct {
    /// Days since 1970-01-01.
    days: i64,

    pub fn order(a: Date, b: Date) Order {
        return std.math.order(a.days, b.days);
    }

    pub fn format(self: Date, writer: *Writer) Writer.Error!void {
        const civil = calendar.civilFromDays(self.days);
        try writeYear(writer, civil.year);
        try writer.print("-{d:0>2}-{d:0>2}", .{ civil.month, civil.day });
    }
};

pub const LocalTime = struct {
    /// Nanoseconds since midnight, in [0, 86400 s).
    nanoseconds: i64,

    pub fn order(a: LocalTime, b: LocalTime) Order {
        return std.math.order(a.nanoseconds, b.nanoseconds);
    }

    pub fn format(self: LocalTime, writer: *Writer) Writer.Error!void {
        try writeTimeOfDay(writer, self.nanoseconds);
    }
};

pub const Time = struct {
    /// Local nanoseconds since midnight, in [0, 86400 s).
    nanoseconds: i64,
    /// Seconds east of UTC.
    offset: i32,

    /// Nanoseconds since midnight UTC (may fall outside one day).
    pub fn utcNanoseconds(self: Time) i64 {
        return self.nanoseconds - @as(i64, self.offset) * nanoseconds_per_second;
    }

    /// By the instant, then by offset (so equal values are identical).
    pub fn order(a: Time, b: Time) Order {
        const by_instant = std.math.order(a.utcNanoseconds(), b.utcNanoseconds());
        if (by_instant != .eq) return by_instant;
        return std.math.order(a.offset, b.offset);
    }

    pub fn format(self: Time, writer: *Writer) Writer.Error!void {
        try writeTimeOfDay(writer, self.nanoseconds);
        try zones.formatOffset(writer, self.offset);
    }
};

pub const LocalDateTime = struct {
    /// Seconds since 1970-01-01T00:00 (local time).
    seconds: i64,
    /// Nanoseconds of the second, in [0, 1e9).
    nanoseconds: u32,

    pub fn init(day: Date, time_of_day: LocalTime) LocalDateTime {
        return .{
            .seconds = day.days * seconds_per_day + @divFloor(time_of_day.nanoseconds, nanoseconds_per_second),
            .nanoseconds = @intCast(@mod(time_of_day.nanoseconds, nanoseconds_per_second)),
        };
    }

    pub fn date(self: LocalDateTime) Date {
        return .{ .days = @divFloor(self.seconds, seconds_per_day) };
    }

    pub fn time(self: LocalDateTime) LocalTime {
        return .{ .nanoseconds = @mod(self.seconds, seconds_per_day) * nanoseconds_per_second + self.nanoseconds };
    }

    pub fn order(a: LocalDateTime, b: LocalDateTime) Order {
        const by_seconds = std.math.order(a.seconds, b.seconds);
        if (by_seconds != .eq) return by_seconds;
        return std.math.order(a.nanoseconds, b.nanoseconds);
    }

    pub fn format(self: LocalDateTime, writer: *Writer) Writer.Error!void {
        try self.date().format(writer);
        try writer.writeByte('T');
        try self.time().format(writer);
    }
};

pub const DateTime = struct {
    /// Seconds since 1970-01-01T00:00Z: the instant.
    seconds: i64,
    /// Nanoseconds of the second, in [0, 1e9).
    nanoseconds: u32,
    /// Seconds east of UTC at this instant.
    offset: i32,
    /// The IANA zone (`Europe/Stockholm`), or empty for a fixed offset.
    zone: []const u8,

    /// The wall-clock date and time at this instant.
    pub fn local(self: DateTime) LocalDateTime {
        return .{ .seconds = self.seconds + self.offset, .nanoseconds = self.nanoseconds };
    }

    /// By the instant, then offset, then zone name.
    pub fn order(a: DateTime, b: DateTime) Order {
        const by_instant = a.instantOrder(b);
        if (by_instant != .eq) return by_instant;
        const by_offset = std.math.order(a.offset, b.offset);
        if (by_offset != .eq) return by_offset;
        return std.mem.order(u8, a.zone, b.zone);
    }

    pub fn instantOrder(a: DateTime, b: DateTime) Order {
        const by_seconds = std.math.order(a.seconds, b.seconds);
        if (by_seconds != .eq) return by_seconds;
        return std.math.order(a.nanoseconds, b.nanoseconds);
    }

    pub fn format(self: DateTime, writer: *Writer) Writer.Error!void {
        try self.local().format(writer);
        try zones.formatOffset(writer, self.offset);
        if (self.zone.len > 0) try writer.print("[{s}]", .{self.zone});
    }
};

pub const Duration = struct {
    months: i64,
    days: i64,
    /// Whole seconds, rounded down (so `nanoseconds` is never negative).
    seconds: i64,
    /// In [0, 1e9).
    nanoseconds: u32,

    pub const zero = Duration{ .months = 0, .days = 0, .seconds = 0, .nanoseconds = 0 };

    /// A duration whose time part is `total_nanoseconds` (any sign).
    pub fn init(months: i64, days: i64, total_nanoseconds: i128) Duration {
        return .{
            .months = months,
            .days = days,
            .seconds = @intCast(@divFloor(total_nanoseconds, nanoseconds_per_second)),
            .nanoseconds = @intCast(@mod(total_nanoseconds, nanoseconds_per_second)),
        };
    }

    /// The time part, in nanoseconds.
    pub fn totalNanoseconds(self: Duration) i128 {
        return @as(i128, self.seconds) * nanoseconds_per_second + self.nanoseconds;
    }

    pub fn negate(self: Duration) Duration {
        return init(-self.months, -self.days, -self.totalNanoseconds());
    }

    /// Component by component (durations have no natural order: a month
    /// is not a fixed number of days).
    pub fn order(a: Duration, b: Duration) Order {
        inline for (.{ "months", "days", "seconds", "nanoseconds" }) |field| {
            const by_field = std.math.order(@field(a, field), @field(b, field));
            if (by_field != .eq) return by_field;
        }
        return .eq;
    }

    /// `P1Y2M3DT4H5M6.5S`; each unit with its own sign (`PT-1M-0.5S`);
    /// `PT0S` when empty.
    pub fn format(self: Duration, writer: *Writer) Writer.Error!void {
        const time = self.totalNanoseconds();
        if (self.months == 0 and self.days == 0 and time == 0) return writer.writeAll("PT0S");
        try writer.writeByte('P');
        const years = @divTrunc(self.months, 12);
        const months = @rem(self.months, 12);
        if (years != 0) try writer.print("{d}Y", .{years});
        if (months != 0) try writer.print("{d}M", .{months});
        if (self.days != 0) try writer.print("{d}D", .{self.days});
        if (time == 0) return;
        try writer.writeByte('T');
        const nanoseconds_per_minute: i128 = 60 * nanoseconds_per_second;
        const hours = @divTrunc(time, 60 * nanoseconds_per_minute);
        const minutes = @divTrunc(@rem(time, 60 * nanoseconds_per_minute), nanoseconds_per_minute);
        const rest = @rem(time, nanoseconds_per_minute);
        if (hours != 0) try writer.print("{d}H", .{hours});
        if (minutes != 0) try writer.print("{d}M", .{minutes});
        if (rest != 0) {
            const magnitude: u128 = @abs(rest);
            if (rest < 0) try writer.writeByte('-');
            const per_second: u128 = nanoseconds_per_second;
            try writer.print("{d}", .{magnitude / per_second});
            try writeFraction(writer, @intCast(magnitude % per_second));
            try writer.writeByte('S');
        }
    }
};

/// Four digits for years 0-9999, else a sign and at least four digits.
fn writeYear(writer: *Writer, year: i64) Writer.Error!void {
    if (year >= 0 and year <= 9999) return writer.print("{d:0>4}", .{@as(u64, @intCast(year))});
    try writer.print("{c}{d:0>4}", .{ @as(u8, if (year < 0) '-' else '+'), @abs(year) });
}

/// `HH:MM`, then `:SS` when the seconds or their fraction are not zero.
fn writeTimeOfDay(writer: *Writer, nanoseconds: i64) Writer.Error!void {
    const seconds: u64 = @intCast(@divFloor(nanoseconds, nanoseconds_per_second));
    const fraction: u32 = @intCast(@mod(nanoseconds, nanoseconds_per_second));
    try writer.print("{d:0>2}:{d:0>2}", .{ seconds / 3600, seconds / 60 % 60 });
    if (seconds % 60 != 0 or fraction != 0) try writer.print(":{d:0>2}", .{seconds % 60});
    try writeFraction(writer, fraction);
}

/// The fraction of a second in as few digits as it needs (`.5`, `.000001`);
/// nothing for zero.
fn writeFraction(writer: *Writer, nanoseconds: u32) Writer.Error!void {
    if (nanoseconds == 0) return;
    var digits: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&digits, "{d:0>9}", .{nanoseconds}) catch unreachable;
    var length: usize = 9;
    while (digits[length - 1] == '0') length -= 1;
    try writer.print(".{s}", .{digits[0..length]});
}

test "formats" {
    var buffer: [128]u8 = undefined;
    var writer = Writer.fixed(&buffer);
    try (Date{ .days = calendar.daysFromCivil(28, 11, 11) }).format(&writer);
    try writer.writeByte(' ');
    try (LocalTime{ .nanoseconds = (12 * 3600 + 31 * 60 + 14) * nanoseconds_per_second + 645_000_000 }).format(&writer);
    try writer.writeByte(' ');
    try (Duration.init(149, 14, (16 * 3600 + 13 * 60 + 10) * @as(i128, nanoseconds_per_second) + 1)).format(&writer);
    try writer.writeByte(' ');
    try (Duration.init(0, 0, -(60 * @as(i128, nanoseconds_per_second) + 1_000_000))).format(&writer);
    try std.testing.expectEqualStrings("0028-11-11 12:31:14.645 P12Y5M14DT16H13M10.000000001S PT-1M-0.001S", writer.buffered());
}
