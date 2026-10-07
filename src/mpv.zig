//! mpv child process driven over its json ipc socket.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

const log = std.log.scoped(.mpv);

/// read by the signal handler so mpv dies with us.
pub var child_pid: std.atomic.Value(i32) = .init(0);

pub const EndReason = enum { eof, stop, err, other };

pub const Event = union(enum) {
    connected,
    disconnected,
    time_pos: f64,
    duration: f64,
    volume: f64,
    bitrate: f64,
    start_file,
    end_file: EndReason,
    idle: bool,
};

pub const Mpv = struct {
    gpa: Allocator,
    io: Io,
    sock_path: []const u8,
    /// pipewire node name, unique per instance so a visualizer never records another daemon's mpv
    client_name: []const u8,
    extra_args: []const []const u8,
    volume: i32,
    ctx: *anyopaque,
    handler: *const fn (*anyopaque, Event) void,
    fd: std.atomic.Value(std.c.fd_t) = .init(-1),
    available: std.atomic.Value(bool) = .init(true),
    stopping: std.atomic.Value(bool) = .init(false),
    wmu: Io.Mutex = .init,
    /// bumped on every (re)connect so the visualizer re-targets the new pipewire node
    generation: std.atomic.Value(u32) = .init(0),

    pub fn start(m: *Mpv) !void {
        const t = try std.Thread.spawn(.{}, run, .{m});
        t.detach();
    }

    pub fn connected(m: *Mpv) bool {
        return m.fd.load(.acquire) >= 0;
    }

    /// sends `{"command": args}`; args is a tuple. fails if mpv isn't connected.
    pub fn send(m: *Mpv, args: anytype) !void {
        const fd = m.fd.load(.acquire);
        if (fd < 0) return error.NoMpv;
        var aw: Io.Writer.Allocating = .init(m.gpa);
        defer aw.deinit();
        try json.Stringify.value(.{ .command = args }, .{}, &aw.writer);
        try aw.writer.writeByte('\n');
        m.wmu.lockUncancelable(m.io);
        defer m.wmu.unlock(m.io);
        var rest = aw.written();
        while (rest.len > 0) {
            const n = std.c.write(fd, rest.ptr, rest.len);
            if (n <= 0) return error.NoMpv;
            rest = rest[@intCast(n)..];
        }
    }

    fn run(m: *Mpv) void {
        while (!m.stopping.load(.acquire)) {
            m.session() catch |err| switch (err) {
                error.FileNotFound => {
                    log.warn("mpv not found in PATH: playback disabled, queue commands still work", .{});
                    m.available.store(false, .release);
                    return;
                },
                else => log.warn("mpv session: {s}", .{@errorName(err)}),
            };
            m.io.sleep(.fromSeconds(1), .awake) catch {};
        }
    }

    fn session(m: *Mpv) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(m.gpa);
        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try argv.appendSlice(m.gpa, &.{ "mpv", "--idle=yes", "--no-video", "--no-terminal" });
        try argv.append(m.gpa, try std.fmt.allocPrint(a, "--audio-client-name={s}", .{m.client_name}));
        try argv.append(m.gpa, try std.fmt.allocPrint(a, "--input-ipc-server={s}", .{m.sock_path}));
        try argv.append(m.gpa, try std.fmt.allocPrint(a, "--volume={d}", .{m.volume}));
        try argv.appendSlice(m.gpa, m.extra_args);

        var z: [std.posix.PATH_MAX]u8 = undefined;
        _ = std.c.unlink(try std.fmt.bufPrintSentinel(&z, "{s}", .{m.sock_path}, 0));
        var child = try std.process.spawn(m.io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        child_pid.store(child.id orelse 0, .release);
        log.info("started mpv pid {d}", .{child.id orelse 0});
        defer {
            child.kill(m.io);
            child_pid.store(0, .release);
        }

        const addr = try Io.net.UnixAddress.init(m.sock_path);
        var tries: u32 = 0;
        const stream = while (true) : (tries += 1) {
            if (addr.connect(m.io)) |s| break s else |err| {
                if (tries > 100) return err;
                m.io.sleep(.fromMilliseconds(50), .awake) catch {};
            }
        };
        const fd = stream.socket.handle;
        defer {
            m.fd.store(-1, .release);
            _ = std.c.close(fd);
            m.handler(m.ctx, .disconnected);
        }
        m.fd.store(fd, .release);
        _ = m.generation.fetchAdd(1, .acq_rel);
        try m.send(.{ "observe_property", 1, "time-pos" });
        try m.send(.{ "observe_property", 2, "duration" });
        try m.send(.{ "observe_property", 3, "volume" });
        try m.send(.{ "observe_property", 4, "audio-bitrate" });
        try m.send(.{ "observe_property", 5, "idle-active" });
        m.handler(m.ctx, .connected);

        var buf: [16384]u8 = undefined;
        var have: usize = 0;
        while (true) {
            const n = std.c.read(fd, buf[have..].ptr, buf.len - have);
            if (n <= 0) return;
            have += @intCast(n);
            var from: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buf[0..have], from, '\n')) |nl| {
                m.line(buf[from..nl]);
                from = nl + 1;
            }
            std.mem.copyForwards(u8, buf[0 .. have - from], buf[from..have]);
            have -= from;
            if (have == buf.len) have = 0;
        }
    }

    fn num(v: ?json.Value) ?f64 {
        const x = v orelse return null;
        return switch (x) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    fn line(m: *Mpv, text: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(m.gpa);
        defer arena.deinit();
        const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{}) catch return;
        if (root != .object) return;
        const ev = root.object.get("event") orelse return;
        if (ev != .string) return;
        if (std.mem.eql(u8, ev.string, "property-change")) {
            const name = root.object.get("name") orelse return;
            if (name != .string) return;
            const data = root.object.get("data");
            if (std.mem.eql(u8, name.string, "time-pos")) {
                if (num(data)) |v| m.handler(m.ctx, .{ .time_pos = v });
            } else if (std.mem.eql(u8, name.string, "duration")) {
                if (num(data)) |v| m.handler(m.ctx, .{ .duration = v });
            } else if (std.mem.eql(u8, name.string, "volume")) {
                if (num(data)) |v| m.handler(m.ctx, .{ .volume = v });
            } else if (std.mem.eql(u8, name.string, "audio-bitrate")) {
                if (num(data)) |v| m.handler(m.ctx, .{ .bitrate = v });
            } else if (std.mem.eql(u8, name.string, "idle-active")) {
                if (data) |d| if (d == .bool) m.handler(m.ctx, .{ .idle = d.bool });
            }
        } else if (std.mem.eql(u8, ev.string, "start-file")) {
            m.handler(m.ctx, .start_file);
        } else if (std.mem.eql(u8, ev.string, "end-file")) {
            var r: EndReason = .other;
            if (root.object.get("reason")) |x| if (x == .string) {
                if (std.mem.eql(u8, x.string, "eof")) r = .eof else if (std.mem.eql(u8, x.string, "stop")) r = .stop else if (std.mem.eql(u8, x.string, "error")) r = .err;
            };
            m.handler(m.ctx, .{ .end_file = r });
        }
    }
};
