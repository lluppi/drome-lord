//! queue + playback state. drome-lord owns the play order; mpv only holds the
//! current track and (for gapless) the one appended after it.
//! methods below assume the caller holds `mu` unless stated otherwise.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const db = @import("db.zig");
const mpvm = @import("mpv.zig");
const subsonic = @import("subsonic.zig");
const hub_mod = @import("hub.zig");
const Sub = hub_mod.Subsystem;

const log = std.log.scoped(.player);

pub const State = enum { stop, play, pause };
pub const Single = enum { off, on, oneshot };

pub const Entry = struct {
    id: u32,
    ver: u32,
    prio: u8 = 0,
    played: bool = false,
    arena: std.heap.ArenaAllocator,
    song: db.Song,

    fn deinit(e: *Entry) void {
        e.arena.deinit();
    }
};

pub const Player = struct {
    gpa: Allocator,
    io: Io,
    hub: *hub_mod.Hub,
    sc: *subsonic.Client,
    mpv: mpvm.Mpv,
    scrobble_enabled: bool,
    mu: Io.Mutex = .init,

    queue: std.ArrayList(Entry) = .empty,
    version: u32 = 1,
    id_counter: u32 = 1,

    state: State = .stop,
    cur: ?u32 = null,
    elapsed: f64 = 0,
    mpv_duration: f64 = 0,
    mpv_bitrate: f64 = 0,
    mpv_next: ?u32 = null,
    rand_next: ?u32 = null,
    pending_seek: ?f64 = null,
    scrobbled: bool = false,
    err_buf: [96]u8 = undefined,
    err_len: usize = 0,

    volume: i32 = 100,
    repeat: bool = false,
    random: bool = false,
    single: Single = .off,
    consume: bool = false,
    crossfade: u32 = 0,
    mixrampdb: f32 = 0,
    mixrampdelay: f32 = -1,
    replay_gain: []const u8 = "off",
    output_enabled: bool = true,
    prng: std.Random.DefaultPrng,

    pub fn create(
        gpa: Allocator,
        io: Io,
        hub: *hub_mod.Hub,
        sc: *subsonic.Client,
        sock_path: []const u8,
        client_name: []const u8,
        mpv_args: []const []const u8,
        scrobble: bool,
    ) !*Player {
        var seed: [8]u8 = undefined;
        io.random(&seed);
        var vol: i32 = 100;
        for (mpv_args) |a| if (std.mem.startsWith(u8, a, "--volume=")) {
            vol = std.fmt.parseInt(i32, a["--volume=".len..], 10) catch 100;
        };
        const p = try gpa.create(Player);
        p.* = .{
            .gpa = gpa,
            .io = io,
            .hub = hub,
            .sc = sc,
            .scrobble_enabled = scrobble,
            .volume = vol,
            .prng = .init(@bitCast(seed)),
            .mpv = .{
                .gpa = gpa,
                .io = io,
                .sock_path = sock_path,
                .client_name = client_name,
                .extra_args = mpv_args,
                .volume = vol,
                .ctx = p,
                .handler = onEvent,
            },
        };
        return p;
    }

    pub fn lock(p: *Player) void {
        p.mu.lockUncancelable(p.io);
    }
    pub fn unlock(p: *Player) void {
        p.mu.unlock(p.io);
    }

    fn notify(p: *Player, comptime subs: anytype) void {
        const m = comptime blk: {
            var acc: u32 = 0;
            for (subs) |s| acc |= Sub.bit(s);
            break :blk acc;
        };
        p.hub.notify(m);
    }

    pub fn errorText(p: *const Player) ?[]const u8 {
        return if (p.err_len > 0) p.err_buf[0..p.err_len] else null;
    }

    fn setError(p: *Player, msg: []const u8) void {
        const n = @min(msg.len, p.err_buf.len);
        @memcpy(p.err_buf[0..n], msg[0..n]);
        p.err_len = n;
    }

    pub fn clearError(p: *Player) void {
        p.err_len = 0;
    }

    // ---- queue

    pub fn posOf(p: *const Player, id: u32) ?usize {
        for (p.queue.items, 0..) |e, i| if (e.id == id) return i;
        return null;
    }

    pub fn curPos(p: *const Player) ?usize {
        return if (p.cur) |c| p.posOf(c) else null;
    }

    pub fn curEntry(p: *Player) ?*Entry {
        return if (p.curPos()) |i| &p.queue.items[i] else null;
    }

    /// bumps the queue version once per modifying command; returns the new one.
    pub fn bump(p: *Player) u32 {
        p.version +%= 1;
        p.rand_next = null;
        return p.version;
    }

    fn touchFrom(p: *Player, pos: usize, ver: u32) void {
        for (p.queue.items[@min(pos, p.queue.items.len)..]) |*e| e.ver = ver;
    }

    /// inserts a copy of `song`; pos null appends. returns the new id.
    pub fn insert(p: *Player, song: db.Song, pos: ?usize, ver: u32) !u32 {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        errdefer arena.deinit();
        const copy = try song.clone(arena.allocator());
        const at = @min(pos orelse p.queue.items.len, p.queue.items.len);
        const id = p.id_counter;
        try p.queue.insert(p.gpa, at, .{ .id = id, .ver = ver, .arena = arena, .song = copy });
        p.id_counter += 1;
        p.touchFrom(at, ver);
        return id;
    }

    /// deleting the playing entry stops playback.
    pub fn deleteRange(p: *Player, start: usize, end: usize, ver: u32) void {
        var i = end;
        while (i > start) {
            i -= 1;
            if (p.cur != null and p.queue.items[i].id == p.cur.?) p.stopPlayback(true);
            p.queue.items[i].deinit();
            _ = p.queue.orderedRemove(i);
        }
        p.touchFrom(start, ver);
    }

    pub fn clear(p: *Player, ver: u32) void {
        p.stopPlayback(true);
        p.deleteRange(0, p.queue.items.len, ver);
    }

    /// moves [start,end) so the block begins at `to` (index after removal).
    pub fn move(p: *Player, start: usize, end: usize, to: usize, ver: u32) !void {
        const n = end - start;
        const block = try p.gpa.dupe(Entry, p.queue.items[start..end]);
        defer p.gpa.free(block);
        p.queue.replaceRangeAssumeCapacity(start, n, &.{});
        try p.queue.insertSlice(p.gpa, to, block);
        p.touchFrom(@min(start, to), ver);
    }

    pub fn swap(p: *Player, a: usize, b: usize, ver: u32) void {
        std.mem.swap(Entry, &p.queue.items[a], &p.queue.items[b]);
        p.queue.items[a].ver = ver;
        p.queue.items[b].ver = ver;
    }

    pub fn shuffle(p: *Player, start: usize, end: usize, ver: u32) void {
        p.prng.random().shuffle(Entry, p.queue.items[start..end]);
        for (p.queue.items[start..end]) |*e| e.ver = ver;
    }

    // ---- playback

    fn mpvSend(p: *Player, args: anytype) void {
        p.mpv.send(args) catch |err| log.debug("mpv send: {s}", .{@errorName(err)});
    }

    fn resetPlayed(p: *Player) void {
        for (p.queue.items) |*e| e.played = false;
        if (p.curEntry()) |e| e.played = true;
    }

    /// entry that should play after the current one, or null to stop.
    pub fn peekNext(p: *Player) ?u32 {
        const pos = p.curPos() orelse return null;
        const items = p.queue.items;
        if (p.single != .off) return if (p.repeat) items[pos].id else null;
        if (p.random) {
            if (p.rand_next) |r| if (p.posOf(r) != null) return r;
            var cand: std.ArrayList(u32) = .empty;
            defer cand.deinit(p.gpa);
            for (0..2) |round| {
                for (items) |e| if (!e.played and e.id != items[pos].id) cand.append(p.gpa, e.id) catch return null;
                if (cand.items.len > 0 or !p.repeat or round == 1) break;
                p.resetPlayed();
            }
            if (cand.items.len == 0) return if (p.repeat and items.len == 1) items[pos].id else null;
            const pick = cand.items[p.prng.random().uintLessThan(usize, cand.items.len)];
            p.rand_next = pick;
            return pick;
        }
        if (pos + 1 < items.len) return items[pos + 1].id;
        return if (p.repeat) items[0].id else null;
    }

    /// keeps mpv's appended entry equal to peekNext() so track changes are gapless.
    pub fn syncNext(p: *Player) void {
        if (p.state == .stop or !p.mpv.connected()) return;
        const want = p.peekNext();
        if (want == p.mpv_next) return;
        p.mpvSend(.{"playlist-clear"});
        p.mpv_next = null;
        const id = want orelse return;
        const pos = p.posOf(id) orelse return;
        p.appendToMpv(pos);
        p.mpv_next = id;
    }

    fn streamUrl(p: *Player, alloc: Allocator, song: *const db.Song) ![]u8 {
        return p.sc.url(alloc, "stream.view", &.{.{ "id", song.sid }});
    }

    fn appendToMpv(p: *Player, pos: usize) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const u = p.streamUrl(arena.allocator(), &p.queue.items[pos].song) catch return;
        p.mpvSend(.{ "loadfile", u, "append" });
    }

    pub fn startEntry(p: *Player, id: u32) void {
        const pos = p.posOf(id) orelse return;
        if (!p.mpv.available.load(.acquire)) p.setError("mpv not available") else p.clearError();
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        if (p.streamUrl(arena.allocator(), &p.queue.items[pos].song)) |u| {
            p.mpvSend(.{ "loadfile", u, "replace" });
            p.mpvSend(.{"playlist-clear"});
            p.mpvSend(.{ "set_property", "pause", false });
        } else |_| {}
        p.cur = id;
        p.queue.items[pos].played = true;
        p.state = .play;
        p.elapsed = 0;
        p.mpv_duration = 0;
        p.mpv_bitrate = 0;
        p.mpv_next = null;
        p.rand_next = null;
        p.scrobbled = false;
        p.pending_seek = null;
        p.scrobbleSend(false);
        p.syncNext();
        p.notify(.{.player});
    }

    /// `forget` drops the current entry (natural end or deletion); otherwise it stays selected.
    pub fn stopPlayback(p: *Player, forget: bool) void {
        if (p.state != .stop) p.mpvSend(.{"stop"});
        p.state = .stop;
        p.mpv_next = null;
        p.elapsed = 0;
        p.pending_seek = null;
        if (forget) p.cur = null;
        p.notify(.{.player});
    }

    pub fn play(p: *Player, pos: ?usize) !void {
        if (pos) |i| {
            if (i >= p.queue.items.len) return error.BadPos;
            if (p.random) p.resetPlayed();
            return p.startEntry(p.queue.items[i].id);
        }
        if (p.state == .pause) return p.setPause(false);
        if (p.state == .play) return;
        if (p.queue.items.len == 0) return;
        if (p.curPos() == null) {
            const i = if (p.random) p.prng.random().uintLessThan(usize, p.queue.items.len) else 0;
            return p.startEntry(p.queue.items[i].id);
        }
        p.startEntry(p.cur.?);
    }

    pub fn setPause(p: *Player, paused: bool) void {
        if (p.state == .stop or (p.state == .pause) == paused) return;
        p.mpvSend(.{ "set_property", "pause", paused });
        p.state = if (paused) .pause else .play;
        p.notify(.{.player});
    }

    /// plays `target` (or stops at the end); consume mode removes `old` from the queue.
    fn moveOn(p: *Player, target: ?u32, old: ?u32) void {
        if (target) |t| p.startEntry(t) else p.stopPlayback(true);
        p.consumeEntry(old);
    }

    fn consumeEntry(p: *Player, old: ?u32) void {
        if (!p.consume) return;
        const i = p.posOf(old orelse return) orelse return;
        const v = p.bump();
        if (p.cur == old) p.cur = null;
        p.deleteRange(i, i + 1, v);
        p.notify(.{.playlist});
    }

    pub fn next(p: *Player) void {
        if (p.state == .stop) return;
        const old = p.cur;
        const t = p.peekNext();
        if (p.single == .oneshot) {
            p.single = .off;
            p.notify(.{.options});
        }
        p.moveOn(t, old);
    }

    pub fn previous(p: *Player) void {
        if (p.state == .stop) return;
        const pos = p.curPos() orelse return;
        var to = pos;
        if (pos > 0) to = pos - 1 else if (p.repeat) to = p.queue.items.len - 1;
        p.startEntry(p.queue.items[to].id);
    }

    pub fn seekTo(p: *Player, pos: usize, secs: f64) !void {
        if (pos >= p.queue.items.len) return error.BadPos;
        const id = p.queue.items[pos].id;
        if (p.cur != id or p.state == .stop) {
            p.startEntry(id);
            p.pending_seek = secs;
        } else {
            p.absSeek(secs);
        }
    }

    /// mpv rejects seeks before the file is loaded; those wait for the duration event.
    fn absSeek(p: *Player, t: f64) void {
        if (p.mpv_duration > 0) p.mpvSend(.{ "seek", t, "absolute" }) else p.pending_seek = t;
        p.elapsed = t;
        p.notify(.{.player});
    }

    pub fn seekCur(p: *Player, secs: f64, relative: bool) !void {
        if (p.state == .stop) return error.NotPlaying;
        const t = @max(0, if (relative) p.elapsed + secs else secs);
        p.absSeek(t);
    }

    pub fn setVolume(p: *Player, v: i32) void {
        p.volume = std.math.clamp(v, 0, 100);
        p.mpvSend(.{ "set_property", "volume", p.volume });
        p.notify(.{.mixer});
    }

    /// to be called after options that change the upcoming track.
    pub fn optionsChanged(p: *Player) void {
        p.rand_next = null;
        if (p.random) p.resetPlayed();
        p.syncNext();
        p.notify(.{.options});
    }

    pub fn duration(p: *Player) f64 {
        if (p.curEntry()) |e| if (e.song.duration > 0) return e.song.duration;
        return p.mpv_duration;
    }

    // ---- scrobbling

    const Scrobble = struct { p: *Player, sid: []u8, submission: bool };

    fn scrobbleThread(s: *Scrobble) void {
        defer {
            s.p.gpa.free(s.sid);
            s.p.gpa.destroy(s);
        }
        var arena: std.heap.ArenaAllocator = .init(s.p.gpa);
        defer arena.deinit();
        _ = s.p.sc.call(arena.allocator(), "scrobble.view", &.{
            .{ "id", s.sid },
            .{ "submission", if (s.submission) "true" else "false" },
        }) catch |err| log.debug("scrobble: {s}", .{@errorName(err)});
    }

    fn scrobbleSend(p: *Player, submission: bool) void {
        if (!p.scrobble_enabled) return;
        const e = p.curEntry() orelse return;
        const s = p.gpa.create(Scrobble) catch return;
        const sid = p.gpa.dupe(u8, e.song.sid) catch {
            p.gpa.destroy(s);
            return;
        };
        s.* = .{ .p = p, .sid = sid, .submission = submission };
        const t = std.Thread.spawn(.{}, scrobbleThread, .{s}) catch {
            p.gpa.free(sid);
            p.gpa.destroy(s);
            return;
        };
        t.detach();
    }

    // ---- mpv events

    fn onEvent(ctx: *anyopaque, ev: mpvm.Event) void {
        const p: *Player = @ptrCast(@alignCast(ctx));
        p.lock();
        defer p.unlock();
        switch (ev) {
            .connected => {
                log.info("mpv connected", .{});
                p.mpv.send(.{ "set_property", "volume", p.volume }) catch {};
            },
            .disconnected => if (p.state != .stop) {
                log.warn("mpv went away, stopping playback", .{});
                p.setError("mpv exited");
                p.state = .stop;
                p.mpv_next = null;
                p.notify(.{.player});
            },
            .time_pos => |t| {
                p.elapsed = t;
                if (!p.scrobbled and p.state == .play) {
                    const d = p.duration();
                    if (t > 240 or (d > 0 and t > d / 2)) {
                        p.scrobbled = true;
                        p.scrobbleSend(true);
                    }
                }
            },
            .duration => |d| {
                p.mpv_duration = d;
                if (p.pending_seek) |t| {
                    p.pending_seek = null;
                    p.mpvSend(.{ "seek", t, "absolute" });
                    p.elapsed = t;
                    p.notify(.{.player});
                }
            },
            .volume => |v| {
                const r: i32 = @intFromFloat(@round(std.math.clamp(v, 0, 100)));
                if (r != p.volume) {
                    p.volume = r;
                    p.notify(.{.mixer});
                }
            },
            .bitrate => |b| p.mpv_bitrate = b,
            .start_file, .idle => {},
            .end_file => |why| p.onEndFile(why),
        }
    }

    fn onEndFile(p: *Player, why: mpvm.EndReason) void {
        if (p.state == .stop) return;
        switch (why) {
            .stop, .other => return,
            .err => {
                log.warn("playback of current track failed", .{});
                p.setError("failed to play track");
                p.stopPlayback(false);
                return;
            },
            .eof => {},
        }
        const old = p.cur;
        const target = p.mpv_next orelse p.peekNext();
        if (p.single == .oneshot) {
            p.single = .off;
            p.notify(.{.options});
        }
        if (p.mpv_next != null) {
            // mpv already moved on to the appended entry: bookkeeping only, no reload
            p.cur = target;
            if (p.curEntry()) |e| e.played = true;
            p.mpv_next = null;
            p.rand_next = null;
            p.elapsed = 0;
            p.mpv_duration = 0;
            p.scrobbled = false;
            p.scrobbleSend(false);
            p.consumeEntry(old);
            p.syncNext();
            p.notify(.{.player});
        } else p.moveOn(target, old);
    }
};
