//! sqlite-backed library cache. queries run against an in-memory snapshot
//! (`Library`) loaded from / persisted to sqlite, so filters stay simple.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const subsonic = @import("subsonic.zig");

const log = std.log.scoped(.db);

// minimal sqlite3 binding; the amalgamation is linked by build.zig
const c = struct {
    const Db = opaque {};
    const Stmt = opaque {};
    extern fn sqlite3_open(path: [*:0]const u8, out: *?*Db) c_int;
    extern fn sqlite3_close(db: *Db) c_int;
    extern fn sqlite3_exec(db: *Db, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
    extern fn sqlite3_prepare_v2(db: *Db, sql: [*]const u8, n: c_int, out: *?*Stmt, tail: ?*?[*]const u8) c_int;
    extern fn sqlite3_step(s: *Stmt) c_int;
    extern fn sqlite3_finalize(s: *Stmt) c_int;
    extern fn sqlite3_reset(s: *Stmt) c_int;
    extern fn sqlite3_bind_text(s: *Stmt, i: c_int, p: [*]const u8, n: c_int, d: ?*const anyopaque) c_int;
    extern fn sqlite3_bind_int64(s: *Stmt, i: c_int, v: i64) c_int;
    extern fn sqlite3_bind_double(s: *Stmt, i: c_int, v: f64) c_int;
    extern fn sqlite3_column_text(s: *Stmt, i: c_int) ?[*]const u8;
    extern fn sqlite3_column_bytes(s: *Stmt, i: c_int) c_int;
    extern fn sqlite3_column_int64(s: *Stmt, i: c_int) i64;
    extern fn sqlite3_column_double(s: *Stmt, i: c_int) f64;
    extern fn sqlite3_busy_timeout(db: *Db, ms: c_int) c_int;
    const ROW = 100;
    const DONE = 101;
};

pub const Tag = enum {
    artist,
    albumartist,
    album,
    title,
    track,
    name,
    genre,
    date,
    composer,
    performer,
    comment,
    disc,
    musicbrainz_trackid,

    pub const names = [_][]const u8{ "Artist", "AlbumArtist", "Album", "Title", "Track", "Name", "Genre", "Date", "Composer", "Performer", "Comment", "Disc", "MUSICBRAINZ_TRACKID" };

    pub fn label(t: Tag) []const u8 {
        return names[@intFromEnum(t)];
    }

    pub fn parse(s: []const u8) ?Tag {
        for (names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, s)) return @enumFromInt(i);
        return null;
    }
};

pub const TagBuf = struct {
    one: [1][]const u8 = undefined,
    num: [16]u8 = undefined,
};

pub const Song = struct {
    sid: []const u8,
    path: []const u8,
    title: []const u8 = "",
    artist: []const u8 = "",
    albumartist: []const u8 = "",
    album: []const u8 = "",
    genres: []const []const u8 = &.{},
    track: u32 = 0,
    disc: u32 = 0,
    year: u32 = 0,
    duration: f64 = 0,
    bitrate: u32 = 0,
    suffix: []const u8 = "",
    mtime: i64 = 0,
    size: u64 = 0,
    cover: []const u8 = "",
    rate: u32 = 0,
    bits: u32 = 0,
    channels: u32 = 0,
    mbid: []const u8 = "",
    compilation: bool = false,

    pub fn tagValues(s: *const Song, t: Tag, buf: *TagBuf) []const []const u8 {
        const one: []const u8 = switch (t) {
            .artist => s.artist,
            .albumartist => s.albumartist,
            .album => s.album,
            .title => s.title,
            .track => if (s.track > 0) std.fmt.bufPrint(&buf.num, "{d}", .{s.track}) catch "" else "",
            .disc => if (s.disc > 0) std.fmt.bufPrint(&buf.num, "{d}", .{s.disc}) catch "" else "",
            .date => if (s.year > 0) std.fmt.bufPrint(&buf.num, "{d}", .{s.year}) catch "" else "",
            .genre => return s.genres,
            .musicbrainz_trackid => s.mbid,
            .name, .composer, .performer, .comment => "",
        };
        if (one.len == 0) return &.{};
        buf.one[0] = one;
        return &buf.one;
    }

    /// deep copy into `alloc` (queue entries must outlive library snapshots).
    pub fn clone(s: Song, alloc: Allocator) !Song {
        var o = s;
        const info = @typeInfo(Song).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            if (T == []const u8) @field(o, name) = try alloc.dupe(u8, @field(s, name));
        }
        const g = try alloc.alloc([]const u8, s.genres.len);
        for (s.genres, g) |src, *dst| dst.* = try alloc.dupe(u8, src);
        o.genres = g;
        return o;
    }
};

