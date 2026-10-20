//! The temporal functions of openCypher (`date`, `localtime`, `time`,
//! `localdatetime`, `datetime`, `duration` and their namespaced variants),
//! the components of temporal values (`d.year`, `dur.hours`), and the
//! arithmetic between temporal values and durations. The calendar work is
//! in src/temporal/; this file translates between it and `Value`s.

const std = @import("std");

const Value = @import("../value.zig").Value;
const MapEntry = @import("../value.zig").MapEntry;
const BinaryOperator = @import("../query/ast.zig").BinaryOperator;

const calendar = @import("../temporal/calendar.zig");
const zones = @import("../temporal/zones.zig");
const types = @import("../temporal/types.zig");
const parse = @import("../temporal/parse.zig");
const durations = @import("../temporal/durations.zig");
const selection = @import("../temporal/selection.zig");

const Executor = @import("Executor.zig");
const ExecutionError = Executor.ExecutionError;

const Parts = types.Parts;
pub const Kind = selection.Kind;

const nanoseconds_per_second = calendar.nanoseconds_per_second;
const nanoseconds_per_day = calendar.nanoseconds_per_day;

const TemporalError = selection.Error || parse.Error || durations.Error;

fn fail(self: *Executor, err: TemporalError) ExecutionError {
    switch (err) {
        error.InvalidTemporal => self.fail(.invalid_expression, "invalid temporal value", .{}),
        error.UnknownTimeZone => self.fail(.invalid_expression, "unknown time zone", .{}),
        error.InvalidOffset => self.fail(.invalid_expression, "invalid time zone offset", .{}),
        error.Overflow => {
            self.fail(.arithmetic, "temporal value out of range", .{});
            return error.IntegerOverflow;
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
    return error.InvalidExpression;
}

fn typeError(self: *Executor, comptime message: []const u8) ExecutionError {
    self.fail(.type_mismatch, message, .{});
    return error.TypeMismatch;
}

// --- Between values and parts -------------------------------------------------

/// The parts of a temporal value, or null for any other value.
pub fn partsOf(value: Value) ?Parts {
    return switch (value) {
        .date => |d| .{ .days = d.days },
        .local_time => |t| .{ .nanoseconds = t.nanoseconds },
        .time => |t| .{ .nanoseconds = t.nanoseconds, .offset = t.offset },
        .local_date_time => |t| .{ .days = t.date().days, .nanoseconds = t.time().nanoseconds },
        .date_time => |t| .{ .days = t.local().date().days, .nanoseconds = t.local().time().nanoseconds, .offset = t.offset, .zone = t.zone },
        else => null,
    };
}

/// The value of `kind` with these parts (the ones `kind` has must be set).
pub fn valueOf(kind: Kind, parts: Parts) TemporalError!Value {
    return switch (kind) {
        .date => .{ .date = .{ .days = parts.days.? } },
        .local_time => .{ .local_time = .{ .nanoseconds = parts.nanoseconds.? } },
        .time => .{ .time = .{ .nanoseconds = parts.nanoseconds.?, .offset = parts.offset orelse 0 } },
        .local_date_time => .{ .local_date_time = types.LocalDateTime.init(.{ .days = parts.days.? }, .{ .nanoseconds = parts.nanoseconds.? }) },
        .date_time => blk: {
            const local = types.LocalDateTime.init(.{ .days = parts.days.? }, .{ .nanoseconds = parts.nanoseconds.? });
            if (parts.zone.len > 0) {
                const instant = try zones.resolveLocal(parts.zone, local.seconds);
                break :blk .{ .date_time = .{ .seconds = instant, .nanoseconds = local.nanoseconds, .offset = try zones.offsetAt(parts.zone, instant), .zone = parts.zone } };
            }
            const offset = parts.offset orelse 0;
            break :blk .{ .date_time = .{ .seconds = local.seconds - offset, .nanoseconds = local.nanoseconds, .offset = offset, .zone = "" } };
        },
    };
}

/// The current instant as parts at UTC: fixed for the statement unless
/// `realtime`.
fn nowParts(self: *Executor, realtime: bool) Parts {
    const instant = if (realtime) clockNow() else self.statementTime();
    return .{ .days = @intCast(@divFloor(instant, nanoseconds_per_day)), .nanoseconds = @intCast(@mod(instant, nanoseconds_per_day)), .offset = 0 };
}

/// Nanoseconds since the epoch, from the system clock.
pub fn clockNow() i128 {
    return std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
}

fn nowSeconds(self: *Executor) i64 {
    return @intCast(@divFloor(self.statementTime(), nanoseconds_per_second));
}

// --- Construction -------------------------------------------------------------

/// `date(x)`, `datetime(x)`, ...: from a string, a map of fields, another
/// temporal value, or (no argument) the current time; null for null.
pub fn construct(self: *Executor, kind: Kind, arguments: []const Value, realtime: bool) ExecutionError!Value {
    if (arguments.len == 0) return converted(self, kind, nowParts(self, realtime));
    return switch (arguments[0]) {
        .null => .{ .null = {} },
        .string => |text| parseText(kind, text) catch |err| fail(self, err),
        .map => |entries| fromMap(self, kind, entries, realtime),
        else => if (partsOf(arguments[0])) |parts| converted(self, kind, parts) else typeError(self, "a temporal function takes a string, a map or a temporal value"),
    };
}

fn parseText(kind: Kind, text: []const u8) TemporalError!Value {
    return switch (kind) {
        .date => .{ .date = try parse.date(text) },
        .local_time => .{ .local_time = try parse.localTime(text) },
        .time => .{ .time = try parse.time(text) },
        .local_date_time => .{ .local_date_time = try parse.localDateTime(text) },
        .date_time => .{ .date_time = try parse.dateTime(text) },
    };
}

/// Another temporal value as `kind`: its own parts, the missing time of day
/// being midnight and the missing zone UTC.
fn converted(self: *Executor, kind: Kind, parts: Parts) ExecutionError!Value {
    var fields = selection.Fields{};
    if (parts.days != null and parts.nanoseconds != null) fields.datetime = parts else if (parts.days != null) fields.date = parts else fields.time = parts;
    if ((kind == .date or kind == .local_date_time or kind == .date_time) and parts.days == null) {
        return typeError(self, "a time has no date to convert");
    }
    if (kind != .date and parts.nanoseconds == null) {
        // A date: at midnight.
        fields.time = .{ .nanoseconds = 0 };
    }
    const built = selection.build(kind, fields, nowSeconds(self)) catch |err| return fail(self, err);
    return valueOf(kind, built) catch |err| fail(self, err);
}

fn fromMap(self: *Executor, kind: Kind, entries: []const MapEntry, realtime: bool) ExecutionError!Value {
    const fields = try fieldsOf(self, entries);
    // `datetime({timezone: 'Europe/Stockholm'})`: now, in that zone.
    const has_date_field = fields.year != null or fields.date != null or fields.datetime != null;
    const has_time_field = fields.hour != null or fields.time != null or fields.datetime != null;
    if ((kind == .date or kind == .local_date_time or kind == .date_time) and !has_date_field or
        (kind == .local_time or kind == .time) and !has_time_field)
    {
        if (onlyTimezone(entries)) {
            var now = nowParts(self, realtime);
            if (fields.timezone) |name| {
                const zone = selection.zoneNamed(name) catch |err| return fail(self, err);
                const offset = if (zone.zone.len > 0) zones.offsetAt(zone.zone, nowSeconds(self)) catch |err| return fail(self, err) else zone.offset.?;
                const moved = @as(i128, now.days.?) * nanoseconds_per_day + now.nanoseconds.? + @as(i128, offset) * nanoseconds_per_second;
                now = .{ .days = @intCast(@divFloor(moved, nanoseconds_per_day)), .nanoseconds = @intCast(@mod(moved, nanoseconds_per_day)), .offset = offset, .zone = zone.zone };
            }
            return converted(self, kind, now);
        }
    }
    const built = selection.build(kind, fields, nowSeconds(self)) catch |err| return fail(self, err);
    return valueOf(kind, built) catch |err| fail(self, err);
}

fn onlyTimezone(entries: []const MapEntry) bool {
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.key, "timezone")) return false;
    }
    return true;
}

