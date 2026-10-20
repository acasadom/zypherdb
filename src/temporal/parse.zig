//! Temporal values from ISO 8601 text, in the forms openCypher accepts:
//!
//! - dates: `2015-07-21`, `20150721`, `2015-07`, `2015-W30-2`, `2015W302`,
//!   `2015-W30`, `2015-202`, `2015202`, `2015`; years outside 0-9999 carry a
//!   sign (`+999999999-12-31`);
//! - times: `21:40:32.142`, `214032.142`, `21:40`, `2140`, `21`, then an
//!   optional offset (`Z`, `+01`, `+0100`, `+01:00`, `+01:00:15`) and, for
//!   date-times, an optional zone (`[Europe/Stockholm]`);
//! - date-times: a date, `T`, a time;
//! - durations: `P1Y2M3W4DT5H6M7.5S` (any unit may be fractional or
//!   negative) or `P2012-02-02T14:37:21.545`.

const std = @import("std");
const calendar = @import("calendar.zig");
const zones = @import("zones.zig");
const durations = @import("durations.zig");
const types = @import("types.zig");

const Date = types.Date;
const LocalTime = types.LocalTime;
const Time = types.Time;
const LocalDateTime = types.LocalDateTime;
const DateTime = types.DateTime;
const Duration = types.Duration;

pub const Error = error{InvalidTemporal} || zones.Error;

const nanoseconds_per_second = calendar.nanoseconds_per_second;

pub fn date(text: []const u8) Error!Date {
    var cursor = Cursor{ .text = text };
    const result = try cursor.date();
    try cursor.end();
    return result;
}

pub fn localTime(text: []const u8) Error!LocalTime {
    var cursor = Cursor{ .text = text };
    const result = try cursor.timeOfDay();
    try cursor.end();
    return result;
}

/// A time; without an offset, at UTC.
pub fn time(text: []const u8) Error!Time {
    var cursor = Cursor{ .text = text };
    const local = try cursor.timeOfDay();
    const offset = try cursor.optionalOffset() orelse 0;
    try cursor.end();
    return .{ .nanoseconds = local.nanoseconds, .offset = offset };
}

pub fn localDateTime(text: []const u8) Error!LocalDateTime {
    var cursor = Cursor{ .text = text };
    const result = try cursor.localDateTime();
    try cursor.end();
    return result;
}

/// A date-time; with neither offset nor zone, at UTC. With a zone and an
/// offset the offset must be the zone's at that time; with a zone alone,
/// the zone gives it.
pub fn dateTime(text: []const u8) Error!DateTime {
    var cursor = Cursor{ .text = text };
    const local = try cursor.localDateTime();
    const offset = try cursor.optionalOffset();
    const zone = try cursor.optionalZone();
    try cursor.end();
    if (zone) |name| {
        const canonical = try zones.canonicalName(name);
        const instant = if (offset) |o| local.seconds - o else try zones.resolveLocal(canonical, local.seconds);
        return .{ .seconds = instant, .nanoseconds = local.nanoseconds, .offset = try zones.offsetAt(canonical, instant), .zone = canonical };
    }
    const o = offset orelse 0;
    return .{ .seconds = local.seconds - o, .nanoseconds = local.nanoseconds, .offset = o, .zone = "" };
}

pub fn duration(text: []const u8) Error!Duration {
    var cursor = Cursor{ .text = text };
    if (!cursor.eat('P') and !cursor.eat('p')) return error.InvalidTemporal;
    if (std.mem.indexOfScalar(u8, text, '-') != null and isAlternativeDuration(text[1..])) return alternativeDuration(text[1..]);
    var builder = durations.Builder{};
    var in_time = false;
    var any = false;
    while (!cursor.done()) {
        if (cursor.eat('T') or cursor.eat('t')) {
            if (in_time) return error.InvalidTemporal;
            in_time = true;
            continue;
        }
        const number = try cursor.decimal();
        const unit: durations.Unit = switch (std.ascii.toUpper(cursor.take() orelse return error.InvalidTemporal)) {
            'Y' => if (in_time) return error.InvalidTemporal else .years,
            'M' => if (in_time) .minutes else .months,
            'W' => if (in_time) return error.InvalidTemporal else .weeks,
            'D' => if (in_time) return error.InvalidTemporal else .days,
            'H' => if (in_time) .hours else return error.InvalidTemporal,
            'S' => if (in_time) .seconds else return error.InvalidTemporal,
            else => return error.InvalidTemporal,
        };
        builder.add(unit, number) catch return error.InvalidTemporal;
        any = true;
    }
    if (!any) return error.InvalidTemporal;
    return builder.finish() catch error.InvalidTemporal;
}

/// `P2012-02-02T14:37:21.545`: years, months, days, hours, minutes, seconds
/// in date-time notation.
fn isAlternativeDuration(text: []const u8) bool {
    return text.len >= 10 and std.ascii.isDigit(text[0]) and text[4] == '-';
}

