//! Time zones: fixed UTC offsets (`+01:00`) and named IANA zones
//! (`Europe/Stockholm`).
//!
//! A named zone's rules come from the IANA time zone database embedded in
//! the library (`vendor/tzdata`, from the tzdata Python package), never the
//! system's, so a zone's history is the same on every machine: its
//! transitions, and the POSIX TZ rule in the file's footer for instants
//! after the last one. Each zone is parsed once per process and kept.

const std = @import("std");
const Tz = std.Tz;
const calendar = @import("calendar.zig");
const tzdata = @import("tzdata");

pub const Error = error{ UnknownTimeZone, InvalidOffset } || std.mem.Allocator.Error;

/// Offsets are limited to ±18:00, as in ISO 8601 and Java.
pub const max_offset_seconds: i32 = 18 * 3600;

/// The offset, in seconds east of UTC, of an offset text: `Z`, `+01`,
/// `+0100`, `+01:00`, `-01:30:15`. Null if `text` is not one.
pub fn parseOffset(text: []const u8) ?i32 {
    if (text.len == 1 and (text[0] == 'Z' or text[0] == 'z')) return 0;
    if (text.len < 3 or (text[0] != '+' and text[0] != '-')) return null;
    const sign: i32 = if (text[0] == '-') -1 else 1;
    var parts: [3]i32 = .{ 0, 0, 0 };
    var count: usize = 0;
    var i: usize = 1;
    while (i < text.len) {
        if (count == 3) return null;
        if (count > 0 and text[i] == ':') i += 1;
        if (i + 2 > text.len or !std.ascii.isDigit(text[i]) or !std.ascii.isDigit(text[i + 1])) return null;
        parts[count] = (text[i] - '0') * 10 + (text[i + 1] - '0');
        count += 1;
        i += 2;
    }
    if (parts[1] >= 60 or parts[2] >= 60) return null;
    const seconds = sign * (parts[0] * 3600 + parts[1] * 60 + parts[2]);
    if (seconds > max_offset_seconds or seconds < -max_offset_seconds) return null;
    return seconds;
}

/// Writes an offset as `Z`, `+01:00` or, with seconds, `+01:00:15`.
pub fn formatOffset(writer: *std.Io.Writer, offset: i32) std.Io.Writer.Error!void {
    if (offset == 0) return writer.writeByte('Z');
    try formatOffsetDigits(writer, offset);
}

/// Like `formatOffset`, but `+00:00` for UTC (the `offset` accessor's form).
pub fn formatOffsetDigits(writer: *std.Io.Writer, offset: i32) std.Io.Writer.Error!void {
    const magnitude: u32 = @abs(offset);
    try writer.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (offset < 0) '-' else '+'), magnitude / 3600, magnitude / 60 % 60 });
    if (magnitude % 60 != 0) try writer.print(":{d:0>2}", .{magnitude % 60});
}

/// True if `name` could be a zone name (and is safe to look up as a path).
pub fn isZoneName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '/' or std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/_+-", c) == null) return false;
    }
    return true;
}

/// The name of a known zone, owned by the zone cache (names match exactly,
/// case included, as in Java). Fails if the zone is unknown.
pub fn canonicalName(name: []const u8) Error![]const u8 {
    return (try load(name)).name;
}

/// The offset of zone `name` at the instant `utc_seconds` (seconds since
/// 1970-01-01T00:00Z).
pub fn offsetAt(name: []const u8, utc_seconds: i64) Error!i32 {
    return (try load(name)).offsetAt(utc_seconds);
}

/// The instant at which the wall-clock time `local_seconds` (seconds since
/// 1970-01-01T00:00 local) happens in zone `name`. In an overlap (clocks set
/// back) the earlier of the two instants; in a gap (clocks set forward), the
/// time moved later by the gap's length. Both as in java.time.
pub fn resolveLocal(name: []const u8, local_seconds: i64) Error!i64 {
    const zone = try load(name);
    // Assumes at most one transition within a day either side.
    const offset_before = zone.offsetAt(local_seconds - calendar.seconds_per_day);
    const offset_after = zone.offsetAt(local_seconds + calendar.seconds_per_day);
    if (zone.offsetAt(local_seconds - offset_before) == offset_before) return local_seconds - offset_before;
    if (zone.offsetAt(local_seconds - offset_after) == offset_after) return local_seconds - offset_after;
    return local_seconds - offset_before; // in a gap
}

// --- The zone cache -----------------------------------------------------------

