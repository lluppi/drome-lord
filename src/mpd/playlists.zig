//! stored playlists, backed by subsonic playlists.
const std = @import("std");
const json = std.json;
const db = @import("../db.zig");
const parse = @import("parse.zig");
const cmds = @import("commands.zig");
const Cx = cmds.Cx;
const Error = cmds.Error;
const Sub = @import("../hub.zig").Subsystem;

const PL = struct { id: []const u8, name: []const u8, changed: i64 };
const Params = std.ArrayList([2][]const u8);

fn str(o: json.ObjectMap, k: []const u8) []const u8 {
    const v = o.get(k) orelse return "";
    return if (v == .string) v.string else "";
}

fn call(cx: *Cx, ep: []const u8, params: []const [2][]const u8) Error!json.ObjectMap {
    return cx.app.sc.call(cx.arena, ep, params) catch cx.fail(.system, "subsonic request failed", .{});
}

fn fetchAll(cx: *Cx) Error![]PL {
    const resp = try call(cx, "getPlaylists.view", &.{});
    var out: std.ArrayList(PL) = .empty;
    const pls = resp.get("playlists") orelse return out.items;
    if (pls != .object) return out.items;
    const arr = pls.object.get("playlist") orelse return out.items;
    if (arr != .array) return out.items;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        try out.append(cx.arena, .{ .id = str(it.object, "id"), .name = str(it.object, "name"), .changed = db.parseTime(str(it.object, "changed")) });
    }
    return out.items;
}

