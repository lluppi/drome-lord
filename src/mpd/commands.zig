//! mpd command implementations. each handler writes its response to `cx.w`
//! and returns error.Ack (with code/message set via `cx.fail`) on failure.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const db = @import("../db.zig");
const parse = @import("parse.zig");
const hub_mod = @import("../hub.zig");
const App = @import("../app.zig").App;
const player_mod = @import("../player.zig");
const Player = player_mod.Player;
const Sub = hub_mod.Subsystem;

pub const Ack = enum(u8) {
    arg = 2,
    permission = 4,
    unknown = 5,
    no_exist = 50,
    system = 52,
    playlist_load = 53,
    update_already = 54,
    exist = 56,
};

pub const Error = error{ Ack, Close, WriteFailed, OutOfMemory };

pub const ClientInfo = struct {
    tag_mask: u32 = (1 << db.Tag.names.len) - 1,
    binary_limit: usize = 8192,
};

pub const Cx = struct {
    app: *App,
    w: *Io.Writer,
    arena: Allocator,
    args: []const []const u8,
    cmd: []const u8,
    client: *ClientInfo,
    code: Ack = .arg,
    msg: []const u8 = "",

    pub fn fail(cx: *Cx, code: Ack, comptime fmt: []const u8, args: anytype) error{Ack} {
        cx.code = code;
        cx.msg = std.fmt.allocPrint(cx.arena, fmt, args) catch "error";
        return error.Ack;
    }

    fn need(cx: *Cx, min: usize, max: usize) Error!void {
        if (cx.args.len < min or cx.args.len > max) return cx.fail(.arg, "wrong number of arguments for \"{s}\"", .{cx.cmd});
    }

    fn int(cx: *Cx, i: usize) Error!i64 {
        return std.fmt.parseInt(i64, cx.args[i], 10) catch cx.fail(.arg, "Integer expected: {s}", .{cx.args[i]});
    }

    fn uint(cx: *Cx, i: usize) Error!usize {
        const v = try cx.int(i);
        if (v < 0) return cx.fail(.arg, "Number is negative: {s}", .{cx.args[i]});
        return @intCast(v);
    }

    fn float(cx: *Cx, s: []const u8) Error!f64 {
        return std.fmt.parseFloat(f64, s) catch cx.fail(.arg, "Float expected: {s}", .{s});
    }

    fn boolean(cx: *Cx, i: usize) Error!bool {
        const v = try cx.int(i);
        if (v != 0 and v != 1) return cx.fail(.arg, "Boolean (0/1) expected: {s}", .{cx.args[i]});
        return v == 1;
    }

    fn range(cx: *Cx, i: usize) Error!parse.Range {
        return parse.parseRange(cx.args[i]) orelse cx.fail(.arg, "Bad range: {s}", .{cx.args[i]});
    }

    /// resolves an optional range against a length; end beyond len is clamped.
    fn bounds(cx: *Cx, r: ?parse.Range, len: usize) Error![2]usize {
        const rr = r orelse return .{ 0, len };
        if (rr.start > len or (rr.end != null and rr.end.? < rr.start)) return cx.fail(.arg, "Bad song index", .{});
        return .{ rr.start, @min(rr.end orelse len, len) };
    }

    pub fn query(cx: *Cx, args: []const []const u8, search: bool) Error!parse.Query {
        return parse.parseQuery(cx.arena, args, search) catch cx.fail(.arg, "Bad filter", .{});
    }
};

const Cmd = enum {
    close, ping, password, commands, notcommands, tagtypes, urlhandlers, decoders, binarylimit, protocol,
    status, currentsong, stats, clearerror, replay_gain_status, replay_gain_mode,
    consume, random, repeat, single, setvol, getvol, volume, crossfade, mixrampdb, mixrampdelay,
    play, playid, pause, stop, next, previous, seek, seekid, seekcur,
    add, addid, clear, delete, deleteid, move, moveid, playlistinfo, playlistid, plchanges,
    plchangesposid, playlistfind, playlistsearch, shuffle, swap, swapid, prio, prioid, rangeid,
    addtagid, cleartagid,
    listplaylists, listplaylist, listplaylistinfo, load, playlistadd, playlistclear, playlistdelete,
    playlistmove, rename, rm, save,
    list, find, findadd, search, searchadd, searchaddpl, count, lsinfo, listall, listallinfo,
    listfiles, update, rescan, albumart, readpicture, getfingerprint,
    outputs, enableoutput, disableoutput, toggleoutput,
};

/// names for `commands`, including the ones handled by the server loop.
pub fn commandNames(w: *Io.Writer) !void {
    inline for (@typeInfo(Cmd).@"enum".field_names) |n| try w.print("command: {s}\n", .{n});
    try w.writeAll("command: idle\ncommand: noidle\ncommand: command_list_begin\ncommand: command_list_ok_begin\ncommand: command_list_end\n");
}

