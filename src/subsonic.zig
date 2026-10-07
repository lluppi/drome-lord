const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

const log = std.log.scoped(.subsonic);

pub const Error = error{ WriteFailed, HttpStatus, ApiError, BadResponse, Unreachable } || Allocator.Error;

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    http: std.http.Client,
    base: []const u8 = "",
    user: []const u8,
    pass: []const u8,
    last_req: Io.Timestamp = .zero,
    mu: Io.Mutex = .init,

    pub fn init(gpa: Allocator, io: Io, user: []const u8, pass: []const u8) Client {
        return .{ .gpa = gpa, .io = io, .http = .{ .allocator = gpa, .io = io }, .user = user, .pass = pass };
    }

    /// first url that answers ping.view wins.
    pub fn pickUrl(c: *Client, urls: []const []const u8) !void {
        for (urls) |u| {
            c.base = std.mem.trimEnd(u8, u, "/");
            var arena: std.heap.ArenaAllocator = .init(c.gpa);
            defer arena.deinit();
            if (c.call(arena.allocator(), "ping.view", &.{})) |_| {
                log.info("using {s}", .{c.base});
                return;
            } else |err| log.warn("{s} not usable: {s}", .{ u, @errorName(err) });
        }
        return error.Unreachable;
    }

    fn encode(w: *Io.Writer, s: []const u8) !void {
        for (s) |ch| {
            if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~')
                try w.writeByte(ch)
            else
                try w.print("%{X:0>2}", .{ch});
        }
    }

    /// builds a signed url; caller owns it. the token is md5(password+salt), never the password.
    pub fn url(c: *Client, alloc: Allocator, endpoint: []const u8, params: []const [2][]const u8) ![]u8 {
        var salt_raw: [8]u8 = undefined;
        c.io.random(&salt_raw);
        const salt = std.fmt.bytesToHex(salt_raw, .lower);
        var h: [16]u8 = undefined;
        var md5: std.crypto.hash.Md5 = .init(.{});
        md5.update(c.pass);
        md5.update(&salt);
        md5.final(&h);
        const token = std.fmt.bytesToHex(h, .lower);

        var aw: Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        const w = &aw.writer;
        try w.print("{s}/rest/{s}?u=", .{ c.base, endpoint });
        try encode(w, c.user);
        try w.print("&t={s}&s={s}&v=1.16.1&c=drome-lord&f=json", .{ token, salt });
        for (params) |p| {
            try w.print("&{s}=", .{p[0]});
            try encode(w, p[1]);
        }
        return aw.toOwnedSlice();
    }

    /// keeps navidrome behind the vps limit: ~8 req/s.
    fn throttle(c: *Client) void {
        c.mu.lockUncancelable(c.io);
        defer c.mu.unlock(c.io);
        const now = Io.Timestamp.now(c.io, .awake);
        const wait_ns = 120 * std.time.ns_per_ms - c.last_req.durationTo(now).toNanoseconds();
        if (wait_ns > 0) c.io.sleep(.fromNanoseconds(@intCast(wait_ns)), .awake) catch {};
        c.last_req = Io.Timestamp.now(c.io, .awake);
    }

    /// raw body of a request; handles 429 with backoff. never logs the url.
    pub fn getBytes(c: *Client, alloc: Allocator, endpoint: []const u8, params: []const [2][]const u8) Error![]u8 {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            c.throttle();
            const u = try c.url(alloc, endpoint, params);
            defer alloc.free(u);
            var aw: Io.Writer.Allocating = .init(alloc);
            errdefer aw.deinit();
            const res = c.http.fetch(.{
                .location = .{ .url = u },
                .response_writer = &aw.writer,
            }) catch |err| {
                log.debug("{s}: {s}", .{ endpoint, @errorName(err) });
                return error.Unreachable;
            };
            if (res.status == .too_many_requests and tries < 6) {
                aw.deinit();
                log.warn("429 from server, backing off", .{});
                c.io.sleep(.fromSeconds(1 + tries), .awake) catch {};
                continue;
            }
            if (res.status != .ok) {
                log.warn("{s}: http {d}", .{ endpoint, @intFromEnum(res.status) });
                return error.HttpStatus;
            }
            return aw.toOwnedSlice();
        }
    }

    /// parsed `subsonic-response` object; everything allocated in `arena`.
    pub fn call(c: *Client, arena: Allocator, endpoint: []const u8, params: []const [2][]const u8) Error!json.ObjectMap {
        const body = try c.getBytes(arena, endpoint, params);
        const root = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch return error.BadResponse;
        if (root != .object) return error.BadResponse;
        const resp = root.object.get("subsonic-response") orelse return error.BadResponse;
        if (resp != .object) return error.BadResponse;
        const status = resp.object.get("status") orelse return error.BadResponse;
        if (status != .string or !std.mem.eql(u8, status.string, "ok")) {
            if (resp.object.get("error")) |e| if (e == .object) if (e.object.get("message")) |m| if (m == .string)
                log.warn("{s}: api error: {s}", .{ endpoint, m.string });
            return error.ApiError;
        }
        return resp.object;
    }
};
