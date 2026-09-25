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

/// A short sleep, spelled for the platform. `std.Io` is the only thing in std
/// that sleeps now, and it wants an event loop these tests have no use for.
const nap = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    fn ms(n: u32) void {
        Sleep(n);
    }
} else struct {
    extern "c" fn usleep(usec: c_uint) c_int;
    fn ms(n: u32) void {
        _ = usleep(n * 1000);
    }
};

fn sleepMs(ms: u32) void {
    nap.ms(ms);
}

/// How long one turn of a polling loop waits, and how many turns it gets.
///
/// Ten milliseconds at a time rather than one: neither a sleep nor
/// `waitReadable` can return faster than the platform's timer resolution, about
/// fifteen milliseconds on Windows, so a loop asking for one millisecond two
/// thousand times spends a minute and a half there against two seconds on a
/// system that honours it. Asking for ten keeps the two within half again of
/// each other.
const POLL_MS: u32 = 10;
/// Turns, giving every wait below the same couple of seconds.
const POLL_TURNS: usize = 200;

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
        // `more` is a pager: it reads its input and pages it, and under a
        // pseudo-console it does not hand back what was written to it, so every
        // test that writes and waits for the text failed. `findstr .` matches
        // any line with a character in it and writes it out verbatim -- no line
        // numbers, so the text still starts at the first cell of the first row,
        // which is what some of these check.
        &[_][*:0]const u8{"cmd.exe /c findstr ."};
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
    for (0..POLL_TURNS) |_| {
        const n = pty.read(seen[len..]) catch break;
        if (n == 0) {
            if (!pty.waitReadable(POLL_MS)) _ = pty.poll();
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
    for (0..POLL_TURNS) |_| {
        const n = pty.read(buf[len..]) catch break;
        if (n == 0) {
            _ = pty.waitReadable(POLL_MS);
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
    for (0..POLL_TURNS) |_| {
        if (pty.poll()) {
            exited = true;
            break;
        }
        _ = pty.waitReadable(POLL_MS);
    }
    try testing.expect(exited);
}

test "waitReadable reports data and times out when there is none" {
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer pty.close();

    // A console host paints its screen the moment it starts, so on Windows
    // there is something to read before anything has been typed. Drain that
    // first: what this asserts is that a *quiet* pty times out, and "quiet"
    // has to mean the same thing on both platforms.
    var scratch: [4096]u8 = undefined;
    var quiet: usize = 0;
    for (0..POLL_TURNS) |_| {
        const n = pty.read(&scratch) catch break;
        if (n > 0) {
            quiet = 0;
            continue;
        }
        quiet += 1;
        if (quiet >= 3) break;
        _ = pty.waitReadable(POLL_MS);
    }

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

    for (0..POLL_TURNS) |_| {
        try testing.expect(!pty.poll());
        try testing.expect(!pty.exited);
        _ = pty.waitReadable(POLL_MS);
    }
    // Still talking, which is the real proof it was alive all along.
    try pty.write("alive\n");
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    for (0..POLL_TURNS) |_| {
        const n = pty.read(buf[len..]) catch break;
        if (n == 0) {
            _ = pty.waitReadable(POLL_MS);
            continue;
        }
        len += n;
        if (std.mem.indexOf(u8, buf[0..len], "alive") != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "alive") != null);
}

test "spawnShell starts the user's shell and it responds" {
    var pty = try Pty.spawnShell(80, 24);
    defer pty.close();

    // A shell prints a prompt, so any output proves it reached the terminal;
    // `exit` then proves it is reading and can be reaped.
    try pty.write("exit\r");

    // Drain until the shell stops talking, however the platform words that.
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    for (0..POLL_TURNS) |_| {
        const n = pty.read(&buf) catch break;
        total += n;
        if (n == 0) {
            if (pty.poll()) break;
            _ = pty.waitReadable(POLL_MS);
        }
    }
    try testing.expect(total > 0);

    // Then wait for it to become reapable, as a step of its own.
    //
    // The two are not the same event and do not arrive in a fixed order: macOS
    // reports the master's hang-up as an error on the read, Linux as end of
    // file, and either can land before the child has a status to collect. The
    // drain above used to carry this assertion, so whichever of the two came
    // first ended the search -- on Linux the hang-up did, `waitReadable`
    // stopped waiting once the master was hung up, and the loop spent its four
    // thousand turns in microseconds before the shell was reapable at all.
    var exited = false;
    // A couple of seconds of ceiling, reached in a millisecond or two in
    // practice. Waiting costs nothing when the answer arrives at once.
    for (0..POLL_TURNS) |_| {
        if (pty.poll()) {
            exited = true;
            break;
        }
        sleepMs(POLL_MS);
    }
    try testing.expect(exited);
}
