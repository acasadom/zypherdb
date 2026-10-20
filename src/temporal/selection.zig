//! Building a temporal value from named fields, as `date({year: 1984, week:
//! 10})` and `datetime({date: d, hour: 12, timezone: 'Europe/Stockholm'})`
//! do, and truncating one (`date.truncate('month', d)`).
//!
//! Every value is handled as `Parts`: its wall-clock day and time of day and
//! its zone, each present or not. Fields override the parts of the base
//! values (`date`, `time`, `datetime`) they are given with:
//!
//! - a date from `year`, `month`, `day`; or a week date from `year` (the
//!   week-year), `week`, `dayOfWeek`; or `year`, `ordinalDay`; or `year`,
//!   `quarter`, `dayOfQuarter`. The parts not given come from the base date
//!   (`{date: d, day: 28}` keeps d's year and month), else from the start of
//!   the larger unit;
//! - a time from `hour`, `minute`, `second` and the fraction (`millisecond`,
//!   `microsecond`, `nanosecond`, added together);
//! - the zone: a `timezone` given with a base that has a zone converts the
//!   value to it (the same instant); with a base that has none, it is the
//!   zone the wall-clock time is in. Without either, UTC.

const std = @import("std");
const calendar = @import("calendar.zig");
const zones = @import("zones.zig");
const parse = @import("parse.zig");

pub const Error = error{InvalidTemporal} || zones.Error;

const nanoseconds_per_second = calendar.nanoseconds_per_second;
const nanoseconds_per_day = calendar.nanoseconds_per_day;

pub const Parts = @import("types.zig").Parts;

pub const Kind = enum {
    date,
    local_time,
    time,
    local_date_time,
    date_time,

    fn hasDate(kind: Kind) bool {
        return kind == .date or kind == .local_date_time or kind == .date_time;
    }

    fn hasTime(kind: Kind) bool {
        return kind != .date;
    }

    fn hasZone(kind: Kind) bool {
        return kind == .time or kind == .date_time;
    }
};

pub const Fields = struct {
    year: ?i64 = null,
    month: ?i64 = null,
    day: ?i64 = null,
    week: ?i64 = null,
    day_of_week: ?i64 = null,
    ordinal_day: ?i64 = null,
    quarter: ?i64 = null,
    day_of_quarter: ?i64 = null,
    hour: ?i64 = null,
    minute: ?i64 = null,
    second: ?i64 = null,
    millisecond: ?i64 = null,
    microsecond: ?i64 = null,
    nanosecond: ?i64 = null,
    timezone: ?[]const u8 = null,
    date: ?Parts = null,
    time: ?Parts = null,
    datetime: ?Parts = null,

    /// The field names a map may use (their spelling in Cypher).
    pub const names = [_]struct { []const u8, std.meta.FieldEnum(Fields) }{
        .{ "year", .year },               .{ "month", .month },
        .{ "day", .day },                 .{ "week", .week },
        .{ "dayOfWeek", .day_of_week },   .{ "ordinalDay", .ordinal_day },
        .{ "quarter", .quarter },         .{ "dayOfQuarter", .day_of_quarter },
        .{ "hour", .hour },               .{ "minute", .minute },
        .{ "second", .second },           .{ "millisecond", .millisecond },
        .{ "microsecond", .microsecond }, .{ "nanosecond", .nanosecond },
        .{ "timezone", .timezone },       .{ "date", .date },
        .{ "time", .time },               .{ "datetime", .datetime },
    };
};