fn fieldsOf(self: *Executor, entries: []const MapEntry) ExecutionError!selection.Fields {
    var fields = selection.Fields{};
    entries: for (entries) |entry| {
        if (entry.value == .null) continue;
        inline for (selection.Fields.names) |name| {
            if (std.mem.eql(u8, entry.key, name[0])) {
                const field = &@field(fields, @tagName(name[1]));
                switch (@TypeOf(field.*)) {
                    ?i64 => field.* = switch (entry.value) {
                        .int => |n| n,
                        else => return typeError(self, "temporal fields take integers"),
                    },
                    ?[]const u8 => field.* = switch (entry.value) {
                        .string => |s| s,
                        else => return typeError(self, "a timezone is a string"),
                    },
                    ?Parts => field.* = partsOf(entry.value) orelse return typeError(self, "date, time and datetime take temporal values"),
                    else => unreachable,
                }
                continue :entries;
            }
        }
        self.fail(.invalid_expression, "unknown temporal field '{s}'", .{entry.key});
        return error.InvalidExpression;
    }
    return fields;
}

/// `date.truncate(unit, value[, fields])`: the value truncated to `unit`,
/// then the fields set; a `timezone` field places the result in that zone.
pub fn truncate(self: *Executor, kind: Kind, arguments: []const Value) ExecutionError!Value {
    if (arguments[0] == .null or arguments[1] == .null) return .{ .null = {} };
    const unit_name = if (arguments[0] == .string) arguments[0].string else return typeError(self, "the truncation unit is a string");
    const unit = selection.unitNamed(unit_name) orelse {
        self.fail(.invalid_expression, "unknown truncation unit '{s}'", .{unit_name});
        return error.InvalidExpression;
    };
    const parts = partsOf(arguments[1]) orelse return typeError(self, "truncate takes a temporal value");
    var truncated = selection.truncate(parts, unit) catch |err| return fail(self, err);
    if (truncated.nanoseconds == null) truncated.nanoseconds = 0;
    var fields = if (arguments.len > 2 and arguments[2] == .map) try fieldsOf(self, arguments[2].map) else selection.Fields{};
    // The truncated wall clock, in the requested zone or the value's own.
    if (fields.timezone == null and truncated.zone.len > 0) fields.timezone = truncated.zone;
    if (fields.timezone == null and truncated.offset != null) fields.timezone = try offsetText(self, truncated.offset.?);
    const unzoned = Parts{ .days = truncated.days, .nanoseconds = truncated.nanoseconds };
    if (kind == .local_time or kind == .time) fields.time = unzoned else if (truncated.days == null) {
        return typeError(self, "a time has no date to truncate to");
    } else {
        fields.datetime = unzoned;
    }
    const built = selection.build(kind, fields, nowSeconds(self)) catch |err| return fail(self, err);
    return valueOf(kind, built) catch |err| fail(self, err);
}

