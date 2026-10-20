//! Duration arithmetic: building a duration from units (some fractional),
//! scaling it, adding it to the other temporal types, and the duration
//! between two temporal values.
//!
//! A duration has three independent parts, months, days and a time (seconds
//! with nanoseconds), because their lengths are not fixed relative to each
//! other: a month has 28 to 31 days, a day 23 to 25 hours across a daylight
//! saving change. A fraction of a unit moves down to the next part: half a
//! month is half an average Gregorian month (2,629,746 s) of days and time,
//! half a day twelve hours.

const std = @import("std");
const calendar = @import("calendar.zig");
const zones = @import("zones.zig");
const types = @import("types.zig");

const Date = types.Date;
const LocalTime = types.LocalTime;
const Time = types.Time;
const LocalDateTime = types.LocalDateTime;
const DateTime = types.DateTime;
const Duration = types.Duration;

const nanoseconds_per_second: i128 = calendar.nanoseconds_per_second;
const nanoseconds_per_day: i128 = calendar.nanoseconds_per_day;
const seconds_per_average_month: i128 = 2_629_746;

pub const Error = error{Overflow};

/// An integer or float amount of a unit.
pub const Number = union(enum) { int: i64, float: f64 };

pub const Unit = enum {
    years,
    quarters,
    months,
    weeks,
    days,
    hours,
    minutes,
    seconds,
    milliseconds,
    microseconds,
    nanoseconds,

    const Part = enum { months, days, time };

    /// Which part of a duration the unit counts, and how many of that
    /// part's units (months, days or nanoseconds) one of it is.
    fn scale(unit: Unit) struct { part: Part, factor: i64 } {
        return switch (unit) {
            .years => .{ .part = .months, .factor = 12 },
            .quarters => .{ .part = .months, .factor = 3 },
            .months => .{ .part = .months, .factor = 1 },
            .weeks => .{ .part = .days, .factor = 7 },
            .days => .{ .part = .days, .factor = 1 },
            .hours => .{ .part = .time, .factor = 3600 * calendar.nanoseconds_per_second },
            .minutes => .{ .part = .time, .factor = 60 * calendar.nanoseconds_per_second },
            .seconds => .{ .part = .time, .factor = calendar.nanoseconds_per_second },
            .milliseconds => .{ .part = .time, .factor = 1_000_000 },
            .microseconds => .{ .part = .time, .factor = 1_000 },
            .nanoseconds => .{ .part = .time, .factor = 1 },
        };
    }
};

/// Sums amounts of units into a duration: integers exactly, fractions
/// cascading to the smaller parts when `finish` is called.
pub const Builder = struct {
    months: i128 = 0,
    days: i128 = 0,
    nanoseconds: i128 = 0,
    fractional_months: f64 = 0,
    fractional_days: f64 = 0,
    fractional_nanoseconds: f64 = 0,

    pub fn add(self: *Builder, unit: Unit, amount: Number) Error!void {
        const scale = unit.scale();
        switch (amount) {
            .int => |n| {
                const value = @as(i128, n) * scale.factor;
                switch (scale.part) {
                    .months => self.months += value,
                    .days => self.days += value,
                    .time => self.nanoseconds += value,
                }
            },
            .float => |x| {
                if (!std.math.isFinite(x)) return error.Overflow;
                const value = x * @as(f64, @floatFromInt(scale.factor));
                switch (scale.part) {
                    .months => self.fractional_months += value,
                    .days => self.fractional_days += value,
                    .time => self.fractional_nanoseconds += value,
                }
            },
        }
    }

    pub fn finish(self: Builder) Error!Duration {
        var months = self.months;
        var days = self.days;
        var nanoseconds = self.nanoseconds;
        // A fraction of a month: whole days, and the rest as time.
        const whole_months = @trunc(self.fractional_months);
        months += try toInteger(whole_months);
        const month_rest = try toInteger(@trunc((self.fractional_months - whole_months) * @as(f64, @floatFromInt(seconds_per_average_month * nanoseconds_per_second))));
        days += @divTrunc(month_rest, nanoseconds_per_day);
        nanoseconds += @rem(month_rest, nanoseconds_per_day);
        // A fraction of a day: time.
        const whole_days = @trunc(self.fractional_days);
        days += try toInteger(whole_days);
        nanoseconds += try toInteger(@trunc((self.fractional_days - whole_days) * @as(f64, @floatFromInt(nanoseconds_per_day))));
        nanoseconds += try toInteger(@trunc(self.fractional_nanoseconds));
        return make(months, days, nanoseconds);
    }
};

