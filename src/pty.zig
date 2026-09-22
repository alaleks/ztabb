const std = @import("std");

const TIOCSWINSZ = 0x5414;

extern "c" fn openpty(amaster: *c_int, aslave: *c_int, name: ?*[*:0]u8, tio: ?*const std.posix.termios, ws: ?*const std.posix.winsize) c_int;
extern "c" fn write(fd: std.posix.fd_t, buf: *const anyopaque, count: usize) isize;
extern "c" fn close(fd: std.posix.fd_t) c_int;
const _write = write;
const _close = close;
extern "c" fn ioctl(fd: std.posix.fd_t, request: u32, ...) c_int;

pub const Pty = struct {
    fd: std.posix.fd_t,

    pub fn open() !Pty {
        var master: c_int = 0;
        var slave: c_int = 0;
        const r = openpty(&master, &slave, null, null, null);
        if (r < 0) return error.OpenPtyFailed;

        var tio = try std.posix.tcgetattr(master);
        tio.iflag.ICRNL = true;
        tio.oflag.ONLCR = true;
        tio.lflag.ICANON = true;
        tio.lflag.ECHO = true;
        tio.lflag.ISIG = true;
        try std.posix.tcsetattr(master, .NOW, tio);

        return Pty{ .fd = master };
    }

    pub fn read(self: *Pty, buf: []u8) !usize {
        const n = std.posix.read(self.fd, buf) catch |err| {
            if (err == error.WouldBlock) return 0;
            return err;
        };
        return n;
    }

    pub fn write(self: *Pty, buf: []const u8) !void {
        const n = _write(self.fd, buf.ptr, buf.len);
        if (n < 0) return error.WriteFailed;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) !void {
        const ws = std.posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = ioctl(self.fd, TIOCSWINSZ, &ws);
    }

    pub fn close(self: *Pty) void {
        _ = _close(self.fd);
    }
};

test "pty open and close" {
    var pty = try Pty.open();
    defer pty.close();
    try std.testing.expect(pty.fd >= 0);
}