fn offsetText(self: *Executor, offset: i32) ExecutionError![]const u8 {
    var buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    zones.formatOffsetDigits(&writer, offset) catch unreachable;
    return self.allocator.dupe(u8, writer.buffered());
}

/// `datetime.fromepoch(seconds, nanoseconds)`, at UTC.
pub fn fromEpoch(self: *Executor, arguments: []const Value) ExecutionError!Value {
    if (arguments[0] == .null or arguments[1] == .null) return .{ .null = {} };
    if (arguments[0] != .int or arguments[1] != .int) return typeError(self, "fromepoch takes integers");
    const total = @as(i128, arguments[0].int) * nanoseconds_per_second + arguments[1].int;
    return epochDateTime(self, total);
}

/// `datetime.fromepochmillis(milliseconds)`, at UTC.
pub fn fromEpochMillis(self: *Executor, arguments: []const Value) ExecutionError!Value {
    if (arguments[0] == .null) return .{ .null = {} };
    if (arguments[0] != .int) return typeError(self, "fromepochmillis takes an integer");
    return epochDateTime(self, @as(i128, arguments[0].int) * 1_000_000);
}

fn epochDateTime(self: *Executor, nanoseconds: i128) ExecutionError!Value {
    const seconds = @divFloor(nanoseconds, nanoseconds_per_second);
    if (seconds > std.math.maxInt(i64) / 2 or seconds < std.math.minInt(i64) / 2) return fail(self, error.Overflow);
    return .{ .date_time = .{ .seconds = @intCast(seconds), .nanoseconds = @intCast(@mod(nanoseconds, nanoseconds_per_second)), .offset = 0, .zone = "" } };
}

// --- Durations --------------------------------------------------------------------

const duration_units = [_]struct { []const u8, durations.Unit }{
    .{ "years", .years },               .{ "quarters", .quarters },       .{ "months", .months },
    .{ "weeks", .weeks },               .{ "days", .days },               .{ "hours", .hours },
    .{ "minutes", .minutes },           .{ "seconds", .seconds },         .{ "milliseconds", .milliseconds },
    .{ "microseconds", .microseconds }, .{ "nanoseconds", .nanoseconds },
};