/// The parts of a value of `kind` built from `fields`. `now` gives the
/// instant (seconds since the epoch) a time in a named zone takes its offset
/// at, when there is no date to take it at.
pub fn build(kind: Kind, fields: Fields, now: i64) Error!Parts {
    var result = Parts{};
    if (kind.hasDate()) result.days = try selectDate(fields, fields.date orelse fields.datetime);
    if (kind.hasTime()) result.nanoseconds = try selectTime(fields, fields.time orelse fields.datetime);
    if (!kind.hasZone()) return result;

    // The zone of the base the time comes from, if it has one.
    const base_zone: ?Parts = blk: {
        if (fields.time) |t| if (t.hasZone()) break :blk t;
        if (fields.time == null) if (fields.datetime) |t| if (t.hasZone()) break :blk t;
        break :blk null;
    };
    const target = if (fields.timezone) |name| try zoneNamed(name) else null;
    if (base_zone) |base| {
        result.offset = base.offset;
        result.zone = base.zone;
        if (target) |zone| try convert(&result, zone, kind, now);
    } else if (target) |zone| {
        result.offset = zone.offset;
        result.zone = zone.zone;
    } else {
        result.offset = 0;
    }
    if (result.zone.len > 0) {
        if (kind == .time) {
            // A time has an offset only: the zone's, now if no base gave it.
            if (result.offset == null) result.offset = try zones.offsetAt(result.zone, now);
            result.zone = "";
        } else {
            // A named zone gives the offset at the wall-clock time.
            result.offset = try offsetOfLocal(result, now);
        }
    }
    return result;
}

/// A `timezone` value: an offset (`+01:00`, `Z`) or a zone name.
pub fn zoneNamed(text: []const u8) Error!Parts {
    if (zones.parseOffset(text)) |offset| return .{ .offset = offset };
    return .{ .zone = try zones.canonicalName(text) };
}

/// Re-expresses `parts` (wall clock in its zone) as the same instant in `zone`.
fn convert(parts: *Parts, zone: Parts, kind: Kind, now: i64) Error!void {
    const local = @as(i128, parts.days orelse 0) * nanoseconds_per_day + parts.nanoseconds.?;
    const instant = local - @as(i128, try offsetOfLocal(parts.*, now)) * nanoseconds_per_second;
    const instant_seconds: i64 = @intCast(@divFloor(instant, nanoseconds_per_second));
    const offset = if (zone.zone.len > 0) try zones.offsetAt(zone.zone, if (kind == .time) now else instant_seconds) else zone.offset.?;
    const moved = instant + @as(i128, offset) * nanoseconds_per_second;
    if (parts.days != null) parts.days = @intCast(@divFloor(moved, nanoseconds_per_day));
    parts.nanoseconds = @intCast(@mod(moved, nanoseconds_per_day));
    parts.offset = offset;
    parts.zone = zone.zone;
}

/// The offset in force at the wall-clock time of `parts`.
fn offsetOfLocal(parts: Parts, now: i64) Error!i32 {
    if (parts.zone.len == 0) return parts.offset orelse 0;
    const days = parts.days orelse return parts.offset orelse zones.offsetAt(parts.zone, now);
    const local_seconds = days * calendar.seconds_per_day + @divFloor(parts.nanoseconds orelse 0, nanoseconds_per_second);
    return zones.offsetAt(parts.zone, try zones.resolveLocal(parts.zone, local_seconds));
}