fn alternativeDuration(text: []const u8) Error!Duration {
    var cursor = Cursor{ .text = text };
    const years = try cursor.digits(4, 4);
    try cursor.expect('-');
    const months = try cursor.digits(2, 2);
    try cursor.expect('-');
    const days = try cursor.digits(2, 2);
    var builder = durations.Builder{};
    builder.add(.years, .{ .int = years }) catch return error.InvalidTemporal;
    builder.add(.months, .{ .int = months }) catch return error.InvalidTemporal;
    builder.add(.days, .{ .int = days }) catch return error.InvalidTemporal;
    if (cursor.eat('T')) {
        const local = try cursor.timeOfDay();
        builder.add(.nanoseconds, .{ .int = local.nanoseconds }) catch return error.InvalidTemporal;
    }
    try cursor.end();
    return builder.finish() catch error.InvalidTemporal;
}

const Cursor = struct {
    text: []const u8,
    position: usize = 0,

    fn done(self: *const Cursor) bool {
        return self.position >= self.text.len;
    }

    fn peek(self: *const Cursor) u8 {
        return if (self.done()) 0 else self.text[self.position];
    }

    fn take(self: *Cursor) ?u8 {
        if (self.done()) return null;
        self.position += 1;
        return self.text[self.position - 1];
    }

    fn eat(self: *Cursor, c: u8) bool {
        if (self.peek() != c) return false;
        self.position += 1;
        return true;
    }

    fn expect(self: *Cursor, c: u8) Error!void {
        if (!self.eat(c)) return error.InvalidTemporal;
    }

    fn end(self: *const Cursor) Error!void {
        if (!self.done()) return error.InvalidTemporal;
    }

    /// The number of digits ahead.
    fn digitsAhead(self: *const Cursor) usize {
        var count: usize = 0;
        while (self.position + count < self.text.len and std.ascii.isDigit(self.text[self.position + count])) count += 1;
        return count;
    }

    /// Between `min` and `max` digits, as a number.
    fn digits(self: *Cursor, min: usize, max: usize) Error!i64 {
        const count = @min(self.digitsAhead(), max);
        if (count < min) return error.InvalidTemporal;
        const value = std.fmt.parseInt(i64, self.text[self.position .. self.position + count], 10) catch return error.InvalidTemporal;
        self.position += count;
        return value;
    }

    /// An optionally signed decimal number (`.` or `,` before a fraction).
    fn decimal(self: *Cursor) Error!durations.Number {
        const start = self.position;
        if (!self.eat('-')) _ = self.eat('+');
        const whole_digits = self.digitsAhead();
        self.position += whole_digits;
        if (self.peek() == '.' or self.peek() == ',') {
            self.position += 1;
            const fraction_digits = self.digitsAhead();
            if (fraction_digits == 0) return error.InvalidTemporal;
            self.position += fraction_digits;
            var buffer: [64]u8 = undefined;
            const text = self.text[start..self.position];
            if (text.len > buffer.len) return error.InvalidTemporal;
            @memcpy(buffer[0..text.len], text);
            if (std.mem.indexOfScalar(u8, buffer[0..text.len], ',')) |comma| buffer[comma] = '.';
            return .{ .float = std.fmt.parseFloat(f64, buffer[0..text.len]) catch return error.InvalidTemporal };
        }
        if (whole_digits == 0) return error.InvalidTemporal;
        return .{ .int = std.fmt.parseInt(i64, self.text[start..self.position], 10) catch return error.InvalidTemporal };
    }

    fn date(self: *Cursor) Error!Date {
        const year = try self.yearNumber();
        if (self.done() or self.peek() == 'T' or self.peek() == 't') return .{ .days = calendar.daysFromCivil(year, 1, 1) };
        const extended = self.eat('-');
        if (self.eat('W') or self.eat('w')) {
            const week = try self.digits(2, 2);
            var day_of_week: i64 = 1;
            if (extended) {
                if (self.eat('-')) day_of_week = try self.digits(1, 1);
            } else if (self.digitsAhead() >= 1) day_of_week = try self.digits(1, 1);
            if (week < 1 or week > calendar.weeksInWeekYear(year) or day_of_week < 1 or day_of_week > 7) return error.InvalidTemporal;
            return .{ .days = calendar.daysFromWeekDate(year, week, day_of_week) };
        }
        const count = self.digitsAhead();
        if (count == 3) {
            const ordinal = try self.digits(3, 3);
            if (ordinal < 1 or ordinal > calendar.daysInYear(year)) return error.InvalidTemporal;
            return .{ .days = calendar.daysFromCivil(year, 1, 1) + ordinal - 1 };
        }
        const month = try self.digits(2, 2);
        var day: i64 = 1;
        if (extended) {
            if (self.eat('-')) day = try self.digits(2, 2);
        } else if (self.digitsAhead() >= 2) day = try self.digits(2, 2);
        return civil(year, month, day);
    }

    /// Four digits, or a sign and up to nine.
    fn yearNumber(self: *Cursor) Error!i64 {
        if (self.peek() == '+' or self.peek() == '-') {
            const negative = self.take().? == '-';
            const magnitude = try self.digits(4, 9);
            return if (negative) -magnitude else magnitude;
        }
        return self.digits(4, 4);
    }

    fn timeOfDay(self: *Cursor) Error!LocalTime {
        const hour = try self.digits(2, 2);
        var minute: i64 = 0;
        var second: i64 = 0;
        var fraction: i64 = 0;
        const extended = self.peek() == ':';
        if (self.eat(':') or self.digitsAhead() >= 2) {
            minute = try self.digits(2, 2);
            if ((extended and self.eat(':')) or (!extended and self.digitsAhead() >= 2)) {
                second = try self.digits(2, 2);
                if (self.eat('.') or self.eat(',')) {
                    const count = self.digitsAhead();
                    if (count == 0 or count > 9) return error.InvalidTemporal;
                    fraction = try self.digits(count, count);
                    fraction *= std.math.pow(i64, 10, @intCast(9 - count));
                }
            }
        }
        return timeFromParts(hour, minute, second, fraction);
    }

    /// A date, then `T` and a time of day; a date alone is at midnight.
    fn localDateTime(self: *Cursor) Error!LocalDateTime {
        const day = try self.date();
        if (!self.eat('T') and !self.eat('t')) return LocalDateTime.init(day, .{ .nanoseconds = 0 });
        return LocalDateTime.init(day, try self.timeOfDay());
    }

    fn optionalOffset(self: *Cursor) Error!?i32 {
        const c = self.peek();
        if (c != 'Z' and c != 'z' and c != '+' and c != '-') return null;
        const start = self.position;
        self.position += 1;
        if (c == '+' or c == '-') {
            while (std.ascii.isDigit(self.peek()) or self.peek() == ':') self.position += 1;
        }
        return zones.parseOffset(self.text[start..self.position]) orelse error.InvalidTemporal;
    }

    fn optionalZone(self: *Cursor) Error!?[]const u8 {
        if (!self.eat('[')) return null;
        const start = self.position;
        while (!self.done() and self.peek() != ']') self.position += 1;
        const name = self.text[start..self.position];
        try self.expect(']');
        return name;
    }
};

