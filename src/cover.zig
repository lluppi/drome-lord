//! `drome-lord cover`: a tiny mpd client that shows the current song's cover in the terminal
//! with the kitty graphics protocol (unicode placeholders + tmux passthrough inside tmux).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

extern fn stbi_load_from_memory(buf: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int, req: c_int) ?[*]u8;
extern fn stbi_image_free(p: ?*anyopaque) void;

const log = std.log.scoped(.cover);

// row/column diacritics: all 297 entries of kitty's gen/rowcolumn-diacritics.txt
const diacritics = [_]u21{
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
    0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
    0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
    0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
    0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
    0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2, 0x06E4, 0x06E7, 0x06E8, 0x06EB,
    0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
    0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3,
    0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
    0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954,
    0x0F82, 0x0F83, 0x0F86, 0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
    0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E, 0x1B6F, 0x1B70, 0x1B71,
    0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
    0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
    0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
    0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7,
    0x20DB, 0x20DC, 0x20E1, 0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
    0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB, 0x2DEC, 0x2DED, 0x2DEE,
    0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
    0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1,
    0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
    0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1,
    0xFE20, 0xFE21, 0xFE22, 0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
    0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243, 0x1D244,
};
const placeholder: u21 = 0x10EEEE;

const Song = struct { file: []const u8, artist: []const u8, album: []const u8, albumartist: []const u8, title: []const u8, date: []const u8 };

const Status = struct {
    state: enum { play, pause, stop } = .stop,
    volume: i32 = -1,
    repeat: bool = false,
    random: bool = false,
    single: bool = false,
    consume: bool = false,
    elapsed: f64 = 0,
    duration: f64 = 0,
};

const Image = struct { w: usize, h: usize, rgba: []u8 };

// ---- mpd connection

const Conn = struct {
    fd: std.c.fd_t,
    buf: [1 << 16]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(c: *Conn) !void {
        if (c.start > 0) {
            std.mem.copyForwards(u8, c.buf[0 .. c.end - c.start], c.buf[c.start..c.end]);
            c.end -= c.start;
            c.start = 0;
        }
        if (c.end == c.buf.len) return error.LineTooLong;
        const n = std.c.read(c.fd, c.buf[c.end..].ptr, c.buf.len - c.end);
        if (n <= 0) return error.Closed;
        c.end += @intCast(n);
    }

    fn hasData(c: *const Conn) bool {
        return c.end > c.start;
    }

    fn line(c: *Conn) ![]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, c.buf[c.start..c.end], '\n')) |i| {
                const l = c.buf[c.start .. c.start + i];
                c.start += i + 1;
                return l;
            }
            try c.fill();
        }
    }

    fn bytes(c: *Conn, out: []u8) !void {
        var got: usize = 0;
        while (got < out.len) {
            if (c.start == c.end) try c.fill();
            const n = @min(out.len - got, c.end - c.start);
            @memcpy(out[got .. got + n], c.buf[c.start .. c.start + n]);
            c.start += n;
            got += n;
        }
    }

    fn send(c: *Conn, data: []const u8) !void {
        try writeAll(c.fd, data);
    }

    /// reads response lines up to OK; returns true on OK, false on ACK. lines go to `cb`.
    fn skipResponse(c: *Conn) !bool {
        while (true) {
            const l = try c.line();
            if (std.mem.eql(u8, l, "OK")) return true;
            if (std.mem.startsWith(u8, l, "ACK")) return false;
        }
    }
};