fn toInteger(x: f64) Error!i128 {
    if (!std.math.isFinite(x) or @abs(x) > 1e36) return error.Overflow;
    return @intFromFloat(x);
}

fn make(months: i128, days: i128, nanoseconds: i128) Error!Duration {
    const seconds = @divFloor(nanoseconds, nanoseconds_per_second);
    if (months > std.math.maxInt(i64) or months < std.math.minInt(i64) or
        days > std.math.maxInt(i64) or days < std.math.minInt(i64) or
        seconds > std.math.maxInt(i64) or seconds < std.math.minInt(i64)) return error.Overflow;
    return Duration.init(@intCast(months), @intCast(days), nanoseconds);
}

pub fn add(a: Duration, b: Duration) Error!Duration {
    return make(@as(i128, a.months) + b.months, @as(i128, a.days) + b.days, a.totalNanoseconds() + b.totalNanoseconds());
}

pub fn subtract(a: Duration, b: Duration) Error!Duration {
    return add(a, b.negate());
}

/// `d * factor`: exact for an integer; for a float each part is scaled and
/// its fraction cascades down, as when building.
pub fn multiply(d: Duration, factor: Number) Error!Duration {
    switch (factor) {
        .int => |n| return make(@as(i128, d.months) * n, @as(i128, d.days) * n, d.totalNanoseconds() * n),
        .float => |x| {
            var builder = Builder{};
            try builder.add(.months, .{ .float = @as(f64, @floatFromInt(d.months)) * x });
            try builder.add(.days, .{ .float = @as(f64, @floatFromInt(d.days)) * x });
            builder.fractional_nanoseconds = @as(f64, @floatFromInt(d.totalNanoseconds())) * x;
            return builder.finish();
        },
    }
}

/// `d / divisor`, as multiplication by its inverse.
pub fn divide(d: Duration, divisor: Number) Error!Duration {
    const x: f64 = switch (divisor) {
        .int => |n| @floatFromInt(n),
        .float => |f| f,
    };
    if (x == 0) return error.Overflow;
    return multiply(d, .{ .float = 1.0 / x });
}

// --- Adding a duration to a temporal value -------------------------------------

/// Months, then days; the time part counts in whole days (toward zero).
pub fn addToDate(date: Date, d: Duration) Error!Date {
    const days = calendar.addMonths(date.days, d.months) + @as(i128, d.days) + @divTrunc(d.totalNanoseconds(), nanoseconds_per_day);
    return .{ .days = try checkedDays(days) };
}

/// The time part only, around the clock.
pub fn addToLocalTime(time: LocalTime, d: Duration) LocalTime {
    return .{ .nanoseconds = @intCast(@mod(time.nanoseconds + d.totalNanoseconds(), nanoseconds_per_day)) };
}

pub fn addToTime(time: Time, d: Duration) Time {
    return .{ .nanoseconds = addToLocalTime(.{ .nanoseconds = time.nanoseconds }, d).nanoseconds, .offset = time.offset };
}

/// Months and days on the date, then the time part.
pub fn addToLocalDateTime(value: LocalDateTime, d: Duration) Error!LocalDateTime {
    const day = calendar.addMonths(value.date().days, d.months) + @as(i128, d.days);
    const nanoseconds = (day * calendar.seconds_per_day + @mod(value.seconds, calendar.seconds_per_day)) * nanoseconds_per_second + value.nanoseconds + d.totalNanoseconds();
    return fromNanoseconds(nanoseconds);
}

