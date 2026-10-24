//! Temporal values: construction, components, arithmetic, comparison,
//! storage and time zones, through queries.

const std = @import("std");
const testing = std.testing;
const acmedb = @import("acmedb");

const Ast = acmedb.Ast;
const Graph = acmedb.Graph;
const Value = acmedb.Value;

const support = @import("../support.zig");
const openStore = support.openStore;
const expectQuery = support.expectQuery;
const expectOrdered = support.expectOrdered;
const expectQueryError = support.expectQueryError;

fn int(n: i64) Value {
    return .{ .int = n };
}

fn string(s: []const u8) Value {
    return .{ .string = s };
}

fn boolean(b: bool) Value {
    return .{ .boolean = b };
}

test "temporal values are built from strings and maps and print as ISO 8601" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\RETURN toString(date('2015-W30-2')), toString(localtime('214032.142')),
        \\       toString(time('21:40-01:30')), toString(localdatetime({year: 1984, ordinalDay: 202, hour: 12})),
        \\       toString(datetime('2015-07-21T21:40:32.142[Europe/London]')), toString(duration({months: 0.75}))
    , &.{&.{
        string("2015-07-21"),                                   string("21:40:32.142"),
        string("21:40-01:30"),                                  string("1984-07-20T12:00"),
        string("2015-07-21T21:40:32.142+01:00[Europe/London]"), string("P22DT19H51M49.5S"),
    }});
    // A base value with fields replaced; a zoned base converted to a new zone.
    try expectQuery(&ast, &g,
        \\WITH date({year: 1984, month: 11, day: 11}) AS d, time({hour: 12, timezone: '+01:00'}) AS t
        \\RETURN toString(date({date: d, week: 1})), toString(time({time: t, timezone: '+05:00'}))
    , &.{&.{ string("1984-01-08"), string("16:00+05:00") }});
    try expectQueryError(&ast, &g, "RETURN date('2015-02-30')", error.InvalidExpression);
    try expectQueryError(&ast, &g, "RETURN datetime({year: 2020, timezone: 'Nowhere/Atlantis'})", error.InvalidExpression);
    try expectQuery(&ast, &g, "RETURN date(null), duration(null)", &.{&.{ .{ .null = {} }, .{ .null = {} } }});
}

test "components, arithmetic and comparison" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\WITH datetime('1984-11-11T12:31:14.645876123+01:00[Europe/Stockholm]') AS d
        \\RETURN d.year, d.week, d.dayOfWeek, d.hour, d.nanosecond, d.timezone, d.offsetMinutes, d.epochSeconds
    , &.{&.{ int(1984), int(45), int(7), int(12), int(645876123), string("Europe/Stockholm"), int(60), int(469020674) }});
    // Months clamp to the end of the month; time is added to the instant.
    try expectQuery(&ast, &g,
        \\RETURN toString(date('2020-01-31') + duration('P1M')),
        \\       toString(datetime('2017-10-28T12:00[Europe/Stockholm]') + duration('PT24H')),
        \\       toString(datetime('2017-10-28T12:00[Europe/Stockholm]') + duration('P1D')),
        \\       toString(duration('PT1H') * 1.5), toString(localtime('23:00') + duration('PT2H'))
    , &.{&.{
        string("2020-02-29"),
        string("2017-10-29T11:00+01:00[Europe/Stockholm]"),
        string("2017-10-29T12:00+01:00[Europe/Stockholm]"),
        string("PT1H30M"),
        string("01:00"),
    }});
    // Date-times compare by instant; durations only for equality.
    try expectQuery(&ast, &g,
        \\RETURN datetime('2020-01-01T12:00+01:00') < datetime('2020-01-01T11:30Z'),
        \\       date('2020-01-01') < date('2020-01-02'), duration('PT60S') = duration('PT1M'),
        \\       duration('P1M') < duration('P2M'), date('2020-01-01') < localtime('12:00')
    , &.{&.{ boolean(true), boolean(true), boolean(true), .{ .null = {} }, .{ .null = {} } }});
    try expectQuery(&ast, &g,
        \\RETURN toString(duration.between(date('1984-10-11'), date('2015-06-24'))),
        \\       toString(duration.inDays(date('1984-10-11'), date('2015-06-24')))
    , &.{&.{ string("P30Y8M13D"), string("P11213D") }});
    try expectQueryError(&ast, &g, "RETURN date('2020-01-01') + 1", error.TypeMismatch);
}