fn find(cx: *Cx, name: []const u8) Error!?PL {
    for (try fetchAll(cx)) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn require(cx: *Cx, name: []const u8) Error!PL {
    return (try find(cx, name)) orelse cx.fail(.no_exist, "No such playlist", .{});
}

fn entries(cx: *Cx, id: []const u8) Error![]const []const u8 {
    const resp = try call(cx, "getPlaylist.view", &.{.{ "id", id }});
    var out: std.ArrayList([]const u8) = .empty;
    const pl = resp.get("playlist") orelse return out.items;
    if (pl != .object) return out.items;
    const arr = pl.object.get("entry") orelse return out.items;
    if (arr != .array) return out.items;
    for (arr.array.items) |it| if (it == .object) try out.append(cx.arena, str(it.object, "id"));
    return out.items;
}

fn songsOf(cx: *Cx, lib: *const db.Library, sids: []const []const u8) Error![]const *const db.Song {
    var out: std.ArrayList(*const db.Song) = .empty;
    for (sids) |sid| if (lib.findSid(sid)) |s| try out.append(cx.arena, s);
    return out.items;
}

fn sidParams(cx: *Cx, base: []const [2][]const u8, key: []const u8, songs: []const *const db.Song) Error!Params {
    var p: Params = .empty;
    try p.appendSlice(cx.arena, base);
    for (songs) |s| try p.append(cx.arena, .{ key, s.sid });
    return p;
}

fn done(cx: *Cx) void {
    cx.app.hub.notify(Sub.stored_playlist.bit());
}

pub fn run(cx: *Cx, name: []const u8) Error!void {
    const eq = std.mem.eql;
    const a = cx.args;
    if (eq(u8, name, "lsinfo-root")) {
        const all = fetchAll(cx) catch return;
        for (all) |p| try cx.w.print("playlist: {s}\n", .{p.name});
        return;
    }
    if (eq(u8, name, "listplaylists")) {
        for (try fetchAll(cx)) |p| {
            try cx.w.print("playlist: {s}\n", .{p.name});
            if (p.changed > 0) {
                try cx.w.writeAll("Last-Modified: ");
                try cmds.writeIso(cx.w, p.changed);
                try cx.w.writeByte('\n');
            }
        }
        return;
    }
    if (a.len == 0) return cx.fail(.arg, "wrong number of arguments for \"{s}\"", .{cx.cmd});

    if (eq(u8, name, "save")) {
        if (try find(cx, a[0]) != null) return cx.fail(.exist, "Playlist already exists", .{});
        const lib = cx.app.lockLib();
        defer cx.app.unlockLib();
        var songs: std.ArrayList(*const db.Song) = .empty;
        {
            const p = cx.app.player;
            p.lock();
            defer p.unlock();
            for (p.queue.items) |e| if (lib.findSid(e.song.sid)) |s| try songs.append(cx.arena, s);
        }
        _ = try call(cx, "createPlaylist.view", (try sidParams(cx, &.{.{ "name", a[0] }}, "songId", songs.items)).items);
        return done(cx);
    }
    if (eq(u8, name, "searchaddpl")) {
        if (a.len < 2) return cx.fail(.arg, "wrong number of arguments", .{});
        const q = try cx.query(a[1..], true);
        const lib = cx.app.lockLib();
        defer cx.app.unlockLib();
        return addToPlaylist(cx, a[0], try cmds.select(cx, lib, q, true));
    }

    const pl = try require(cx, a[0]);
    if (eq(u8, name, "listplaylist") or eq(u8, name, "listplaylistinfo")) {
        const sids = try entries(cx, pl.id);
        const lib = cx.app.lockLib();
        defer cx.app.unlockLib();
        for (try songsOf(cx, lib, sids)) |s| {
            if (eq(u8, name, "listplaylist")) try cx.w.print("file: {s}\n", .{s.path}) else try cmds.writeSongInfo(cx, s);
        }
    } else if (eq(u8, name, "load")) {
        const sids = try entries(cx, pl.id);
        const lib = cx.app.lockLib();
        defer cx.app.unlockLib();
        var songs = try songsOf(cx, lib, sids);
        if (a.len > 1) {
            const r = parse.parseRange(a[1]) orelse return cx.fail(.arg, "Bad range", .{});
            const s = @min(r.start, songs.len);
            songs = songs[s..@max(s, @min(r.end orelse songs.len, songs.len))];
        }
        const first = try cmds.addSongsPublic(cx, songs, null);
        _ = first;
    } else if (eq(u8, name, "playlistadd")) {
        if (a.len < 2) return cx.fail(.arg, "wrong number of arguments", .{});
        const lib = cx.app.lockLib();
        defer cx.app.unlockLib();
        try addToPlaylist(cx, a[0], try cmds.songsAt(cx, lib, a[1]));
    } else if (eq(u8, name, "playlistclear")) {
        // createPlaylist with no songs does not empty it, so remove by index
        const n = (try entries(cx, pl.id)).len;
        if (n == 0) return;
        var p: Params = .empty;
        try p.append(cx.arena, .{ "playlistId", pl.id });
        for (0..n) |i| try p.append(cx.arena, .{ "songIndexToRemove", try std.fmt.allocPrint(cx.arena, "{d}", .{i}) });
        _ = try call(cx, "updatePlaylist.view", p.items);
        done(cx);
    } else if (eq(u8, name, "playlistdelete")) {
        if (a.len != 2) return cx.fail(.arg, "wrong number of arguments", .{});
        _ = try call(cx, "updatePlaylist.view", &.{ .{ "playlistId", pl.id }, .{ "songIndexToRemove", a[1] } });
        done(cx);
    } else if (eq(u8, name, "playlistmove")) {
        if (a.len != 3) return cx.fail(.arg, "wrong number of arguments", .{});
        const sids = try cx.arena.dupe([]const u8, try entries(cx, pl.id));
        const from = std.fmt.parseInt(usize, a[1], 10) catch return cx.fail(.arg, "Integer expected", .{});
        const to = std.fmt.parseInt(usize, a[2], 10) catch return cx.fail(.arg, "Integer expected", .{});
        if (from >= sids.len or to >= sids.len) return cx.fail(.arg, "Bad song index", .{});
        const item = sids[from];
        if (from < to) std.mem.copyForwards([]const u8, sids[from..to], sids[from + 1 .. to + 1]) else std.mem.copyBackwards([]const u8, sids[to + 1 .. from + 1], sids[to..from]);
        sids[to] = item;
        var p: Params = .empty;
        try p.append(cx.arena, .{ "playlistId", pl.id });
        for (sids) |s| try p.append(cx.arena, .{ "songId", s });
        _ = try call(cx, "createPlaylist.view", p.items);
        done(cx);
    } else if (eq(u8, name, "rename")) {
        if (a.len != 2) return cx.fail(.arg, "wrong number of arguments", .{});
        if (try find(cx, a[1]) != null) return cx.fail(.exist, "Playlist already exists", .{});
        _ = try call(cx, "updatePlaylist.view", &.{ .{ "playlistId", pl.id }, .{ "name", a[1] } });
        done(cx);
    } else if (eq(u8, name, "rm")) {
        _ = try call(cx, "deletePlaylist.view", &.{.{ "id", pl.id }});
        done(cx);
    }
}

fn addToPlaylist(cx: *Cx, name: []const u8, songs: []const *const db.Song) Error!void {
    if (try find(cx, name)) |pl| {
        _ = try call(cx, "updatePlaylist.view", (try sidParams(cx, &.{.{ "playlistId", pl.id }}, "songIdToAdd", songs)).items);
    } else {
        _ = try call(cx, "createPlaylist.view", (try sidParams(cx, &.{.{ "name", name }}, "songId", songs)).items);
    }
    done(cx);
}
