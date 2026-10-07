const std = @import("std");
const Io = std.Io;
const config = @import("config.zig");
const subsonic = @import("subsonic.zig");
const db = @import("db.zig");
const hub_mod = @import("hub.zig");
const player_mod = @import("player.zig");
const mpv = @import("mpv.zig");
const server = @import("mpd/server.zig");
const App = @import("app.zig").App;

const log = std.log.scoped(.main);

var verbose = false;

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    if (level == .debug and !verbose) return;
    std.log.defaultLog(level, scope, fmt, args);
}

/// our own mpv socket, unlinked on exit (read from the signal handler)
var sock_z: [std.posix.PATH_MAX:0]u8 = @splat(0);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    const pid = mpv.child_pid.load(.acquire);
    if (pid > 0) _ = std.c.kill(pid, .TERM);
    _ = std.c.unlink(&sock_z);
    std.c._exit(0);
}

fn installSignals() void {
    const term: std.posix.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.INT, &term, null);
    std.posix.sigaction(.TERM, &term, null);
    std.posix.sigaction(.HUP, &term, null);
    const ign: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.PIPE, &ign, null);
}

fn portInUse(io: Io, cfg: config.Config) bool {
    const addr = Io.net.IpAddress.parse(cfg.bind, cfg.port) catch return false;
    const s = addr.connect(io, .{ .mode = .stream }) catch return false; // local connect: no timeout needed
    s.close(io);
    return true;
}

const usage = "usage: drome-lord [--config path] [--verbose]\n";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var opts: config.Options = .{};
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, a, "--config")) {
            opts.config_path = args.next() orelse {
                std.debug.print(usage, .{});
                std.process.exit(2);
            };
        } else {
            std.debug.print(usage, .{});
            std.process.exit(if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) 0 else 2);
        }
    }
    verbose = opts.verbose;

    const cfg = config.load(arena, io, init.environ_map, opts) catch |err| {
        log.err("config: {s} (need urls in the config file and username/password in credentials)", .{@errorName(err)});
        std.process.exit(1);
    };

    // never touch shared state if another instance already owns the port
    if (portInUse(io, cfg)) {
        log.err("{s}:{d} is already in use (another drome-lord/mpd running?), refusing to start", .{ cfg.bind, cfg.port });
        std.process.exit(1);
    }

    const app = try gpa.create(App);
    app.* = .{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .sc = subsonic.Client.init(gpa, io, cfg.username, cfg.password),
        .store = try db.Store.open(gpa, io, cfg.cache_dir),
        .hub = .{ .gpa = gpa, .io = io },
        .player = undefined,
        .lib = undefined,
        .started = Io.Timestamp.now(io, .awake),
    };
    app.lib = try app.store.load(gpa);
    log.info("cache: {d} songs", .{app.lib.songs.len});

    var sock_buf: [std.posix.PATH_MAX]u8 = undefined;
    // per-instance socket: two daemons must never share one mpv
    var sock = try std.fmt.bufPrint(&sock_buf, "{s}/drome-lord-mpv-{d}.sock", .{ cfg.runtime_dir, cfg.port });
    if (sock.len > 100) sock = try std.fmt.bufPrint(&sock_buf, "/tmp/drome-lord-{d}-{d}.sock", .{ cfg.port, std.c.getpid() });
    @memcpy(sock_z[0..sock.len], sock);
    app.player = try player_mod.Player.create(gpa, io, &app.hub, &app.sc, try arena.dupe(u8, sock), try std.fmt.allocPrint(arena, "drome-lord-{d}", .{cfg.port}), cfg.mpv_args, cfg.scrobble);

    installSignals();
    app.sc.pickUrl(cfg.urls) catch log.warn("no navidrome url reachable yet, serving cached library", .{});
    try app.player.mpv.start();
    if (cfg.visualizer.len > 0) app.viz = @import("visualizer.zig").Visualizer.start(gpa, io, app.player, cfg.visualizer);

    const age = app.nowSec() - app.lib.updated;
    if (app.lib.songs.len == 0 or age > 12 * 3600) _ = try app.startUpdate();
    try server.serve(app);
}