fn writeAll(fd: std.c.fd_t, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

fn currentSong(c: *Conn, a: Allocator) !?Song {
    try c.send("currentsong\n");
    var s: Song = .{ .file = "", .artist = "", .album = "", .albumartist = "", .title = "", .date = "" };
    while (true) {
        const l = try c.line();
        if (std.mem.eql(u8, l, "OK")) break;
        if (std.mem.startsWith(u8, l, "ACK")) return null;
        const i = std.mem.indexOf(u8, l, ": ") orelse continue;
        const k = l[0..i];
        const v = try a.dupe(u8, l[i + 2 ..]);
        if (std.mem.eql(u8, k, "file")) s.file = v else if (std.mem.eql(u8, k, "Artist")) s.artist = v else if (std.mem.eql(u8, k, "Album")) s.album = v else if (std.mem.eql(u8, k, "AlbumArtist")) s.albumartist = v else if (std.mem.eql(u8, k, "Title")) s.title = v else if (std.mem.eql(u8, k, "Date")) s.date = v;
    }
    return if (s.file.len > 0) s else null;
}

fn getStatus(c: *Conn) !Status {
    try c.send("status\n");
    var st: Status = .{};
    while (true) {
        const l = try c.line();
        if (std.mem.eql(u8, l, "OK")) break;
        if (std.mem.startsWith(u8, l, "ACK")) return error.Ack;
        const i = std.mem.indexOf(u8, l, ": ") orelse continue;
        const k = l[0..i];
        const v = l[i + 2 ..];
        if (std.mem.eql(u8, k, "state")) st.state = if (std.mem.eql(u8, v, "play")) .play else if (std.mem.eql(u8, v, "pause")) .pause else .stop else if (std.mem.eql(u8, k, "volume")) st.volume = std.fmt.parseInt(i32, v, 10) catch -1 else if (std.mem.eql(u8, k, "repeat")) st.repeat = v[0] == '1' else if (std.mem.eql(u8, k, "random")) st.random = v[0] == '1' else if (std.mem.eql(u8, k, "single")) st.single = v[0] != '0' else if (std.mem.eql(u8, k, "consume")) st.consume = v[0] == '1' else if (std.mem.eql(u8, k, "elapsed")) st.elapsed = std.fmt.parseFloat(f64, v) catch 0 else if (std.mem.eql(u8, k, "duration")) st.duration = std.fmt.parseFloat(f64, v) catch 0;
    }
    return st;
}

/// fetches the whole cover with chunked `albumart`; null if the song has none.
fn albumart(c: *Conn, a: Allocator, file: []const u8) !?[]u8 {
    var quoted: std.ArrayList(u8) = .empty;
    for (file) |ch| {
        if (ch == '"' or ch == '\\') try quoted.append(a, '\\');
        try quoted.append(a, ch);
    }
    var data: std.ArrayList(u8) = .empty;
    var total: usize = 0;
    while (true) {
        const cmd = try std.fmt.allocPrint(a, "albumart \"{s}\" {d}\n", .{ quoted.items, data.items.len });
        try c.send(cmd);
        var size: ?usize = null;
        var chunk: usize = 0;
        while (true) {
            const l = try c.line();
            if (std.mem.startsWith(u8, l, "ACK")) return null;
            if (std.mem.startsWith(u8, l, "size: ")) size = std.fmt.parseInt(usize, l[6..], 10) catch return null;
            if (std.mem.startsWith(u8, l, "binary: ")) {
                chunk = std.fmt.parseInt(usize, l[8..], 10) catch return null;
                const dst = try data.addManyAsSlice(a, chunk);
                try c.bytes(dst);
                const nl = try c.line(); // trailing newline after the blob
                _ = nl;
                break;
            }
            if (std.mem.eql(u8, l, "OK")) return null;
        }
        const ok = try c.line();
        if (!std.mem.eql(u8, ok, "OK")) return null;
        total = size orelse return null;
        if (chunk == 0 or data.items.len >= total) break;
    }
    return data.items;
}

// ---- image

fn decode(a: Allocator, bytes: []const u8) ?Image {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const p = stbi_load_from_memory(bytes.ptr, @intCast(bytes.len), &w, &h, &comp, 4) orelse return null;
    defer stbi_image_free(p);
    if (w <= 0 or h <= 0) return null;
    const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const copy = a.dupe(u8, p[0..n]) catch return null;
    return .{ .w = @intCast(w), .h = @intCast(h), .rgba = copy };
}

/// area-average downscale (never upscales; kitty stretches to the cell box).
fn scale(a: Allocator, img: Image, dw: usize, dh: usize) ![]u8 {
    const out = try a.alloc(u8, dw * dh * 4);
    for (0..dh) |y| {
        const y0 = y * img.h / dh;
        const y1 = @max(y0 + 1, (y + 1) * img.h / dh);
        for (0..dw) |x| {
            const x0 = x * img.w / dw;
            const x1 = @max(x0 + 1, (x + 1) * img.w / dw);
            var sum = [4]u32{ 0, 0, 0, 0 };
            for (y0..y1) |sy| for (x0..x1) |sx| {
                const i = (sy * img.w + sx) * 4;
                inline for (0..4) |k| sum[k] += img.rgba[i + k];
            };
            const cnt: u32 = @intCast((y1 - y0) * (x1 - x0));
            inline for (0..4) |k| out[(y * dw + x) * 4 + k] = @intCast(sum[k] / cnt);
        }
    }
    return out;
}

// ---- terminal

const Term = struct {
    rows: usize = 24,
    cols: usize = 80,
    cw: usize = 8,
    ch: usize = 16,
    tmux: bool,
    id: u32,
};

const Layout = enum { auto, horizontal, vertical };
const Opts = struct { text: bool = true, image: bool = true, layout: Layout = .auto };

// kanagawa wave
const fuji_white = "\x1b[38;2;220;215;186m";
const carp_yellow = "\x1b[38;2;230;195;132m";
const crystal_blue = "\x1b[38;2;126;156;216m";
const fuji_gray = "\x1b[38;2;114;113;105m";
const sumi_ink4 = "\x1b[38;2;84;84;109m";
const spring_green = "\x1b[38;2;152;187;108m";
const reset = "\x1b[0m";

const icon_play = "\u{F040A}";
const icon_pause = "\u{F03E4}";
const icon_stop = "\u{F04DB}";
const icon_repeat = "\u{F0456}";
const icon_single = "\u{F0458}";
const icon_random = "\u{F049D}";
const icon_consume = "\u{F01B4}";
const icon_volume = "\u{F057E}";



fn termSize(t: *Term) void {
    var ws: std.posix.winsize = undefined;
    for ([_]std.c.fd_t{ 1, 0, 2 }) |fd| {
        if (std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws)) == 0 and ws.row > 0 and ws.col > 0) {
            t.rows = ws.row;
            t.cols = ws.col;
            if (ws.xpixel > 0 and ws.ypixel > 0) {
                t.cw = @max(1, ws.xpixel / ws.col);
                t.ch = @max(1, ws.ypixel / ws.row);
            }
            return;
        }
    }
}