pub fn isKnown(name: []const u8) bool {
    return std.meta.stringToEnum(Cmd, name) != null;
}

pub fn execute(cx: *Cx) Error!void {
    const cmd = std.meta.stringToEnum(Cmd, cx.cmd) orelse
        return cx.fail(.unknown, "unknown command \"{s}\"", .{cx.cmd});
    switch (cmd) {
        .close => return error.Close,
        .ping, .password, .protocol, .urlhandlers, .decoders, .notcommands => {},
        .commands => try commandNames(cx.w),
        .tagtypes => try cmdTagtypes(cx),
        .binarylimit => {
            try cx.need(1, 1);
            const n = try cx.uint(0);
            if (n < 64) return cx.fail(.arg, "Value too small", .{});
            cx.client.binary_limit = n;
        },
        .status => try cmdStatus(cx),
        .currentsong => try cmdCurrentsong(cx),
        .stats => try cmdStats(cx),
        .clearerror => {
            cx.app.player.lock();
            defer cx.app.player.unlock();
            cx.app.player.clearError();
            cx.app.hub.notify(Sub.player.bit());
        },
        .replay_gain_status => {
            cx.app.player.lock();
            defer cx.app.player.unlock();
            try cx.w.print("replay_gain_mode: {s}\n", .{cx.app.player.replay_gain});
        },
        .replay_gain_mode => {
            try cx.need(1, 1);
            const modes = [_][]const u8{ "off", "track", "album", "auto" };
            for (modes) |m| if (std.mem.eql(u8, m, cx.args[0])) {
                cx.app.player.lock();
                defer cx.app.player.unlock();
                cx.app.player.replay_gain = m;
                cx.app.hub.notify(Sub.options.bit());
                return;
            };
            return cx.fail(.arg, "Unrecognized replay gain mode", .{});
        },
        .consume, .random, .repeat, .single, .setvol, .volume, .crossfade, .mixrampdb, .mixrampdelay => try cmdOption(cx, cmd),
        .getvol => {
            cx.app.player.lock();
            defer cx.app.player.unlock();
            try cx.w.print("volume: {d}\n", .{cx.app.player.volume});
        },
        .play, .playid, .pause, .stop, .next, .previous, .seek, .seekid, .seekcur => try cmdPlayback(cx, cmd),
        .add, .addid => try cmdAdd(cx, cmd == .addid),
        .clear => {
            const p = cx.app.player;
            p.lock();
            defer p.unlock();
            p.clear(p.bump());
            cx.app.hub.notify(Sub.playlist.bit());
        },
        .delete, .deleteid, .move, .moveid, .swap, .swapid, .shuffle, .prio, .prioid, .rangeid => try cmdQueueEdit(cx, cmd),
        .playlistinfo, .playlistid, .plchanges, .plchangesposid, .playlistfind, .playlistsearch => try cmdQueueInfo(cx, cmd),
        .addtagid, .cleartagid => return cx.fail(.arg, "tags on queue entries are not supported", .{}),
        .listplaylists, .listplaylist, .listplaylistinfo, .load, .playlistadd, .playlistclear, .playlistdelete, .playlistmove, .rename, .rm, .save, .searchaddpl => try @import("playlists.zig").run(cx, @tagName(cmd)),
        .list => try cmdList(cx),
        .find, .search => try cmdFind(cx, cmd == .search),
        .findadd, .searchadd => try cmdFindAdd(cx, cmd == .searchadd),
        .count => try cmdCount(cx),
        .lsinfo, .listall, .listallinfo, .listfiles => try cmdBrowse(cx, cmd),
        .update, .rescan => {
            const job = (cx.app.startUpdate() catch return cx.fail(.system, "cannot start update", .{})) orelse return cx.fail(.update_already, "already updating", .{});
            try cx.w.print("updating_db: {d}\n", .{job});
        },
        .albumart, .readpicture => try cmdAlbumart(cx, cmd == .readpicture),
        .getfingerprint => return cx.fail(.arg, "fingerprints are not supported", .{}),
        .outputs => try cmdOutputs(cx),
        .enableoutput, .disableoutput, .toggleoutput => {
            try cx.need(1, 1);
            if ((try cx.uint(0)) != 0) return cx.fail(.no_exist, "No such audio output", .{});
            const p = cx.app.player;
            p.lock();
            defer p.unlock();
            p.output_enabled = switch (cmd) {
                .enableoutput => true,
                .disableoutput => false,
                else => !p.output_enabled,
            };
            if (!p.output_enabled) p.setPause(true);
            cx.app.hub.notify(Sub.output.bit());
        },
    }
}

// ---- song output

