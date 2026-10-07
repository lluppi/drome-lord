//! `drome-lord cover`: a tiny mpd client that shows the current song's cover in the terminal
//! with the kitty graphics protocol (unicode placeholders + tmux passthrough inside tmux).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

extern fn stbi_load_from_memory(buf: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int, req: c_int) ?[*]u8;
extern fn stbi_image_free(p: ?*anyopaque) void;

const log = std.log.scoped(.cover);

// row diacritics from kitty's rowcolumn-diacritics table (first entries; enough for 66 rows)
const diacritics = [_]u21{
    0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346, 0x034A, 0x034B, 0x034C,
    0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
    0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
    0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
    0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615,
    0x0616, 0x0617, 0x0657, 0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E,
};
const placeholder: u21 = 0x10EEEE;

const Song = struct { file: []const u8, artist: []const u8, album: []const u8, albumartist: []const u8, title: []const u8 };

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
    var s: Song = .{ .file = "", .artist = "", .album = "", .albumartist = "", .title = "" };
    while (true) {
        const l = try c.line();
        if (std.mem.eql(u8, l, "OK")) break;
        if (std.mem.startsWith(u8, l, "ACK")) return null;
        const i = std.mem.indexOf(u8, l, ": ") orelse continue;
        const k = l[0..i];
        const v = try a.dupe(u8, l[i + 2 ..]);
        if (std.mem.eql(u8, k, "file")) s.file = v else if (std.mem.eql(u8, k, "Artist")) s.artist = v else if (std.mem.eql(u8, k, "Album")) s.album = v else if (std.mem.eql(u8, k, "AlbumArtist")) s.albumartist = v else if (std.mem.eql(u8, k, "Title")) s.title = v;
    }
    return if (s.file.len > 0) s else null;
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

fn put(f: *std.ArrayList(u8), a: Allocator, row: usize, col: usize, text: []const u8) !void {
    try f.print(a, "\x1b[{d};{d}H{s}", .{ row, col, text });
}

/// a line of text centered on `row`, cut to the pane width.
fn centered(f: *std.ArrayList(u8), a: Allocator, t: *const Term, row: usize, text: []const u8) !void {
    var n: usize = 0;
    var end: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (n == t.cols) break;
        n += 1;
        end += cp.len;
    }
    if (n == 0) return;
    try put(f, a, row, (t.cols - n) / 2 + 1, text[0..end]);
}

fn drawFrame(f: *std.ArrayList(u8), a: Allocator, t: *const Term, song: ?Song, img: ?Image, status: []const u8) !void {
    try f.appendSlice(a, "\x1b[2J\x1b[H");
    try apc(f, a, t, try std.fmt.allocPrint(a, "a=d,d=I,i={d},q=2", .{t.id}), "");
    const text_rows: usize = if (t.rows >= 8) 2 else 0;
    if (img) |im| if (song) |s| blk: {
        const avail = t.rows - text_rows;
        const aspect = @as(f64, @floatFromInt(im.w)) / @as(f64, @floatFromInt(im.h));
        const cw: f64 = @floatFromInt(t.cw);
        const ch: f64 = @floatFromInt(t.ch);
        var hc: usize = avail;
        var wc: usize = @intFromFloat(@round(@as(f64, @floatFromInt(hc)) * ch * aspect / cw));
        if (wc > t.cols) {
            wc = t.cols;
            hc = @intFromFloat(@round(@as(f64, @floatFromInt(wc)) * cw / aspect / ch));
        }
        wc = @max(1, wc);
        hc = std.math.clamp(hc, 1, avail);
        // pixel size matching the cell box, never above the source and capped at 640px
        const box_w: f64 = @floatFromInt(wc * t.cw);
        const box_h: f64 = @floatFromInt(hc * t.ch);
        var k = @min(box_w / @as(f64, @floatFromInt(im.w)), box_h / @as(f64, @floatFromInt(im.h)));
        k = @min(k, 1.0);
        k = @min(k, 640.0 / @as(f64, @floatFromInt(@max(im.w, im.h))));
        const pw = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(im.w)) * k))));
        const ph = @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(im.h)) * k))));
        const px = scale(a, im, pw, ph) catch break :blk;
        const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(px.len));
        _ = std.base64.standard.Encoder.encode(b64, px);

        const row0 = (avail - hc) / 2 + 1;
        const col0 = (t.cols - wc) / 2 + 1;
        if (!t.tmux) try f.print(a, "\x1b[{d};{d}H", .{ row0, col0 });
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
                try put(f, a, row0 + r, col0, "");
                try f.print(a, "\x1b[38;2;{d};{d};{d}m", .{ (id >> 16) & 255, (id >> 8) & 255, id & 255 });
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
        if (text_rows > 0) {
            try f.appendSlice(a, "\x1b[1m");
            try centered(f, a, t, t.rows - 1, if (s.title.len > 0) s.title else s.file);
            try f.appendSlice(a, "\x1b[0m");
            const who = try std.fmt.allocPrint(a, "{s} \u{2014} {s}", .{ s.artist, s.album });
            try centered(f, a, t, t.rows, who);
        }
        return;
    };
    // no cover: plain text
    const mid = t.rows / 2;
    if (song) |s| {
        try f.appendSlice(a, "\x1b[1m");
        try centered(f, a, t, mid, if (s.artist.len > 0) s.artist else s.albumartist);
        try f.appendSlice(a, "\x1b[0m");
        try centered(f, a, t, mid + 1, s.album);
        try centered(f, a, t, mid + 2, s.title);
    } else try centered(f, a, t, mid, status);
}

