//! The Snowball English stemmer, "Porter2"
//! (https://snowballstem.org/algorithms/english/), translated from
//! english.sbl onto `snowball.Env`. It works on lower-case words.
//!
//! Snowball's `do C` runs C and puts the cursor back; `try C` puts it back
//! only if C fails; `C1 or C2` tries C2 from where C1 started. In backward
//! mode the cursor is kept as a distance from the end (`l - m`), as the word
//! may change length.

const std = @import("std");
const Allocator = std.mem.Allocator;
const snowball = @import("snowball.zig");
const Env = snowball.Env;
const u = snowball.u;
const us = snowball.us;

const aeo = u("aeo");
const v = u("aeiouy");
const v_WXY = u("aeiouywxY");
const valid_LI = u("cdeghkmnrt");

const Regions = struct { p1: usize, p2: usize };

/// Stems `word` (lower case); the stem, allocated with `allocator`.
pub fn stem(allocator: Allocator, word: []const u21) Allocator.Error![]const u21 {
    var env = try Env.init(allocator, word);
    // exception1 or not hop 3 or ( ... )
    if (try exception1(&env)) return env.word();
    if (env.l < 3) return env.word();
    const y_found = try prelude(&env);
    const regions = markRegions(&env);
    env.lb = env.c;
    env.c = env.l;
    inline for (.{ step1a, step1b, step1c, step2, step3, step4, step5 }) |step| {
        const m = env.l - env.c;
        _ = try step(&env, regions);
        env.c = env.l - m;
    }
    env.c = env.lb;
    if (y_found) try postlude(&env);
    return env.word();
}

fn exception1(env: *Env) Allocator.Error!bool {
    const words = us(&.{ "skis", "skies", "idly", "gently", "ugly", "early", "only", "singly", "sky", "news", "howe", "atlas", "cosmos", "bias", "andes" });
    const replacements = us(&.{ "ski", "sky", "idl", "gentl", "ugli", "earli", "onli", "singl" });
    const start = env.c;
    env.bra = env.c;
    const found = env.findAmong(words) orelse return false;
    env.ket = env.c;
    if (env.c != env.l) {
        env.c = start;
        return false;
    }
    if (found < replacements.len) try env.sliceFrom(replacements[found]);
    return true;
}

/// Removes an initial apostrophe and marks consonant y's as Y; true if any.
fn prelude(env: *Env) Allocator.Error!bool {
    var y_found = false;
    const start = env.c;
    // do ( ['\''] delete )
    env.bra = env.c;
    if (env.eq(u("'"))) {
        env.ket = env.c;
        try env.sliceDel();
    }
    env.c = start;
    // do ( ['y'] <-'Y' set Y_found )
    env.bra = env.c;
    if (env.eq(u("y"))) {
        env.ket = env.c;
        try env.sliceFrom(u("Y"));
        y_found = true;
    }
    env.c = start;
    // do repeat ( goto (v ['y']) <-'Y' set Y_found )
    while (true) {
        // goto: find the first position where (v ['y']) matches.
        const found = while (true) {
            const at = env.c;
            if (env.inGrouping(v)) {
                env.bra = env.c;
                if (env.eq(u("y"))) {
                    env.ket = env.c;
                    break true;
                }
            }
            env.c = at;
            if (env.c >= env.l) break false;
            env.c += 1;
        };
        if (!found) break;
        try env.sliceFrom(u("Y"));
        y_found = true;
    }
    env.c = start;
    return y_found;
}

fn markRegions(env: *Env) Regions {
    var regions = Regions{ .p1 = env.l, .p2 = env.l };
    const start = env.c;
    const prefixes = us(&.{ "gener", "commun", "arsen", "past", "univers", "later", "emerg", "organ", "inter" });
    const r1_found = env.findAmong(prefixes) != null or (env.gopastIn(v) and env.gopastOut(v));
    if (r1_found) {
        regions.p1 = env.c;
        if (env.gopastIn(v) and env.gopastOut(v)) regions.p2 = env.c;
    }
    env.c = start;
    return regions;
}