pub fn writeIso(w: *Io.Writer, secs: i64) Error!void {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

pub fn writeSongInfo(cx: *Cx, s: *const db.Song) Error!void {
    const w = cx.w;
    try w.print("file: {s}\n", .{s.path});
    if (s.mtime > 0) {
        try w.writeAll("Last-Modified: ");
        try writeIso(w, s.mtime);
        try w.writeByte('\n');
    }
    if (s.rate > 0) {
        if (s.bits > 0) try w.print("Format: {d}:{d}:{d}\n", .{ s.rate, s.bits, s.channels }) else try w.print("Format: {d}:f:{d}\n", .{ s.rate, s.channels });
    }
    for (std.enums.values(db.Tag)) |t| {
        if (cx.client.tag_mask & (@as(u32, 1) << @intFromEnum(t)) != 0) {
            var b: db.TagBuf = .{};
            for (s.tagValues(t, &b)) |v| try w.print("{s}: {s}\n", .{ t.label(), v });
        }
    }
    if (s.duration > 0) try w.print("Time: {d}\nduration: {d:.3}\n", .{ @as(u64, @intFromFloat(@round(s.duration))), s.duration });
}

fn writeEntry(cx: *Cx, pos: usize, e: *const player_mod.Entry) Error!void {
    try writeSongInfo(cx, &e.song);
    try cx.w.print("Pos: {d}\nId: {d}\n", .{ pos, e.id });
    if (e.prio > 0) try cx.w.print("Prio: {d}\n", .{e.prio});
}

// ---- status & options

fn cmdTagtypes(cx: *Cx) Error!void {
    const all: u32 = (1 << db.Tag.names.len) - 1;
    if (cx.args.len == 0) {
        for (db.Tag.names, 0..) |n, i| if (cx.client.tag_mask & (@as(u32, 1) << @intCast(i)) != 0) try cx.w.print("tagtype: {s}\n", .{n});
        return;
    }
    const sub = cx.args[0];
    if (std.ascii.eqlIgnoreCase(sub, "clear")) cx.client.tag_mask = 0 else if (std.ascii.eqlIgnoreCase(sub, "all") or std.ascii.eqlIgnoreCase(sub, "reset")) cx.client.tag_mask = all else if (std.ascii.eqlIgnoreCase(sub, "enable") or std.ascii.eqlIgnoreCase(sub, "disable")) {
        for (cx.args[1..]) |n| {
            const t = db.Tag.parse(n) orelse return cx.fail(.arg, "Unknown tag type: {s}", .{n});
            const bit = @as(u32, 1) << @intFromEnum(t);
            if (std.ascii.eqlIgnoreCase(sub, "enable")) cx.client.tag_mask |= bit else cx.client.tag_mask &= ~bit;
        }
    } else return cx.fail(.arg, "Unknown sub command", .{});
}

fn cmdStatus(cx: *Cx) Error!void {
    const p = cx.app.player;
    p.lock();
    defer p.unlock();
    const w = cx.w;
    try w.print("volume: {d}\nrepeat: {d}\nrandom: {d}\nsingle: {s}\nconsume: {d}\npartition: default\n", .{
        p.volume,
        @intFromBool(p.repeat),
        @intFromBool(p.random),
        switch (p.single) {
            .off => "0",
            .on => "1",
            .oneshot => "oneshot",
        },
        @intFromBool(p.consume),
    });
    try w.print("playlist: {d}\nplaylistlength: {d}\n", .{ p.version, p.queue.items.len });
    if (p.crossfade > 0) try w.print("xfade: {d}\n", .{p.crossfade});
    try w.print("mixrampdb: {d:.6}\n", .{p.mixrampdb});
    if (p.mixrampdelay >= 0) try w.print("mixrampdelay: {d:.6}\n", .{p.mixrampdelay});
    try w.print("state: {s}\n", .{@tagName(p.state)});
    if (p.curPos()) |pos| {
        try w.print("song: {d}\nsongid: {d}\n", .{ pos, p.queue.items[pos].id });
        if (p.peekNext()) |nid| if (p.posOf(nid)) |np| try w.print("nextsong: {d}\nnextsongid: {d}\n", .{ np, nid });
        if (p.state != .stop) {
            const d = p.duration();
            try w.print("time: {d}:{d}\nelapsed: {d:.3}\n", .{ @as(u64, @intFromFloat(p.elapsed)), @as(u64, @intFromFloat(d)), p.elapsed });
            const e = &p.queue.items[pos];
            const br: u64 = if (e.song.bitrate > 0) e.song.bitrate else @intFromFloat(p.mpv_bitrate / 1000);
            if (br > 0) try w.print("bitrate: {d}\n", .{br});
            if (d > 0) try w.print("duration: {d:.3}\n", .{d});
            if (e.song.rate > 0) {
                if (e.song.bits > 0) try w.print("audio: {d}:{d}:{d}\n", .{ e.song.rate, e.song.bits, e.song.channels }) else try w.print("audio: {d}:f:{d}\n", .{ e.song.rate, e.song.channels });
            }
        }
    }
    const job = cx.app.update_job.load(.acquire);
    if (job != 0) try w.print("updating_db: {d}\n", .{job});
    if (p.errorText()) |e| try w.print("error: {s}\n", .{e});
}

fn cmdCurrentsong(cx: *Cx) Error!void {
    const p = cx.app.player;
    p.lock();
    defer p.unlock();
    if (p.curPos()) |pos| try writeEntry(cx, pos, &p.queue.items[pos]);
}

fn cmdStats(cx: *Cx) Error!void {
    const lib = cx.app.lockLib();
    defer cx.app.unlockLib();
    const up = cx.app.started.durationTo(Io.Timestamp.now(cx.app.io, .awake)).toSeconds();
    try cx.w.print("artists: {d}\nalbums: {d}\nsongs: {d}\nuptime: {d}\nplaytime: 0\ndb_playtime: {d}\ndb_update: {d}\n", .{
        lib.artists, lib.albums, lib.songs.len, up, @as(u64, @intFromFloat(lib.playtime)), lib.updated,
    });
}

fn cmdOption(cx: *Cx, cmd: Cmd) Error!void {
    try cx.need(1, 1);
    const p = cx.app.player;
    p.lock();
    defer p.unlock();
    switch (cmd) {
        .consume => p.consume = try cx.boolean(0),
        .repeat => p.repeat = try cx.boolean(0),
        .random => p.random = try cx.boolean(0),
        .single => {
            if (std.mem.eql(u8, cx.args[0], "oneshot")) p.single = .oneshot else p.single = if (try cx.boolean(0)) .on else .off;
        },
        .setvol => {
            const v = try cx.int(0);
            if (v < 0 or v > 100) return cx.fail(.arg, "Invalid volume value: {d}", .{v});
            p.setVolume(@intCast(v));
            return;
        },
        .volume => {
            p.setVolume(p.volume + @as(i32, @intCast(std.math.clamp(try cx.int(0), -100, 100))));
            return;
        },
        .crossfade => {
            p.crossfade = @intCast(try cx.uint(0));
        },
        .mixrampdb => p.mixrampdb = @floatCast(try cx.float(cx.args[0])),
        .mixrampdelay => p.mixrampdelay = @floatCast(try cx.float(cx.args[0])),
        else => unreachable,
    }
    p.optionsChanged();
}

// ---- playback

fn cmdPlayback(cx: *Cx, cmd: Cmd) Error!void {
    const p = cx.app.player;
    p.lock();
    defer p.unlock();
    switch (cmd) {
        .play => {
            try cx.need(0, 1);
            var pos: ?usize = null;
            if (cx.args.len == 1) {
                const v = try cx.int(0);
                if (v >= 0) pos = @intCast(v);
            }
            p.play(pos) catch return cx.fail(.no_exist, "Bad song index", .{});
        },
        .playid => {
            try cx.need(0, 1);
            if (cx.args.len == 0 or (try cx.int(0)) < 0) return p.play(null) catch {};
            const i = p.posOf(@intCast(try cx.uint(0))) orelse return cx.fail(.no_exist, "No such song", .{});
            p.play(i) catch {};
        },
        .pause => {
            try cx.need(0, 1);
            p.setPause(if (cx.args.len == 1) try cx.boolean(0) else p.state == .play);
        },
        .stop => p.stopPlayback(false),
        .next => p.next(),
        .previous => p.previous(),
        .seek => {
            try cx.need(2, 2);
            p.seekTo(try cx.uint(0), try cx.float(cx.args[1])) catch return cx.fail(.no_exist, "Bad song index", .{});
        },
        .seekid => {
            try cx.need(2, 2);
            const i = p.posOf(@intCast(try cx.uint(0))) orelse return cx.fail(.no_exist, "No such song", .{});
            p.seekTo(i, try cx.float(cx.args[1])) catch return cx.fail(.no_exist, "Bad song index", .{});
        },
        .seekcur => {
            try cx.need(1, 1);
            const a = cx.args[0];
            const rel = a.len > 0 and (a[0] == '+' or a[0] == '-');
            p.seekCur(try cx.float(a), rel) catch return cx.fail(.arg, "Not playing", .{});
        },
        else => unreachable,
    }
}

// ---- queue

pub fn addSongsPublic(cx: *Cx, songs: []const *const db.Song, pos: ?usize) Error!?u32 {
    return addSongs(cx, songs, pos);
}

fn addSongs(cx: *Cx, songs: []const *const db.Song, pos: ?usize) Error!?u32 {
    const p = cx.app.player;
    p.lock();
    defer p.unlock();
    if (songs.len == 0) return null;
    const ver = p.bump();
    var first: ?u32 = null;
    for (songs, 0..) |s, i| {
        const id = p.insert(s.*, if (pos) |x| x + i else null, ver) catch return cx.fail(.system, "out of memory", .{});
        if (first == null) first = id;
    }
    p.syncNext();
    cx.app.hub.notify(Sub.playlist.bit());
    return first;
}

/// songs at `uri`: a single file or everything below a directory.
pub fn songsAt(cx: *Cx, lib: *const db.Library, uri_raw: []const u8) Error![]const *const db.Song {
    const uri = std.mem.trim(u8, uri_raw, "/");
    var out: std.ArrayList(*const db.Song) = .empty;
    if (lib.findPath(uri)) |s| {
        try out.append(cx.arena, s);
        return out.items;
    }
    const r = dirRange(lib, uri);
    for (lib.songs[r[0]..r[1]]) |*s| try out.append(cx.arena, s);
    if (out.items.len == 0) return cx.fail(.no_exist, "No such directory", .{});
    return out.items;
}

fn cmdAdd(cx: *Cx, with_id: bool) Error!void {
    try cx.need(if (with_id) 1 else 0, 2);
    const uri = if (cx.args.len > 0) cx.args[0] else "";
    const pos: ?usize = if (cx.args.len > 1) try cx.uint(1) else null;
    const lib = cx.app.lockLib();
    defer cx.app.unlockLib();
    const songs = try songsAt(cx, lib, uri);
    if (with_id and songs.len != 1) return cx.fail(.no_exist, "No such song", .{});
    const id = try addSongs(cx, songs, pos);
    if (with_id) try cx.w.print("Id: {d}\n", .{id.?});
}

fn parseId(cx: *Cx, p: *Player, i: usize) Error!usize {
    return p.posOf(@intCast(try cx.uint(i))) orelse cx.fail(.no_exist, "No such song", .{});
}

fn cmdQueueEdit(cx: *Cx, cmd: Cmd) Error!void {
    const p = cx.app.player;
    p.lock();
    defer p.unlock();
    const len = p.queue.items.len;
    switch (cmd) {
        .delete, .deleteid => {
            try cx.need(if (cmd == .delete) 0 else 1, 1);
            var s: usize = 0;
            var e: usize = len;
            if (cmd == .deleteid) {
                s = try parseId(cx, p, 0);
                e = s + 1;
            } else if (cx.args.len == 1) {
                const r = try cx.range(0);
                if (r.start >= len or (r.end != null and r.end.? > len)) return cx.fail(.arg, "Bad song index", .{});
                s = r.start;
                e = r.end orelse len;
            }
            p.deleteRange(s, e, p.bump());
        },
        .move, .moveid => {
            try cx.need(2, 2);
            var s: usize = undefined;
            var e: usize = undefined;
            if (cmd == .moveid) {
                s = try parseId(cx, p, 0);
                e = s + 1;
            } else {
                const r = try cx.range(0);
                s = r.start;
                e = r.end orelse (r.start + 1);
            }
            var to: usize = undefined;
            const ts = cx.args[1];
            if (ts.len > 0 and (ts[0] == '+' or ts[0] == '-')) {
                const off = std.fmt.parseInt(i64, ts, 10) catch return cx.fail(.arg, "Integer expected", .{});
                const cur = @as(i64, @intCast(s)) + off;
                if (cur < 0) return cx.fail(.arg, "Bad song index", .{});
                to = @intCast(cur);
            } else to = try cx.uint(1);
            if (s >= e or e > len or to + (e - s) > len) return cx.fail(.arg, "Bad song index", .{});
            try p.move(s, e, to, p.bump());
        },
        .swap, .swapid => {
            try cx.need(2, 2);
            var a: usize = undefined;
            var b: usize = undefined;
            if (cmd == .swapid) {
                a = try parseId(cx, p, 0);
                b = try parseId(cx, p, 1);
            } else {
                a = try cx.uint(0);
                b = try cx.uint(1);
            }
            if (a >= len or b >= len) return cx.fail(.arg, "Bad song index", .{});
            p.swap(a, b, p.bump());
        },
        .shuffle => {
            try cx.need(0, 1);
            const b = try cx.bounds(if (cx.args.len == 1) try cx.range(0) else null, len);
            p.shuffle(b[0], b[1], p.bump());
        },
        .prio, .prioid => {
            if (cx.args.len < 2) return cx.fail(.arg, "wrong number of arguments", .{});
            const pr: u8 = @intCast(std.math.clamp(try cx.int(0), 0, 255));
            const ver = p.bump();
            for (cx.args[1..], 1..) |_, i| {
                if (cmd == .prioid) {
                    const pos = try parseId(cx, p, i);
                    p.queue.items[pos].prio = pr;
                    p.queue.items[pos].ver = ver;
                } else {
                    const b = try cx.bounds(try cx.range(i), len);
                    for (p.queue.items[b[0]..b[1]]) |*e| {
                        e.prio = pr;
                        e.ver = ver;
                    }
                }
            }
        },
        .rangeid => try cx.need(2, 2), // per-song playback ranges are not supported; accepted as no-op
        else => unreachable,
    }
    p.syncNext();
    cx.app.hub.notify(Sub.playlist.bit());
}

fn cmdQueueInfo(cx: *Cx, cmd: Cmd) Error!void {
    const p = cx.app.player;
    p.lock();
    defer p.unlock();
    const items = p.queue.items;
    switch (cmd) {
        .playlistinfo => {
            try cx.need(0, 1);
            const r: ?parse.Range = if (cx.args.len == 1) try cx.range(0) else null;
            if (r) |rr| if (rr.end != null and rr.start >= items.len and rr.end.? == rr.start + 1) return cx.fail(.arg, "Bad song index", .{});
            const b = try cx.bounds(r, items.len);
            for (items[b[0]..b[1]], b[0]..) |*e, i| try writeEntry(cx, i, e);
        },
        .playlistid => {
            try cx.need(0, 1);
            if (cx.args.len == 1) {
                const i = try parseId(cx, p, 0);
                try writeEntry(cx, i, &items[i]);
            } else for (items, 0..) |*e, i| try writeEntry(cx, i, e);
        },
        .plchanges, .plchangesposid => {
            try cx.need(1, 2);
            const v = try cx.int(0);
            const b = try cx.bounds(if (cx.args.len == 2) try cx.range(1) else null, items.len);
            for (items[b[0]..b[1]], b[0]..) |*e, i| if (v < 0 or e.ver > v) {
                if (cmd == .plchanges) try writeEntry(cx, i, e) else try cx.w.print("cpos: {d}\nId: {d}\n", .{ i, e.id });
            };
        },
        .playlistfind, .playlistsearch => {
            const q = try cx.query(cx.args, cmd == .playlistsearch);
            for (items, 0..) |*e, i| if (q.filter.matches(&e.song, cmd == .playlistsearch)) try writeEntry(cx, i, e);
        },
        else => unreachable,
    }
}

// ---- database queries

fn ciLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return lx < ly;
    }
    return a.len < b.len;
}