/// appends one kitty APC command, wrapped for tmux passthrough when needed.
fn apc(f: *std.ArrayList(u8), a: Allocator, t: *const Term, ctrl: []const u8, payload: []const u8) !void {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try raw.appendSlice(a, "\x1b_G");
    try raw.appendSlice(a, ctrl);
    if (payload.len > 0) {
        try raw.append(a, ';');
        try raw.appendSlice(a, payload);
    }
    try raw.appendSlice(a, "\x1b\\");
    if (!t.tmux) return f.appendSlice(a, raw.items);
    try f.appendSlice(a, "\x1bPtmux;");
    for (raw.items) |ch| {
        if (ch == 0x1b) try f.append(a, 0x1b);
        try f.append(a, ch);
    }
    try f.appendSlice(a, "\x1b\\");
}

fn cpCount(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// cuts `text` to `max` columns, ending in … when it had to be shortened.
fn fit(a: Allocator, text: []const u8, max: usize) ![]const u8 {
    if (max == 0) return "";
    if (cpCount(text) <= max) return text;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var end: usize = 0;
    var n: usize = 0;
    while (it.nextCodepointSlice()) |cp| {
        if (n == max - 1) break;
        end += cp.len;
        n += 1;
    }
    return std.fmt.allocPrint(a, "{s}\u{2026}", .{text[0..end]});
}

fn clock(a: Allocator, secs: f64) ![]const u8 {
    const t: u64 = @intFromFloat(@max(secs, 0));
    if (t >= 3600) return std.fmt.allocPrint(a, "{d}:{d:0>2}:{d:0>2}", .{ t / 3600, t / 60 % 60, t % 60 });
    return std.fmt.allocPrint(a, "{d}:{d:0>2}", .{ t / 60, t % 60 });
}

fn flag(f: *std.ArrayList(u8), a: Allocator, on: bool, icon: []const u8) !void {
    try f.appendSlice(a, if (on) spring_green else fuji_gray);
    try f.appendSlice(a, icon);
    try f.append(a, ' ');
}

/// where the text block goes and how it is shaped.
const TextPos = struct { row: usize = 1, col: usize = 1, width: usize = 80, horizontal: bool = false };

fn textLines(horizontal: bool) usize {
    return if (horizontal) 6 else 5;
}

/// progress bar + " 1:23 / 3:45", `width` columns in total.
fn progress(f: *std.ArrayList(u8), a: Allocator, width: usize, st: Status) !void {
    const label = try std.fmt.allocPrint(a, " {s} / {s}", .{ try clock(a, st.elapsed), try clock(a, st.duration) });
    const lw = cpCount(label);
    if (width <= lw + 4) return f.appendSlice(a, label[0..@min(label.len, width)]);
    const bw = width - lw;
    var filled: usize = 0;
    if (st.state != .stop and st.duration > 0) {
        const frac = std.math.clamp(st.elapsed / st.duration, 0.0, 1.0);
        filled = @intFromFloat(@round(frac * @as(f64, @floatFromInt(bw))));
    }
    try f.appendSlice(a, carp_yellow);
    if (filled > 0) {
        for (0..filled - 1) |_| try f.appendSlice(a, "\u{2500}");
        try f.appendSlice(a, "\u{257C}");
    }
    try f.appendSlice(a, sumi_ink4);
    for (0..bw - filled) |_| try f.appendSlice(a, "\u{2500}");
    if (st.state == .stop) {
        try f.appendSlice(a, reset);
        return;
    }
    try f.print(a, "{s} {s} {s}/ {s}{s}", .{ carp_yellow, try clock(a, st.elapsed), fuji_gray, try clock(a, st.duration), reset });
}

/// the now-playing block at `pos`; each line is cleared to its right edge and rewritten in place.
fn drawText(f: *std.ArrayList(u8), a: Allocator, t: *const Term, pos: TextPos, song: ?Song, st: Status, waiting: []const u8) !void {
    const w = pos.width;
    const n = textLines(pos.horizontal);
    var lines: [6]std.ArrayList(u8) = @splat(.empty);
    const icon = switch (st.state) {
        .play => icon_play,
        .pause => icon_pause,
        .stop => icon_stop,
    };
    // title: state icon + title
    try lines[0].print(a, "{s}{s} {s}\x1b[1m{s}{s}", .{ carp_yellow, icon, fuji_white, try fit(a, if (song) |s| (if (s.title.len > 0) s.title else s.file) else waiting, w -| 2), reset });
    const bar_line: usize = if (pos.horizontal) 4 else 3;
    if (song) |s| {
        try lines[1].print(a, "{s}{s}{s}", .{ crystal_blue, try fit(a, if (s.artist.len > 0) s.artist else s.albumartist, w), reset });
        const al = if (s.date.len >= 4) try std.fmt.allocPrint(a, "{s} \u{B7} {s}", .{ s.album, s.date[0..4] }) else s.album;
        try lines[2].print(a, "{s}{s}{s}", .{ fuji_gray, try fit(a, al, w), reset });
    }
    try progress(&lines[bar_line], a, w, st);
    const fl = &lines[n - 1];
    try flag(fl, a, st.repeat, icon_repeat);
    try flag(fl, a, st.single, icon_single);
    try flag(fl, a, st.random, icon_random);
    try flag(fl, a, st.consume, icon_consume);
    if (st.volume >= 0) try fl.print(a, " {s}{s} {d}%", .{ spring_green, icon_volume, st.volume });
    try fl.appendSlice(a, reset);
    for (lines[0..n], 0..) |l, i| {
        if (pos.row + i > t.rows) break;
        try f.print(a, "\x1b[{d};{d}H\x1b[K{s}", .{ pos.row + i, pos.col, l.items });
    }
}

const Placed = struct { rows: usize, cols: usize };

/// image fitted into max_cols x max_rows cells keeping aspect, top-left at (1, col0 or centred).
fn drawImage(f: *std.ArrayList(u8), a: Allocator, t: *const Term, im: Image, max_cols: usize, max_rows: usize, center: bool) !?Placed {
    if (max_rows < 2 or max_cols < 2) return null;
    const aspect = @as(f64, @floatFromInt(im.w)) / @as(f64, @floatFromInt(im.h));
    const cw: f64 = @floatFromInt(t.cw);
    const ch: f64 = @floatFromInt(t.ch);
    var wc: usize = max_cols;
    var hc: usize = @intFromFloat(@round(@as(f64, @floatFromInt(wc)) * cw / aspect / ch));
    if (hc > max_rows) {
        hc = max_rows;
        wc = @intFromFloat(@round(@as(f64, @floatFromInt(hc)) * ch * aspect / cw));
    }
    wc = std.math.clamp(wc, 1, max_cols);
    hc = std.math.clamp(hc, 1, max_rows);
    // pixel size matching the cell box, never above the source and capped at 640px
    const box_w: f64 = @floatFromInt(wc * t.cw);
    const box_h: f64 = @floatFromInt(hc * t.ch);
    var k = @min(box_w / @as(f64, @floatFromInt(im.w)), box_h / @as(f64, @floatFromInt(im.h)));
    k = @min(k, 1.0);
    k = @min(k, 640.0 / @as(f64, @floatFromInt(@max(im.w, im.h))));
    const pw = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(im.w)) * k))));
    const ph = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(im.h)) * k))));
    const px = try scale(a, im, pw, ph);
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(px.len));
    _ = std.base64.standard.Encoder.encode(b64, px);

    const col0: usize = if (center) (t.cols - wc) / 2 + 1 else 1;
    if (!t.tmux) try f.print(a, "\x1b[1;{d}H", .{col0});
    const chunk = 4096;
    var off: usize = 0;
    while (off < b64.len) {
        const end = @min(off + chunk, b64.len);
        const more: u8 = if (end < b64.len) '1' else '0';
        const ctrl = if (off == 0)
            try std.fmt.allocPrint(a, "a=T,f=32,s={d},v={d},i={d},c={d},r={d},C=1,q=2{s},m={c}", .{ pw, ph, t.id, wc, hc, if (t.tmux) ",U=1" else "", more })
        else
            try std.fmt.allocPrint(a, "m={c}", .{more});
        try apc(f, a, t, ctrl, b64[off..end]);
        off = end;
    }
    if (t.tmux) {
        // virtual placement: the image shows wherever these placeholder cells are
        const id = t.id;
        for (0..@min(hc, diacritics.len)) |r| {
            try f.print(a, "\x1b[{d};{d}H\x1b[38;2;{d};{d};{d}m", .{ 1 + r, col0, (id >> 16) & 255, (id >> 8) & 255, id & 255 });
            var tmp: [4]u8 = undefined;
            for (0..wc) |cidx| {
                var n = try std.unicode.utf8Encode(placeholder, &tmp);
                try f.appendSlice(a, tmp[0..n]);
                if (cidx == 0) {
                    n = try std.unicode.utf8Encode(diacritics[r], &tmp);
                    try f.appendSlice(a, tmp[0..n]);
                    n = try std.unicode.utf8Encode(diacritics[0], &tmp);
                    try f.appendSlice(a, tmp[0..n]);
                }
            }
            try f.appendSlice(a, "\x1b[39m");
        }
    }
    return .{ .rows = hc, .cols = wc };
}

