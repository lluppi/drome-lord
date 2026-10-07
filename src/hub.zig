//! idle subsystem fan-out: each client has a pending bitmask and a wake pipe.
const std = @import("std");
const Io = std.Io;

pub const Subsystem = enum(u5) {
    database,
    update,
    stored_playlist,
    playlist,
    player,
    mixer,
    output,
    options,

    pub fn bit(s: Subsystem) u32 {
        return @as(u32, 1) << @intFromEnum(s);
    }
};

pub const all_mask: u32 = (1 << @typeInfo(Subsystem).@"enum".field_names.len) - 1;

pub fn parseSubsystem(name: []const u8) ?Subsystem {
    return std.meta.stringToEnum(Subsystem, name);
}

pub const Waker = struct {
    rd: std.c.fd_t,
    wr: std.c.fd_t,
    pending: u32 = 0,
    idling: bool = false,

    pub fn init() !Waker {
        var fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return error.Pipe;
        return .{ .rd = fds[0], .wr = fds[1] };
    }

    pub fn deinit(w: *Waker) void {
        _ = std.c.close(w.rd);
        _ = std.c.close(w.wr);
    }
};

pub const Hub = struct {
    gpa: std.mem.Allocator,
    io: Io,
    mu: Io.Mutex = .init,
    clients: std.ArrayList(*Waker) = .empty,

    pub fn register(h: *Hub, w: *Waker) !void {
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        try h.clients.append(h.gpa, w);
    }

    pub fn unregister(h: *Hub, w: *Waker) void {
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        for (h.clients.items, 0..) |x, i| if (x == w) {
            _ = h.clients.swapRemove(i);
            break;
        };
    }

    pub fn notify(h: *Hub, subs: u32) void {
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        for (h.clients.items) |w| {
            w.pending |= subs;
            if (w.idling and w.pending != 0) {
                w.idling = false; // one wake byte per idle
                _ = std.c.write(w.wr, "x", 1);
            }
        }
    }

    /// returns and clears pending & mask.
    pub fn take(h: *Hub, w: *Waker, mask: u32) u32 {
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        const hit = w.pending & mask;
        w.pending &= ~hit;
        return hit;
    }

    /// arms the waker so notify() writes the wake pipe; false if an event is already pending.
    pub fn arm(h: *Hub, w: *Waker, mask: u32) bool {
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        if (w.pending & mask != 0) return false;
        w.idling = true;
        return true;
    }

    /// disarms and consumes the wake byte if notify() already wrote one.
    pub fn disarm(h: *Hub, w: *Waker) void {
        h.mu.lockUncancelable(h.io);
        defer h.mu.unlock(h.io);
        if (!w.idling) {
            var b: [1]u8 = undefined;
            _ = std.c.read(w.rd, &b, 1);
        }
        w.idling = false;
    }
};