// ---- main loop

var sig_wr: std.c.fd_t = -1;

fn onSignal(sig: std.posix.SIG) callconv(.c) void {
    const b: [1]u8 = .{@intCast(@intFromEnum(sig))};
    _ = std.c.write(sig_wr, &b, 1);
}

pub fn run(init: std.process.Init, args: *std.process.Args.Iterator) !void {
    const gpa = init.gpa;
    const io = init.io;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 6600;
    var force_placeholders = false;
    var dump_path: ?[]const u8 = null;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--host")) host = args.next() orelse return error.BadArgs else if (std.mem.eql(u8, a, "--port")) port = try std.fmt.parseInt(u16, args.next() orelse return error.BadArgs, 10) else if (std.mem.eql(u8, a, "--placeholders")) force_placeholders = true else if (std.mem.eql(u8, a, "--dump")) dump_path = args.next() else {
            std.debug.print("usage: drome-lord cover [--host 127.0.0.1] [--port 6600] [--placeholders]\n", .{});
            return;
        }
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

    var conn: ?*Conn = null;
    var last_key: []u8 = &.{};
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
        var status: []const u8 = "waiting for drome-lord…";
        if (conn) |c| {
            if (currentSong(c, fa)) |maybe| if (maybe) |s| {
                song = s;
                const key = try std.fmt.allocPrint(fa, "{s}\x00{s}", .{ s.albumartist, s.album });
                if (!std.mem.eql(u8, key, last_key)) {
                    _ = image_arena.reset(.retain_capacity);
                    image = null;
                    gpa.free(last_key);
                    last_key = try gpa.dupe(u8, key);
                    if (albumart(c, fa, s.file)) |art| {
                        if (art) |bytes| image = decode(image_arena.allocator(), bytes);
                    } else |_| {}
                }
            } else {
                image = null;
            } else |_| {
                _ = std.c.close(c.fd);
                gpa.destroy(c);
                conn = null;
                gpa.free(last_key);
                last_key = &.{};
                image = null;
            }
            if (conn != null) status = "nothing playing";
        }
        try drawFrame(&f, fa, &term, song, if (song != null) image else null, status);
        if (dump_path) |p| {
            const file = try Io.Dir.cwd().createFile(io, p, .{});
            defer file.close(io);
            var wbuf: [4096]u8 = undefined;
            var w = file.writer(io, &wbuf);
            try w.interface.writeAll(f.items);
            try w.interface.flush();
        }
        try writeAll(1, f.items);

        // wait for a song change (idle) or a signal
        if (conn) |c| {
            try c.send("idle player\n");
            var fds = [_]std.c.pollfd{
                .{ .fd = c.fd, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = pipe_fds[0], .events = std.c.POLL.IN, .revents = 0 },
            };
            while (true) {
                if (!c.hasData()) {
                    _ = std.c.poll(&fds, 2, -1);
                }
                if (fds[1].revents != 0) {
                    var sb: [16]u8 = undefined;
                    const n = std.c.read(pipe_fds[0], &sb, sb.len);
                    var quit = false;
                    var winch = false;
                    for (sb[0..@intCast(@max(n, 0))]) |sg| {
                        if (sg == @intFromEnum(std.posix.SIG.WINCH)) winch = true else quit = true;
                    }
                    if (quit) return;
                    if (winch) {
                        c.send("noidle\n") catch {};
                        _ = c.skipResponse() catch {
                            _ = std.c.close(c.fd);
                            gpa.destroy(c);
                            conn = null;
                        };
                        break;
                    }
                    fds[1].revents = 0;
                    continue;
                }
                if (c.hasData() or fds[0].revents != 0) {
                    const ok = c.skipResponse() catch {
                        _ = std.c.close(c.fd);
                        gpa.destroy(c);
                        conn = null;
                        break;
                    };
                    _ = ok;
                    break;
                }
            }
            if (conn == null) continue;
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
