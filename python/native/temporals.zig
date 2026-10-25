//! Temporal values between the engine and Python's `datetime` module,
//! converted field by field (no text in between).
//!
//! | Engine          | Python                                             |
//! | --------------- | -------------------------------------------------- |
//! | date            | `datetime.date`                                    |
//! | local time      | `datetime.time` (naive)                            |
//! | time            | `datetime.time` with a fixed-offset `timezone`     |
//! | local date-time | `datetime.datetime` (naive)                        |
//! | date-time       | `datetime.datetime` in its `ZoneInfo` zone, or at its fixed offset |
//! | duration        | `datetime.timedelta`; `zypherdb.Duration` when it has months |
//!
//! Python's types stop at microseconds and at years 1 to 9999: nanoseconds
//! are truncated, and a year outside that range raises `ValueError` (a
//! database opened with `temporals="iso"` returns the exact ISO 8601 text
//! instead).

const std = @import("std");
const zypherdb = @import("zypherdb");
const py = @import("python");

const Value = zypherdb.Value;
const types = zypherdb.temporal.types;
const calendar = zypherdb.temporal.calendar;
const zones = zypherdb.temporal.zones;

const nanoseconds_per_second = calendar.nanoseconds_per_second;

/// The `datetime`-module classes and ZypherDB's `Duration`, registered by
/// `configure` (new references, kept for the life of the process).
pub const Classes = struct {
    date: ?*py.PyObject = null,
    time: ?*py.PyObject = null,
    datetime: ?*py.PyObject = null,
    timedelta: ?*py.PyObject = null,
    timezone: ?*py.PyObject = null,
    zone_info: ?*py.PyObject = null,
    duration: ?*py.PyObject = null,
};

pub var classes = Classes{};
/// `timezone` objects by offset and `ZoneInfo` objects by name, made once.
var time_zones: ?*py.PyObject = null;

pub fn configure(table: ?*py.PyObject) bool {
    inline for (@typeInfo(Classes).@"struct".field_names) |name| {
        const entry = py.PyDict_GetItemString(table, name) orelse {
            py.PyErr_SetString(py.PyExc_KeyError, "configure: missing " ++ name);
            return false;
        };
        py.Py_IncRef(entry);
        @field(classes, name) = entry;
    }
    time_zones = py.PyDict_New() orelse return false;
    return true;
}

// --- Engine -> Python ----------------------------------------------------------

/// The Python value of a temporal `value` (a new reference; null with an
/// exception set). With `iso`, its ISO 8601 text.
pub fn toPython(value: Value, iso: bool) ?*py.PyObject {
    if (iso) return isoText(value);
    return switch (value) {
        .date => |d| date: {
            const civil = calendar.civilFromDays(d.days);
            if (!representable(civil.year)) break :date outOfRange(value);
            break :date call(classes.date, &.{ int(civil.year), int(civil.month), int(civil.day) });
        },
        .local_time => |t| clock(t.nanoseconds, null),
        .time => |t| clock(t.nanoseconds, fixedZone(t.offset) orelse return null),
        .local_date_time => |t| localDateTime(t, null, value),
        .date_time => |t| dateTime(t, value),
        .duration => |d| if (d.months == 0)
            call(classes.timedelta, &.{ int(d.days), int(d.seconds), int(@divTrunc(d.nanoseconds, 1000)) })
        else
            call(classes.duration, &.{ int(d.months), int(d.days), int(d.seconds), int(d.nanoseconds) }),
        else => unreachable,
    };
}

fn isoText(value: Value) ?*py.PyObject {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    switch (value) {
        inline .date, .local_time, .time, .local_date_time, .date_time, .duration => |t| t.format(&writer) catch {
            py.PyErr_SetString(py.PyExc_ValueError, "temporal value too long");
            return null;
        },
        else => unreachable,
    }
    const text = writer.buffered();
    return py.PyUnicode_FromStringAndSize(text.ptr, @intCast(text.len));
}

