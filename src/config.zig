const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Config = struct {
    urls: []const []const u8 = &.{},
    bind: []const u8 = "127.0.0.1",
    port: u16 = 6600,
    mpv_args: []const []const u8 = &.{},
    scrobble: bool = true,
    /// udp host:port for ncmpcpp's visualizer; empty = off
    visualizer: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    cache_dir: []const u8 = "",
    runtime_dir: []const u8 = "",
};

pub const Options = struct {
    config_path: ?[]const u8 = null,
    verbose: bool = false,
};

fn readFile(gpa: Allocator, io: Io, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch null;
}

fn splitList(arena: Allocator, v: []const u8, sep: u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, v, sep);
    while (it.next()) |t| {
        const s = std.mem.trim(u8, t, " \t");
        if (s.len > 0) try list.append(arena, s);
    }
    return list.items;
}

const Pair = struct { key: []const u8, value: []const u8 };

fn nextPair(it: *std.mem.SplitIterator(u8, .scalar)) ??Pair {
    const raw = it.next() orelse return null;
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return @as(?Pair, null);
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return @as(?Pair, null);
    return Pair{
        .key = std.mem.trim(u8, line[0..eq], " \t"),
        .value = std.mem.trim(u8, line[eq + 1 ..], " \t"),
    };
}

/// all returned slices live in `arena`.
pub fn load(arena: Allocator, io: Io, env: *const std.process.Environ.Map, opts: Options) !Config {
    const home = env.get("HOME") orelse "";
    var cfg: Config = .{};

    const cfg_dir = if (env.get("XDG_CONFIG_HOME")) |x|
        try std.fs.path.join(arena, &.{ x, "drome-lord" })
    else
        try std.fs.path.join(arena, &.{ home, ".config", "drome-lord" });
    const cfg_path = opts.config_path orelse env.get("DROME_LORD_CONFIG") orelse
        try std.fs.path.join(arena, &.{ cfg_dir, "config" });
    cfg.cache_dir = if (env.get("XDG_CACHE_HOME")) |x|
        try std.fs.path.join(arena, &.{ x, "drome-lord" })
    else
        try std.fs.path.join(arena, &.{ home, ".cache", "drome-lord" });
    cfg.runtime_dir = env.get("XDG_RUNTIME_DIR") orelse cfg.cache_dir;

    if (readFile(arena, io, cfg_path)) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (nextPair(&lines)) |maybe| {
            const p = maybe orelse continue;
            if (std.mem.eql(u8, p.key, "urls")) cfg.urls = try splitList(arena, p.value, ',');
            if (std.mem.eql(u8, p.key, "bind")) cfg.bind = p.value;
            if (std.mem.eql(u8, p.key, "port")) cfg.port = try std.fmt.parseInt(u16, p.value, 10);
            if (std.mem.eql(u8, p.key, "mpv_args")) cfg.mpv_args = try splitList(arena, p.value, ' ');
            if (std.mem.eql(u8, p.key, "visualizer")) cfg.visualizer = p.value;
            if (std.mem.eql(u8, p.key, "scrobble")) cfg.scrobble = std.mem.eql(u8, p.value, "true");
        }
    } else std.log.warn("no config at {s}, using defaults", .{cfg_path});

    const cred_path = try std.fs.path.join(arena, &.{ cfg_dir, "credentials" });
    if (readFile(arena, io, cred_path)) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (nextPair(&lines)) |maybe| {
            const p = maybe orelse continue;
            if (std.mem.eql(u8, p.key, "username")) cfg.username = p.value;
            if (std.mem.eql(u8, p.key, "password")) cfg.password = p.value;
        }
        if (Io.Dir.cwd().statFile(io, cred_path, .{})) |st| {
            if (st.permissions.toMode() & 0o077 != 0)
                std.log.warn("credentials file is readable by group/others, consider chmod 600", .{});
        } else |_| {}
    }
    if (env.get("DROME_LORD_USERNAME")) |v| cfg.username = v;
    if (env.get("DROME_LORD_PASSWORD")) |v| cfg.password = v;
    if (cfg.urls.len == 0) return error.NoUrls;
    if (cfg.username.len == 0 or cfg.password.len == 0) return error.NoCredentials;
    return cfg;
}
