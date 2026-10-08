//! feeds ncmpcpp's visualizer: records mpv's playback as raw s16le 44.1k stereo and forwards it
//! as udp datagrams. linux: pw-record on mpv's pipewire stream. macos: `drome-lord tap <mpv pid>`,
//! a core audio process tap (src/tap.m, macos 14.2+).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Player = @import("player.zig").Player;

const log = std.log.scoped(.visualizer);

const macos = builtin.os.tag == .macos;
/// what `outputs` reports as the visualizer's plugin
pub const plugin = if (macos) "coreaudio" else "pipewire";

pub const Visualizer = struct {
    io: Io,
    player: *Player,
    /// "localhost" resolves to ::1 for ncmpcpp, so loopback targets get both families
    dests: [2]Io.net.IpAddress,
    socks: [2]Io.net.Socket,
    n: usize,
    enabled: std.atomic.Value(bool) = .init(true),
    kick: std.atomic.Value(u32) = .init(0),
    /// macos: our own binary, re-run as `drome-lord tap <pid>`
    self_exe: []const u8 = "",

    /// null when unsupported on this os or the address is unusable.
    pub fn start(gpa: Allocator, io: Io, player: *Player, spec: []const u8) ?*Visualizer {
        if (builtin.os.tag != .linux and !macos) {
            log.warn("visualizer needs pipewire (linux) or core audio taps (macos): unsupported on this os, skipping", .{});
            return null;
        }
        const v = gpa.create(Visualizer) catch return null;
        v.* = .{ .io = io, .player = player, .dests = undefined, .socks = undefined, .n = 0 };
        if (macos) v.self_exe = std.process.executablePathAlloc(io, gpa) catch |err| {
            log.warn("visualizer: can't find own executable ({s}), visualizer off", .{@errorName(err)});
            return null;
        };
        v.addTargets(spec) catch {
            log.warn("bad visualizer address \"{s}\" (want host:port), visualizer off", .{spec});
            return null;
        };
        const t = std.Thread.spawn(.{}, run, .{v}) catch return null;
        t.detach();
        log.info("visualizer feed to {s}", .{spec});
        return v;
    }

    /// enable/disable output; either way the capture restarts (ncmpcpp does this to flush).
    pub fn setEnabled(v: *Visualizer, on: bool) void {
        v.enabled.store(on, .release);
        _ = v.kick.fetchAdd(1, .acq_rel);
    }

    fn addTargets(v: *Visualizer, spec: []const u8) !void {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return error.BadAddress;
        const host = std.mem.trim(u8, spec[0..colon], "[]");
        const port = try std.fmt.parseInt(u16, spec[colon + 1 ..], 10);
        const loop = std.mem.eql(u8, host, "localhost");
        if (loop or std.mem.indexOfScalar(u8, host, ':') == null) {
            try v.add(try Io.net.IpAddress.parseIp4(if (loop) "127.0.0.1" else host, port), "0.0.0.0");
        }
        if (loop or std.mem.indexOfScalar(u8, host, ':') != null) {
            try v.add(try Io.net.IpAddress.parseIp6(if (loop) "::1" else host, port), "::");
        }
    }

    fn add(v: *Visualizer, dest: Io.net.IpAddress, bind_host: []const u8) !void {
        const any = try Io.net.IpAddress.parse(bind_host, 0);
        v.socks[v.n] = any.bind(v.io, .{ .mode = .dgram }) catch |err| {
            log.warn("visualizer socket: {s}", .{@errorName(err)});
            return error.Socket;
        };
        v.dests[v.n] = dest;
        v.n += 1;
    }

    fn wanted(v: *Visualizer) bool {
        if (!v.enabled.load(.acquire) or !v.player.mpv.connected()) return false;
        v.player.lock();
        defer v.player.unlock();
        return v.player.state != .stop;
    }

    fn run(v: *Visualizer) void {
        while (true) {
            if (v.wanted()) {
                v.capture() catch |err| switch (err) {
                    error.FileNotFound => {
                        log.warn("{s} not found: visualizer disabled", .{if (macos) v.self_exe else "pw-record"});
                        return;
                    },
                    else => log.debug("capture: {s}", .{@errorName(err)}),
                };
            }
            v.io.sleep(.fromMilliseconds(400), .awake) catch {};
        }
    }

    fn capture(v: *Visualizer) !void {
        const session = v.player.mpv.generation.load(.acquire);
        const kick = v.kick.load(.acquire);
        var pid_buf: [16]u8 = undefined;
        const mpv_pid = @import("mpv.zig").child_pid.load(.acquire);
        if (macos and mpv_pid <= 0) return;
        // the tap exits straight away until mpv has opened its audio output; run() retries
        const tap_argv = [_][]const u8{ v.self_exe, "tap", std.fmt.bufPrint(&pid_buf, "{d}", .{mpv_pid}) catch unreachable };
        const pw_argv = [_][]const u8{
            "pw-record", "--raw", "--target", v.player.mpv.client_name,
            // never fall back to the default source (the microphone) if mpv's stream is gone
            "-P",       "{ node.dont-fallback = true node.dont-reconnect = true }",
            "--rate",   "44100",
            "--channels", "2",
            "--format", "s16",
            "-",
        };
        const argv: []const []const u8 = if (macos) &tap_argv else &pw_argv;
        var child = try std.process.spawn(v.io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
        defer child.kill(v.io);
        const fd = child.stdout.?.handle;
        var buf: [4096]u8 = undefined;
        while (true) {
            var fds = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            const r = std.c.poll(&fds, 1, 300);
            if (r == 0) {
                if (v.kick.load(.acquire) != kick or v.player.mpv.generation.load(.acquire) != session or !v.wanted()) return;
                continue;
            }
            if (r < 0) return;
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) return;
            if (v.kick.load(.acquire) != kick or !v.enabled.load(.acquire)) return;
            for (0..v.n) |i| v.socks[i].send(v.io, &v.dests[i], buf[0..@intCast(n)]) catch |err| log.debug("send {d}: {s}", .{ i, @errorName(err) });
        }
    }
};