fn representable(year: i64) bool {
    return year >= 1 and year <= 9999;
}

fn outOfRange(value: Value) ?*py.PyObject {
    var buffer: [160]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    writer.writeAll("cannot be a Python datetime value (years 1-9999 only): ") catch {};
    switch (value) {
        inline .date, .local_date_time, .date_time => |t| t.format(&writer) catch {},
        else => {},
    }
    writer.writeByte(0) catch {};
    py.PyErr_SetString(py.PyExc_ValueError, @ptrCast(writer.buffered().ptr));
    return null;
}

fn int(n: anytype) ?*py.PyObject {
    return py.PyLong_FromLongLong(@intCast(n));
}

/// `function(*arguments)`, taking ownership of the arguments.
fn call(function: ?*py.PyObject, arguments: []const ?*py.PyObject) ?*py.PyObject {
    const tuple = py.PyTuple_New(@intCast(arguments.len));
    var failed = tuple == null;
    for (arguments, 0..) |argument, i| {
        if (argument) |a| {
            if (tuple) |t| _ = py.PyTuple_SetItem(t, @intCast(i), a) else py.Py_DecRef(a);
        } else failed = true;
    }
    if (failed) {
        if (tuple) |t| py.Py_DecRef(t);
        return null;
    }
    defer py.Py_DecRef(tuple);
    return py.PyObject_Call(function, tuple, null);
}

/// A time of day, naive or in `zone` (borrowed).
fn clock(nanoseconds: i64, zone: ?*py.PyObject) ?*py.PyObject {
    const seconds = @divFloor(nanoseconds, nanoseconds_per_second);
    const microseconds = @divFloor(@mod(nanoseconds, nanoseconds_per_second), 1000);
    const hour = int(@divFloor(seconds, 3600));
    const minute = int(@mod(@divFloor(seconds, 60), 60));
    const second = int(@mod(seconds, 60));
    if (zone) |z| {
        py.Py_IncRef(z);
        return call(classes.time, &.{ hour, minute, second, int(microseconds), z });
    }
    return call(classes.time, &.{ hour, minute, second, int(microseconds) });
}

/// A wall-clock date and time, naive or in `zone` (borrowed).
fn localDateTime(t: types.LocalDateTime, zone: ?*py.PyObject, original: Value) ?*py.PyObject {
    const civil = calendar.civilFromDays(t.date().days);
    if (!representable(civil.year)) return outOfRange(original);
    const seconds = @mod(t.seconds, calendar.seconds_per_day);
    const arguments = [_]?*py.PyObject{
        int(civil.year),                     int(civil.month),                      int(civil.day),
        int(@divFloor(seconds, 3600)),       int(@mod(@divFloor(seconds, 60), 60)), int(@mod(seconds, 60)),
        int(@divFloor(t.nanoseconds, 1000)),
    };
    if (zone) |z| {
        py.Py_IncRef(z);
        return call(classes.datetime, &(arguments ++ [_]?*py.PyObject{z}));
    }
    return call(classes.datetime, &arguments);
}

/// A date-time in its named zone (`ZoneInfo`), or at its fixed offset. In a
/// named zone it is built from the instant (UTC, then `astimezone`), so an
/// ambiguous wall-clock time gets the right `fold`.
fn dateTime(t: types.DateTime, original: Value) ?*py.PyObject {
    if (t.zone.len > 0) {
        if (namedZone(t.zone)) |zone| {
            const utc = fixedZone(0) orelse return null;
            const instant = localDateTime(.{ .seconds = t.seconds, .nanoseconds = t.nanoseconds }, utc, original) orelse return null;
            defer py.Py_DecRef(instant);
            return py.PyObject_CallMethod(instant, "astimezone", "O", zone);
        }
        // The zone is unknown to Python's time zone database: its offset still holds.
        py.PyErr_Clear();
    }
    return localDateTime(t.local(), fixedZone(t.offset) orelse return null, original);
}