/// `duration(map or string)`.
pub fn duration(self: *Executor, arguments: []const Value) ExecutionError!Value {
    switch (arguments[0]) {
        .null => return .{ .null = {} },
        .string => |text| return .{ .duration = parse.duration(text) catch |err| return fail(self, err) },
        .map => |entries| {
            var builder = durations.Builder{};
            entries: for (entries) |entry| {
                for (duration_units) |unit| {
                    if (std.mem.eql(u8, entry.key, unit[0])) {
                        const amount: durations.Number = switch (entry.value) {
                            .int => |n| .{ .int = n },
                            .float => |x| .{ .float = x },
                            .null => continue :entries,
                            else => return typeError(self, "duration fields take numbers"),
                        };
                        builder.add(unit[1], amount) catch |err| return fail(self, err);
                        continue :entries;
                    }
                }
                self.fail(.invalid_expression, "unknown duration field '{s}'", .{entry.key});
                return error.InvalidExpression;
            }
            return .{ .duration = builder.finish() catch |err| return fail(self, err) };
        },
        else => return typeError(self, "duration() takes a map or a string"),
    }
}

/// `duration.between(a, b)` and `duration.inMonths/inDays/inSeconds(a, b)`.
pub fn between(self: *Executor, precision: durations.Precision, arguments: []const Value) ExecutionError!Value {
    if (arguments[0] == .null or arguments[1] == .null) return .{ .null = {} };
    const start = partsOf(arguments[0]) orelse return typeError(self, "duration.between takes temporal values");
    const end = partsOf(arguments[1]) orelse return typeError(self, "duration.between takes temporal values");
    return .{ .duration = durations.between(start, end, precision) catch |err| return fail(self, err) };
}

// --- Components ---------------------------------------------------------------------

/// `value.key` for a temporal value (null if `value` is not one).
pub fn component(self: *Executor, value: Value, key: []const u8) ExecutionError!?Value {
    if (value == .duration) return try durationComponent(self, value.duration, key);
    const parts = partsOf(value) orelse return null;
    if (parts.days) |days| if (dateComponent(days, key)) |n| return .{ .int = n };
    if (parts.nanoseconds) |nanoseconds| if (timeComponent(nanoseconds, key)) |n| return .{ .int = n };
    if (parts.hasZone()) {
        const offset = parts.offset orelse 0;
        if (std.mem.eql(u8, key, "timezone")) return .{ .string = if (parts.zone.len > 0) parts.zone else try offsetText(self, offset) };
        if (std.mem.eql(u8, key, "offset")) return .{ .string = try offsetText(self, offset) };
        if (std.mem.eql(u8, key, "offsetMinutes")) return .{ .int = @divTrunc(offset, 60) };
        if (std.mem.eql(u8, key, "offsetSeconds")) return .{ .int = offset };
    }
    if (value == .date_time) {
        const t = value.date_time;
        if (std.mem.eql(u8, key, "epochSeconds")) return .{ .int = t.seconds };
        if (std.mem.eql(u8, key, "epochMillis")) return .{ .int = t.seconds * 1000 + t.nanoseconds / 1_000_000 };
    }
    self.fail(.invalid_expression, "a temporal value has no component '{s}'", .{key});
    return error.InvalidExpression;
}

fn dateComponent(days: i64, key: []const u8) ?i64 {
    const civil = calendar.civilFromDays(days);
    const table = .{
        .{ "year", civil.year },
        .{ "quarter", @as(i64, calendar.quarter(civil.month)) },
        .{ "month", @as(i64, civil.month) },
        .{ "week", calendar.week(days) },
        .{ "weekYear", calendar.weekYear(days) },
        .{ "day", @as(i64, civil.day) },
        .{ "ordinalDay", calendar.ordinalDay(days) },
        .{ "dayOfWeek", @as(i64, calendar.dayOfWeek(days)) },
        .{ "weekDay", @as(i64, calendar.dayOfWeek(days)) },
        .{ "dayOfQuarter", calendar.dayOfQuarter(days) },
    };
    inline for (table) |entry| if (std.mem.eql(u8, key, entry[0])) return entry[1];
    return null;
}

fn timeComponent(nanoseconds: i64, key: []const u8) ?i64 {
    const seconds = @divFloor(nanoseconds, nanoseconds_per_second);
    const fraction = @mod(nanoseconds, nanoseconds_per_second);
    const table = .{
        .{ "hour", @divFloor(seconds, 3600) },
        .{ "minute", @mod(@divFloor(seconds, 60), 60) },
        .{ "second", @mod(seconds, 60) },
        .{ "millisecond", @divFloor(fraction, 1_000_000) },
        .{ "microsecond", @divFloor(fraction, 1_000) },
        .{ "nanosecond", fraction },
    };
    inline for (table) |entry| if (std.mem.eql(u8, key, entry[0])) return entry[1];
    return null;
}