fn pathLess(_: void, x: Song, y: Song) bool {
    const o = std.mem.order(u8, x.path, y.path);
    return if (o == .eq) std.mem.lessThan(u8, x.sid, y.sid) else o == .lt;
}

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    songs: []Song = &.{},
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    by_sid: std.StringHashMapUnmanaged(u32) = .empty,
    albums: usize = 0,
    artists: usize = 0,
    playtime: f64 = 0,
    updated: i64 = 0,

    pub fn create(gpa: Allocator) !*Library {
        const l = try gpa.create(Library);
        l.* = .{ .arena = .init(gpa) };
        return l;
    }

    pub fn destroy(l: *Library, gpa: Allocator) void {
        l.arena.deinit();
        gpa.destroy(l);
    }

    /// sorts by path, dedupes colliding paths, builds indexes and counters.
    fn finish(l: *Library, songs: []Song) !void {
        const a = l.arena.allocator();
        std.mem.sort(Song, songs, {}, pathLess);
        var used: std.StringHashMapUnmanaged(void) = .empty;
        defer used.deinit(l.arena.child_allocator);
        for (songs) |*sg| {
            var n: u32 = 2;
            while (used.contains(sg.path)) : (n += 1) {
                const p = sg.path;
                const ext = std.fs.path.extension(p);
                sg.path = try std.fmt.allocPrint(a, "{s} ({d}){s}", .{ p[0 .. p.len - ext.len], n, ext });
            }
            try used.put(l.arena.child_allocator, sg.path, {});
        }
        std.mem.sort(Song, songs, {}, pathLess);
        l.songs = songs;
        try l.indexAll();
    }

    fn indexAll(l: *Library) !void {
        const a = l.arena.allocator();
        var albums: std.StringHashMapUnmanaged(void) = .empty;
        var artists: std.StringHashMapUnmanaged(void) = .empty;
        defer albums.deinit(l.arena.child_allocator);
        defer artists.deinit(l.arena.child_allocator);
        const g = l.arena.child_allocator;
        try l.by_path.ensureTotalCapacity(a, @intCast(l.songs.len));
        try l.by_sid.ensureTotalCapacity(a, @intCast(l.songs.len));
        for (l.songs, 0..) |s, idx| {
            l.by_path.putAssumeCapacity(s.path, @intCast(idx));
            l.by_sid.putAssumeCapacity(s.sid, @intCast(idx));
            l.playtime += s.duration;
            const key = try std.fmt.allocPrint(g, "{s}\x00{s}", .{ s.albumartist, s.album });
            const e = try albums.getOrPut(g, key);
            if (e.found_existing) g.free(key);
            const k2 = try g.dupe(u8, s.artist);
            const e2 = try artists.getOrPut(g, k2);
            if (e2.found_existing) g.free(k2);
        }
        l.albums = albums.count();
        l.artists = artists.count();
        var it = albums.keyIterator();
        while (it.next()) |k| g.free(k.*);
        var it2 = artists.keyIterator();
        while (it2.next()) |k| g.free(k.*);
    }

    pub fn findPath(l: *const Library, path: []const u8) ?*const Song {
        const i = l.by_path.get(path) orelse return null;
        return &l.songs[i];
    }

    pub fn findSid(l: *const Library, sid: []const u8) ?*const Song {
        const i = l.by_sid.get(sid) orelse return null;
        return &l.songs[i];
    }
};

// ---- json -> Song

fn str(o: json.ObjectMap, k: []const u8) []const u8 {
    const v = o.get(k) orelse return "";
    return if (v == .string) v.string else "";
}