test "temporal properties are stored, indexed and ordered" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\CREATE (:Badge {id: 1, issued: date('2024-03-01'), shifts: [localtime('09:00'), localtime('18:00')]}),
        \\       (:Badge {id: 2, issued: date('2023-12-15'), shifts: [localtime('22:00')]})
    , &.{});
    try expectQuery(&ast, &g, "MATCH (b:Badge {issued: date('2024-03-01')}) RETURN b.id, size(b.shifts)", &.{&.{ int(1), int(2) }});
    try expectOrdered(&ast, &g, "MATCH (b:Badge) RETURN b.id ORDER BY b.issued", &.{ &.{int(2)}, &.{int(1)} });
}

test "an access-control rule: weekdays from 9:00 to 18:00, local time" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    try expectQuery(&ast, &g,
        \\CREATE (:Group {name: 'engineering'})-[:MAY_ENTER {days: [1, 2, 3, 4, 5], from: localtime('09:00'), until: localtime('18:00'), zone: 'Europe/Madrid'}]->(:Zone {name: 'floor 3'})
    , &.{});
    // Cypher does not chain comparisons (`a <= b < c`): each is spelt out.
    const query =
        \\MATCH (:Group {name: 'engineering'})-[w:MAY_ENTER]->(:Zone {name: 'floor 3'})
        \\WITH w, datetime({datetime: $at, timezone: w.zone}) AS local
        \\RETURN local.dayOfWeek IN w.days AND w.from <= localtime(local) AND localtime(local) < w.until
    ;
    const at = struct {
        fn instant(text: []const u8) !Value {
            return .{ .date_time = try acmedb.temporal.parse.dateTime(text) };
        }
    };
    // Tuesday 07:30 UTC is 09:30 in Madrid (summer time): allowed.
    try support.expectQueryWithParameters(&ast, &g, query, &.{.{ "at", try at.instant("2024-07-02T07:30Z") }}, &.{&.{boolean(true)}});
    // Tuesday 16:30 UTC is 18:30 in Madrid: too late.
    try support.expectQueryWithParameters(&ast, &g, query, &.{.{ "at", try at.instant("2024-07-02T16:30Z") }}, &.{&.{boolean(false)}});
    // Saturday: not a working day.
    try support.expectQueryWithParameters(&ast, &g, query, &.{.{ "at", try at.instant("2024-07-06T10:00+02:00") }}, &.{&.{boolean(false)}});
}

test "a fixed time replaces the clock, for realtime readings too" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [256]u8 = undefined;
    var store = try openStore(&tmp, &path_buffer);
    defer store.deinit();
    var g = Graph.init(&store, testing.allocator);
    var ast = Ast.init(testing.allocator);
    defer ast.deinit();

    const query = try acmedb.parser.parse(&ast, "RETURN datetime().epochMillis, datetime.realtime().epochMillis, date()", null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var executor = acmedb.Executor.init(&ast, &g, arena.allocator());
    executor.fixed_time = 1_700_000_000_123 * std.time.ns_per_ms;
    const rows = try executor.run(query);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqual(@as(i64, 1_700_000_000_123), rows[0].items[0].int);
    try testing.expectEqual(@as(i64, 1_700_000_000_123), rows[0].items[1].int);
    try support.expectRows(try executor.run(try acmedb.parser.parse(&ast, "RETURN toString(date())", null)), &.{&.{string("2023-11-14")}});
}