// ---- main loop

var sig_wr: std.c.fd_t = -1;

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    const b: [1]u8 = .{@intCast(@intFromEnum(sig))};
    _ = std.c.write(sig_wr, &b, 1);
}

const usage = "usage: drome-lord cover [--host 127.0.0.1] [--port 6600] [--layout auto|horizontal|vertical] [--no-text] [--no-image] [--placeholders]\n";

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const gpa = init.gpa;
    const io = init.io;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 6600;
    var force_placeholders = false;
    var dump_path: ?[]const u8 = null;
    var opts: Opts = .{};
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--host")) host = args.next() orelse return error.BadArgs else if (std.mem.eql(u8, a, "--port")) port = try std.fmt.parseInt(u16, args.next() orelse return error.BadArgs, 10) else if (std.mem.eql(u8, a, "--placeholders")) force_placeholders = true else if (std.mem.eql(u8, a, "--layout")) opts.layout = std.meta.stringToEnum(Layout, args.next() orelse "") orelse return error.BadArgs else if (std.mem.eql(u8, a, "--no-text")) opts.text = false else if (std.mem.eql(u8, a, "--no-image")) opts.image = false else if (std.mem.eql(u8, a, "--dump")) dump_path = args.next() else {
            std.debug.print(usage, .{});
            return;
        }
    }
    if (!opts.text and !opts.image) {
        std.debug.print("--no-text and --no-image together leave nothing to show\n", .{});
        return;
    }
    if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";
    const addr = try Io.net.IpAddress.parse(host, port);

    var term: Term = .{
        .tmux = force_placeholders or ((init.environ_map.get("TMUX") orelse @as([]const u8, "")).len > 0),
        .id = 0x10000 + @as(u32, @intCast(std.c.getpid() & 0xffff)),
    };

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.Pipe;
    sig_wr = pipe_fds[1];
    const act: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    inline for (.{ .WINCH, .INT, .TERM, .HUP }) |s| std.posix.sigaction(s, &act, null);

    const saved = std.posix.tcgetattr(0) catch null;
    if (saved) |sv| {
        var raw = sv;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        std.posix.tcsetattr(0, .NOW, raw) catch {};
    }
    try writeAll(1, "\x1b[?1049h\x1b[?25l");
    defer {
        var f: std.ArrayList(u8) = .empty;
        defer f.deinit(gpa);
        const del: []const u8 = std.fmt.allocPrint(gpa, "a=d,d=I,i={d},q=2", .{term.id}) catch "";
        apc(&f, gpa, &term, del, "") catch {};
        f.appendSlice(gpa, "\x1b[?25h\x1b[?1049l") catch {};
        writeAll(1, f.items) catch {};
        if (saved) |sv| std.posix.tcsetattr(0, .NOW, sv) catch {};
    }

    var dump: ?Io.File = null;
    if (dump_path) |p| dump = try Io.Dir.cwd().createFile(io, p, .{});
    defer if (dump) |d| d.close(io);

    var conn: ?*Conn = null;
    defer dropConn(gpa, &conn);
    var drawn_key: []u8 = &.{};
    defer gpa.free(drawn_key);
    var drawn_rows: usize = 0;
    var drawn_cols: usize = 0;
    var drawn_had_song = false;
    var text_pos: TextPos = .{};
    var need_full = true;
    var image: ?Image = null;
    var image_arena: std.heap.ArenaAllocator = .init(gpa);
    defer image_arena.deinit();

    while (true) {
        var frame_arena: std.heap.ArenaAllocator = .init(gpa);
        defer frame_arena.deinit();
        const fa = frame_arena.allocator();
        termSize(&term);
        var f: std.ArrayList(u8) = .empty;

        if (conn == null) {
            if (addr.connect(io, .{ .mode = .stream })) |st| {
                const c = try gpa.create(Conn);
                c.* = .{ .fd = st.socket.handle };
                if (c.line()) |_| conn = c else |_| {
                    _ = std.c.close(c.fd);
                    gpa.destroy(c);
                }
            } else |_| {}
        }

        var song: ?Song = null;
        var status: Status = .{};
        var waiting: []const u8 = "waiting for drome-lord\u{2026}";
        if (conn) |c| blk: {
            const sg = currentSong(c, fa) catch {
                dropConn(gpa, &conn);
                break :blk;
            };
            status = getStatus(c) catch {
                dropConn(gpa, &conn);
                break :blk;
            };
            waiting = "nothing playing";
            song = sg;
            if (sg) |s| {
                const key = try std.fmt.allocPrint(fa, "{s}\x00{s}", .{ s.albumartist, s.album });
                if (!std.mem.eql(u8, key, drawn_key)) {
                    _ = image_arena.reset(.retain_capacity);
                    image = null;
                    if (opts.image) if (albumart(c, fa, s.file)) |art| {
                        if (art) |bytes| image = decode(image_arena.allocator(), bytes);
                    } else |_| {};
                    gpa.free(drawn_key);
                    drawn_key = try gpa.dupe(u8, key);
                    need_full = true;
                }
            } else if (drawn_key.len > 0 or drawn_had_song) {
                gpa.free(drawn_key);
                drawn_key = &.{};
                image = null;
                need_full = true;
            }
        }
        if (conn == null and drawn_had_song) {
            need_full = true;
            image = null;
            gpa.free(drawn_key);
            drawn_key = &.{};
        }
        if (term.rows != drawn_rows or term.cols != drawn_cols) need_full = true;

        if (need_full) {
            try f.appendSlice(fa, "\x1b[2J\x1b[H");
            try apc(&f, fa, &term, try std.fmt.allocPrint(fa, "a=d,d=I,i={d},q=2", .{term.id}), "");
            const horizontal = switch (opts.layout) {
                .horizontal => true,
                .vertical => false,
                .auto => term.cols >= term.rows * 4,
            };
            var placed: ?Placed = null;
            if (opts.image and song != null) if (image) |im| {
                if (!opts.text) {
                    placed = try drawImage(&f, fa, &term, im, term.cols, term.rows, true);
                } else if (horizontal) {
                    placed = try drawImage(&f, fa, &term, im, term.cols -| 24, term.rows, false);
                } else {
                    placed = try drawImage(&f, fa, &term, im, term.cols, term.rows -| textLines(false), true);
                }
            };
            const n = textLines(horizontal);
            text_pos = .{ .horizontal = horizontal, .row = 1, .col = 1, .width = term.cols };
            if (horizontal) {
                const x = if (placed) |p| p.cols + 2 else 0;
                text_pos.col = x + 1;
                text_pos.width = term.cols -| x;
                text_pos.row = if (term.rows > n) (term.rows - n) / 2 + 1 else 1;
            } else if (placed) |p| {
                text_pos.row = p.rows + 1;
            }
            drawn_rows = term.rows;
            drawn_cols = term.cols;
            need_full = false;
        }
        drawn_had_song = song != null;
        if (opts.text) try drawText(&f, fa, &term, text_pos, song, status, waiting);
        if (dump) |d| {
            var wbuf: [4096]u8 = undefined;
            var w = d.writerStreaming(io, &wbuf);
            try w.interface.writeAll(f.items);
            try w.interface.flush();
        }
        try writeAll(1, f.items);

        // wait for mpd events, a signal, or (while playing) the next second tick
        const timeout: c_int = if (opts.text and status.state == .play) 1000 else -1;
        if (conn) |c| {
            try c.send("idle player mixer options\n");
            var fds = [_]std.c.pollfd{
                .{ .fd = c.fd, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = pipe_fds[0], .events = std.c.POLL.IN, .revents = 0 },
            };
            while (true) {
                if (!c.hasData()) {
                    const r = std.c.poll(&fds, 2, timeout);
                    if (r == 0) {
                        // tick: cancel the idle and loop for a fresh status
                        if (!cancelIdle(c)) dropConn(gpa, &conn);
                        break;
                    }
                }
                if (fds[1].revents != 0) {
                    var sb: [16]u8 = undefined;
                    const n = std.c.read(pipe_fds[0], &sb, sb.len);
                    var quit = false;
                    for (sb[0..@intCast(@max(n, 0))]) |sg| {
                        if (sg != @intFromEnum(std.posix.SIG.WINCH)) quit = true;
                    }
                    if (quit) return;
                    if (!cancelIdle(c)) dropConn(gpa, &conn); // resize: size change is detected on the next pass
                    break;
                }
                if (c.hasData() or fds[0].revents != 0) {
                    _ = c.skipResponse() catch dropConn(gpa, &conn);
                    break;
                }
            }
        } else {
            // not connected: retry in a second, but react to signals
            var fds = [_]std.c.pollfd{.{ .fd = pipe_fds[0], .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 1000) > 0) {
                var sb: [16]u8 = undefined;
                const n = std.c.read(pipe_fds[0], &sb, sb.len);
                for (sb[0..@intCast(@max(n, 0))]) |sg| if (sg != @intFromEnum(std.posix.SIG.WINCH)) return;
            }
        }
    }
}

fn cancelIdle(c: *Conn) bool {
    c.send("noidle\n") catch return false;
    _ = c.skipResponse() catch return false;
    return true;
}

fn dropConn(gpa: Allocator, conn: *?*Conn) void {
    if (conn.*) |c| {
        _ = std.c.close(c.fd);
        gpa.destroy(c);
    }
    conn.* = null;
}