fn num(o: json.ObjectMap, k: []const u8) f64 {
    const v = o.get(k) orelse return 0;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

fn unum(o: json.ObjectMap, k: []const u8) u32 {
    const n = num(o, k);
    return if (n > 0 and n < 4e9) @intFromFloat(n) else 0;
}

fn days(y_: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_ - 1 else y_;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// "2026-03-02T14:56:29.158986141+11:00" -> unix seconds, 0 if unparsable.
pub fn parseTime(s: []const u8) i64 {
    if (s.len < 19) return 0;
    const p = struct {
        fn n(x: []const u8) i64 {
            return std.fmt.parseInt(i64, x, 10) catch 0;
        }
    }.n;
    var t = days(p(s[0..4]), p(s[5..7]), p(s[8..10])) * 86400 + p(s[11..13]) * 3600 + p(s[14..16]) * 60 + p(s[17..19]);
    if (s.len >= 25 and (s[s.len - 6] == '+' or s[s.len - 6] == '-')) {
        const off = p(s[s.len - 5 .. s.len - 3]) * 3600 + p(s[s.len - 2 ..]) * 60;
        t += if (s[s.len - 6] == '+') -off else off;
    }
    return t;
}

fn sanitize(a: Allocator, s: []const u8) ![]u8 {
    const t = std.mem.trim(u8, s, " ");
    const out = try a.dupe(u8, t);
    for (out) |*ch| if (ch.* == '/') {
        ch.* = '-';
    };
    return out;
}

fn fallbackPath(a: Allocator, s: Song) ![]u8 {
    const aa = try sanitize(a, if (s.albumartist.len > 0) s.albumartist else if (s.artist.len > 0) s.artist else "Unknown Artist");
    const al = try sanitize(a, if (s.album.len > 0) s.album else "Unknown Album");
    const ti = try sanitize(a, if (s.title.len > 0) s.title else s.sid);
    var buf: [16]u8 = undefined;
    const year = if (s.year > 0) try std.fmt.bufPrint(&buf, " ({d})", .{s.year}) else "";
    const ext = if (s.suffix.len > 0) s.suffix else "bin";
    const disc = if (s.disc > 1) try std.fmt.allocPrint(a, "{d}-", .{s.disc}) else "";
    return std.fmt.allocPrint(a, "{s}/{s}{s}/{s}{d:0>2} - {s}.{s}", .{ aa, al, year, disc, s.track, ti, ext });
}

fn songFromJson(a: Allocator, o: json.ObjectMap) !?Song {
    const sid = str(o, "id");
    if (sid.len == 0) return null;
    if (o.get("isDir")) |d| if (d == .bool and d.bool) return null;
    var s: Song = .{ .sid = try a.dupe(u8, sid), .path = "" };
    s.title = try a.dupe(u8, str(o, "title"));
    const da = str(o, "displayArtist");
    s.artist = try a.dupe(u8, if (da.len > 0) da else str(o, "artist"));
    var aa = str(o, "displayAlbumArtist");
    if (aa.len == 0) if (o.get("albumArtists")) |arr| if (arr == .array and arr.array.items.len > 0 and arr.array.items[0] == .object)
        {
            aa = str(arr.array.items[0].object, "name");
        };
    s.albumartist = try a.dupe(u8, if (aa.len > 0) aa else s.artist);
    s.album = try a.dupe(u8, str(o, "album"));
    var gl: std.ArrayList([]const u8) = .empty;
    if (o.get("genres")) |arr| if (arr == .array) for (arr.array.items) |g| if (g == .object) {
        const n = str(g.object, "name");
        if (n.len > 0) try gl.append(a, try a.dupe(u8, n));
    };
    if (gl.items.len == 0 and str(o, "genre").len > 0) try gl.append(a, try a.dupe(u8, str(o, "genre")));
    s.genres = gl.items;
    s.track = unum(o, "track");
    s.disc = unum(o, "discNumber");
    s.year = unum(o, "year");
    s.duration = num(o, "duration");
    s.bitrate = unum(o, "bitRate");
    s.suffix = try a.dupe(u8, str(o, "suffix"));
    s.mtime = parseTime(str(o, "created"));
    s.size = @intFromFloat(num(o, "size"));
    s.cover = try a.dupe(u8, str(o, "coverArt"));
    s.rate = unum(o, "samplingRate");
    s.bits = unum(o, "bitDepth");
    s.channels = unum(o, "channelCount");
    s.mbid = try a.dupe(u8, str(o, "musicBrainzId"));
    if (o.get("isCompilation")) |v| s.compilation = v == .bool and v.bool;
    const p = std.mem.trim(u8, str(o, "path"), "/ ");
    s.path = if (p.len > 0) try a.dupe(u8, p) else try fallbackPath(a, s);
    return s;
}

pub const Store = struct {
    db: *c.Db,

    pub fn open(gpa: Allocator, io: Io, dir: []const u8) !Store {
        try Io.Dir.cwd().createDirPath(io, dir);
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/library.db", .{dir}, 0);
        defer gpa.free(path);
        var h: ?*c.Db = null;
        if (c.sqlite3_open(path.ptr, &h) != 0 or h == null) return error.SqliteOpen;
        _ = c.sqlite3_busy_timeout(h.?, 5000);
        var st: Store = .{ .db = h.? };
        try st.exec(
            \\PRAGMA journal_mode=WAL;
            \\CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            \\CREATE TABLE IF NOT EXISTS songs(
            \\ sid TEXT PRIMARY KEY, path TEXT NOT NULL, title TEXT, artist TEXT, albumartist TEXT,
            \\ album TEXT, genres TEXT, track INT, disc INT, year INT, duration REAL, bitrate INT,
            \\ suffix TEXT, mtime INT, size INT, cover TEXT, rate INT, bits INT, channels INT,
            \\ mbid TEXT, compilation INT, raw_json TEXT);
            \\CREATE UNIQUE INDEX IF NOT EXISTS songs_path ON songs(path);
        );
        return st;
    }

    pub fn close(st: *Store) void {
        _ = c.sqlite3_close(st.db);
    }

    fn exec(st: *Store, sql: [*:0]const u8) !void {
        if (c.sqlite3_exec(st.db, sql, null, null, null) != 0) return error.Sqlite;
    }

    fn prepare(st: *Store, sql: []const u8) !*c.Stmt {
        var s: ?*c.Stmt = null;
        if (c.sqlite3_prepare_v2(st.db, sql.ptr, @intCast(sql.len), &s, null) != 0) return error.Sqlite;
        return s.?;
    }

    fn text(s: *c.Stmt, i: c_int, a: Allocator) ![]const u8 {
        const p = c.sqlite3_column_text(s, i) orelse return "";
        return a.dupe(u8, p[0..@intCast(c.sqlite3_column_bytes(s, i))]);
    }

    pub fn lastSync(st: *Store) i64 {
        const s = st.prepare("SELECT value FROM meta WHERE key='synced'") catch return 0;
        defer _ = c.sqlite3_finalize(s);
        if (c.sqlite3_step(s) != c.ROW) return 0;
        const p = c.sqlite3_column_text(s, 0) orelse return 0;
        return std.fmt.parseInt(i64, p[0..@intCast(c.sqlite3_column_bytes(s, 0))], 10) catch 0;
    }

    pub fn load(st: *Store, gpa: Allocator) !*Library {
        const lib = try Library.create(gpa);
        errdefer lib.destroy(gpa);
        const a = lib.arena.allocator();
        const s = try st.prepare("SELECT sid,path,title,artist,albumartist,album,genres,track,disc,year,duration,bitrate,suffix,mtime,size,cover,rate,bits,channels,mbid,compilation FROM songs");
        defer _ = c.sqlite3_finalize(s);
        var list: std.ArrayList(Song) = .empty;
        while (c.sqlite3_step(s) == c.ROW) {
            var o: Song = .{ .sid = try text(s, 0, a), .path = try text(s, 1, a) };
            o.title = try text(s, 2, a);
            o.artist = try text(s, 3, a);
            o.albumartist = try text(s, 4, a);
            o.album = try text(s, 5, a);
            const g = try text(s, 6, a);
            var gl: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, g, 0x1f);
            while (it.next()) |x| if (x.len > 0) try gl.append(a, x);
            o.genres = gl.items;
            o.track = @intCast(c.sqlite3_column_int64(s, 7));
            o.disc = @intCast(c.sqlite3_column_int64(s, 8));
            o.year = @intCast(c.sqlite3_column_int64(s, 9));
            o.duration = c.sqlite3_column_double(s, 10);
            o.bitrate = @intCast(c.sqlite3_column_int64(s, 11));
            o.suffix = try text(s, 12, a);
            o.mtime = c.sqlite3_column_int64(s, 13);
            o.size = @intCast(c.sqlite3_column_int64(s, 14));
            o.cover = try text(s, 15, a);
            o.rate = @intCast(c.sqlite3_column_int64(s, 16));
            o.bits = @intCast(c.sqlite3_column_int64(s, 17));
            o.channels = @intCast(c.sqlite3_column_int64(s, 18));
            o.mbid = try text(s, 19, a);
            o.compilation = c.sqlite3_column_int64(s, 20) != 0;
            try list.append(a, o);
        }
        lib.updated = st.lastSync();
        try lib.finish(list.items);
        return lib;
    }

    fn bindText(s: *c.Stmt, i: c_int, v: []const u8) void {
        _ = c.sqlite3_bind_text(s, i, v.ptr, @intCast(v.len), null);
    }

    /// replaces the whole songs table in one transaction.
    pub fn save(st: *Store, gpa: Allocator, lib: *const Library, raws: *const std.StringHashMapUnmanaged([]const u8)) !void {
        try st.exec("BEGIN");
        errdefer st.exec("ROLLBACK") catch {};
        try st.exec("DELETE FROM songs");
        const s = try st.prepare("INSERT INTO songs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
        defer _ = c.sqlite3_finalize(s);
        for (lib.songs) |o| {
            const g = try std.mem.join(gpa, "\x1f", o.genres);
            defer gpa.free(g);
            bindText(s, 1, o.sid);
            bindText(s, 2, o.path);
            bindText(s, 3, o.title);
            bindText(s, 4, o.artist);
            bindText(s, 5, o.albumartist);
            bindText(s, 6, o.album);
            bindText(s, 7, g);
            _ = c.sqlite3_bind_int64(s, 8, o.track);
            _ = c.sqlite3_bind_int64(s, 9, o.disc);
            _ = c.sqlite3_bind_int64(s, 10, o.year);
            _ = c.sqlite3_bind_double(s, 11, o.duration);
            _ = c.sqlite3_bind_int64(s, 12, o.bitrate);
            bindText(s, 13, o.suffix);
            _ = c.sqlite3_bind_int64(s, 14, o.mtime);
            _ = c.sqlite3_bind_int64(s, 15, @intCast(o.size));
            bindText(s, 16, o.cover);
            _ = c.sqlite3_bind_int64(s, 17, o.rate);
            _ = c.sqlite3_bind_int64(s, 18, o.bits);
            _ = c.sqlite3_bind_int64(s, 19, o.channels);
            bindText(s, 20, o.mbid);
            _ = c.sqlite3_bind_int64(s, 21, @intFromBool(o.compilation));
            bindText(s, 22, raws.get(o.sid) orelse "");
            if (c.sqlite3_step(s) != c.DONE) return error.Sqlite;
            _ = c.sqlite3_reset(s);
        }
        try st.exec("COMMIT");
    }

    pub fn setSynced(st: *Store, now: i64) !void {
        var buf: [64]u8 = undefined;
        const q = try std.fmt.bufPrintSentinel(&buf, "REPLACE INTO meta VALUES('synced','{d}')", .{now}, 0);
        try st.exec(q.ptr);
    }
};

pub const SyncResult = struct { lib: *Library, raw_arena: std.heap.ArenaAllocator, raws: std.StringHashMapUnmanaged([]const u8) };

/// pages through search3 with an empty query (navidrome returns every song).
/// raw json lives in `raw_arena` only until it has been saved.
pub fn sync(gpa: Allocator, sc: *subsonic.Client, now: i64) !SyncResult {
    const lib = try Library.create(gpa);
    errdefer lib.destroy(gpa);
    const a = lib.arena.allocator();
    var list: std.ArrayList(Song) = .empty;
    var raw_arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer raw_arena.deinit();
    const ra = raw_arena.allocator();
    var raws: std.StringHashMapUnmanaged([]const u8) = .empty;
    var offset: usize = 0;
    const page = 500;
    while (true) {
        var tmp: std.heap.ArenaAllocator = .init(gpa);
        defer tmp.deinit();
        var ob: [16]u8 = undefined;
        const off = try std.fmt.bufPrint(&ob, "{d}", .{offset});
        const resp = try sc.call(tmp.allocator(), "search3.view", &.{
            .{ "query", "" },       .{ "songCount", "500" }, .{ "songOffset", off },
            .{ "artistCount", "0" }, .{ "albumCount", "0" },
        });
        const sr = resp.get("searchResult3") orelse break;
        if (sr != .object) break;
        const arr = sr.object.get("song") orelse break;
        if (arr != .array) break;
        for (arr.array.items) |item| {
            if (item != .object) continue;
            const song = (try songFromJson(a, item.object)) orelse continue;
            try list.append(a, song);
            const raw = try json.Stringify.valueAlloc(ra, item, .{});
            try raws.put(ra, song.sid, raw);
        }
        log.debug("synced {d} songs", .{list.items.len});
        if (arr.array.items.len < page) break;
        offset += page;
    }
    lib.updated = now;
    try lib.finish(list.items);
    return .{ .lib = lib, .raw_arena = raw_arena, .raws = raws };
}