/// Months and days on the wall-clock date, then the time part on the
/// instant (so a day across a daylight saving change is still a day, and
/// 24 hours are 24 hours).
pub fn addToDateTime(value: DateTime, d: Duration) (Error || zones.Error)!DateTime {
    const local = value.local();
    const day = calendar.addMonths(local.date().days, d.months) + @as(i128, d.days);
    const moved_local = try checkedSeconds(day * calendar.seconds_per_day + @mod(local.seconds, calendar.seconds_per_day));
    const moved = if (value.zone.len > 0) try zones.resolveLocal(value.zone, moved_local) else moved_local - value.offset;
    const instant = try fromNanoseconds(@as(i128, moved) * nanoseconds_per_second + value.nanoseconds + d.totalNanoseconds());
    const offset = if (value.zone.len > 0) try zones.offsetAt(value.zone, instant.seconds) else value.offset;
    return .{ .seconds = instant.seconds, .nanoseconds = instant.nanoseconds, .offset = offset, .zone = value.zone };
}

fn fromNanoseconds(nanoseconds: i128) Error!LocalDateTime {
    return .{
        .seconds = try checkedSeconds(@divFloor(nanoseconds, nanoseconds_per_second)),
        .nanoseconds = @intCast(@mod(nanoseconds, nanoseconds_per_second)),
    };
}

fn checkedDays(days: i128) Error!i64 {
    const limit = calendar.daysFromCivil(calendar.max_year, 12, 31);
    if (days > limit or days < calendar.daysFromCivil(calendar.min_year, 1, 1)) return error.Overflow;
    return @intCast(days);
}

fn checkedSeconds(seconds: i128) Error!i64 {
    _ = try checkedDays(@divFloor(seconds, calendar.seconds_per_day));
    return @intCast(seconds);
}

// --- The duration between two values ----------------------------------------

pub const Moment = types.Parts;

pub const Precision = enum { full, months, days, seconds };

/// The duration from `start` to `end`: whole months, then whole days, then
/// the time left (`full`), or only one of those measures. A value without a
/// date takes the other's, and without a zone the other's zone; when either
/// has no date only the time between them counts.
pub fn between(start_moment: Moment, end_moment: Moment, precision: Precision) (Error || zones.Error)!Duration {
    var start = start_moment;
    var end = end_moment;
    const time_only = start.days == null or end.days == null;
    if (start.days == null) start.days = end.days orelse 0;
    if (end.days == null) end.days = start.days;
    if (start.offset == null and start.zone.len == 0) {
        start.offset = end.offset;
        start.zone = end.zone;
    }
    if (end.offset == null and end.zone.len == 0) {
        end.offset = start.offset;
        end.zone = start.zone;
    }
    const start_instant = try instantOf(start);
    const end_instant = try instantOf(end);
    if (time_only) {
        if (precision == .months or precision == .days) return Duration.zero;
        return make(0, 0, end_instant - start_instant);
    }
    switch (precision) {
        .seconds => return make(0, 0, end_instant - start_instant),
        else => {},
    }
    // Calendar units count on the start's wall clock.
    const start_local = localNanoseconds(start);
    const end_local = try localIn(end_instant, start);
    var months: i64 = 0;
    var cursor = start_local;
    if (precision != .days) {
        months = monthsBetween(start_local, end_local);
        cursor = addMonthsToLocal(start_local, months);
    }
    if (precision == .months) return make(months, 0, 0);
    const days = daysBetween(cursor, end_local);
    if (precision == .days) return make(0, days, 0);
    cursor += @as(i128, days) * nanoseconds_per_day;
    const cursor_instant = try instantOfLocal(cursor, start);
    return make(months, days, end_instant - cursor_instant);
}

/// Nanoseconds since 1970-01-01T00:00 on the wall clock.
fn localNanoseconds(m: Moment) i128 {
    return @as(i128, m.days.?) * nanoseconds_per_day + (m.nanoseconds orelse 0);
}

/// Nanoseconds since 1970-01-01T00:00Z (a value with no zone is taken as UTC).
fn instantOf(m: Moment) zones.Error!i128 {
    return instantOfLocal(localNanoseconds(m), m);
}