/// A validated date.
pub fn civil(year: i64, month: i64, day: i64) Error!Date {
    if (year < calendar.min_year or year > calendar.max_year or month < 1 or month > 12) return error.InvalidTemporal;
    if (day < 1 or day > calendar.daysInMonth(year, @intCast(month))) return error.InvalidTemporal;
    return .{ .days = calendar.daysFromCivil(year, @intCast(month), @intCast(day)) };
}

/// A validated time of day; `fraction` in nanoseconds.
pub fn timeFromParts(hour: i64, minute: i64, second: i64, fraction: i64) Error!LocalTime {
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59 or fraction < 0 or fraction >= nanoseconds_per_second) return error.InvalidTemporal;
    return .{ .nanoseconds = ((hour * 60 + minute) * 60 + second) * nanoseconds_per_second + fraction };
}

test "dates in every form" {
    const expected = calendar.daysFromCivil(2015, 7, 21);
    for ([_][]const u8{ "2015-07-21", "20150721", "2015-W30-2", "2015W302", "2015-202", "2015202" }) |text| {
        try std.testing.expectEqual(expected, (try date(text)).days);
    }
    try std.testing.expectEqual(calendar.daysFromCivil(2015, 7, 1), (try date("201507")).days);
    try std.testing.expectEqual(calendar.daysFromCivil(2015, 7, 20), (try date("2015-W30")).days);
    try std.testing.expectEqual(calendar.daysFromCivil(-999_999_999, 1, 1), (try date("-999999999-01-01")).days);
    try std.testing.expectError(error.InvalidTemporal, date("2015-02-30"));
}

test "times, offsets and durations" {
    try std.testing.expectEqual(@as(i64, (21 * 3600 + 40 * 60 + 32) * nanoseconds_per_second + 142_000_000), (try localTime("214032.142")).nanoseconds);
    const t = try time("2140-02");
    try std.testing.expectEqual(@as(i32, -7200), t.offset);
    const d = try duration("P0.75M");
    try std.testing.expectEqual(@as(i64, 22), d.days);
    try std.testing.expectEqual(@as(i64, 19 * 3600 + 51 * 60 + 49), d.seconds);
    try std.testing.expectEqual(@as(u32, 500_000_000), d.nanoseconds);
    const alternative = try duration("P2012-02-02T14:37:21.545");
    try std.testing.expectEqual(@as(i64, 2012 * 12 + 2), alternative.months);
}
