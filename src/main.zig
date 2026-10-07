const std = @import("std");
const config = @import("config.zig");
const subsonic = @import("subsonic.zig");
const db = @import("db.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cfg = try config.load(init.arena.allocator(), io, init.environ_map, .{});
    var sc = subsonic.Client.init(gpa, io, cfg.username, cfg.password);
    try sc.pickUrl(cfg.urls);
    var st = try db.Store.open(gpa, io, cfg.cache_dir);
    const t0 = std.Io.Timestamp.now(io, .awake);
    const r = try db.sync(gpa, &sc, 1);
    std.debug.print("songs {d} albums {d} artists {d} in {d}ms\n", .{ r.lib.songs.len, r.lib.albums, r.lib.artists, t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds() });
    try st.save(gpa, r.lib, &r.raws);
    const l2 = try st.load(gpa);
    std.debug.print("reloaded {d}; {s}\n", .{ l2.songs.len, l2.songs[100].path });
}
