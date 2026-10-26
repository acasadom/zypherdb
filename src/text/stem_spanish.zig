//! The Snowball Spanish stemmer (https://snowballstem.org/algorithms/spanish/),
//! translated from spanish.sbl onto `snowball.Env`. It works on lower-case
//! words with their accents; the analyzer removes accents after.
//!
//! Snowball's `do C` runs C and puts the cursor back; `try C` puts it back
//! only if C fails; `C1 or C2` tries C2 from where C1 started. In backward
//! mode the cursor is kept as a distance from the end (`l - m`), as the word
//! may shrink.

const std = @import("std");
const Allocator = std.mem.Allocator;
const snowball = @import("snowball.zig");
const Env = snowball.Env;
const u = snowball.u;
const us = snowball.us;

const v = u("aeiouáéíóúü");

const Regions = struct { pV: usize, p1: usize, p2: usize };

/// Stems `word` (lower case, accents kept); the stem, allocated with `allocator`.
pub fn stem(allocator: Allocator, word: []const u21) Allocator.Error![]const u21 {
    var env = try Env.init(allocator, word);
    const regions = markRegions(&env);
    // backwards (...)
    env.lb = env.c;
    env.c = env.l;
    {
        const m = env.l - env.c;
        _ = try attachedPronoun(&env, regions);
        env.c = env.l - m;
    }
    {
        const m = env.l - env.c;
        if (!try standardSuffix(&env, regions)) {
            env.c = env.l - m;
            if (!try yVerbSuffix(&env, regions)) {
                env.c = env.l - m;
                _ = try verbSuffix(&env, regions);
            }
        }
        env.c = env.l - m;
    }
    {
        const m = env.l - env.c;
        _ = try residualSuffix(&env, regions);
        env.c = env.l - m;
    }
    env.c = env.lb;
    try postlude(&env);
    return env.word();
}

fn markRegions(env: *Env) Regions {
    var regions = Regions{ .pV = env.l, .p1 = env.l, .p2 = env.l };
    const start = env.c;
    // do ( ( v (non-v gopast v) or (v gopast non-v) ) or ( non-v (non-v gopast v) or (v next) ) setmark pV )
    const found = vowel_first: {
        if (env.inGrouping(v)) {
            const after_first = env.c;
            if (env.outGrouping(v) and env.gopastIn(v)) break :vowel_first true;
            env.c = after_first;
            if (env.inGrouping(v) and env.gopastOut(v)) break :vowel_first true;
        }
        env.c = start;
        if (env.outGrouping(v)) {
            const after_first = env.c;
            if (env.outGrouping(v) and env.gopastIn(v)) break :vowel_first true;
            env.c = after_first;
            if (env.inGrouping(v) and env.c < env.l) {
                env.c += 1; // next
                break :vowel_first true;
            }
        }
        break :vowel_first false;
    };
    if (found) regions.pV = env.c;
    env.c = start;
    // do ( gopast v gopast non-v setmark p1 gopast v gopast non-v setmark p2 )
    if (env.gopastIn(v) and env.gopastOut(v)) {
        regions.p1 = env.c;
        if (env.gopastIn(v) and env.gopastOut(v)) regions.p2 = env.c;
    }
    env.c = start;
    return regions;
}

fn postlude(env: *Env) Allocator.Error!void {
    const accented = us(&.{ "á", "é", "í", "ó", "ú", "" });
    const plain = us(&.{ "a", "e", "i", "o", "u" });
    // repeat ( [substring] among ( ... '' (next) ) )
    while (true) {
        env.bra = env.c;
        const found = env.findAmong(accented).?; // '' always matches
        env.ket = env.c;
        if (found < plain.len) {
            try env.sliceFrom(plain[found]);
            continue;
        }
        if (env.c >= env.l) return;
        env.c += 1;
    }
}

const pronouns = us(&.{ "me", "se", "sela", "selo", "selas", "selos", "la", "le", "lo", "las", "les", "los", "nos" });

