//! A pseudo-terminal with a child process attached to its slave side.
//!
//! `Pty.spawn` forks, makes the child a session leader owning the slave as its
//! controlling terminal, and executes the requested program. The parent keeps
//! the master in non-blocking mode so the render loop never stalls on a read.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// `TIOCSWINSZ` is an `_IOW('t', 103, struct winsize)` ioctl whose encoding
/// differs between the BSDs (macOS included) and Linux.
const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5414,
    else => 0x80087467,
};
const TIOCSCTTY: c_ulong = switch (builtin.os.tag) {
    .linux => 0x540E,
    else => 0x20007461,
};

// The pty layer is inherently POSIX, and `std.posix` in 0.16 no longer wraps
// most of what it needs, so the calls are declared against libc directly. They
// live in a namespace so names like `close` and `write` do not collide with
// `Pty`'s own methods.
const libc = struct {
    extern "c" fn openpty(
        amaster: *c_int,
        aslave: *c_int,
        name: ?[*:0]u8,
        tio: ?*const posix.termios,
        ws: ?*const posix.winsize,
    ) c_int;
    extern "c" fn login_tty(fd: c_int) c_int;
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn waitpid(pid: posix.pid_t, status: ?*c_int, options: c_int) posix.pid_t;
    extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn setsid() posix.pid_t;
    extern "c" fn dup2(old: c_int, new: c_int) c_int;
    extern "c" fn kill(pid: posix.pid_t, sig: c_int) c_int;
    extern "c" fn usleep(usec: c_uint) c_int;
    extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout: c_int) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
    extern "c" fn __error() *c_int;
    extern "c" var environ: [*:null]?[*:0]const u8;
};

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};
const POLLIN: c_short = 0x0001;

const EAGAIN: c_int = 35;
const EINTR: c_int = 4;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x0004;
const SIGHUP: c_int = 1;
const WNOHANG: c_int = 1;
const F_OK: c_int = 0;

fn errno() c_int {
    return libc.__error().*;
}

pub const SpawnError = error{
    OpenPtyFailed,
    ForkFailed,
};

pub const Pty = struct {
    master: posix.fd_t,
    child: posix.pid_t,
    /// Set once the child has been reaped; the tab may then be closed.
    exited: bool = false,
    exit_status: u32 = 0,

    /// Starts `argv[0]` on the slave side of a fresh pty sized `cols` x `rows`.
    ///
    /// `argv` and `extra_env` entries must outlive the call but are not
    /// retained. Caller owns the result and must `close` it.
    pub fn spawn(
        argv: []const [*:0]const u8,
        extra_env: []const [*:0]const u8,
        cols: u16,
        rows: u16,
    ) SpawnError!Pty {
        std.debug.assert(argv.len > 0);

        var master: c_int = -1;
        var slave: c_int = -1;
        const ws = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (libc.openpty(&master, &slave, null, null, &ws) < 0) return error.OpenPtyFailed;
        errdefer {
            _ = libc.close(master);
            _ = libc.close(slave);
        }

        var env = buildEnv(extra_env);

        const pid = std.c.fork();
        if (pid < 0) return error.ForkFailed;

        if (pid == 0) {
            // Child: become a session leader owning the slave as its controlling
            // terminal, then hand the fds over as stdin/stdout/stderr.
            _ = libc.close(master);
            childExec(slave, argv, &env);
            // childExec only returns when exec fails; the parent sees the pty
            // close, which it reports as the tab's process exiting.
            libc._exit(127);
        }

        _ = libc.close(slave);
        // Non-blocking: the UI thread polls every tab each frame and must never
        // block on a shell that has nothing to say.
        const flags = libc.fcntl(master, F_GETFL, @as(c_int, 0));
        if (flags >= 0) _ = libc.fcntl(master, F_SETFL, flags | O_NONBLOCK);

        return .{ .master = master, .child = pid };
    }

    /// Convenience wrapper: runs the user's login shell.
    pub fn spawnShell(cols: u16, rows: u16) SpawnError!Pty {
        const shell = defaultShell();
        // `-l` so the shell sources the user's profile and zsh startup files.
        const argv = [_][*:0]const u8{ shell, "-l" };
        const env = [_][*:0]const u8{ "TERM=xterm-256color", "COLORTERM=truecolor" };
        return spawn(&argv, &env, cols, rows);
    }

    /// Reads whatever the child has produced. Returns 0 when nothing is ready.
    /// Returns `error.Closed` once the child's side of the pty is gone.
    pub fn read(self: *Pty, buf: []u8) error{Closed}!usize {
        return posix.read(self.master, buf) catch |err| switch (err) {
            error.WouldBlock => 0,
            // macOS reports a hung-up pty master as EIO, Linux as EOF.
            error.InputOutput => error.Closed,
            else => error.Closed,
        };
    }

    /// Writes the whole slice, retrying on short writes and on a full tty
    /// buffer. Bytes that cannot be delivered are dropped rather than blocking
    /// the UI, which matches what a real terminal does when the reader stalls.
    pub fn write(self: *Pty, buf: []const u8) error{Closed}!void {
        var off: usize = 0;
        var stalls: u8 = 0;
        while (off < buf.len) {
            const n = libc.write(self.master, buf[off..].ptr, buf.len - off);
            if (n < 0) {
                const e = errno();
                if (e == EINTR) continue;
                if (e == EAGAIN) {
                    stalls += 1;
                    if (stalls > 16) return;
                    _ = libc.usleep(1000);
                    continue;
                }
                return error.Closed;
            }
            if (n == 0) return error.Closed;
            off += @intCast(n);
        }
    }

    /// Blocks until the child has something to say, or `timeout_ms` passes.
    ///
    /// Used right after a keystroke: a shell echoes within a millisecond or
    /// two, and waiting for it means the character appears in the same frame
    /// as the key press rather than the next one.
    pub fn waitReadable(self: *Pty, timeout_ms: i32) bool {
        var fds = [_]PollFd{.{ .fd = self.master, .events = POLLIN, .revents = 0 }};
        return libc.poll(&fds, 1, timeout_ms) > 0;
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        const ws = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = libc.ioctl(self.master, TIOCSWINSZ, &ws);
    }

    /// Reaps the child without blocking. Sets `exited` when it is gone, so a
    /// finished shell does not linger as a zombie for the life of the app.
    pub fn poll(self: *Pty) bool {
        if (self.exited) return true;
        var status: c_int = 0;
        if (libc.waitpid(self.child, &status, WNOHANG) == self.child) {
            self.exited = true;
            self.exit_status = @bitCast(status);
        }
        return self.exited;
    }

    pub fn close(self: *Pty) void {
        _ = libc.close(self.master);
        if (!self.exited) {
            // SIGHUP first, as a terminal would; the shell exits on its own.
            _ = libc.kill(self.child, SIGHUP);
            var status: c_int = 0;
            _ = libc.waitpid(self.child, &status, 0);
            self.exited = true;
        }
    }
};