pub fn select(cx: *Cx, lib: *const db.Library, q: parse.Query, fold: bool) Error![]*const db.Song {
    var out: std.ArrayList(*const db.Song) = .empty;
    for (lib.songs) |*s| if (q.filter.matches(s, fold)) try out.append(cx.arena, s);
    if (q.sort) |t| {
        const Item = struct { s: *const db.Song, key: []const u8, num: u32 };
        const items = try cx.arena.alloc(Item, out.items.len);
        for (out.items, items) |s, *it| {
            var b: db.TagBuf = .{};
            const vals = s.tagValues(t, &b);
            it.s = s;
            it.key = if (vals.len > 0) try cx.arena.dupe(u8, vals[0]) else "";
            it.num = std.fmt.parseInt(u32, it.key, 10) catch 0;
        }
        const numeric = t == .track or t == .disc or t == .date;
        const Ctx = struct {
            desc: bool,
            numeric: bool,
            fn lt(c: @This(), x: Item, y: Item) bool {
                if (c.numeric) return if (c.desc) x.num > y.num else x.num < y.num;
                return if (c.desc) ciLess(y.key, x.key) else ciLess(x.key, y.key);
            }
        };
        std.mem.sort(Item, items, Ctx{ .desc = q.sort_desc, .numeric = numeric }, Ctx.lt);
        for (items, out.items) |it, *o| o.* = it.s;
    } else if (q.sort_file and q.sort_desc) std.mem.reverse(*const db.Song, out.items);
    if (q.window) |wd| {
        const s = @min(wd.start, out.items.len);
        const e = @min(wd.end orelse out.items.len, out.items.len);
        return out.items[s..@max(s, e)];
    }
    return out.items;
}

