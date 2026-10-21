//! Regular expressions for `=~`, with Java's syntax (what Neo4j uses) and
//! its whole-string matching: `'abc' =~ 'a.'` is false.
//!
//! A pattern is parsed into a tree, compiled into a program of a small
//! automaton (characters, classes, splits, jumps, assertions), and run over
//! the text's code points by simulating every thread at once (Thompson's
//! construction, as a Pike VM without captures). That takes O(text length ×
//! program size) time whatever the pattern, so no pattern can make a query
//! hang (no backtracking).
//!
//! Supported: literals and escapes (`\t \n \r \f \e \a \0oo \xhh \x{h…}
//! \uhhhh`, `\.` and the like, `\Q…\E`), `.`, classes (`[a-z]`, `[^…]`,
//! ranges, escapes in them), `\d \w \s` and their negations, `^ $ \b \B`,
//! groups `(…)`, `(?:…)` and `(?<name>…)`, alternation `|`, quantifiers
//! `* + ? {n} {n,} {n,m}` (lazy `?` and possessive `+` forms, which do not
//! change whether a whole string matches), and the flags `(?i)` (case
//! insensitive, with Unicode's case folding) and `(?s)` (`.` matches line
//! ends), alone or scoped as `(?i:…)`. Not supported, and an error:
//! backreferences, lookahead and lookbehind, class intersections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");

pub const CompileError = error{ InvalidRegex, OutOfMemory };

/// Why a pattern did not compile, and where (a code point offset).
pub const Problem = struct { message: []const u8 = "", offset: usize = 0 };

/// Programs larger than this are refused (a pattern like `(a{1000}){1000}`).
const max_program_length = 100_000;

pub const Regex = struct {
    program: []const Instruction,
    classes: []const Class,

    /// Compiles `pattern`; on `error.InvalidRegex`, `problem` says why.
    pub fn compile(allocator: Allocator, pattern: []const u8, problem: *Problem) CompileError!Regex {
        var codes = std.ArrayList(u21).empty;
        var iterator = unicode.CodePoints{ .bytes = pattern };
        while (iterator.next()) |code| try codes.append(allocator, code);
        var parser = Parser{ .allocator = allocator, .codes = codes.items, .problem = problem };
        const tree = try parser.parseAlternation();
        if (parser.position < parser.codes.len) return parser.fail("unmatched ')'");
        var compiler = Compiler{ .allocator = allocator, .problem = problem };
        try compiler.emit(tree);
        try compiler.append(.match);
        return .{ .program = compiler.program.items, .classes = parser.classes.items };
    }

    /// True if the whole of `text` matches.
    pub fn matches(self: Regex, allocator: Allocator, text: []const u8) Allocator.Error!bool {
        var codes = std.ArrayList(u21).empty;
        defer codes.deinit(allocator);
        var iterator = unicode.CodePoints{ .bytes = text };
        while (iterator.next()) |code| try codes.append(allocator, code);

        var machine = try Machine.init(allocator, self, codes.items);
        defer machine.deinit();
        return machine.run();
    }
};

// --- The program --------------------------------------------------------------

const Instruction = union(enum) {
    /// One code point (`folded`: compared after case folding).
    character: struct { code: u21, folded: bool },
    /// Any code point (line ends only with `dotall`).
    any: struct { dotall: bool },
    class: struct { index: u32, folded: bool },
    /// Continue at both (the first is preferred, which only matters for captures).
    split: struct { first: u32, second: u32 },
    jump: u32,
    assertion: Assertion,
    match,
};

const Assertion = enum { text_start, text_end, word_boundary, not_word_boundary };

const Class = struct {
    items: []const ClassItem,
    negated: bool,

    /// True if one of `codes` (a code point and its other cases) is among
    /// the items: then the class matches unless it is negated.
    fn matchesAny(self: Class, codes: []const u21) bool {
        for (codes) |code| {
            for (self.items) |item| if (item.contains(code)) return !self.negated;
        }
        return self.negated;
    }
};

const ClassItem = union(enum) {
    range: struct { first: u21, last: u21 },
    predefined: struct { kind: Predefined, negated: bool },

    fn contains(self: ClassItem, code: u21) bool {
        return switch (self) {
            .range => |range| code >= range.first and code <= range.last,
            .predefined => |predefined| predefined.kind.contains(code) != predefined.negated,
        };
    }
};