/// ( non-v_WXY v non-v ) or ( non-v v atlimit ) or ( 'past' ), backwards.
fn shortV(env: *Env) bool {
    const start = env.c;
    if (env.outGroupingB(v_WXY) and env.inGroupingB(v) and env.outGroupingB(v)) return true;
    env.c = start;
    if (env.outGroupingB(v) and env.inGroupingB(v) and env.c == env.lb) return true;
    env.c = start;
    if (env.eqB(u("past"))) return true;
    env.c = start;
    return false;
}

fn step1a(env: *Env, regions: Regions) Allocator.Error!bool {
    _ = regions;
    // try ( [substring] among ( '\'' '\'s' '\'s\'' (delete) ) )
    {
        const m = env.l - env.c;
        env.ket = env.c;
        if (env.findAmongB(us(&.{ "'", "'s", "'s'" })) != null) {
            env.bra = env.c;
            try env.sliceDel();
        } else env.c = env.l - m;
    }
    env.ket = env.c;
    const found = env.findAmongB(us(&.{ "sses", "ied", "ies", "s", "us", "ss" })) orelse return false;
    env.bra = env.c;
    switch (found) {
        0 => try env.sliceFrom(u("ss")),
        1, 2 => {
            // (hop 2 <-'i') or <-'ie'
            const m = env.l - env.c;
            if (env.hopB(2)) try env.sliceFrom(u("i")) else {
                env.c = env.l - m;
                try env.sliceFrom(u("ie"));
            }
        },
        3 => {
            // next gopast v delete
            if (env.c <= env.lb) return false;
            env.c -= 1;
            if (!env.gopastInB(v)) return false;
            try env.sliceDel();
        },
        4, 5 => {},
        else => unreachable,
    }
    return true;
}

fn step1b(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    const suffixes = us(&.{ "eed", "eedly", "ed", "edly", "ingly", "ing", "" });
    const found = env.findAmongB(suffixes).?; // '' always matches
    env.bra = env.c;
    const after_suffix = env.l - env.c;
    const handled = switch (found) {
        0, 1 => blk: {
            // do ( R1 among('proc' 'exc' 'succ' (atlimit)) or (<-'ee') )
            const m = env.l - env.c;
            if (env.c >= regions.p1) {
                const m2 = env.l - env.c;
                var kept = false;
                if (env.findAmongB(us(&.{ "proc", "exc", "succ" })) != null and env.c == env.lb) kept = true;
                if (!kept) {
                    env.c = env.l - m2;
                    try env.sliceFrom(u("ee"));
                }
            }
            env.c = env.l - m;
            break :blk true;
        },
        2, 3, 4 => false,
        5 => blk: {
            const which = env.findAmongB(us(&.{ "y", "inn", "out", "cann", "herr", "earr", "even" })) orelse break :blk false;
            if (which == 0) {
                // test(non-v atlimit) ] <-'ie'
                const m = env.l - env.c;
                if (!(env.outGroupingB(v) and env.c == env.lb)) break :blk false;
                env.c = env.l - m;
                env.bra = env.c;
                try env.sliceFrom(u("ie"));
                break :blk true;
            }
            break :blk env.c == env.lb; // (atlimit)
        },
        6 => true,
        else => unreachable,
    };
    if (handled) return true;

    // Handle 'ed' 'edly' 'ing' 'ingly' (the alternative after `or`).
    env.c = env.l - after_suffix;
    {
        // test gopast v
        const m = env.l - env.c;
        if (!env.gopastInB(v)) return false;
        env.c = env.l - m;
    }
    try env.sliceDel();
    // [] test ( substring among( ... ) )
    env.ket = env.c;
    env.bra = env.c;
    {
        const m = env.l - env.c;
        const endings = us(&.{ "at", "bl", "iz", "bb", "dd", "ff", "gg", "mm", "nn", "pp", "rr", "tt", "" });
        const ending = env.findAmongB(endings).?;
        switch (ending) {
            0, 1, 2 => {
                // fail(<- 'e')
                env.c = env.l - m;
                try env.sliceFrom(u("e"));
                return false;
            },
            3...11 => {
                // not (aeo atlimit)
                if (env.inGroupingB(aeo) and env.c == env.lb) return false;
            },
            12 => {
                // fail(atmark p1 test shortv <- 'e')
                if (env.c == regions.p1) {
                    const m2 = env.l - env.c;
                    if (shortV(env)) {
                        env.c = env.l - m2;
                        try env.sliceFrom(u("e"));
                    }
                }
                return false;
            },
            else => unreachable,
        }
        env.c = env.l - m;
    }
    // [next] delete
    env.ket = env.c;
    if (env.c <= env.lb) return false;
    env.c -= 1;
    env.bra = env.c;
    try env.sliceDel();
    return true;
}