fn attachedPronoun(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    _ = env.findAmongB(pronouns) orelse return false;
    env.bra = env.c;
    const endings = us(&.{ "iéndo", "ándo", "ár", "ér", "ír", "ando", "iendo", "ar", "er", "ir", "yendo" });
    const ending = env.findAmongB(endings) orelse return false;
    if (env.c < regions.pV) return false; // RV
    switch (ending) {
        0, 1, 2, 3, 4 => {
            env.bra = env.c; // ]
            const unaccented = us(&.{ "iendo", "ando", "ar", "er", "ir" });
            try env.sliceFrom(unaccented[ending]);
        },
        5, 6, 7, 8, 9 => try env.sliceDel(),
        10 => {
            if (!env.eqB(u("u"))) return false;
            try env.sliceDel();
        },
        else => unreachable,
    }
    return true;
}

const Standard = enum { r2_delete, r2_delete_ic, log, u_, ente, amente, mente, idad, iv };

const standard_suffixes = blk: {
    const groups = .{
        .{ Standard.r2_delete, &.{ "anza", "anzas", "ico", "ica", "icos", "icas", "ismo", "ismos", "able", "ables", "ible", "ibles", "ista", "istas", "oso", "osa", "osos", "osas", "amiento", "amientos", "imiento", "imientos" } },
        .{ Standard.r2_delete_ic, &.{ "adora", "ador", "ación", "adoras", "adores", "aciones", "ante", "antes", "ancia", "ancias", "acion" } },
        .{ Standard.log, &.{ "logía", "logías" } },
        .{ Standard.u_, &.{ "ución", "uciones", "ucion" } },
        .{ Standard.ente, &.{ "encia", "encias" } },
        .{ Standard.amente, &.{"amente"} },
        .{ Standard.mente, &.{"mente"} },
        .{ Standard.idad, &.{ "idad", "idades" } },
        .{ Standard.iv, &.{ "iva", "ivo", "ivas", "ivos" } },
    };
    var strings: []const []const u21 = &.{};
    var actions: []const Standard = &.{};
    for (groups) |group| for (group[1]) |text| {
        strings = strings ++ &[_][]const u21{u(text)};
        actions = actions ++ &[_]Standard{group[0]};
    };
    break :blk .{ .strings = strings, .actions = actions };
};

fn standardSuffix(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    const found = env.findAmongB(standard_suffixes.strings) orelse return false;
    env.bra = env.c;
    switch (standard_suffixes.actions[found]) {
        .r2_delete => {
            if (env.c < regions.p2) return false;
            try env.sliceDel();
        },
        .r2_delete_ic => {
            if (env.c < regions.p2) return false;
            try env.sliceDel();
            // try ( ['ic'] R2 delete )
            const m = env.l - env.c;
            env.ket = env.c;
            if (env.eqB(u("ic"))) {
                env.bra = env.c;
                if (env.c >= regions.p2) try env.sliceDel() else env.c = env.l - m;
            } else env.c = env.l - m;
        },
        .log => {
            if (env.c < regions.p2) return false;
            try env.sliceFrom(u("log"));
        },
        .u_ => {
            if (env.c < regions.p2) return false;
            try env.sliceFrom(u("u"));
        },
        .ente => {
            if (env.c < regions.p2) return false;
            try env.sliceFrom(u("ente"));
        },
        .amente => {
            if (env.c < regions.p1) return false;
            try env.sliceDel();
            // try ( [substring] R2 delete among( 'iv' (['at'] R2 delete) 'os' 'ic' 'ad' ) )
            const m = env.l - env.c;
            env.ket = env.c;
            if (env.findAmongB(us(&.{ "iv", "os", "ic", "ad" }))) |which| {
                env.bra = env.c;
                if (env.c >= regions.p2) {
                    try env.sliceDel();
                    if (which == 0) {
                        const m2 = env.l - env.c;
                        env.ket = env.c;
                        if (env.eqB(u("at"))) {
                            env.bra = env.c;
                            if (env.c >= regions.p2) try env.sliceDel() else env.c = env.l - m2;
                        } else env.c = env.l - m2;
                    }
                } else env.c = env.l - m;
            } else env.c = env.l - m;
        },
        .mente => {
            if (env.c < regions.p2) return false;
            try env.sliceDel();
            try deleteInR2(env, regions, us(&.{ "ante", "able", "ible" }));
        },
        .idad => {
            if (env.c < regions.p2) return false;
            try env.sliceDel();
            try deleteInR2(env, regions, us(&.{ "abil", "ic", "iv" }));
        },
        .iv => {
            if (env.c < regions.p2) return false;
            try env.sliceDel();
            try deleteInR2(env, regions, us(&.{"at"}));
        },
    }
    return true;
}