/// `\d`, `\w`, `\s`: ASCII, as in Java without UNICODE_CHARACTER_CLASS.
const Predefined = enum {
    digit,
    word,
    space,

    fn contains(self: Predefined, code: u21) bool {
        return switch (self) {
            .digit => code >= '0' and code <= '9',
            .word => isWordCode(code),
            .space => switch (code) {
                ' ', '\t', '\n', 0x0B, 0x0C, '\r' => true,
                else => false,
            },
        };
    }
};

fn isWordCode(code: u21) bool {
    return code < 0x80 and (std.ascii.isAlphanumeric(@intCast(code)) or code == '_');
}

fn isLineEnd(code: u21) bool {
    return switch (code) {
        '\n', '\r', 0x85, 0x2028, 0x2029 => true,
        else => false,
    };
}

/// The code point `code` folds to, when it folds to one.
fn fold(code: u21) u21 {
    if (unicode.caseFold(code)) |folded| if (folded.len == 1) return folded[0];
    return code;
}

/// The code point `code` upper-cases to, when it maps to one.
fn upper(code: u21) u21 {
    if (unicode.upperCase(code)) |mapped| if (mapped.len == 1) return mapped[0];
    return code;
}

// --- Parsing ------------------------------------------------------------------

const Node = union(enum) {
    empty,
    character: struct { code: u21, folded: bool },
    any: struct { dotall: bool },
    class: struct { index: u32, folded: bool },
    assertion: Assertion,
    concatenation: []const *const Node,
    alternation: []const *const Node,
    repeat: struct { node: *const Node, min: u32, max: ?u32 },
};

const Flags = struct { case_insensitive: bool = false, dotall: bool = false };