fn step1c(env: *Env, regions: Regions) Allocator.Error!bool {
    _ = regions;
    env.ket = env.c;
    if (!env.eqB(u("y")) and !env.eqB(u("Y"))) return false;
    env.bra = env.c;
    if (!env.outGroupingB(v)) return false;
    if (env.c == env.lb) return false; // not atlimit
    try env.sliceFrom(u("i"));
    return true;
}

const step2_suffixes = us(&.{
    "tional", "enci",  "anci",  "abli",    "entli", "izer",    "ization", "ational", "ation",  "ator",
    "alism",  "aliti", "alli",  "fulness", "ousli", "ousness", "iveness", "iviti",   "biliti", "bli",
    "ogist",  "ogi",   "fulli", "lessli",  "li",
});
const step2_replacements = us(&.{
    "tion", "ence", "ance", "able", "ent", "ize", "ize", "ate", "ate", "ate",
    "al",   "al",   "al",   "ful",  "ous", "ous", "ive", "ive", "ble", "ble",
    "og",   "og",   "ful",  "less", "",
});

fn step2(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    const found = env.findAmongB(step2_suffixes) orelse return false;
    env.bra = env.c;
    if (env.c < regions.p1) return false; // R1
    const suffix = step2_suffixes[found];
    if (std.mem.eql(u21, suffix, u("ogi"))) {
        if (!env.eqB(u("l"))) return false;
    } else if (std.mem.eql(u21, suffix, u("li"))) {
        if (!env.inGroupingB(valid_LI)) return false;
        try env.sliceDel();
        return true;
    }
    try env.sliceFrom(step2_replacements[found]);
    return true;
}

fn step3(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    const suffixes = us(&.{ "tional", "ational", "alize", "icate", "iciti", "ical", "ful", "ness", "ative" });
    const found = env.findAmongB(suffixes) orelse return false;
    env.bra = env.c;
    if (env.c < regions.p1) return false; // R1
    switch (found) {
        0 => try env.sliceFrom(u("tion")),
        1 => try env.sliceFrom(u("ate")),
        2 => try env.sliceFrom(u("al")),
        3, 4, 5 => try env.sliceFrom(u("ic")),
        6, 7 => try env.sliceDel(),
        8 => {
            if (env.c < regions.p2) return false;
            try env.sliceDel();
        },
        else => unreachable,
    }
    return true;
}

fn step4(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    const suffixes = us(&.{ "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment", "ent", "ism", "ate", "iti", "ous", "ive", "ize", "ion" });
    const found = env.findAmongB(suffixes) orelse return false;
    env.bra = env.c;
    if (env.c < regions.p2) return false; // R2
    if (found == suffixes.len - 1) {
        // 'ion' ('s' or 't' delete)
        if (!env.eqB(u("s")) and !env.eqB(u("t"))) return false;
    }
    try env.sliceDel();
    return true;
}

fn step5(env: *Env, regions: Regions) Allocator.Error!bool {
    env.ket = env.c;
    const found = env.findAmongB(us(&.{ "e", "l" })) orelse return false;
    env.bra = env.c;
    switch (found) {
        0 => {
            // (R2 or (R1 not shortv)) delete
            const in_r2 = env.c >= regions.p2;
            if (!in_r2) {
                if (env.c < regions.p1) return false;
                const m = env.l - env.c;
                const short = shortV(env);
                env.c = env.l - m;
                if (short) return false;
            }
            try env.sliceDel();
        },
        1 => {
            // R2 'l' delete
            if (env.c < regions.p2) return false;
            if (!env.eqB(u("l"))) return false;
            try env.sliceDel();
        },
        else => unreachable,
    }
    return true;
}

/// Y_found repeat ( goto (['Y']) <-'y' ): every Y back to y.
fn postlude(env: *Env) Allocator.Error!void {
    for (env.p.items[0..env.l]) |*code| {
        if (code.* == 'Y') code.* = 'y';
    }
}