/// The `timezone` of a fixed offset (borrowed from the cache).
fn fixedZone(offset: i32) ?*py.PyObject {
    const key = py.PyLong_FromLong(offset) orelse return null;
    defer py.Py_DecRef(key);
    if (py.PyDict_GetItem(time_zones, key)) |zone| return zone;
    const delta = call(classes.timedelta, &.{ int(0), int(offset) }) orelse return null;
    const zone = call(classes.timezone, &.{delta}) orelse return null;
    defer py.Py_DecRef(zone);
    if (py.PyDict_SetItem(time_zones, key, zone) != 0) return null;
    return py.PyDict_GetItem(time_zones, key);
}

/// The `ZoneInfo` of a zone name (borrowed from the cache); null with an
/// exception set if Python does not know the zone.
fn namedZone(name: []const u8) ?*py.PyObject {
    const key = py.PyUnicode_FromStringAndSize(name.ptr, @intCast(name.len)) orelse return null;
    defer py.Py_DecRef(key);
    if (py.PyDict_GetItem(time_zones, key)) |zone| return zone;
    py.Py_IncRef(key);
    const zone = call(classes.zone_info, &.{key}) orelse return null;
    defer py.Py_DecRef(zone);
    if (py.PyDict_SetItem(time_zones, key, zone) != 0) return null;
    return py.PyDict_GetItem(time_zones, key);
}

// --- Python -> engine ----------------------------------------------------------

pub const Conversion = union(enum) { value: Value, not_temporal, failed };

/// A `datetime`-module value or a `zypherdb.Duration` as an engine value.
pub fn fromPython(object: *py.PyObject) Conversion {
    // `datetime` is a subclass of `date`: test it first.
    if (isInstance(object, classes.datetime)) return dateTimeOf(object);
    if (isInstance(object, classes.date)) {
        const days = daysOf(object) orelse return .failed;
        return .{ .value = .{ .date = .{ .days = days } } };
    }
    if (isInstance(object, classes.time)) {
        const nanoseconds = clockOf(object) orelse return .failed;
        const offset = offsetOf(object) orelse return .failed;
        if (offset) |o| return .{ .value = .{ .time = .{ .nanoseconds = nanoseconds, .offset = o } } };
        return .{ .value = .{ .local_time = .{ .nanoseconds = nanoseconds } } };
    }
    if (isInstance(object, classes.timedelta)) {
        const days = attribute(object, "days") orelse return .failed;
        const seconds = attribute(object, "seconds") orelse return .failed;
        const microseconds = attribute(object, "microseconds") orelse return .failed;
        return .{ .value = .{ .duration = types.Duration.init(0, days, @as(i128, seconds) * nanoseconds_per_second + microseconds * 1000) } };
    }
    if (isInstance(object, classes.duration)) {
        const months = attribute(object, "months") orelse return .failed;
        const days = attribute(object, "days") orelse return .failed;
        const seconds = attribute(object, "seconds") orelse return .failed;
        const nanoseconds = attribute(object, "nanoseconds") orelse return .failed;
        return .{ .value = .{ .duration = types.Duration.init(months, days, @as(i128, seconds) * nanoseconds_per_second + nanoseconds) } };
    }
    return .not_temporal;
}

fn isInstance(object: *py.PyObject, class: ?*py.PyObject) bool {
    return py.PyObject_IsInstance(object, class) == 1;
}

/// An integer attribute (`date.year`); null with an exception set.
fn attribute(object: *py.PyObject, comptime name: [:0]const u8) ?i64 {
    const value = py.PyObject_GetAttrString(object, name) orelse return null;
    defer py.Py_DecRef(value);
    const n = py.PyLong_AsLongLong(value);
    if (n == -1 and py.PyErr_Occurred() != null) return null;
    return n;
}