fn durationComponent(self: *Executor, d: types.Duration, key: []const u8) ExecutionError!Value {
    const s = d.seconds;
    const n: i64 = d.nanoseconds;
    const table = .{
        .{ "years", @divTrunc(d.months, 12) },
        .{ "quarters", @divTrunc(d.months, 3) },
        .{ "months", d.months },
        .{ "weeks", @divTrunc(d.days, 7) },
        .{ "days", d.days },
        .{ "hours", @divTrunc(s, 3600) },
        .{ "minutes", @divTrunc(s, 60) },
        .{ "seconds", s },
        .{ "milliseconds", s * 1000 + @divTrunc(n, 1_000_000) },
        .{ "microseconds", s * 1_000_000 + @divTrunc(n, 1_000) },
        .{ "nanoseconds", s * nanoseconds_per_second + n },
        .{ "quartersOfYear", @divTrunc(@rem(d.months, 12), 3) },
        .{ "monthsOfQuarter", @rem(d.months, 3) },
        .{ "monthsOfYear", @rem(d.months, 12) },
        .{ "daysOfWeek", @rem(d.days, 7) },
        .{ "minutesOfHour", @rem(@divTrunc(s, 60), 60) },
        .{ "secondsOfMinute", @rem(s, 60) },
        .{ "millisecondsOfSecond", @divTrunc(n, 1_000_000) },
        .{ "microsecondsOfSecond", @divTrunc(n, 1_000) },
        .{ "nanosecondsOfSecond", n },
    };
    inline for (table) |entry| if (std.mem.eql(u8, key, entry[0])) return .{ .int = entry[1] };
    self.fail(.invalid_expression, "a duration has no component '{s}'", .{key});
    return error.InvalidExpression;
}

// --- Arithmetic ---------------------------------------------------------------------

pub fn isTemporal(value: Value) bool {
    return switch (value) {
        .date, .local_time, .time, .local_date_time, .date_time, .duration => true,
        else => false,
    };
}

/// `+ - * /` with a temporal operand: a duration added to or subtracted
/// from a temporal value or another duration, or scaled by a number.
pub fn arithmetic(self: *Executor, operator: BinaryOperator, left: Value, right: Value) ExecutionError!Value {
    const result = switch (operator) {
        .add => if (right == .duration) addDuration(left, right.duration) else if (left == .duration) addDuration(right, left.duration) else return typeError(self, "only a duration can be added to a temporal value"),
        .subtract => if (right == .duration) addDuration(left, right.duration.negate()) else return typeError(self, "only a duration can be subtracted from a temporal value"),
        .multiply => if (left == .duration and number(right) != null)
            Value{ .duration = durations.multiply(left.duration, number(right).?) catch |err| return fail(self, err) }
        else if (right == .duration and number(left) != null)
            Value{ .duration = durations.multiply(right.duration, number(left).?) catch |err| return fail(self, err) }
        else
            return typeError(self, "a duration can be multiplied only by a number"),
        .divide => if (left == .duration and number(right) != null)
            Value{ .duration = durations.divide(left.duration, number(right).?) catch |err| return fail(self, err) }
        else
            return typeError(self, "a duration can be divided only by a number"),
        else => return typeError(self, "this operator does not apply to temporal values"),
    };
    return result catch |err| fail(self, err);
}

fn number(value: Value) ?durations.Number {
    return switch (value) {
        .int => |n| .{ .int = n },
        .float => |x| .{ .float = x },
        else => null,
    };
}

fn addDuration(value: Value, d: types.Duration) TemporalError!Value {
    return switch (value) {
        .duration => |other| .{ .duration = try durations.add(other, d) },
        .date => |date| .{ .date = try durations.addToDate(date, d) },
        .local_time => |t| .{ .local_time = durations.addToLocalTime(t, d) },
        .time => |t| .{ .time = durations.addToTime(t, d) },
        .local_date_time => |t| .{ .local_date_time = try durations.addToLocalDateTime(t, d) },
        .date_time => |t| .{ .date_time = try durations.addToDateTime(t, d) },
        else => error.InvalidTemporal,
    };
}
