//! listener, per-client threads, idle and command lists.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const App = @import("../app.zig").App;
const hub_mod = @import("../hub.zig");
const cmds = @import("commands.zig");
const parse = @import("parse.zig");

const log = std.log.scoped(.server);

pub fn serve(app: *App) !void {
    const addr = try Io.net.IpAddress.parse(app.cfg.bind, app.cfg.port);
    var server = try addr.listen(app.io, .{ .reuse_address = true });
    log.info("listening on {s}:{d}", .{ app.cfg.bind, app.cfg.port });
    while (true) {
        const stream = server.accept(app.io) catch |err| {
            log.warn("accept: {s}", .{@errorName(err)});
            continue;
        };
        const t = std.Thread.spawn(.{}, clientMain, .{ app, stream.socket.handle }) catch {
            _ = std.c.close(stream.socket.handle);
            continue;
        };
        t.detach();
    }
}

const Client = struct {
    app: *App,
    fd: std.c.fd_t,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,
    waker: hub_mod.Waker,
    info: cmds.ClientInfo = .{},
    out: Io.Writer.Allocating,

    fn readLine(c: *Client) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, c.buf[c.start..c.end], '\n')) |i| {
                const line = c.buf[c.start .. c.start + i];
                c.start += i + 1;
                return std.mem.trimEnd(u8, line, "\r");
            }
            if (c.start > 0) {
                std.mem.copyForwards(u8, c.buf[0 .. c.end - c.start], c.buf[c.start..c.end]);
                c.end -= c.start;
                c.start = 0;
            }
            if (c.end == c.buf.len) return error.LineTooLong;
            const n = std.c.read(c.fd, c.buf[c.end..].ptr, c.buf.len - c.end);
            if (n <= 0) return null;
            c.end += @intCast(n);
        }
    }

    fn hasLine(c: *Client) bool {
        return std.mem.indexOfScalar(u8, c.buf[c.start..c.end], '\n') != null;
    }

    fn flush(c: *Client) !void {
        var rest = c.out.written();
        while (rest.len > 0) {
            const n = std.c.write(c.fd, rest.ptr, rest.len);
            if (n <= 0) return error.Closed;
            rest = rest[@intCast(n)..];
        }
        c.out.clearRetainingCapacity();
    }
};

fn clientMain(app: *App, fd: std.c.fd_t) void {
    const gpa = app.gpa;
    defer _ = std.c.close(fd);
    var c: Client = .{
        .app = app,
        .fd = fd,
        .buf = gpa.alloc(u8, 1 << 16) catch return,
        .waker = hub_mod.Waker.init() catch return,
        .out = .init(gpa),
    };
    defer {
        gpa.free(c.buf);
        c.waker.deinit();
        c.out.deinit();
    }
    app.hub.register(&c.waker) catch return;
    defer app.hub.unregister(&c.waker);
    run(&c) catch |err| switch (err) {
        error.Closed => {},
        else => log.debug("client ended: {s}", .{@errorName(err)}),
    };
}

const ListMode = enum { none, plain, ok };

fn run(c: *Client) !void {
    const gpa = c.app.gpa;
    try c.out.writer.writeAll("OK MPD 0.23.5\n");
    try c.flush();
    var mode: ListMode = .none;
    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |l| gpa.free(l);
        list.deinit(gpa);
    }
    while (true) {
        const line = (try c.readLine()) orelse return;
        if (mode != .none) {
            if (std.mem.eql(u8, line, "command_list_end")) {
                const keep = try runList(c, list.items, mode == .ok);
                for (list.items) |l| gpa.free(l);
                list.clearRetainingCapacity();
                mode = .none;
                try c.flush();
                if (!keep) return;
            } else try list.append(gpa, try gpa.dupe(u8, line));
            continue;
        }
        if (std.mem.eql(u8, line, "command_list_begin")) {
            mode = .plain;
            continue;
        }
        if (std.mem.eql(u8, line, "command_list_ok_begin")) {
            mode = .ok;
            continue;
        }
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const toks = parse.tokenize(arena.allocator(), line) catch {
            try c.out.writer.writeAll("ACK [5@0] {} Invalid unquoted character\n");
            try c.flush();
            continue;
        };
        if (toks.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(toks[0], "noidle")) continue;
        if (std.ascii.eqlIgnoreCase(toks[0], "idle")) {
            if (!try idle(c, toks[1..])) return;
            try c.flush();
            continue;
        }
        const r = try runOneIn(c, arena.allocator(), toks, 0);
        if (r == .ok) try c.out.writer.writeAll("OK\n");
        try c.flush();
        if (r == .close) return;
    }
}

