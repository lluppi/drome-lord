//! mpd line tokenizer and song filters (legacy tag/value pairs and 0.21+ expressions).
const std = @import("std");
const Allocator = std.mem.Allocator;
const db = @import("../db.zig");

/// splits a command line into words; quoted words may use backslash escapes.
pub fn tokenize(arena: Allocator, line: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r')) i += 1;
        if (i >= line.len) break;
        if (line[i] == '"') {
            i += 1;
            var w: std.ArrayList(u8) = .empty;
            while (true) {
                if (i >= line.len) return error.UnterminatedQuote;
                const ch = line[i];
                if (ch == '"') {
                    i += 1;
                    break;
                }
                if (ch == '\\' and i + 1 < line.len) i += 1;
                try w.append(arena, line[i]);
                i += 1;
            }
            try out.append(arena, w.items);
        } else {
            const s = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\r') i += 1;
            try out.append(arena, line[s..i]);
        }
    }
    return out.items;
}

pub const Field = union(enum) { tag: db.Tag, any, file, base, modified_since };
pub const Op = enum { eq, ne, contains, not_contains, starts_with, re, nre };

pub const Filter = union(enum) {
    all,
    cmp: struct { field: Field, op: Op, value: []const u8 },
    not: *const Filter,
    and_: []const Filter,

    pub fn matches(f: *const Filter, s: *const db.Song, fold: bool) bool {
        switch (f.*) {
            .all => return true,
            .not => |n| return !n.matches(s, fold),
            .and_ => |l| {
                for (l) |*x| if (!x.matches(s, fold)) return false;
                return true;
            },
            .cmp => |c| return cmpMatches(c.field, c.op, c.value, s, fold),
        }
    }
};

fn textMatch(op: Op, have: []const u8, want: []const u8, fold: bool) bool {
    switch (op) {
        .eq, .ne => return if (fold) std.ascii.eqlIgnoreCase(have, want) else std.mem.eql(u8, have, want),
        .contains, .not_contains => return if (fold)
            std.ascii.findIgnoreCase(have, want) != null
        else
            std.mem.indexOf(u8, have, want) != null,
        .starts_with => return if (fold) std.ascii.startsWithIgnoreCase(have, want) else std.mem.startsWith(u8, have, want),
        .re, .nre => {
            // no regex engine: honour ^ and $ anchors, rest is literal
            var w = want;
            const a = w.len > 0 and w[0] == '^';
            if (a) w = w[1..];
            const e = w.len > 0 and w[w.len - 1] == '$';
            if (e) w = w[0 .. w.len - 1];
            if (a and e) return textMatch(.eq, have, w, fold);
            if (a) return textMatch(.starts_with, have, w, fold);
            if (e) return if (fold) std.ascii.endsWithIgnoreCase(have, w) else std.mem.endsWith(u8, have, w);
            return textMatch(.contains, have, w, fold);
        },
    }
}

fn anyValue(vals: []const []const u8, op: Op, want: []const u8, fold: bool) bool {
    if (vals.len == 0) return textMatch(op, "", want, fold);
    for (vals) |v| if (textMatch(op, v, want, fold)) return true;
    return false;
}

fn cmpMatches(field: Field, op: Op, want: []const u8, s: *const db.Song, fold: bool) bool {
    const neg = op == .ne or op == .not_contains or op == .nre;
    const hit: bool = switch (field) {
        .file => textMatch(op, s.path, want, fold),
        .base => want.len == 0 or (std.mem.startsWith(u8, s.path, want) and s.path.len > want.len and s.path[want.len] == '/'),
        .modified_since => return true,
        .tag => |t| blk: {
            var b: db.TagBuf = .{};
            break :blk anyValue(s.tagValues(t, &b), op, want, fold);
        },
        .any => blk: {
            if (textMatch(op, s.path, want, fold)) break :blk true;
            for (std.enums.values(db.Tag)) |t| {
                var b: db.TagBuf = .{};
                if (anyValue(s.tagValues(t, &b), op, want, fold)) break :blk true;
            }
            break :blk false;
        },
    };
    return if (field == .base) hit else if (neg) !hit else hit;
}