const Parser = struct {
    allocator: Allocator,
    codes: []const u21,
    position: usize = 0,
    flags: Flags = .{},
    classes: std.ArrayList(Class) = .empty,
    problem: *Problem,

    fn fail(self: *Parser, message: []const u8) CompileError {
        self.problem.* = .{ .message = message, .offset = self.position };
        return error.InvalidRegex;
    }

    fn peek(self: *const Parser) ?u21 {
        return if (self.position < self.codes.len) self.codes[self.position] else null;
    }

    fn peekAt(self: *const Parser, offset: usize) ?u21 {
        return if (self.position + offset < self.codes.len) self.codes[self.position + offset] else null;
    }

    fn node(self: *Parser, value: Node) CompileError!*const Node {
        const pointer = try self.allocator.create(Node);
        pointer.* = value;
        return pointer;
    }

    /// `a|b|…`; a flag group (`(?i)`) changes the flags until the end of
    /// the group it is in.
    fn parseAlternation(self: *Parser) CompileError!*const Node {
        const saved = self.flags;
        defer self.flags = saved;
        var branches = std.ArrayList(*const Node).empty;
        try branches.append(self.allocator, try self.parseConcatenation());
        while (self.peek() == '|') {
            self.position += 1;
            try branches.append(self.allocator, try self.parseConcatenation());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.node(.{ .alternation = branches.items });
    }

    fn parseConcatenation(self: *Parser) CompileError!*const Node {
        var parts = std.ArrayList(*const Node).empty;
        while (self.peek()) |code| {
            if (code == '|' or code == ')') break;
            if (code == '\\' and self.peekAt(1) == 'Q') {
                try self.parseQuoted(&parts);
                continue;
            }
            const atom = try self.parseAtom() orelse continue;
            try parts.append(self.allocator, try self.parseQuantifier(atom));
        }
        if (parts.items.len == 1) return parts.items[0];
        if (parts.items.len == 0) return self.node(.empty);
        return self.node(.{ .concatenation = parts.items });
    }

    /// `\Q…\E`: every code point in between is a literal.
    fn parseQuoted(self: *Parser, parts: *std.ArrayList(*const Node)) CompileError!void {
        self.position += 2;
        while (self.peek()) |code| {
            if (code == '\\' and self.peekAt(1) == 'E') {
                self.position += 2;
                return;
            }
            self.position += 1;
            try parts.append(self.allocator, try self.literal(code));
        }
    }

    fn literal(self: *Parser, code: u21) CompileError!*const Node {
        const folded = self.flags.case_insensitive;
        return self.node(.{ .character = .{ .code = if (folded) fold(code) else code, .folded = folded } });
    }

    /// One atom, or null for a flag group (`(?i)`), which matches nothing.
    fn parseAtom(self: *Parser) CompileError!?*const Node {
        const code = self.peek().?;
        self.position += 1;
        switch (code) {
            '(' => return self.parseGroup(),
            '[' => return try self.parseClass(),
            '.' => return try self.node(.{ .any = .{ .dotall = self.flags.dotall } }),
            '^' => return try self.node(.{ .assertion = .text_start }),
            '$' => return try self.node(.{ .assertion = .text_end }),
            '\\' => return try self.parseEscape(),
            '*', '+', '?' => {
                self.position -= 1;
                return self.fail("a quantifier has nothing to repeat");
            },
            '{' => if (self.atRepetition()) {
                self.position -= 1;
                return self.fail("a quantifier has nothing to repeat");
            } else return try self.literal('{'),
            else => return try self.literal(code),
        }
    }

    fn parseGroup(self: *Parser) CompileError!?*const Node {
        if (self.peek() == '?') {
            self.position += 1;
            const kind = self.peek() orelse return self.fail("unfinished group");
            switch (kind) {
                ':' => self.position += 1,
                '=', '!' => return self.fail("lookahead is not supported"),
                '<' => {
                    if (self.peekAt(1) == '=' or self.peekAt(1) == '!') return self.fail("lookbehind is not supported");
                    // A named group: the name only matters for captures.
                    self.position += 1;
                    while (self.peek()) |name_code| : (self.position += 1) {
                        if (name_code == '>') break;
                        if (!isWordCode(name_code)) return self.fail("invalid group name");
                    } else return self.fail("unfinished group name");
                    self.position += 1;
                },
                '>' => self.position += 1, // atomic: the same for a whole-string match
                else => {
                    // Flags: `(?i)`, `(?-s)`, `(?is:…)`.
                    var flags = self.flags;
                    var on = true;
                    while (self.peek()) |flag| : (self.position += 1) {
                        switch (flag) {
                            'i' => flags.case_insensitive = on,
                            's' => flags.dotall = on,
                            'm', 'u', 'U', 'x', 'd' => return self.fail("this flag is not supported (only i and s are)"),
                            '-' => on = false,
                            ')', ':' => break,
                            else => return self.fail("invalid flag"),
                        }
                    } else return self.fail("unfinished group");
                    const end = self.peek().?;
                    self.position += 1;
                    if (end == ')') {
                        self.flags = flags; // until the end of the enclosing group
                        return null;
                    }
                    const saved = self.flags;
                    self.flags = flags;
                    defer self.flags = saved;
                    return try self.finishGroup();
                },
            }
        }
        return try self.finishGroup();
    }

    fn finishGroup(self: *Parser) CompileError!*const Node {
        const inner = try self.parseAlternation();
        if (self.peek() != ')') return self.fail("missing ')'");
        self.position += 1;
        return inner;
    }

    fn parseEscape(self: *Parser) CompileError!*const Node {
        if (try self.parseClassEscape()) |item| return self.classNode(&.{item}, false);
        const code = self.peek() orelse return self.fail("a pattern cannot end with '\\'");
        switch (code) {
            'b' => {
                self.position += 1;
                return self.node(.{ .assertion = .word_boundary });
            },
            'B' => {
                self.position += 1;
                return self.node(.{ .assertion = .not_word_boundary });
            },
            'A' => {
                self.position += 1;
                return self.node(.{ .assertion = .text_start });
            },
            'z', 'Z' => {
                self.position += 1;
                return self.node(.{ .assertion = .text_end });
            },
            '1'...'9' => return self.fail("backreferences are not supported"),
            'k' => return self.fail("backreferences are not supported"),
            else => return self.literal(try self.parseEscapedCode()),
        }
    }

    /// `\d \D \w \W \s \S` after the backslash, or null (nothing consumed).
    fn parseClassEscape(self: *Parser) CompileError!?ClassItem {
        const code = self.peek() orelse return null;
        const kind: Predefined = switch (code) {
            'd', 'D' => .digit,
            'w', 'W' => .word,
            's', 'S' => .space,
            else => return null,
        };
        self.position += 1;
        return .{ .predefined = .{ .kind = kind, .negated = std.ascii.isUpper(@intCast(code)) } };
    }

    /// The code point an escape (after its backslash) stands for.
    fn parseEscapedCode(self: *Parser) CompileError!u21 {
        const code = self.peek() orelse return self.fail("a pattern cannot end with '\\'");
        self.position += 1;
        return switch (code) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            'f' => 0x0C,
            'e' => 0x1B,
            'a' => 0x07,
            '0' => self.parseNumber(8, 1, 3),
            'x' => if (self.peek() == '{') braced: {
                self.position += 1;
                const value = try self.parseNumber(16, 1, 6);
                if (self.peek() != '}') return self.fail("missing '}' in \\x{...}");
                self.position += 1;
                break :braced value;
            } else self.parseNumber(16, 2, 2),
            'u' => self.parseNumber(16, 4, 4),
            else => if (code < 0x80 and std.ascii.isAlphanumeric(@intCast(code)))
                self.fail("unknown escape")
            else
                code,
        };
    }

    fn parseNumber(self: *Parser, base: u8, min_digits: usize, max_digits: usize) CompileError!u21 {
        var value: u32 = 0;
        var digits: usize = 0;
        while (digits < max_digits) : (digits += 1) {
            const code = self.peek() orelse break;
            if (code >= 0x80) break;
            const digit = std.fmt.charToDigit(@intCast(code), base) catch break;
            value = value * base + digit;
            self.position += 1;
        }
        if (digits < min_digits) return self.fail("an escape needs more digits");
        if (value > 0x10FFFF) return self.fail("not a code point");
        return @intCast(value);
    }

    fn classNode(self: *Parser, items: []const ClassItem, negated: bool) CompileError!*const Node {
        const index: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.allocator, .{ .items = try self.allocator.dupe(ClassItem, items), .negated = negated });
        return self.node(.{ .class = .{ .index = index, .folded = self.flags.case_insensitive } });
    }

    /// `[…]` after its `[`.
    fn parseClass(self: *Parser) CompileError!*const Node {
        var negated = false;
        if (self.peek() == '^') {
            self.position += 1;
            negated = true;
        }
        var items = std.ArrayList(ClassItem).empty;
        var first = true;
        while (true) : (first = false) {
            const code = self.peek() orelse return self.fail("missing ']'");
            if (code == ']' and !first) {
                self.position += 1;
                break;
            }
            if (code == '[') return self.fail("nested classes are not supported");
            if (code == '&' and self.peekAt(1) == '&') return self.fail("class intersections are not supported");
            self.position += 1;
            var low = code;
            if (code == '\\') {
                if (try self.parseClassEscape()) |item| {
                    try items.append(self.allocator, item);
                    continue;
                }
                low = try self.parseEscapedCode();
            }
            // A range `a-z` (a `-` first, last or after a range is itself).
            if (self.peek() == '-' and self.peekAt(1) != null and self.peekAt(1) != ']') {
                self.position += 1;
                var high = self.peek().?;
                self.position += 1;
                if (high == '\\') high = try self.parseEscapedCode();
                if (high < low) return self.fail("a class range goes backwards");
                try items.append(self.allocator, .{ .range = .{ .first = low, .last = high } });
            } else {
                try items.append(self.allocator, .{ .range = .{ .first = low, .last = low } });
            }
        }
        return self.classNode(items.items, negated);
    }

    /// True if a `{n}`, `{n,}` or `{n,m}` starts at the current position
    /// (after its `{`).
    fn atRepetition(self: *const Parser) bool {
        var offset: usize = 0;
        var digits: usize = 0;
        while (self.peekAt(offset)) |code| : (offset += 1) {
            if (code >= '0' and code <= '9') digits += 1 else break;
        }
        if (digits == 0) return false;
        if (self.peekAt(offset) == '}') return true;
        if (self.peekAt(offset) != ',') return false;
        offset += 1;
        while (self.peekAt(offset)) |code| : (offset += 1) {
            if (code < '0' or code > '9') break;
        }
        return self.peekAt(offset) == '}';
    }

    fn parseQuantifier(self: *Parser, atom: *const Node) CompileError!*const Node {
        const code = self.peek() orelse return atom;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (code) {
            '*' => self.position += 1,
            '+' => {
                self.position += 1;
                min = 1;
            },
            '?' => {
                self.position += 1;
                max = 1;
            },
            '{' => {
                self.position += 1;
                if (!self.atRepetition()) {
                    self.position -= 1;
                    return atom;
                }
                min = try self.parseCount();
                if (self.peek() == ',') {
                    self.position += 1;
                    max = if (self.peek() == '}') null else try self.parseCount();
                } else max = min;
                self.position += 1; // `}`
                if (max) |bound| if (bound < min) return self.fail("a repetition's maximum is below its minimum");
            },
            else => return atom,
        }
        // Lazy and possessive forms match the same whole strings.
        if (self.peek() == '?' or self.peek() == '+') self.position += 1;
        if (self.peek()) |next| if (next == '*' or next == '+' or next == '?') return self.fail("a quantifier cannot follow another");
        return self.node(.{ .repeat = .{ .node = atom, .min = min, .max = max } });
    }

    fn parseCount(self: *Parser) CompileError!u32 {
        var value: u32 = 0;
        while (self.peek()) |code| {
            if (code < '0' or code > '9') break;
            value = std.math.mul(u32, value, 10) catch return self.fail("a repetition count is too large");
            value = std.math.add(u32, value, code - '0') catch return self.fail("a repetition count is too large");
            self.position += 1;
        }
        return value;
    }
};