/// A copy of the parent environment with `extra` entries overriding any
/// same-named variable. The strings live in a fixed buffer owned by the caller
/// because the child may not allocate between `fork` and `exec`.
const Env = struct {
    entries: [MAX_ENV:null]?[*:0]const u8,

    const MAX_ENV = 512;
};

fn buildEnv(extra: []const [*:0]const u8) Env {
    var env: Env = .{ .entries = [_:null]?[*:0]const u8{null} ** Env.MAX_ENV };
    var n: usize = 0;

    for (extra) |e| {
        if (n == Env.MAX_ENV) break;
        env.entries[n] = e;
        n += 1;
    }

    const it = libc.environ;
    var i: usize = 0;
    outer: while (it[i]) |entry| : (i += 1) {
        if (n == Env.MAX_ENV) break;
        const name = nameOf(std.mem.span(entry));
        for (extra) |e| {
            if (std.mem.eql(u8, name, nameOf(std.mem.span(e)))) continue :outer;
        }
        env.entries[n] = entry;
        n += 1;
    }
    return env;
}

fn nameOf(entry: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return entry;
    return entry[0..eq];
}

/// Runs in the forked child. Only async-signal-safe calls are allowed here.
fn childExec(slave: c_int, argv: []const [*:0]const u8, env: *Env) void {
    // login_tty does setsid + TIOCSCTTY + dup2 of 0/1/2 in one step.
    if (libc.login_tty(slave) < 0) {
        _ = libc.setsid();
        _ = libc.ioctl(slave, TIOCSCTTY, @as(c_int, 0));
        _ = libc.dup2(slave, 0);
        _ = libc.dup2(slave, 1);
        _ = libc.dup2(slave, 2);
        if (slave > 2) _ = libc.close(slave);
    }

    var cargv: [64:null]?[*:0]const u8 = [_:null]?[*:0]const u8{null} ** 64;
    const count = @min(argv.len, cargv.len);
    for (argv[0..count], 0..) |a, i| cargv[i] = a;

    // execvp searches $PATH; the child's environment is installed first so the
    // new program sees TERM and friends.
    libc.environ = @ptrCast(&env.entries);
    _ = libc.execvp(argv[0], &cargv);
}