/// try ( [substring] among( strings (R2 delete) ) )
fn deleteInR2(env: *Env, regions: Regions, strings: []const []const u21) Allocator.Error!void {
    const m = env.l - env.c;
    env.ket = env.c;
    if (env.findAmongB(strings) != null) {
        env.bra = env.c;
        if (env.c >= regions.p2) return env.sliceDel();
    }
    env.c = env.l - m;
}

/// setlimit tomark pV for ([substring]) among(strings): the suffix's index,
/// or null (the cursor left where it was).
fn findInRv(env: *Env, regions: Regions, strings: []const []const u21) ?usize {
    if (env.c < regions.pV) return null;
    const saved_limit = env.lb;
    env.lb = regions.pV;
    defer env.lb = saved_limit;
    env.ket = env.c;
    const found = env.findAmongB(strings) orelse return null;
    env.bra = env.c;
    return found;
}

fn yVerbSuffix(env: *Env, regions: Regions) Allocator.Error!bool {
    const y_suffixes = us(&.{ "ya", "ye", "yan", "yen", "yeron", "yendo", "yo", "yó", "yas", "yes", "yais", "yamos" });
    _ = findInRv(env, regions, y_suffixes) orelse return false;
    if (!env.eqB(u("u"))) return false;
    try env.sliceDel();
    return true;
}

const verb_suffixes_en = us(&.{ "en", "es", "éis", "emos" });
const verb_suffixes_delete = us(&.{
    "arían",
    "arías",
    "arán",
    "arás",
    "aríais",
    "aría",
    "aréis",
    "aríamos",
    "aremos",
    "ará",
    "aré",
    "erían",
    "erías",
    "erán",
    "erás",
    "eríais",
    "ería",
    "eréis",
    "eríamos",
    "eremos",
    "erá",
    "eré",
    "irían",
    "irías",
    "irán",
    "irás",
    "iríais",
    "iría",
    "iréis",
    "iríamos",
    "iremos",
    "irá",
    "iré",
    "aba",
    "ada",
    "ida",
    "ía",
    "ara",
    "iera",
    "ad",
    "ed",
    "id",
    "ase",
    "iese",
    "aste",
    "iste",
    "an",
    "aban",
    "ían",
    "aran",
    "ieran",
    "asen",
    "iesen",
    "aron",
    "ieron",
    "ado",
    "ido",
    "ando",
    "iendo",
    "ió",
    "ar",
    "er",
    "ir",
    "as",
    "abas",
    "adas",
    "idas",
    "ías",
    "aras",
    "ieras",
    "ases",
    "ieses",
    "ís",
    "áis",
    "abais",
    "íais",
    "arais",
    "ierais",
    "aseis",
    "ieseis",
    "asteis",
    "isteis",
    "ados",
    "idos",
    "amos",
    "ábamos",
    "íamos",
    "imos",
    "áramos",
    "iéramos",
    "iésemos",
    "ásemos",
});
const verb_suffixes = verb_suffixes_en ++ verb_suffixes_delete;

fn verbSuffix(env: *Env, regions: Regions) Allocator.Error!bool {
    const found = findInRv(env, regions, verb_suffixes) orelse return false;
    if (found < verb_suffixes_en.len) {
        // try ('u' test 'g') ] delete
        const m = env.l - env.c;
        if (env.eqB(u("u"))) {
            const m2 = env.l - env.c;
            if (env.eqB(u("g"))) env.c = env.l - m2 else env.c = env.l - m;
        } else env.c = env.l - m;
        env.bra = env.c;
    }
    try env.sliceDel();
    return true;
}

fn residualSuffix(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    const found = env.findAmongB(us(&.{ "os", "a", "o", "á", "í", "ó", "e", "é" })) orelse return false;
    env.bra = env.c;
    if (env.c < regions.pV) return false; // RV
    try env.sliceDel();
    if (found >= 6) {
        // try ( ['u'] test 'g' RV delete )
        const m = env.l - env.c;
        env.ket = env.c;
        if (env.eqB(u("u"))) {
            env.bra = env.c;
            const m2 = env.l - env.c;
            if (env.eqB(u("g"))) {
                env.c = env.l - m2;
                if (env.c >= regions.pV) return blk: {
                    try env.sliceDel();
                    break :blk true;
                };
            }
        }
        env.c = env.l - m;
    }
    return true;
}