const Parser = struct {
    arena: Allocator,
    s: []const u8,
    i: usize = 0,

    fn ws(p: *Parser) void {
        while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
    }
    fn eat(p: *Parser, ch: u8) !void {
        p.ws();
        if (p.i >= p.s.len or p.s[p.i] != ch) return error.BadFilter;
        p.i += 1;
    }
    fn word(p: *Parser) ![]const u8 {
        p.ws();
        const st = p.i;
        while (p.i < p.s.len and p.s[p.i] != ' ' and p.s[p.i] != '(' and p.s[p.i] != ')' and p.s[p.i] != '"' and p.s[p.i] != '\'') p.i += 1;
        if (st == p.i) return error.BadFilter;
        return p.s[st..p.i];
    }
    fn quoted(p: *Parser) ![]const u8 {
        p.ws();
        if (p.i >= p.s.len) return error.BadFilter;
        const q = p.s[p.i];
        if (q != '"' and q != '\'') return error.BadFilter;
        p.i += 1;
        var w: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.i >= p.s.len) return error.BadFilter;
            const ch = p.s[p.i];
            p.i += 1;
            if (ch == q) break;
            if (ch == '\\' and p.i < p.s.len) {
                try w.append(p.arena, p.s[p.i]);
                p.i += 1;
            } else try w.append(p.arena, ch);
        }
        return w.items;
    }

    fn field(name: []const u8) ?Field {
        if (std.ascii.eqlIgnoreCase(name, "any")) return .any;
        if (std.ascii.eqlIgnoreCase(name, "file")) return .file;
        if (db.Tag.parse(name)) |t| return .{ .tag = t };
        return null;
    }

    fn expr(p: *Parser) anyerror!Filter {
        try p.eat('(');
        p.ws();
        var result: Filter = undefined;
        if (p.i < p.s.len and p.s[p.i] == '!') {
            p.i += 1;
            const inner = try p.arena.create(Filter);
            inner.* = try p.expr();
            result = .{ .not = inner };
        } else if (p.i < p.s.len and p.s[p.i] == '(') {
            var parts: std.ArrayList(Filter) = .empty;
            try parts.append(p.arena, try p.expr());
            while (true) {
                p.ws();
                if (p.i < p.s.len and p.s[p.i] == ')') break;
                const w = try p.word();
                if (!std.ascii.eqlIgnoreCase(w, "AND")) return error.BadFilter;
                try parts.append(p.arena, try p.expr());
            }
            result = if (parts.items.len == 1) parts.items[0] else .{ .and_ = parts.items };
        } else {
            const name = try p.word();
            if (std.ascii.eqlIgnoreCase(name, "base")) {
                result = .{ .cmp = .{ .field = .base, .op = .eq, .value = try p.quoted() } };
            } else if (std.ascii.eqlIgnoreCase(name, "modified-since") or std.ascii.eqlIgnoreCase(name, "added-since")) {
                result = .{ .cmp = .{ .field = .modified_since, .op = .eq, .value = try p.quoted() } };
            } else {
                const f = field(name) orelse return error.BadFilter;
                const ops = try p.word();
                const op: Op = if (std.mem.eql(u8, ops, "==")) .eq else if (std.mem.eql(u8, ops, "!=")) .ne else if (std.mem.eql(u8, ops, "contains")) .contains else if (std.mem.eql(u8, ops, "!contains")) .not_contains else if (std.mem.eql(u8, ops, "starts_with")) .starts_with else if (std.mem.eql(u8, ops, "=~")) .re else if (std.mem.eql(u8, ops, "!~")) .nre else return error.BadFilter;
                result = .{ .cmp = .{ .field = f, .op = op, .value = try p.quoted() } };
            }
        }
        try p.eat(')');
        return result;
    }
};

pub const Range = struct { start: usize, end: ?usize };

pub fn parseRange(s: []const u8) ?Range {
    if (std.mem.indexOfScalar(u8, s, ':')) |c| {
        const a = if (c == 0) 0 else std.fmt.parseInt(usize, s[0..c], 10) catch return null;
        const e: ?usize = if (c + 1 == s.len) null else std.fmt.parseInt(usize, s[c + 1 ..], 10) catch return null;
        return .{ .start = a, .end = e };
    }
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    return .{ .start = n, .end = n + 1 };
}

pub const Query = struct {
    filter: Filter = .all,
    sort: ?db.Tag = null,
    sort_file: bool = false,
    sort_desc: bool = false,
    window: ?Range = null,
    groups: []const db.Tag = &.{},
};

/// parses `[expr | tag value ...] [sort TAG] [window S:E] [group TAG]...`; legacy pairs
/// become exact (find) or case-insensitive substring (search) matches.
pub fn parseQuery(arena: Allocator, args: []const []const u8, search: bool) !Query {
    var q: Query = .{};
    var parts: std.ArrayList(Filter) = .empty;
    var groups: std.ArrayList(db.Tag) = .empty;
    var i: usize = 0;
    while (i < args.len) {
        const a = args[i];
        if (a.len > 0 and a[0] == '(') {
            var p: Parser = .{ .arena = arena, .s = a };
            try parts.append(arena, try p.expr());
            // tolerate `(a) AND (b)` without the outer parens
            while (true) {
                p.ws();
                if (p.i >= p.s.len) break;
                if (!std.ascii.eqlIgnoreCase(try p.word(), "AND")) return error.BadFilter;
                try parts.append(arena, try p.expr());
            }
            i += 1;
        } else if (std.ascii.eqlIgnoreCase(a, "sort")) {
            if (i + 1 >= args.len) return error.BadFilter;
            var n = args[i + 1];
            if (n.len > 0 and n[0] == '-') {
                q.sort_desc = true;
                n = n[1..];
            }
            if (std.ascii.eqlIgnoreCase(n, "Last-Modified") or std.ascii.eqlIgnoreCase(n, "file")) q.sort_file = true else q.sort = db.Tag.parse(n) orelse return error.BadFilter;
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(a, "window")) {
            if (i + 1 >= args.len) return error.BadFilter;
            q.window = parseRange(args[i + 1]) orelse return error.BadFilter;
            i += 2;
        } else if (std.ascii.eqlIgnoreCase(a, "group")) {
            if (i + 1 >= args.len) return error.BadFilter;
            try groups.append(arena, db.Tag.parse(args[i + 1]) orelse return error.BadFilter);
            i += 2;
        } else {
            if (i + 1 >= args.len) return error.BadFilter;
            const f = Parser.field(a) orelse return error.BadFilter;
            try parts.append(arena, .{ .cmp = .{ .field = f, .op = if (search) .contains else .eq, .value = args[i + 1] } });
            i += 2;
        }
    }
    q.groups = groups.items;
    if (parts.items.len == 1) q.filter = parts.items[0] else if (parts.items.len > 1) q.filter = .{ .and_ = parts.items };
    return q;
}