/// `$SHELL`, falling back to zsh (the macOS default) and then to sh.
pub fn defaultShell() [*:0]const u8 {
    if (std.c.getenv("SHELL")) |s| {
        if (s[0] != 0) return s;
    }
    if (fileExists("/bin/zsh")) return "/bin/zsh";
    return "/bin/sh";
}

fn fileExists(path: [*:0]const u8) bool {
    return libc.access(path, F_OK) == 0;
}

test "default shell is an absolute path" {
    const shell = std.mem.span(defaultShell());
    try std.testing.expect(shell.len > 0);
    try std.testing.expectEqual(@as(u8, '/'), shell[0]);
}

test "nameOf splits at the first equals sign" {
    try std.testing.expectEqualStrings("TERM", nameOf("TERM=xterm-256color"));
    try std.testing.expectEqualStrings("PATH", nameOf("PATH=/usr/bin:/bin"));
    try std.testing.expectEqualStrings("BARE", nameOf("BARE"));
    try std.testing.expectEqualStrings("", nameOf("=leading"));
}

test "buildEnv puts overrides first and drops the inherited duplicate" {
    const extra = [_][*:0]const u8{"TERM=ztabb-test"};
    const env = buildEnv(&extra);
    try std.testing.expectEqualStrings("TERM=ztabb-test", std.mem.span(env.entries[0].?));

    var seen_term: usize = 0;
    var i: usize = 0;
    while (env.entries[i]) |e| : (i += 1) {
        if (std.mem.eql(u8, "TERM", nameOf(std.mem.span(e)))) seen_term += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen_term);
    try std.testing.expect(i < Env.MAX_ENV);
}

test "spawn runs a command and streams its output" {
    const argv = [_][*:0]const u8{ "/bin/echo", "ztabb" };
    var pty = try Pty.spawn(&argv, &.{}, 80, 24);
    defer pty.close();

    var seen: [256]u8 = undefined;
    var len: usize = 0;
    // echo exits immediately, so read until the master reports hang-up.
    for (0..2000) |_| {
        const n = pty.read(seen[len..]) catch break;
        if (n == 0) {
            _ = libc.usleep(1000);
            continue;
        }
        len += n;
        if (len == seen.len) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, seen[0..len], "ztabb") != null);
}

test "write reaches the child and comes back through the echo" {
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    var pty = try Pty.spawn(&argv, &.{}, 80, 24);
    defer pty.close();

    try pty.write("hello\n");
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (0..2000) |_| {
        const n = pty.read(buf[len..]) catch break;
        if (n == 0) {
            _ = libc.usleep(1000);
            continue;
        }
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "hello") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "hello") != null);
}

test "poll reports a finished child" {
    const argv = [_][*:0]const u8{"/usr/bin/true"};
    var pty = try Pty.spawn(&argv, &.{}, 80, 24);
    defer pty.close();

    var exited = false;
    for (0..2000) |_| {
        if (pty.poll()) {
            exited = true;
            break;
        }
        _ = libc.usleep(1000);
    }
    try std.testing.expect(exited);
}

test "spawnShell starts the user's login shell and it responds" {
    var pty = try Pty.spawnShell(80, 24);
    defer pty.close();

    // A login shell prints a prompt, so any output proves it reached the tty.
    // `exit` then proves it is reading from the pty and can be reaped.
    try pty.write("exit\r");

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    var exited = false;
    for (0..4000) |_| {
        const n = pty.read(&buf) catch break;
        total += n;
        if (pty.poll()) {
            exited = true;
            break;
        }
        if (n == 0) _ = libc.usleep(1000);
    }
    try std.testing.expect(total > 0);
    try std.testing.expect(exited);
}

test "waitReadable reports data and times out when there is none" {
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    var pty = try Pty.spawn(&argv, &.{}, 80, 24);
    defer pty.close();

    // Nothing sent yet: the wait must return empty-handed rather than hang.
    try std.testing.expect(!pty.waitReadable(20));

    try pty.write("ping\n");
    try std.testing.expect(pty.waitReadable(2000));

    var buf: [64]u8 = undefined;
    const n = try pty.read(&buf);
    try std.testing.expect(n > 0);
}

test "resize does not fail on a live pty" {
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    var pty = try Pty.spawn(&argv, &.{}, 80, 24);
    defer pty.close();
    pty.resize(120, 40);

    // `stty size` in the child would need a shell; instead just assert the
    // ioctl left the master usable.
    try pty.write("x\n");
}
