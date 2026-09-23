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