// --- Compiling ----------------------------------------------------------------

const Compiler = struct {
    allocator: Allocator,
    program: std.ArrayList(Instruction) = .empty,
    problem: *Problem,

    fn append(self: *Compiler, instruction: Instruction) CompileError!void {
        if (self.program.items.len >= max_program_length) {
            self.problem.* = .{ .message = "the pattern is too large" };
            return error.InvalidRegex;
        }
        try self.program.append(self.allocator, instruction);
    }

    fn here(self: *const Compiler) u32 {
        return @intCast(self.program.items.len);
    }

    fn emit(self: *Compiler, tree: *const Node) CompileError!void {
        switch (tree.*) {
            .empty => {},
            .character => |character| try self.append(.{ .character = .{ .code = character.code, .folded = character.folded } }),
            .any => |any| try self.append(.{ .any = .{ .dotall = any.dotall } }),
            .class => |class| try self.append(.{ .class = .{ .index = class.index, .folded = class.folded } }),
            .assertion => |assertion| try self.append(.{ .assertion = assertion }),
            .concatenation => |parts| for (parts) |part| try self.emit(part),
            .alternation => |branches| {
                // split → branch, jump end; split → next branch …; the last plain.
                var jumps = std.ArrayList(u32).empty;
                for (branches, 0..) |branch, i| {
                    if (i + 1 < branches.len) {
                        const split = self.here();
                        try self.append(.{ .split = .{ .first = split + 1, .second = 0 } });
                        try self.emit(branch);
                        try jumps.append(self.allocator, self.here());
                        try self.append(.{ .jump = 0 });
                        self.program.items[split].split.second = self.here();
                    } else try self.emit(branch);
                }
                for (jumps.items) |jump| self.program.items[jump] = .{ .jump = self.here() };
            },
            .repeat => |repeat| {
                for (0..repeat.min) |_| try self.emit(repeat.node);
                if (repeat.max) |max| {
                    // Each optional copy may be skipped to the end.
                    var splits = std.ArrayList(u32).empty;
                    for (repeat.min..max) |_| {
                        try splits.append(self.allocator, self.here());
                        try self.append(.{ .split = .{ .first = self.here() + 1, .second = 0 } });
                        try self.emit(repeat.node);
                    }
                    for (splits.items) |split| self.program.items[split].split.second = self.here();
                } else {
                    // loop: split body, end; body; jump loop.
                    const loop = self.here();
                    try self.append(.{ .split = .{ .first = loop + 1, .second = 0 } });
                    try self.emit(repeat.node);
                    try self.append(.{ .jump = loop });
                    self.program.items[loop].split.second = self.here();
                }
            },
        }
    }
};

