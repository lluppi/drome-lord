//! feeds ncmpcpp's visualizer: records mpv's pipewire playback stream with pw-record
//! (raw s16le 44.1k stereo) and forwards it as udp datagrams. linux/pipewire only.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Player = @import("player.zig").Player;

const log = std.log.scoped(.visualizer);

pub const Visualizer = struct {
    io: Io,
    player: *Player,
    dest: Io.net.IpAddress,
    sock: Io.net.Socket,
    enabled: std.atomic.Value(bool) = .init(true),
    kick: std.atomic.Value(u32) = .init(0),

    /// null when unsupported on this os or the address is unusable.
    pub fn start(gpa: Allocator, io: Io, player: *Player, spec: []const u8) ?*Visualizer {
        if (builtin.os.tag != .linux) {
            log.warn("visualizer needs pipewire (linux): unsupported on this os, skipping", .{});
            return null;
        }
        const dest = parseDest(spec) catch {
            log.warn("bad visualizer address \"{s}\" (want host:port), visualizer off", .{spec});
            return null;
        };
        const any = Io.net.IpAddress.parseIp4("0.0.0.0", 0) catch return null;
        const sock = any.bind(io, .{ .mode = .dgram }) catch |err| {
            log.warn("visualizer socket: {s}", .{@errorName(err)});
            return null;
        };
        const v = gpa.create(Visualizer) catch return null;
        v.* = .{ .io = io, .player = player, .dest = dest, .sock = sock };
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

    fn parseDest(spec: []const u8) !Io.net.IpAddress {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return error.BadAddress;
        var host = spec[0..colon];
        if (std.mem.eql(u8, host, "localhost")) host = "127.0.0.1";
        const port = try std.fmt.parseInt(u16, spec[colon + 1 ..], 10);
        return Io.net.IpAddress.parseIp4(host, port);
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
                        log.warn("pw-record not found: visualizer disabled", .{});
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
        const argv = [_][]const u8{
            "pw-record", "--raw", "--target", v.player.mpv.client_name,
            // never fall back to the default source (the microphone) if mpv's stream is gone
            "-P",       "{ node.dont-fallback = true node.dont-reconnect = true }",
            "--rate",   "44100",
            "--channels", "2",
            "--format", "s16",
            "-",
        };
        var child = try std.process.spawn(v.io, .{ .argv = &argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore });
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
            v.sock.send(v.io, &v.dest, buf[0..@intCast(n)]) catch {};
        }
    }
};
