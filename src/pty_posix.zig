//! The POSIX pseudo-terminal: `openpty`, then a forked child that takes the
//! slave side as its controlling terminal.
//!
//! Selected by `pty.zig` on every platform but Windows, which has no such
//! thing and uses ConPTY instead.
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
    extern "c" var environ: [*:null]?[*:0]const u8;
};

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};
const POLLIN: c_short = 0x0001;

// Taken from the platform's own definitions rather than written out: the BSD
// and Linux values differ (EAGAIN is 35 on one and 11 on the other, O_NONBLOCK
// 0x4 against 0x800), and hardcoding either set silently misreads the other.
const F_GETFL: c_int = posix.F.GETFL;
const F_SETFL: c_int = posix.F.SETFL;
const O_NONBLOCK: c_int = @bitCast(@as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
const SIGHUP: c_int = @intFromEnum(posix.SIG.HUP);
const SIGKILL: c_int = @intFromEnum(posix.SIG.KILL);
const WNOHANG: c_int = 1;
const F_OK: c_int = 0;

fn errno() posix.E {
    return @enumFromInt(std.c._errno().*);
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
    /// The size the child was last told about.
    cols: u16,
    rows: u16,

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

        return .{ .master = master, .child = pid, .cols = cols, .rows = rows };
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
                if (e == .INTR) continue;
                if (e == .AGAIN) {
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
        // A window size the child already has is not worth a SIGWINCH: the
        // shell repaints its prompt on every one, and the geometry is
        // recomputed on events that change nothing about it.
        if (cols == self.cols and rows == self.rows) return;
        self.cols = cols;
        self.rows = rows;
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
        return self.reap(0);
    }

    /// Hangs the child up and reaps it, without ever blocking indefinitely.
    ///
    /// Closing the master is the hang-up a real terminal performs, and a shell
    /// exits on it. One that does not -- a program holding SIGHUP, or a shell
    /// waiting on a foreground job of its own -- must not be able to wedge the
    /// window. An unbounded `waitpid` here did exactly that: the app froze on
    /// the key that closes a pane, and again on the way out, which is what the
    /// sampled main thread was sitting in.
    ///
    /// So the wait is bounded and escalates, the way the ConPTY side already
    /// did: ask, then insist.
    pub fn close(self: *Pty) void {
        _ = libc.close(self.master);
        if (self.exited) return;

        self.signal(SIGHUP);
        if (self.reap(GRACE_MS)) return;
        self.signal(SIGKILL);
        // SIGKILL cannot be held off, so this is a formality -- but a bounded
        // one, because a process stopped in the kernel still takes a moment.
        if (self.reap(GRACE_MS)) return;
        // Out of patience. The child is on its own; leaving it unreaped costs
        // a zombie until ztabb exits, which is far cheaper than never
        // returning from here.
        self.exited = true;
    }

    /// How long a closing pane gives its shell before insisting.
    const GRACE_MS: u32 = 200;
    const POLL_MS: u32 = 2;

    /// Signals the child's whole process group, falling back to the child
    /// alone.
    ///
    /// The group matters: the process holding the terminal is usually the
    /// shell's foreground job rather than the shell, and it is a grandchild of
    /// ztabb's, not something we can name. The child leads a group of its own,
    /// having been made a session leader when it was spawned.
    fn signal(self: *Pty, sig: c_int) void {
        if (libc.kill(-self.child, sig) == 0) return;
        _ = libc.kill(self.child, sig);
    }

    /// Reaps the child, waiting up to `ms` for it. Returns whether it is gone.
    fn reap(self: *Pty, ms: u32) bool {
        var waited: u32 = 0;
        while (true) {
            var status: c_int = 0;
            const got = libc.waitpid(self.child, &status, WNOHANG);
            if (got == self.child) {
                self.exited = true;
                self.exit_status = @bitCast(status);
                return true;
            }
            if (got < 0) {
                if (errno() == .INTR) continue;
                // ECHILD: somebody already reaped it, which is just as good.
                self.exited = true;
                return true;
            }
            if (waited >= ms) return false;
            _ = libc.usleep(POLL_MS * 1000);
            waited += POLL_MS;
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

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test "nameOf splits at the first equals sign" {
    try testing.expectEqualStrings("TERM", nameOf("TERM=xterm-256color"));
    try testing.expectEqualStrings("PATH", nameOf("PATH=/usr/bin:/bin"));
    try testing.expectEqualStrings("BARE", nameOf("BARE"));
    try testing.expectEqualStrings("", nameOf("=leading"));
}

test "buildEnv puts overrides first and drops the inherited duplicate" {
    const extra = [_][*:0]const u8{"TERM=ztabb-test"};
    const env = buildEnv(&extra);
    try testing.expectEqualStrings("TERM=ztabb-test", std.mem.span(env.entries[0].?));

    var seen_term: usize = 0;
    var i: usize = 0;
    while (env.entries[i]) |e| : (i += 1) {
        if (std.mem.eql(u8, "TERM", nameOf(std.mem.span(e)))) seen_term += 1;
    }
    try testing.expectEqual(@as(usize, 1), seen_term);
    try testing.expect(i < Env.MAX_ENV);
}