fn instantOfLocal(local: i128, m: Moment) zones.Error!i128 {
    if (m.zone.len > 0) {
        const seconds = @divFloor(local, nanoseconds_per_second);
        const instant = try zones.resolveLocal(m.zone, @intCast(seconds));
        return @as(i128, instant) * nanoseconds_per_second + @mod(local, nanoseconds_per_second);
    }
    return local - @as(i128, m.offset orelse 0) * nanoseconds_per_second;
}

/// The wall-clock time of `instant` in the zone of `m`.
fn localIn(instant: i128, m: Moment) zones.Error!i128 {
    const offset: i128 = if (m.zone.len > 0) try zones.offsetAt(m.zone, @intCast(@divFloor(instant, nanoseconds_per_second))) else m.offset orelse 0;
    return instant + offset * nanoseconds_per_second;
}

/// Whole months from `start` to `end` (wall-clock nanoseconds), toward zero.
fn monthsBetween(start: i128, end: i128) i64 {
    const start_civil = calendar.civilFromDays(@intCast(@divFloor(start, nanoseconds_per_day)));
    const end_civil = calendar.civilFromDays(@intCast(@divFloor(end, nanoseconds_per_day)));
    var months = (end_civil.year - start_civil.year) * 12 + @as(i64, end_civil.month) - start_civil.month;
    // Not a whole month yet if the end's day and time come before the start's.
    const start_rest = @as(i128, start_civil.day) * nanoseconds_per_day + @mod(start, nanoseconds_per_day);
    const end_rest = @as(i128, end_civil.day) * nanoseconds_per_day + @mod(end, nanoseconds_per_day);
    if (months > 0 and end_rest < start_rest) months -= 1;
    if (months < 0 and end_rest > start_rest) months += 1;
    return months;
}

fn addMonthsToLocal(local: i128, months: i64) i128 {
    const day = calendar.addMonths(@intCast(@divFloor(local, nanoseconds_per_day)), months);
    return @as(i128, day) * nanoseconds_per_day + @mod(local, nanoseconds_per_day);
}

/// Whole days from `start` to `end` (wall-clock nanoseconds), toward zero.
fn daysBetween(start: i128, end: i128) i64 {
    var days: i64 = @intCast(@divFloor(end, nanoseconds_per_day) - @divFloor(start, nanoseconds_per_day));
    const start_time = @mod(start, nanoseconds_per_day);
    const end_time = @mod(end, nanoseconds_per_day);
    if (days > 0 and end_time < start_time) days -= 1;
    if (days < 0 and end_time > start_time) days += 1;
    return days;
}

test "fractions cascade to smaller units" {
    var builder = Builder{};
    try builder.add(.years, .{ .float = 12.5 });
    try builder.add(.months, .{ .float = 5.5 });
    try builder.add(.days, .{ .float = 14.5 });
    try builder.add(.hours, .{ .float = 16.5 });
    try builder.add(.minutes, .{ .float = 12.5 });
    try builder.add(.seconds, .{ .float = 70.5 });
    try builder.add(.nanoseconds, .{ .int = 3 });
    const d = try builder.finish();
    try std.testing.expectEqual(@as(i64, 155), d.months);
    try std.testing.expectEqual(@as(i64, 29), d.days);
    try std.testing.expectEqual(@as(i64, 122_293), d.seconds);
    try std.testing.expectEqual(@as(u32, 500_000_003), d.nanoseconds);
}

test "between counts months, then days, then time" {
    const start = Moment{ .days = calendar.daysFromCivil(1984, 10, 11) };
    const end = Moment{ .days = calendar.daysFromCivil(2015, 6, 24) };
    const d = try between(start, end, .full);
    try std.testing.expectEqual(@as(i64, 30 * 12 + 8), d.months);
    try std.testing.expectEqual(@as(i64, 13), d.days);
    try std.testing.expectEqual(@as(i64, 11213), (try between(start, end, .days)).days);
}