const Zone = struct {
    name: []const u8,
    tz: Tz,
    rule: ?PosixRule,

    fn offsetAt(self: *const Zone, utc_seconds: i64) i32 {
        const transitions = self.tz.transitions;
        if (transitions.len == 0 or utc_seconds < transitions[0].ts) {
            // Before the first transition: local mean time, the first type.
            if (transitions.len == 0) if (self.rule) |rule| return rule.offsetAt(utc_seconds);
            return if (self.tz.timetypes.len > 0) self.tz.timetypes[0].offset else 0;
        }
        if (utc_seconds >= transitions[transitions.len - 1].ts) {
            if (self.rule) |rule| return rule.offsetAt(utc_seconds);
            return transitions[transitions.len - 1].timetype.offset;
        }
        // The last transition at or before the instant.
        var low: usize = 0;
        var high: usize = transitions.len - 1;
        while (low < high) {
            const middle = (low + high + 1) / 2;
            if (transitions[middle].ts <= utc_seconds) low = middle else high = middle - 1;
        }
        return transitions[low].timetype.offset;
    }
};

var cache_mutex: std.Io.Mutex = .init;
var cache: std.StringHashMapUnmanaged(*Zone) = .empty;
const cache_allocator = std.heap.page_allocator;

fn load(name: []const u8) Error!*Zone {
    if (!isZoneName(name)) return error.UnknownTimeZone;
    const io = std.Io.Threaded.global_single_threaded.io();
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    if (cache.get(name)) |zone| return zone;

    var reader = std.Io.Reader.fixed(zoneFile(name) orelse return error.UnknownTimeZone);
    const tz = Tz.parse(cache_allocator, &reader) catch return error.UnknownTimeZone;
    const zone = try cache_allocator.create(Zone);
    zone.* = .{
        .name = try cache_allocator.dupe(u8, name),
        .tz = tz,
        .rule = if (tz.footer) |footer| PosixRule.parse(footer) else null,
    };
    try cache.put(cache_allocator, zone.name, zone);
    return zone;
}

/// The embedded TZif file of zone `name` (exact, case included), by binary
/// search of the sorted names. O(log zones).
fn zoneFile(name: []const u8) ?[]const u8 {
    var low: usize = 0;
    var high: usize = tzdata.zones.len;
    while (low < high) {
        const middle = (low + high) / 2;
        const zone = tzdata.zones[middle];
        switch (std.mem.order(u8, zone.name, name)) {
            .lt => low = middle + 1,
            .gt => high = middle,
            .eq => return tzdata.bytes[zone.start..][0..zone.length],
        }
    }
    return null;
}

// --- POSIX TZ rules (RFC 8536 footers) ------------------------------------

