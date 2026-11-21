//! Decimal rounding for `round(value, precision[, mode])`, as Neo4j does it (Java's
//! `BigDecimal.valueOf(value).setScale(precision, mode)`): the float is read as the shortest
//! decimal that converts back to it, so `round(2.675, 2)` is 2.68 (what the user wrote), not
//! 2.67 (what the nearest binary float, 2.67499999…, would give).
const std = @import("std");

/// Java's rounding modes, by their Cypher names.
pub const Mode = enum { up, down, ceiling, floor, half_up, half_down, half_even };

const mode_names = std.StaticStringMap(Mode).initComptime(.{
    .{ "UP", .up },               .{ "DOWN", .down },       .{ "CEILING", .ceiling },
    .{ "FLOOR", .floor },         .{ "HALF_UP", .half_up }, .{ "HALF_DOWN", .half_down },
    .{ "HALF_EVEN", .half_even },
});

/// The mode a name stands for (upper case, as in Neo4j), or null.
pub fn modeOf(name: []const u8) ?Mode {
    return mode_names.get(name);
}

/// `x` rounded to `precision` digits after the decimal point. NaN and infinities are returned
/// as they are; a result of zero is 0.0, never -0.0 (a BigDecimal has no negative zero).
pub fn roundDecimal(x: f64, precision: u32, mode: Mode) f64 {
    if (std.math.isNan(x) or std.math.isInf(x) or x == 0) return x;
    // The shortest decimal of a float has at most 17 digits, and its exponent is above -325:
    // past 400 digits after the point, nothing is ever dropped.
    if (precision > 400) return x;

    // The shortest decimal as 0.d1 d2 … dn × 10^(exponent + 1).
    var text_buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{e}", .{@abs(x)}) catch unreachable;
    const e_at = std.mem.indexOfScalar(u8, text, 'e').?;
    const exponent = std.fmt.parseInt(i64, text[e_at + 1 ..], 10) catch unreachable;
    var digits: [32]u8 = undefined;
    var count: usize = 0;
    for (text[0..e_at]) |c| {
        if (c == '.') continue;
        digits[count] = c - '0';
        count += 1;
    }

    // How many of the digits come before 10^-precision: the ones kept.
    const keep = exponent + 1 + @as(i64, precision);
    if (keep >= count) return x;
    const kept_count: usize = if (keep > 0) @intCast(keep) else 0;
    var kept: u64 = 0;
    for (digits[0..kept_count]) |digit| kept = kept * 10 + digit;

    // The first dropped digit, and whether any after it is not zero. With keep < 0, the first
    // dropped digit is one of the zeros before d1, and d1 (never zero) comes after it.
    const first: u8 = if (keep < 0) 0 else digits[kept_count];
    const rest_nonzero = keep < 0 or for (digits[kept_count + 1 .. count]) |digit| {
        if (digit != 0) break true;
    } else false;
    const dropped_nonzero = first != 0 or rest_nonzero;
    const above_half = first > 5 or (first == 5 and rest_nonzero);
    const tie = first == 5 and !rest_nonzero;
    const negative = x < 0;

    const away_from_zero = switch (mode) {
        .up => dropped_nonzero,
        .down => false,
        .ceiling => dropped_nonzero and !negative,
        .floor => dropped_nonzero and negative,
        .half_up => above_half or tie,
        .half_down => above_half,
        .half_even => above_half or (tie and kept % 2 == 1),
    };
    if (away_from_zero) kept += 1;
    if (kept == 0) return 0.0;

    // kept × 10^-precision, read back as the nearest float.
    var result_buffer: [64]u8 = undefined;
    const result = std.fmt.bufPrint(&result_buffer, "{s}{d}e-{d}", .{ if (negative) "-" else "", kept, precision }) catch unreachable;
    return std.fmt.parseFloat(f64, result) catch unreachable;
}
