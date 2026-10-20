//! The proleptic Gregorian calendar and ISO-8601 week dates, on day numbers:
//! a date is the count of days since 1970-01-01 (negative before it).
//!
//! All functions are total over the supported range (years -999,999,999 to
//! 999,999,999) and use floor division, so they hold on both sides of the
//! epoch. The civil conversions are Howard Hinnant's algorithms
//! (https://howardhinnant.github.io/date_algorithms.html).

const std = @import("std");

pub const min_year: i64 = -999_999_999;
pub const max_year: i64 = 999_999_999;

pub const seconds_per_day: i64 = 86_400;
pub const nanoseconds_per_second: i64 = 1_000_000_000;
pub const nanoseconds_per_day: i64 = seconds_per_day * nanoseconds_per_second;

/// A calendar date as year, month (1-12) and day of month (1-31).
pub const Civil = struct { year: i64, month: u8, day: u8 };

/// The day number of a valid civil date.
pub fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400; // [0, 399]
    const m: i64 = month;
    const day_of_year = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1; // [0, 365]
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

/// The civil date of a day number.
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const day_of_era = z - era * 146_097; // [0, 146096]
    const year_of_era = @divFloor(day_of_era - @divFloor(day_of_era, 1460) + @divFloor(day_of_era, 36_524) - @divFloor(day_of_era, 146_096), 365);
    const day_of_year = day_of_era - (365 * year_of_era + @divFloor(year_of_era, 4) - @divFloor(year_of_era, 100));
    const shifted_month = @divFloor(5 * day_of_year + 2, 153); // [0, 11], March first
    const day: u8 = @intCast(day_of_year - @divFloor(153 * shifted_month + 2, 5) + 1);
    const month: u8 = @intCast(if (shifted_month < 10) shifted_month + 3 else shifted_month - 9);
    const year = year_of_era + era * 400 + @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

pub fn isLeapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysInMonth(year: i64, month: u8) u8 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub fn daysInYear(year: i64) i64 {
    return if (isLeapYear(year)) 366 else 365;
}

/// ISO day of the week: 1 (Monday) to 7 (Sunday). 1970-01-01 was a Thursday.
pub fn dayOfWeek(days: i64) u8 {
    return @intCast(@mod(days + 3, 7) + 1);
}

/// Day of the year, 1-based.
pub fn ordinalDay(days: i64) i64 {
    return days - daysFromCivil(civilFromDays(days).year, 1, 1) + 1;
}

pub fn quarter(month: u8) u8 {
    return (month - 1) / 3 + 1;
}

/// The day number of the first day of `quarter_number` (1-4) of `year`.
pub fn quarterStart(year: i64, quarter_number: u8) i64 {
    return daysFromCivil(year, (quarter_number - 1) * 3 + 1, 1);
}

/// Day of the quarter, 1-based.
pub fn dayOfQuarter(days: i64) i64 {
    const civil = civilFromDays(days);
    return days - quarterStart(civil.year, quarter(civil.month)) + 1;
}

/// The Monday that starts ISO week 1 of `week_year`: the week holding 4 January.
pub fn weekYearStart(week_year: i64) i64 {
    const fourth = daysFromCivil(week_year, 1, 4);
    return fourth - (dayOfWeek(fourth) - 1);
}

/// 52 or 53.
pub fn weeksInWeekYear(week_year: i64) i64 {
    return @divExact(weekYearStart(week_year + 1) - weekYearStart(week_year), 7);
}

/// The ISO week-numbering year a day belongs to (it differs from the calendar
/// year for a few days around New Year).
pub fn weekYear(days: i64) i64 {
    const year = civilFromDays(days).year;
    if (days < weekYearStart(year)) return year - 1;
    if (days >= weekYearStart(year + 1)) return year + 1;
    return year;
}

/// The ISO week of the year, 1 to 53.
pub fn week(days: i64) i64 {
    return @divFloor(days - weekYearStart(weekYear(days)), 7) + 1;
}

/// The day number of a week date: `week` (1-53) of `week_year`, `day_of_week` (1-7).
pub fn daysFromWeekDate(week_year: i64, week_number: i64, day_of_week: i64) i64 {
    return weekYearStart(week_year) + (week_number - 1) * 7 + (day_of_week - 1);
}

/// `days` moved by `months` calendar months, the day clamped to the length
/// of the month it lands in (31 January + 1 month is 28 or 29 February).
pub fn addMonths(days: i64, months: i64) i64 {
    const civil = civilFromDays(days);
    const total = civil.year * 12 + (civil.month - 1) + months;
    const year = @divFloor(total, 12);
    const month: u8 = @intCast(@mod(total, 12) + 1);
    return daysFromCivil(year, month, @min(civil.day, daysInMonth(year, month)));
}

test "civil conversions round-trip and agree with known dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 5397), daysFromCivil(1984, 10, 11));
    try std.testing.expectEqual(@as(i64, -719_528), daysFromCivil(0, 1, 1));
    var days: i64 = -800_000;
    while (days < 800_000) : (days += 97) {
        const civil = civilFromDays(days);
        try std.testing.expectEqual(days, daysFromCivil(civil.year, civil.month, civil.day));
    }
    const far = civilFromDays(daysFromCivil(max_year, 12, 31));
    try std.testing.expectEqual(Civil{ .year = max_year, .month = 12, .day = 31 }, far);
}

test "ISO week dates" {
    // 1984-01-01 is a Sunday in week 52 of week-year 1983.
    const new_year = daysFromCivil(1984, 1, 1);
    try std.testing.expectEqual(@as(u8, 7), dayOfWeek(new_year));
    try std.testing.expectEqual(@as(i64, 1983), weekYear(new_year));
    try std.testing.expectEqual(@as(i64, 52), week(new_year));
    try std.testing.expectEqual(daysFromCivil(1816, 12, 31), daysFromWeekDate(1817, 1, 2));
    try std.testing.expectEqual(@as(i64, 53), weeksInWeekYear(1818));
    try std.testing.expectEqual(daysFromCivil(1984, 2, 29), addMonths(daysFromCivil(1984, 1, 31), 1));
}
