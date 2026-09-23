//! A pseudo-terminal with a shell attached, whichever the platform calls it.
//!
//! POSIX systems get `openpty` and a forked child; Windows has no such thing
//! and uses ConPTY, a pseudo-console reached through a pair of pipes. The two
//! implementations present the same API, so nothing above this file has to
//! know which one it is talking to.

const std = @import("std");
const builtin = @import("builtin");

const impl = switch (builtin.os.tag) {
    .windows => @import("pty_windows.zig"),
    else => @import("pty_posix.zig"),
};

pub const Pty = impl.Pty;
pub const SpawnError = impl.SpawnError;

/// The user's shell: `$SHELL` on POSIX, `%COMSPEC%` on Windows.
pub const defaultShell = impl.defaultShell;

// -- tests -----------------------------------------------------------------

const testing = std.testing;
const posix_only = builtin.os.tag != .windows;

/// A command that prints and exits, spelled for the platform.
fn echoArgv() []const [*:0]const u8 {
    return if (posix_only)
        &[_][*:0]const u8{ "/bin/echo", "ztabb" }
    else
        &[_][*:0]const u8{"cmd.exe /c echo ztabb"};
}

/// A command that echoes its input back.
fn catArgv() []const [*:0]const u8 {
    return if (posix_only)
        &[_][*:0]const u8{ "/bin/cat", "-u" }
    else
        &[_][*:0]const u8{"cmd.exe /c more"};
}

test "the default shell is named" {
    const shell = std.mem.span(defaultShell());
    try testing.expect(shell.len > 0);
    if (posix_only) {
        // A POSIX shell is always given as an absolute path.
        try testing.expectEqual(@as(u8, '/'), shell[0]);
    }
}

test "spawn runs a command and streams its output" {
    var pty = try Pty.spawn(echoArgv(), &.{}, 80, 24);
    defer pty.close();

    var seen: [256]u8 = undefined;
    var len: usize = 0;
    for (0..2000) |_| {
        const n = pty.read(seen[len..]) catch break;
        if (n == 0) {
            if (!pty.waitReadable(2)) _ = pty.poll();
            continue;
        }
        len += n;
        if (len == seen.len) break;
        if (std.mem.indexOf(u8, seen[0..len], "ztabb") != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, seen[0..len], "ztabb") != null);
}

test "write reaches the child and comes back through the echo" {
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer pty.close();

    try pty.write("hello\n");
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (0..2000) |_| {
        const n = pty.read(buf[len..]) catch break;
        if (n == 0) {
            _ = pty.waitReadable(2);
            continue;
        }
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "hello") != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "hello") != null);
}

test "poll reports a finished child" {
    const argv = if (posix_only)
        &[_][*:0]const u8{"/usr/bin/true"}
    else
        &[_][*:0]const u8{"cmd.exe /c exit"};
    var pty = try Pty.spawn(argv, &.{}, 80, 24);
    defer pty.close();

    var exited = false;
    for (0..2000) |_| {
        if (pty.poll()) {
            exited = true;
            break;
        }
        _ = pty.waitReadable(1);
    }
    try testing.expect(exited);
}

test "waitReadable reports data and times out when there is none" {
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer pty.close();

    // Nothing sent yet: the wait must come back empty-handed rather than hang.
    try testing.expect(!pty.waitReadable(20));

    try pty.write("ping\n");
    try testing.expect(pty.waitReadable(2000));

    var buf: [64]u8 = undefined;
    const n = try pty.read(&buf);
    try testing.expect(n > 0);
}

test "resize does not fail on a live pty" {
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer pty.close();
    pty.resize(120, 40);
    try pty.write("x\n");
}

test "the pty remembers its size and ignores a repeat of it" {
    // Every window event recomputes the geometry, and most of them arrive at
    // the size the child already has. Telling it again raises SIGWINCH, which
    // makes the shell repaint its prompt -- a visible blink for nothing.
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer pty.close();
    try testing.expectEqual(@as(u16, 80), pty.cols);
    try testing.expectEqual(@as(u16, 24), pty.rows);

    pty.resize(80, 24); // no change: nothing to tell the child
    try testing.expectEqual(@as(u16, 80), pty.cols);

    pty.resize(100, 30);
    try testing.expectEqual(@as(u16, 100), pty.cols);
    try testing.expectEqual(@as(u16, 30), pty.rows);
    try pty.write("x\n");
}

test "a live child is never reported as exited" {
    // `poll` reaps with WNOHANG and now also treats "no such child" as gone,
    // so that a pane whose shell vanished is closed rather than polled for
    // ever. The other side of that has to hold: while the child is running,
    // every poll must say so, or panes would close under the user.
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer pty.close();

    for (0..500) |_| {
        try testing.expect(!pty.poll());
        try testing.expect(!pty.exited);
        _ = pty.waitReadable(1);
    }
    // Still talking, which is the real proof it was alive all along.
    try pty.write("alive\n");
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (0..2000) |_| {
        const n = pty.read(buf[len..]) catch break;
        if (n == 0) {
            _ = pty.waitReadable(2);
            continue;
        }
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "alive") != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "alive") != null);
}

test "closing a child that holds SIGHUP still returns, and still kills it" {
    // The hang-up is a request, and a program is entitled to refuse it: a
    // shell with `trap '' HUP` set, or one waiting on a foreground job that
    // ignores it. `close` used to wait for such a child forever, which froze
    // the window on the key that closes a pane and again on the way out.
    if (!posix_only) return;

    const argv = [_][*:0]const u8{ "/bin/sh", "-c", "trap '' HUP; while :; do sleep 1; done" };
    var pty = try Pty.spawn(&argv, &.{}, 80, 24);
    const child = pty.child;

    // Give the shell time to install the trap, or it dies to the default
    // action and proves nothing.
    for (0..200) |_| {
        var buf: [64]u8 = undefined;
        _ = pty.read(&buf) catch break;
        if (!pty.waitReadable(2)) {}
    }

    pty.close();
    try testing.expect(pty.exited);
    // Reaped, so the pid is no longer ours to signal. Anything else means it
    // was left running.
    try testing.expect(kill(child, 0) != 0);
}

extern "c" fn kill(pid: std.posix.pid_t, sig: c_int) c_int;

test "spawnShell starts the user's shell and it responds" {
    var pty = try Pty.spawnShell(80, 24);
    defer pty.close();

    // A shell prints a prompt, so any output proves it reached the terminal;
    // `exit` then proves it is reading and can be reaped.
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
        if (n == 0) _ = pty.waitReadable(1);
    }
    try testing.expect(total > 0);
    try testing.expect(exited);
}