fn selectDate(f: Fields, base: ?Parts) Error!i64 {
    const base_days: ?i64 = if (base) |b| b.days else null;
    // Without a base date, a date needs a year.
    if (base_days == null and f.year == null) return error.InvalidTemporal;
    if (f.week != null or f.day_of_week != null) {
        const week_year = f.year orelse calendar.weekYear(base_days.?);
        const week = f.week orelse if (base_days) |d| calendar.week(d) else 1;
        const day_of_week = f.day_of_week orelse if (base_days) |d| calendar.dayOfWeek(d) else 1;
        try checkYear(week_year);
        if (week < 1 or week > calendar.weeksInWeekYear(week_year) or day_of_week < 1 or day_of_week > 7) return error.InvalidTemporal;
        return calendar.daysFromWeekDate(week_year, week, day_of_week);
    }
    const base_civil = if (base_days) |d| calendar.civilFromDays(d) else null;
    const year = f.year orelse base_civil.?.year;
    try checkYear(year);
    if (f.ordinal_day) |ordinal| {
        if (ordinal < 1 or ordinal > calendar.daysInYear(year)) return error.InvalidTemporal;
        return calendar.daysFromCivil(year, 1, 1) + ordinal - 1;
    }
    if (f.quarter != null or f.day_of_quarter != null) {
        const base_quarter: ?i64 = if (base_civil) |c| calendar.quarter(c.month) else null;
        const quarter = f.quarter orelse base_quarter orelse 1;
        if (quarter < 1 or quarter > 4) return error.InvalidTemporal;
        if (f.day_of_quarter) |day_of_quarter| {
            const start = calendar.quarterStart(year, @intCast(quarter));
            const length = calendar.quarterStart(year + @intFromBool(quarter == 4), if (quarter == 4) 1 else @intCast(quarter + 1)) - start;
            if (day_of_quarter < 1 or day_of_quarter > length) return error.InvalidTemporal;
            return start + day_of_quarter - 1;
        }
        // A new quarter only: the same month of the quarter and day (clamped).
        const civil = base_civil orelse return calendar.quarterStart(year, @intCast(quarter));
        const month: u8 = @intCast((quarter - 1) * 3 + (civil.month - 1) % 3 + 1);
        return calendar.daysFromCivil(year, month, @min(civil.day, calendar.daysInMonth(year, month)));
    }
    const month = f.month orelse if (base_civil) |c| c.month else 1;
    if (month < 1 or month > 12) return error.InvalidTemporal;
    if (f.day) |day| return (try parse.civil(year, month, day)).days;
    const day: i64 = if (base_civil) |c| @min(c.day, calendar.daysInMonth(year, @intCast(month))) else 1;
    return calendar.daysFromCivil(year, @intCast(month), @intCast(day));
}

fn checkYear(year: i64) Error!void {
    if (year < calendar.min_year or year > calendar.max_year) return error.InvalidTemporal;
}

fn selectTime(f: Fields, base: ?Parts) Error!i64 {
    const base_nanoseconds: ?i64 = if (base) |b| b.nanoseconds else null;
    if (base_nanoseconds == null) {
        // A smaller unit needs the larger ones.
        if (f.minute != null and f.hour == null) return error.InvalidTemporal;
        if (f.second != null and f.minute == null) return error.InvalidTemporal;
        if ((f.millisecond != null or f.microsecond != null or f.nanosecond != null) and f.second == null) return error.InvalidTemporal;
    }
    const base_seconds = if (base_nanoseconds) |n| @divFloor(n, nanoseconds_per_second) else 0;
    const hour = f.hour orelse @divFloor(base_seconds, 3600);
    const minute = f.minute orelse @mod(@divFloor(base_seconds, 60), 60);
    const second = f.second orelse @mod(base_seconds, 60);
    const base_fraction = if (base_nanoseconds) |n| @mod(n, nanoseconds_per_second) else 0;
    const fraction = if (f.millisecond != null or f.microsecond != null or f.nanosecond != null) blk: {
        // The sub-second units not given come from the base: `{nanosecond:
        // 2}` on 14.645 is 14.645000002. A microsecond or nanosecond above
        // 999 counts from the second, replacing the larger units.
        const wide_microsecond = if (f.microsecond) |n| n > 999 else false;
        const wide_nanosecond = if (f.nanosecond) |n| n > 999 else false;
        const millisecond = f.millisecond orelse if (wide_microsecond or wide_nanosecond) 0 else @divFloor(base_fraction, 1_000_000);
        const microsecond = f.microsecond orelse if (wide_nanosecond) 0 else @mod(@divFloor(base_fraction, 1_000), 1_000);
        const nanosecond = f.nanosecond orelse @mod(base_fraction, 1_000);
        if (millisecond < 0 or millisecond > 999) return error.InvalidTemporal;
        if (microsecond < 0 or microsecond > (if (f.millisecond != null) @as(i64, 999) else 999_999)) return error.InvalidTemporal;
        if (nanosecond < 0 or nanosecond > (if (f.millisecond != null or f.microsecond != null) @as(i64, 999) else 999_999_999)) return error.InvalidTemporal;
        const total = millisecond * 1_000_000 + microsecond * 1_000 + nanosecond;
        if (total >= nanoseconds_per_second) return error.InvalidTemporal;
        break :blk total;
    } else base_fraction;
    return (try parse.timeFromParts(hour, minute, second, fraction)).nanoseconds;
}