fn cmdFind(cx: *Cx, fold: bool) Error!void {
    const q = try cx.query(cx.args, fold);
    const lib = cx.app.lockLib();
    defer cx.app.unlockLib();
    for (try select(cx, lib, q, fold)) |s| try writeSongInfo(cx, s);
}

fn cmdFindAdd(cx: *Cx, fold: bool) Error!void {
    const q = try cx.query(cx.args, fold);
    const lib = cx.app.lockLib();
    defer cx.app.unlockLib();
    _ = try addSongs(cx, try select(cx, lib, q, fold), null);
}

fn cmdCount(cx: *Cx) Error!void {
    const q = try cx.query(cx.args, false);
    const lib = cx.app.lockLib();
    defer cx.app.unlockLib();
    const songs = try select(cx, lib, q, false);
    if (q.groups.len == 0) {
        var t: f64 = 0;
        for (songs) |s| t += s.duration;
        try cx.w.print("songs: {d}\nplaytime: {d}\n", .{ songs.len, @as(u64, @intFromFloat(t)) });
        return;
    }
    const g = q.groups[0];
    var map: std.StringArrayHashMapUnmanaged([2]f64) = .empty;
    for (songs) |s| {
        var b: db.TagBuf = .{};
        const vals = s.tagValues(g, &b);
        const v = if (vals.len > 0) vals[0] else "";
        const e = try map.getOrPut(cx.arena, try cx.arena.dupe(u8, v));
        if (!e.found_existing) e.value_ptr.* = .{ 0, 0 };
        e.value_ptr[0] += 1;
        e.value_ptr[1] += s.duration;
    }
    const keys = map.keys();
    const idx = try cx.arena.alloc(usize, keys.len);
    for (idx, 0..) |*x, i| x.* = i;
    std.mem.sort(usize, idx, keys, struct {
        fn lt(k: [][]const u8, a: usize, b: usize) bool {
            return ciLess(k[a], k[b]);
        }
    }.lt);
    for (idx) |i| try cx.w.print("{s}: {s}\nsongs: {d}\nplaytime: {d}\n", .{ g.label(), keys[i], @as(u64, @intFromFloat(map.values()[i][0])), @as(u64, @intFromFloat(map.values()[i][1])) });
}