// --- Running ------------------------------------------------------------------

const Machine = struct {
    allocator: Allocator,
    regex: Regex,
    text: []const u21,
    current: std.ArrayList(u32) = .empty,
    next: std.ArrayList(u32) = .empty,
    /// The step each instruction was last added to a list in (a thread per
    /// instruction and step).
    added: []usize,
    step: usize = 0,

    fn init(allocator: Allocator, regex: Regex, text: []const u21) Allocator.Error!Machine {
        const added = try allocator.alloc(usize, regex.program.len);
        @memset(added, std.math.maxInt(usize));
        return .{ .allocator = allocator, .regex = regex, .text = text, .added = added };
    }

    fn deinit(self: *Machine) void {
        self.allocator.free(self.added);
        self.current.deinit(self.allocator);
        self.next.deinit(self.allocator);
    }

    fn run(self: *Machine) Allocator.Error!bool {
        try self.addThread(&self.current, 0, 0);
        for (self.text, 0..) |code, position| {
            self.step += 1;
            self.next.clearRetainingCapacity();
            for (self.current.items) |pc| {
                if (self.consumes(self.regex.program[pc], code)) try self.addThread(&self.next, pc + 1, position + 1);
            }
            std.mem.swap(std.ArrayList(u32), &self.current, &self.next);
            if (self.current.items.len == 0) return false;
        }
        for (self.current.items) |pc| if (self.regex.program[pc] == .match) return true;
        return false;
    }

    /// Adds the thread at `pc`, following jumps, splits and assertions that
    /// hold at `position`, to `list` (each instruction once per step).
    fn addThread(self: *Machine, list: *std.ArrayList(u32), pc: u32, position: usize) Allocator.Error!void {
        if (self.added[pc] == self.step) return;
        self.added[pc] = self.step;
        switch (self.regex.program[pc]) {
            .jump => |target| try self.addThread(list, target, position),
            .split => |split| {
                try self.addThread(list, split.first, position);
                try self.addThread(list, split.second, position);
            },
            .assertion => |assertion| if (self.holds(assertion, position)) try self.addThread(list, pc + 1, position),
            else => try list.append(self.allocator, pc),
        }
    }

    fn holds(self: *const Machine, assertion: Assertion, position: usize) bool {
        return switch (assertion) {
            .text_start => position == 0,
            .text_end => position == self.text.len,
            .word_boundary, .not_word_boundary => boundary: {
                const before = position > 0 and isWordCode(self.text[position - 1]);
                const after = position < self.text.len and isWordCode(self.text[position]);
                break :boundary (before != after) == (assertion == .word_boundary);
            },
        };
    }

    fn consumes(self: *const Machine, instruction: Instruction, code: u21) bool {
        return switch (instruction) {
            .character => |character| (if (character.folded) fold(code) else code) == character.code,
            .any => |any| any.dotall or !isLineEnd(code),
            .class => |class| class_test: {
                const set = self.regex.classes[class.index];
                // Case-insensitive: the code point's other cases count too.
                if (!class.folded) break :class_test set.matchesAny(&.{code});
                break :class_test set.matchesAny(&.{ code, fold(code), upper(code) });
            },
            .split, .jump, .assertion, .match => false,
        };
    }
};

