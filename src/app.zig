//! shared daemon state handed to every client thread.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const db = @import("db.zig");
const subsonic = @import("subsonic.zig");
const hub_mod = @import("hub.zig");
const player_mod = @import("player.zig");
const config = @import("config.zig");

const log = std.log.scoped(.app);

const max_covers = 6;

const Cover = struct { id: []u8, data: []u8 };

pub const App = struct {
    gpa: Allocator,
    io: Io,
    cfg: config.Config,
    sc: subsonic.Client,
    store: db.Store,
    hub: hub_mod.Hub,
    player: *player_mod.Player,
    lib_mu: Io.Mutex = .init,
    lib: *db.Library,
    update_job: std.atomic.Value(u32) = .init(0),
    job_counter: u32 = 0,
    started: Io.Timestamp,
    cover_mu: Io.Mutex = .init,
    covers: std.ArrayList(Cover) = .empty,

    pub fn lockLib(a: *App) *const db.Library {
        a.lib_mu.lockUncancelable(a.io);
        return a.lib;
    }

    pub fn unlockLib(a: *App) void {
        a.lib_mu.unlock(a.io);
    }

    pub fn nowSec(a: *App) i64 {
        return Io.Timestamp.now(a.io, .real).toSeconds();
    }

    /// starts a background sync; returns the job id, or null if one is already running.
    pub fn startUpdate(a: *App) !?u32 {
        if (a.update_job.load(.acquire) != 0) return null;
        a.job_counter += 1;
        const job = a.job_counter;
        a.update_job.store(job, .release);
        const t = std.Thread.spawn(.{}, syncThread, .{a}) catch |err| {
            a.update_job.store(0, .release);
            return err;
        };
        t.detach();
        a.hub.notify(hub_mod.Subsystem.update.bit());
        return job;
    }

    fn syncThread(a: *App) void {
        defer {
            a.update_job.store(0, .release);
            a.hub.notify(hub_mod.Subsystem.update.bit());
        }
        const t0 = Io.Timestamp.now(a.io, .awake);
        log.info("library sync started", .{});
        if (!a.sc.reachable) a.sc.pickUrl(a.cfg.urls) catch {
            log.err("no navidrome url reachable", .{});
            return;
        };
        var r = db.sync(a.gpa, &a.sc, a.nowSec()) catch |err| {
            log.err("library sync failed: {s}", .{@errorName(err)});
            return;
        };
        defer r.raw_arena.deinit();
        a.store.save(a.gpa, r.lib, &r.raws) catch |err| log.err("saving library: {s}", .{@errorName(err)});
        a.store.setSynced(a.nowSec()) catch {};
        a.lib_mu.lockUncancelable(a.io);
        const old = a.lib;
        a.lib = r.lib;
        a.lib_mu.unlock(a.io);
        old.destroy(a.gpa);
        const ms = t0.durationTo(Io.Timestamp.now(a.io, .awake)).toMilliseconds();
        log.info("library sync done: {d} songs, {d} albums, {d} artists in {d}ms", .{ r.lib.songs.len, r.lib.albums, r.lib.artists, ms });
        a.hub.notify(hub_mod.Subsystem.database.bit());
    }

    /// writes `size/binary` header + a chunk of the cover bytes; fetches the cover once.
    pub fn coverChunk(a: *App, cover_id: []const u8, offset: usize, limit: usize, w: *Io.Writer) !bool {
        if (!try a.ensureCover(cover_id)) return false;
        a.cover_mu.lockUncancelable(a.io);
        defer a.cover_mu.unlock(a.io);
        for (a.covers.items) |c| if (std.mem.eql(u8, c.id, cover_id)) {
            const start = @min(offset, c.data.len);
            const end = @min(start + limit, c.data.len);
            try w.print("size: {d}\nbinary: {d}\n", .{ c.data.len, end - start });
            try w.writeAll(c.data[start..end]);
            try w.writeByte('\n');
            return true;
        };
        return false;
    }

    fn ensureCover(a: *App, id: []const u8) !bool {
        {
            a.cover_mu.lockUncancelable(a.io);
            defer a.cover_mu.unlock(a.io);
            for (a.covers.items) |c| if (std.mem.eql(u8, c.id, id)) return true;
        }
        const data = a.sc.getBytes(a.gpa, "getCoverArt.view", &.{ .{ "id", id }, .{ "size", "800" } }) catch return false;
        errdefer a.gpa.free(data);
        const key = try a.gpa.dupe(u8, id);
        a.cover_mu.lockUncancelable(a.io);
        defer a.cover_mu.unlock(a.io);
        if (a.covers.items.len >= max_covers) {
            const old = a.covers.orderedRemove(0);
            a.gpa.free(old.id);
            a.gpa.free(old.data);
        }
        try a.covers.append(a.gpa, .{ .id = key, .data = data });
        return true;
    }
};