/// `STD offset [DST [offset] [,start[/time],end[/time]]]`, e.g.
/// `CET-1CEST,M3.5.0,M10.5.0/3`. POSIX offsets count west of UTC, so their
/// sign is the reverse of ours. Only `Mm.w.d` dates are supported (the form
/// every current zone uses); anything else is treated as standard time.
const PosixRule = struct {
    standard_offset: i32,
    daylight: ?struct { offset: i32, start: RuleDate, end: RuleDate },

    const RuleDate = struct { month: u8, week: u8, weekday: u8, seconds: i32 };

    fn parse(text: []const u8) ?PosixRule {
        var parser = Parser{ .text = text };
        if (!parser.skipName()) return null;
        const standard = -(parser.offset() orelse return null);
        if (parser.done()) return .{ .standard_offset = standard, .daylight = null };
        if (!parser.skipName()) return null;
        const daylight = if (parser.peek() != ',') -(parser.offset() orelse return null) else standard + 3600;
        if (!parser.eat(',')) return .{ .standard_offset = standard, .daylight = null };
        const start = parser.ruleDate() orelse return .{ .standard_offset = standard, .daylight = null };
        if (!parser.eat(',')) return null;
        const end = parser.ruleDate() orelse return .{ .standard_offset = standard, .daylight = null };
        return .{ .standard_offset = standard, .daylight = .{ .offset = daylight, .start = start, .end = end } };
    }

    fn offsetAt(self: PosixRule, utc_seconds: i64) i32 {
        const daylight = self.daylight orelse return self.standard_offset;
        const year = calendar.civilFromDays(@divFloor(utc_seconds + self.standard_offset, calendar.seconds_per_day)).year;
        // The transitions are given in the local time in force before each.
        const start = localSeconds(year, daylight.start) - self.standard_offset;
        const end = localSeconds(year, daylight.end) - daylight.offset;
        const in_daylight = if (start < end)
            utc_seconds >= start and utc_seconds < end
        else // southern hemisphere: daylight time spans New Year
            utc_seconds >= start or utc_seconds < end;
        return if (in_daylight) daylight.offset else self.standard_offset;
    }

    /// The local time of `rule_date` in `year`: the `week`-th (5: last)
    /// `weekday` (0: Sunday) of `month`, plus its time of day.
    fn localSeconds(year: i64, rule_date: RuleDate) i64 {
        const first = calendar.daysFromCivil(year, rule_date.month, 1);
        const first_weekday = calendar.dayOfWeek(first) % 7; // 0: Sunday
        var day = first + @mod(@as(i64, rule_date.weekday) - first_weekday, 7) + (@as(i64, rule_date.week) - 1) * 7;
        const last = first + calendar.daysInMonth(year, rule_date.month) - 1;
        while (day > last) day -= 7;
        return day * calendar.seconds_per_day + rule_date.seconds;
    }

    const Parser = struct {
        text: []const u8,
        position: usize = 0,

        fn done(self: *const Parser) bool {
            return self.position >= self.text.len;
        }

        fn peek(self: *const Parser) u8 {
            return if (self.done()) 0 else self.text[self.position];
        }

        fn eat(self: *Parser, c: u8) bool {
            if (self.peek() != c) return false;
            self.position += 1;
            return true;
        }

        /// A zone abbreviation: letters, or anything inside `<...>`.
        fn skipName(self: *Parser) bool {
            const start = self.position;
            if (self.eat('<')) {
                while (!self.done() and self.peek() != '>') self.position += 1;
                return self.eat('>');
            }
            while (std.ascii.isAlphabetic(self.peek())) self.position += 1;
            return self.position - start >= 3;
        }

        /// `[+-]h[h][:mm[:ss]]`, in seconds.
        fn offset(self: *Parser) ?i32 {
            var sign: i32 = 1;
            if (self.eat('-')) sign = -1 else _ = self.eat('+');
            const hours = self.number() orelse return null;
            var seconds = hours * 3600;
            if (self.eat(':')) seconds += (self.number() orelse return null) * 60;
            if (self.eat(':')) seconds += self.number() orelse return null;
            return sign * seconds;
        }

        fn number(self: *Parser) ?i32 {
            const start = self.position;
            var value: i32 = 0;
            while (std.ascii.isDigit(self.peek()) and self.position - start < 3) : (self.position += 1) {
                value = value * 10 + (self.text[self.position] - '0');
            }
            return if (self.position == start) null else value;
        }

        /// `Mm.w.d[/time]`.
        fn ruleDate(self: *Parser) ?RuleDate {
            if (!self.eat('M')) return null;
            const month = self.number() orelse return null;
            if (!self.eat('.')) return null;
            const week_number = self.number() orelse return null;
            if (!self.eat('.')) return null;
            const weekday = self.number() orelse return null;
            if (month < 1 or month > 12 or week_number < 1 or week_number > 5 or weekday > 6) return null;
            const seconds = if (self.eat('/')) self.offset() orelse return null else 2 * 3600;
            return .{ .month = @intCast(month), .week = @intCast(week_number), .weekday = @intCast(weekday), .seconds = seconds };
        }
    };
};

test "offsets parse and print" {
    try std.testing.expectEqual(@as(?i32, 3600), parseOffset("+01:00"));
    try std.testing.expectEqual(@as(?i32, 3600), parseOffset("+0100"));
    try std.testing.expectEqual(@as(?i32, -7200), parseOffset("-02"));
    try std.testing.expectEqual(@as(?i32, -(2 * 3600 + 5 * 60 + 7)), parseOffset("-02:05:07"));
    try std.testing.expectEqual(@as(?i32, 0), parseOffset("Z"));
    try std.testing.expectEqual(@as(?i32, null), parseOffset("+19:00"));
    try std.testing.expectEqual(@as(?i32, null), parseOffset("Europe/Stockholm"));
}

test "POSIX rules give daylight saving time between their transitions" {
    const rule = PosixRule.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    // 2040-07-01T12:00Z is summer; 2040-01-01T12:00Z winter.
    try std.testing.expectEqual(@as(i32, 7200), rule.offsetAt(2_224_670_400));
    try std.testing.expectEqual(@as(i32, 3600), rule.offsetAt(2_208_988_800 + 43_200));
    try std.testing.expectEqual(@as(i32, -36000), PosixRule.parse("HST10").?.offsetAt(0));
}