// --- Tests --------------------------------------------------------------------

fn expectMatch(pattern: []const u8, text: []const u8, expected: bool) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem = Problem{};
    const regex = Regex.compile(arena.allocator(), pattern, &problem) catch |err| {
        std.debug.print("pattern {s}: {s} at {d}\n", .{ pattern, problem.message, problem.offset });
        return err;
    };
    std.testing.expectEqual(expected, try regex.matches(arena.allocator(), text)) catch |err| {
        std.debug.print("pattern {s} on {s}\n", .{ pattern, text });
        return err;
    };
}

fn expectInvalid(pattern: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var problem = Problem{};
    try std.testing.expectError(error.InvalidRegex, Regex.compile(arena.allocator(), pattern, &problem));
    try std.testing.expect(problem.message.len > 0);
}

test "the whole text must match" {
    try expectMatch("abc", "abc", true);
    try expectMatch("ab", "abc", false);
    try expectMatch("a.c", "abc", true);
    try expectMatch(".*b.*", "abc", true);
    try expectMatch("", "", true);
    try expectMatch("", "a", false);
    try expectMatch("^abc$", "abc", true);
}

test "quantifiers, alternation and groups" {
    try expectMatch("a*", "", true);
    try expectMatch("a*", "aaaa", true);
    try expectMatch("a+", "", false);
    try expectMatch("colou?r", "color", true);
    try expectMatch("colou?r", "colour", true);
    try expectMatch("a{3}", "aaa", true);
    try expectMatch("a{3}", "aa", false);
    try expectMatch("a{2,}", "aaaaa", true);
    try expectMatch("a{2,3}", "aaaa", false);
    try expectMatch("(ab)+", "ababab", true);
    try expectMatch("(ab)+", "ababa", false);
    try expectMatch("cat|dog", "dog", true);
    try expectMatch("(?:cat|dog)s", "cats", true);
    try expectMatch("(?<animal>cat|dog)s?", "dog", true);
    try expectMatch("a.*?b", "axxb", true);
    try expectMatch("a++b", "aab", true);
    // Empty loops end (no thread is added twice in a step).
    try expectMatch("(a*)*b", "aab", true);
    try expectMatch("(a|)*", "aaa", true);
    // No catastrophic backtracking: this answers at once.
    try expectMatch("(a*)*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false);
    try expectMatch("x{", "x{", true);
}

test "classes and escapes" {
    try expectMatch("[a-c]+", "abcba", true);
    try expectMatch("[a-c]+", "abd", false);
    try expectMatch("[^0-9]+", "abc", true);
    try expectMatch("[^0-9]+", "a1", false);
    try expectMatch("[-a]+", "-a-", true);
    try expectMatch("[a-]+", "a-", true);
    try expectMatch("[]a]+", "]a", true);
    try expectMatch("\\d{3}-\\d{4}", "555-1234", true);
    try expectMatch("\\w+@\\w+\\.com", "ana@example.com", true);
    try expectMatch("\\s*x\\s*", " \tx\n", true);
    try expectMatch("[\\d\\s]+", "1 2", true);
    try expectMatch("\\D+", "12", false);
    try expectMatch("[\\W]+", "!?", true);
    try expectMatch("a\\.b", "a.b", true);
    try expectMatch("a\\.b", "axb", false);
    try expectMatch("\\Qa.b*\\E", "a.b*", true);
    try expectMatch("\\x41\\u00e9\\x{1F600}", "Aé😀", true);
    try expectMatch("\\t\\n", "\t\n", true);
    try expectMatch(".", "é", true);
    try expectMatch(".", "\n", false);
    try expectMatch("(?s).", "\n", true);
}

test "anchors and word boundaries" {
    try expectMatch(".*\\bcat\\b.*", "a cat here", true);
    try expectMatch(".*\\bcat\\b.*", "concatenate", false);
    try expectMatch(".*\\Bcat\\B.*", "concatenate", true);
    try expectMatch("a^b", "ab", false);
}

test "case-insensitive matching folds cases" {
    try expectMatch("(?i)hello", "HeLLo", true);
    try expectMatch("(?i)[a-z]+", "ABC", true);
    try expectMatch("(?i)[^a-z]+", "ABC", false);
    try expectMatch("(?i)ñandú", "ÑANDÚ", true);
    try expectMatch("a(?i)b", "aB", true);
    try expectMatch("a(?i)b", "AB", false);
    try expectMatch("(?i:a)b", "Ab", true);
    try expectMatch("(?i:a)b", "AB", false);
    try expectMatch("((?i)a)b", "AB", false);
    try expectMatch("(?i)a(?-i)b", "Ab", true);
    try expectMatch("(?i)a(?-i)b", "AB", false);
}

test "unsupported and malformed patterns are errors" {
    try expectInvalid("(a)\\1");
    try expectInvalid("a(?=b)");
    try expectInvalid("(?<=a)b");
    try expectInvalid("(abc");
    try expectInvalid("abc)");
    try expectInvalid("[abc");
    try expectInvalid("*a");
    try expectInvalid("a**");
    try expectInvalid("[z-a]");
    try expectInvalid("\\q");
    try expectInvalid("a{3,2}");
    try expectInvalid("a\\");
    try expectInvalid("(?m)a");
    try expectInvalid("(a{1000}){1000}");
}