const Row = []const []const u8;

fn rowLess(_: void, a: Row, b: Row) bool {
    for (a, b) |x, y| {
        if (std.mem.eql(u8, x, y)) continue;
        return ciLess(x, y) or (!ciLess(y, x) and std.mem.lessThan(u8, x, y));
    }
    return false;
}

fn cmdList(cx: *Cx) Error!void {
    if (cx.args.len == 0) return cx.fail(.arg, "wrong number of arguments for \"list\"", .{});
    const ty = db.Tag.parse(cx.args[0]) orelse return cx.fail(.arg, "Unknown tag type: {s}", .{cx.args[0]});
    var rest = cx.args[1..];
    var legacy: [2][]const u8 = undefined;
    // old-style `list album "Artist"`
    if (rest.len == 1 and (rest[0].len == 0 or rest[0][0] != '(')) {
        legacy = .{ "artist", rest[0] };
        rest = &legacy;
    }
    const q = try cx.query(rest, false);
    const lib = cx.app.lockLib();
    defer cx.app.unlockLib();
    const songs = try select(cx, lib, q, false);

    const depth = q.groups.len + 1;
    var rows: std.ArrayList(Row) = .empty;
    for (songs) |s| {
        const lists = try cx.arena.alloc([]const []const u8, depth);
        var skip = false;
        for (0..depth) |d| {
            const tag = if (d < q.groups.len) q.groups[d] else ty;
            const buf = try cx.arena.create(db.TagBuf);
            buf.* = .{};
            const vals = s.tagValues(tag, buf);
            if (vals.len == 0) {
                if (d == q.groups.len) skip = true;
                lists[d] = &.{""};
            } else lists[d] = vals;
        }
        if (skip) continue;
        const cur = try cx.arena.alloc([]const u8, depth);
        try product(cx.arena, &rows, lists, cur, 0);
    }
    std.mem.sort(Row, rows.items, {}, rowLess);
    var prev: ?Row = null;
    for (rows.items) |r| {
        if (prev) |pr| if (std.mem.eql(u8, pr[depth - 1], r[depth - 1]) and sameGroups(pr, r, depth - 1)) continue;
        if (prev == null or !sameGroups(prev.?, r, depth - 1)) for (q.groups, 0..) |g, i| try cx.w.print("{s}: {s}\n", .{ g.label(), r[i] });
        try cx.w.print("{s}: {s}\n", .{ ty.label(), r[depth - 1] });
        prev = r;
    }
}