/// returns false when the client should be disconnected.
fn runList(c: *Client, lines: []const []u8, ok_mode: bool) !bool {
    for (lines, 0..) |line, i| {
        var arena: std.heap.ArenaAllocator = .init(c.app.gpa);
        defer arena.deinit();
        const toks = parse.tokenize(arena.allocator(), line) catch {
            try c.out.writer.print("ACK [5@{d}] {{}} Invalid unquoted character\n", .{i});
            return true;
        };
        if (toks.len == 0) continue;
        const r = try runOneIn(c, arena.allocator(), toks, i);
        switch (r) {
            .ok => if (ok_mode) try c.out.writer.writeAll("list_OK\n"),
            .failed => return true,
            .close => return false,
        }
    }
    try c.out.writer.writeAll("OK\n");
    return true;
}

const Result = enum { ok, failed, close };

fn runOneIn(c: *Client, arena: Allocator, toks: []const []const u8, idx: usize) !Result {
    var tmp: Io.Writer.Allocating = .init(arena);
    var cx: cmds.Cx = .{
        .app = c.app,
        .w = &tmp.writer,
        .arena = arena,
        .args = toks[1..],
        .cmd = toks[0],
        .client = &c.info,
    };
    lower(toks[0]);
    if (cmds.execute(&cx)) |_| {
        try c.out.writer.writeAll(tmp.written());
        return .ok;
    } else |err| switch (err) {
        error.Close => return .close,
        error.Ack => {
            try c.out.writer.print("ACK [{d}@{d}] {{{s}}} {s}\n", .{ @intFromEnum(cx.code), idx, cx.cmd, cx.msg });
            return .failed;
        },
        else => {
            try c.out.writer.print("ACK [52@{d}] {{{s}}} internal error\n", .{ idx, cx.cmd });
            return .failed;
        },
    }
}

fn lower(s: []const u8) void {
    const m: []u8 = @constCast(s);
    for (m) |*ch| ch.* = std.ascii.toLower(ch.*);
}

/// handles `idle`; returns false if the connection should close.
fn idle(c: *Client, args: []const []const u8) !bool {
    var mask: u32 = 0;
    for (args) |a| {
        const s = hub_mod.parseSubsystem(a) orelse {
            try c.out.writer.print("ACK [2@0] {{idle}} Unrecognized idle event: {s}\n", .{a});
            return true;
        };
        mask |= s.bit();
    }
    if (args.len == 0) mask = hub_mod.all_mask;
    const hub = &c.app.hub;
    var changed: u32 = 0;
    while (true) {
        if (!hub.arm(&c.waker, mask)) {
            changed = hub.take(&c.waker, mask);
            break;
        }
        var pending_line = c.hasLine();
        if (!pending_line) {
            var fds = [_]std.c.pollfd{
                .{ .fd = c.fd, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = c.waker.rd, .events = std.c.POLL.IN, .revents = 0 },
            };
            _ = std.c.poll(&fds, 2, -1);
            pending_line = fds[0].revents != 0;
            if (!pending_line and fds[1].revents == 0) {
                hub.disarm(&c.waker);
                continue;
            }
        }
        if (pending_line) {
            const line = (try c.readLine()) orelse {
                hub.disarm(&c.waker);
                return false;
            };
            hub.disarm(&c.waker);
            if (std.ascii.eqlIgnoreCase(line, "noidle")) break;
            return false; // anything else during idle is a protocol violation
        }
        hub.disarm(&c.waker);
        changed = hub.take(&c.waker, mask);
        if (changed != 0) break;
    }
    inline for (std.enums.values(hub_mod.Subsystem)) |s| {
        if (changed & s.bit() != 0) try c.out.writer.print("changed: {s}\n", .{@tagName(s)});
    }
    try c.out.writer.writeAll("OK\n");
    return true;
}