// --- Truncation ----------------------------------------------------------------

pub const Unit = enum { millennium, century, decade, year, week_year, quarter, month, week, day, hour, minute, second, millisecond, microsecond };

pub fn unitNamed(name: []const u8) ?Unit {
    const table = [_]struct { []const u8, Unit }{
        .{ "millennium", .millennium },   .{ "century", .century },         .{ "decade", .decade },
        .{ "year", .year },               .{ "weekYear", .week_year },      .{ "quarter", .quarter },
        .{ "month", .month },             .{ "week", .week },               .{ "day", .day },
        .{ "hour", .hour },               .{ "minute", .minute },           .{ "second", .second },
        .{ "millisecond", .millisecond }, .{ "microsecond", .microsecond },
    };
    for (table) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
    return null;
}

/// `parts` with everything below `unit` reset (to the first day / zero),
/// keeping its zone. A date unit needs a date.
pub fn truncate(parts: Parts, unit: Unit) Error!Parts {
    var result = parts;
    const is_date_unit = @backingInt(unit) <= @backingInt(Unit.day);
    if (is_date_unit) {
        const days = parts.days orelse return error.InvalidTemporal;
        const civil = calendar.civilFromDays(days);
        result.days = switch (unit) {
            .millennium => calendar.daysFromCivil(@divFloor(civil.year, 1000) * 1000, 1, 1),
            .century => calendar.daysFromCivil(@divFloor(civil.year, 100) * 100, 1, 1),
            .decade => calendar.daysFromCivil(@divFloor(civil.year, 10) * 10, 1, 1),
            .year => calendar.daysFromCivil(civil.year, 1, 1),
            .week_year => calendar.weekYearStart(calendar.weekYear(days)),
            .quarter => calendar.quarterStart(civil.year, calendar.quarter(civil.month)),
            .month => calendar.daysFromCivil(civil.year, civil.month, 1),
            .week => days - (calendar.dayOfWeek(days) - 1),
            .day => days,
            else => unreachable,
        };
        if (result.nanoseconds != null) result.nanoseconds = 0;
        return result;
    }
    const nanoseconds = parts.nanoseconds orelse return error.InvalidTemporal;
    const step: i64 = switch (unit) {
        .hour => 3600 * nanoseconds_per_second,
        .minute => 60 * nanoseconds_per_second,
        .second => nanoseconds_per_second,
        .millisecond => 1_000_000,
        .microsecond => 1_000,
        else => unreachable,
    };
    result.nanoseconds = nanoseconds - @mod(nanoseconds, step);
    return result;
}

test "week dates and quarters select from the base date" {
    const base = Parts{ .days = calendar.daysFromCivil(1984, 11, 11) };
    try std.testing.expectEqual(calendar.daysFromCivil(1984, 1, 8), (try build(.date, .{ .date = base, .week = 1 }, 0)).days.?);
    try std.testing.expectEqual(calendar.daysFromCivil(1984, 8, 11), (try build(.date, .{ .date = base, .quarter = 3 }, 0)).days.?);
    try std.testing.expectEqual(calendar.daysFromCivil(28, 11, 11), (try build(.date, .{ .date = base, .year = 28 }, 0)).days.?);
    try std.testing.expectEqual(calendar.daysFromCivil(1984, 8, 14), (try build(.date, .{ .year = 1984, .quarter = 3, .day_of_quarter = 45 }, 0)).days.?);
}

test "a timezone converts a zoned base and places an unzoned one" {
    const noon = 12 * 3600 * nanoseconds_per_second;
    const zoned = Parts{ .nanoseconds = noon, .offset = 3600 };
    const converted = try build(.time, .{ .time = zoned, .timezone = "+05:00" }, 0);
    try std.testing.expectEqual(@as(i64, 16 * 3600 * nanoseconds_per_second), converted.nanoseconds.?);
    const placed = try build(.time, .{ .time = .{ .nanoseconds = noon }, .timezone = "+05:00" }, 0);
    try std.testing.expectEqual(noon, placed.nanoseconds.?);
    try std.testing.expectEqual(@as(?i32, 5 * 3600), placed.offset);
}