fn sameGroups(a: Row, b: Row, n: usize) bool {
    for (a[0..n], b[0..n]) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn product(arena: Allocator, rows: *std.ArrayList(Row), lists: []const []const []const u8, cur: [][]const u8, d: usize) !void {
    if (d == lists.len) {
        try rows.append(arena, try arena.dupe([]const u8, cur));
        return;
    }
    for (lists[d]) |v| {
        cur[d] = v;
        try product(arena, rows, lists, cur, d + 1);
    }
}

// ---- browsing

/// index range of songs under directory `dir` ("" = everything).
fn dirRange(lib: *const db.Library, dir: []const u8) [2]usize {
    if (dir.len == 0) return .{ 0, lib.songs.len };
    const songs = lib.songs;
    var lo: usize = 0;
    var hi: usize = songs.len;
    // first path >= "dir/"
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const p = songs[mid].path;
        const n = @min(p.len, dir.len);
        var o = std.mem.order(u8, p[0..n], dir[0..n]);
        if (o == .eq) o = if (p.len <= dir.len) .lt else std.mem.order(u8, p[dir.len .. dir.len + 1], "/");
        if (o == .lt) lo = mid + 1 else hi = mid;
    }
    var end = lo;
    while (end < songs.len and songs[end].path.len > dir.len and std.mem.startsWith(u8, songs[end].path, dir) and songs[end].path[dir.len] == '/') end += 1;
    return .{ lo, end };
}