fn daysOf(object: *py.PyObject) ?i64 {
    const year = attribute(object, "year") orelse return null;
    const month = attribute(object, "month") orelse return null;
    const day = attribute(object, "day") orelse return null;
    return calendar.daysFromCivil(year, @intCast(month), @intCast(day));
}

fn clockOf(object: *py.PyObject) ?i64 {
    const hour = attribute(object, "hour") orelse return null;
    const minute = attribute(object, "minute") orelse return null;
    const second = attribute(object, "second") orelse return null;
    const microsecond = attribute(object, "microsecond") orelse return null;
    return ((hour * 60 + minute) * 60 + second) * nanoseconds_per_second + microsecond * 1000;
}

/// The UTC offset in seconds (`utcoffset()`), or null for a naive value;
/// the outer null means an exception is set.
fn offsetOf(object: *py.PyObject) ??i32 {
    const delta = py.PyObject_CallMethod(object, "utcoffset", null) orelse return null;
    defer py.Py_DecRef(delta);
    if (delta == @as(*py.PyObject, @ptrCast(&py._Py_NoneStruct))) return @as(?i32, null);
    const days = attribute(delta, "days") orelse return null;
    const seconds = attribute(delta, "seconds") orelse return null;
    return @as(?i32, @intCast(days * calendar.seconds_per_day + seconds));
}

fn dateTimeOf(object: *py.PyObject) Conversion {
    const days = daysOf(object) orelse return .failed;
    const nanoseconds = clockOf(object) orelse return .failed;
    const local = types.LocalDateTime.init(.{ .days = days }, .{ .nanoseconds = nanoseconds });
    const offset = (offsetOf(object) orelse return .failed) orelse return .{ .value = .{ .local_date_time = local } };
    const instant = local.seconds - offset;
    // A `ZoneInfo` zone keeps its name when the engine knows the zone.
    const zone = zoneNameOf(object) orelse return .failed;
    if (zone) |name| {
        if (zones.canonicalName(name)) |canonical| {
            const zone_offset = zones.offsetAt(canonical, instant) catch offset;
            return .{ .value = .{ .date_time = .{ .seconds = instant, .nanoseconds = local.nanoseconds, .offset = zone_offset, .zone = canonical } } };
        } else |_| {}
    }
    return .{ .value = .{ .date_time = .{ .seconds = instant, .nanoseconds = local.nanoseconds, .offset = offset, .zone = "" } } };
}

/// The name of a `ZoneInfo` time zone (its `key`), or null for another
/// kind; the outer null means an exception is set. The name points into a
/// string kept alive by the zone object, which the value outlives only
/// within the call (zone names are copied by the engine's zone cache).
fn zoneNameOf(object: *py.PyObject) ??[]const u8 {
    const tzinfo = py.PyObject_GetAttrString(object, "tzinfo") orelse return null;
    defer py.Py_DecRef(tzinfo);
    if (!isInstance(tzinfo, classes.zone_info)) return @as(?[]const u8, null);
    const key = py.PyObject_GetAttrString(tzinfo, "key") orelse return null;
    defer py.Py_DecRef(key);
    const bytes = py.PyUnicode_AsUTF8String(key) orelse return null;
    defer py.Py_DecRef(bytes);
    var pointer: [*c]u8 = undefined;
    var length: py.Py_ssize_t = 0;
    if (py.PyBytes_AsStringAndSize(bytes, &pointer, &length) != 0) return null;
    // Look the zone up now, while the bytes are alive: the canonical name
    // returned below belongs to the engine's zone cache.
    const canonical = zones.canonicalName(pointer[0..@intCast(length)]) catch return @as(?[]const u8, null);
    return @as(?[]const u8, canonical);
}

/// Renders a duration as ISO 8601 text (`zypherdb.Duration.__str__`).
pub fn durationText(months: i64, days: i64, seconds: i64, nanoseconds: u32) ?*py.PyObject {
    return isoText(.{ .duration = .{ .months = months, .days = days, .seconds = seconds, .nanoseconds = nanoseconds } });
}