fn cmdBrowse(cx: *Cx, cmd: Cmd) Error!void {
    try cx.need(0, 1);
    const dir = std.mem.trim(u8, if (cx.args.len > 0) cx.args[0] else "", "/");
    const lib = cx.app.lockLib();
    defer cx.app.unlockLib();
    const w = cx.w;
    if (dir.len > 0) if (lib.findPath(dir)) |s| {
        if (cmd == .lsinfo or cmd == .listallinfo) try writeSongInfo(cx, s) else try w.print("file: {s}\n", .{s.path});
        return;
    };
    const r = dirRange(lib, dir);
    if (r[0] == r[1] and dir.len > 0) return cx.fail(.no_exist, "No such directory", .{});
    const songs = lib.songs[r[0]..r[1]];
    const skip = if (dir.len == 0) 0 else dir.len + 1;

    if (cmd == .listall or cmd == .listallinfo) {
        var last_dir: []const u8 = "";
        for (songs) |*s| {
            const d = std.fs.path.dirname(s.path) orelse "";
            if (d.len > 0 and !std.mem.eql(u8, d, last_dir)) {
                var it = std.mem.splitScalar(u8, d, '/');
                var li = std.mem.splitScalar(u8, last_dir, '/');
                var same = true;
                var end: usize = 0;
                while (it.next()) |comp| {
                    const lc = li.next();
                    end += comp.len;
                    if (same and lc != null and std.mem.eql(u8, comp, lc.?)) {
                        end += 1;
                        continue;
                    }
                    same = false;
                    if (end > dir.len) try w.print("directory: {s}\n", .{d[0..end]});
                    end += 1;
                }
                last_dir = d;
            }
            if (cmd == .listall) try w.print("file: {s}\n", .{s.path}) else try writeSongInfo(cx, s);
        }
        return;
    }

    // one level: directories first, then files
    var last: []const u8 = "";
    for (songs) |s| {
        const rest = s.path[skip..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
            const name = rest[0..i];
            if (std.mem.eql(u8, name, last)) continue;
            last = name;
            try w.print("directory: {s}\n", .{s.path[0 .. skip + i]});
        }
    }
    for (songs) |*s| {
        const rest = s.path[skip..];
        if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
        if (cmd == .listfiles) try w.print("file: {s}\nsize: {d}\n", .{ rest, s.size }) else try writeSongInfo(cx, s);
    }
    if (cmd == .lsinfo and dir.len == 0) try @import("playlists.zig").run(cx, "lsinfo-root");
}

fn cmdAlbumart(cx: *Cx, picture: bool) Error!void {
    try cx.need(if (picture) 2 else 2, 2);
    const off = try cx.uint(1);
    var cover_buf: [256]u8 = undefined;
    const cover = blk: {
        const lib = cx.app.lockLib();
        defer cx.app.unlockLib();
        const s = lib.findPath(std.mem.trim(u8, cx.args[0], "/")) orelse return cx.fail(.no_exist, "No such file", .{});
        if (s.cover.len == 0 or s.cover.len > cover_buf.len) {
            if (picture) return;
            return cx.fail(.no_exist, "No file exists", .{});
        }
        @memcpy(cover_buf[0..s.cover.len], s.cover);
        break :blk cover_buf[0..s.cover.len];
    };
    const ok = cx.app.coverChunk(cover, off, cx.client.binary_limit, cx.w) catch return cx.fail(.system, "cover cache", .{});
    if (!ok and !picture) return cx.fail(.no_exist, "No file exists", .{});
}

fn cmdOutputs(cx: *Cx) Error!void {
    cx.app.player.lock();
    defer cx.app.player.unlock();
    try cx.w.print("outputid: 0\noutputname: mpv\nplugin: mpv\noutputenabled: {d}\n", .{@intFromBool(cx.app.player.output_enabled)});
}
