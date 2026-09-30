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

/// Says what the pty actually produced when the text looked for is not in it.
///
/// A failed `indexOf` says nothing about whether nothing arrived, or a screen
/// repaint arrived and the payload did not -- and those want opposite fixes. A
/// pseudo-console makes the difference matter: it renders rather than passes
/// bytes through, and announces itself with a full repaint before the child has
/// said anything at all.
fn reportIfMissing(wanted: []const u8, got: []const u8) void {
    if (std.mem.indexOf(u8, got, wanted) != null) return;
    std.debug.print(
        "\n  looked for '{s}' and did not find it in the {d} bytes the pty gave:\n  {f}\n",
        .{ wanted, got.len, std.zig.fmtString(got) },
    );
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

/// Windows-only step markers.
///
/// The Windows suite wedges in CI with no sign of where: the test runner prints
/// a test's name before running it, so a hang in the body and a hang in a
/// `defer` look the same from outside, and the calls this file makes into
/// ConPTY are the ones that can wait for ever. CI prints the last line a
/// wedged suite managed to write, so a marker before each of those calls names
/// the one that never returned.
///
/// Off everywhere else, so no other platform's output changes.
const trace_steps = builtin.os.tag == .windows;

fn step(comptime name: []const u8) void {
    if (!trace_steps) return;
    std.debug.print("      [step] " ++ name ++ "\n", .{});
}

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

/// A command that stays alive briefly without reading its input, so a test can
/// fill the pty's input buffer and watch the write side drop rather than block.
fn sleepArgv() []const [*:0]const u8 {
    return if (posix_only)
        &[_][*:0]const u8{ "/bin/sh", "-c", "sleep 3" }
    else
        &[_][*:0]const u8{"cmd.exe /c ping -n 4 127.0.0.1 >nul"};
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

    var seen: [64 * 1024]u8 = undefined;
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
    reportIfMissing("ztabb", seen[0..len]);
    try testing.expect(std.mem.indexOf(u8, seen[0..len], "ztabb") != null);
}

test "write reaches the child and comes back through the echo" {
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer pty.close();

    try pty.write("hello\n");
    var buf: [64 * 1024]u8 = undefined;
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
    reportIfMissing("hello", buf[0..len]);
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
    // Pace with a sleep, not `waitReadable`: a pseudo-console always has its
    // handshake pending in the pipe, so `waitReadable` returns at once and the
    // loop can finish before the child has had time to start, let alone exit.
    for (0..POLL_TURNS) |_| {
        if (pty.poll()) {
            exited = true;
            break;
        }
        sleepMs(POLL_MS);
    }
    try testing.expect(exited);
}

/// Reads until `want` shows up or the turns run out. Windows echoes through a
/// console host, so what comes back arrives in pieces and carries escape
/// sequences around it; only the presence of the text is asserted.
fn awaitText(pty: *Pty, want: []const u8) bool {
    // A console host repaints a whole screen, so this has to hold more than the
    // echoed line itself. What does not fit is dropped from the front, which is
    // harmless: the text being looked for is far shorter than one read.
    var seen: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    for (0..POLL_TURNS) |_| {
        const n = pty.read(seen[len..]) catch return false;
        if (n > 0) {
            len += n;
            if (std.mem.indexOf(u8, seen[0..len], want) != null) return true;
            if (seen.len - len < 4096) {
                // Keep the tail, so text split across two reads still matches.
                const keep = want.len;
                std.mem.copyForwards(u8, seen[0..keep], seen[len - keep ..][0..keep]);
                len = keep;
            }
            continue;
        }
        _ = pty.waitReadable(POLL_MS);
    }
    return false;
}

test "waitReadable reports data and times out when there is none" {
    step("spawn");
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer {
        step("close");
        pty.close();
        step("closed");
    }
    step("spawned");

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

    step("assert a quiet pty times out");
    try testing.expect(!pty.waitReadable(20));

    step("write");
    try pty.write("ping\n");
    step("wait for the echo");
    const answered = pty.waitReadable(2000);
    if (!answered) {
        std.debug.print(
            "\n  wrote to the child and nothing came back in two seconds:" ++
                " either it is not attached to this pty, or it does not echo\n",
            .{},
        );
    }
    try testing.expect(answered);

    step("read the echo");
    var buf: [64]u8 = undefined;
    const n = try pty.read(&buf);
    try testing.expect(n > 0);
    step("body done");
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
    var buf: [64 * 1024]u8 = undefined;
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
    reportIfMissing("alive", buf[0..len]);
    try testing.expect(std.mem.indexOf(u8, buf[0..len], "alive") != null);
}

test "write does not block a child that has stopped reading" {
    step("spawn a child that does not read");
    var pty = try Pty.spawn(sleepArgv(), &.{}, 80, 24);
    defer {
        step("close");
        pty.close();
        step("closed");
    }

    // Far more than any input buffer holds. A child that never reads fills the
    // pipe, and a blocking write would wedge this test for ever; the pty must
    // drop the overflow and return instead.
    var junk = [_]u8{'x'} ** (256 * 1024);
    step("write more than the pipe holds");
    try pty.write(&junk);
    step("write returned");
}

test "two ptys at once each get their own input pipe" {
    // On Windows the input channel is a named pipe, created with
    // FILE_FLAG_FIRST_PIPE_INSTANCE so that a name collision fails loudly
    // rather than quietly wiring two panes to one console. Every pane in a
    // session is a pty of its own, so the names have to differ.
    var a = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer a.close();
    var b = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer b.close();

    step("write to both");
    try a.write("first\n");
    try b.write("second\n");

    // Each has to come back with its own text, not the other's and not both.
    step("read both back");
    try testing.expect(awaitText(&a, "first"));
    try testing.expect(awaitText(&b, "second"));
}

test "a second close does not reach a pty opened since the first" {
    // The test below proves a second close does not crash. It cannot prove the
    // dangerous part, because nothing has taken the closed descriptor back.
    // Descriptors are handed out lowest free first, so the pty opened here very
    // likely sits on the number the first one gave up -- and a close that ran
    // twice would shut this one instead of nothing at all.
    var first = try Pty.spawn(catArgv(), &.{}, 80, 24);
    first.close();

    var second = try Pty.spawn(catArgv(), &.{}, 80, 24);
    defer second.close();

    step("close the first pty a second time");
    first.close();

    // The second pty has to be untouched: still writable, still answering.
    step("prove the second still works");
    try second.write("alive\n");
    try testing.expect(awaitText(&second, "alive"));
}

test "writeSome reports what it took and never waits for room" {
    var pty = try Pty.spawn(sleepArgv(), &.{}, 80, 24);
    defer pty.close();

    // This child never reads its input. What the two platforms then do differs,
    // and neither may hang: a pty master on macOS accepts the bytes and the
    // line discipline discards what will not fit, while ConPTY's pipe fills and
    // the write is taken back once WRITE_MS is up. Either way the call has to
    // return, promptly and with a count -- a caller that must not lose bytes
    // retries and drains between tries, which it can only do if this comes back.
    var junk = [_]u8{'x'} ** (64 * 1024);
    var total: usize = 0;
    step("offer more than the pipe holds, repeatedly");
    for (0..64) |_| {
        const n = pty.writeSome(&junk) catch break;
        try testing.expect(n <= junk.len);
        total += n;
    }
    step("writeSome returned every time");

    // Something went, and this test reaching its end is the proof that no
    // attempt waited for a reader that was never going to arrive.
    try testing.expect(total > 0);
}

test "closing a pty twice is harmless" {
    step("spawn");
    var pty = try Pty.spawn(catArgv(), &.{}, 80, 24);
    step("first close");
    pty.close();
    step("second close");
    // The second close must be a no-op, not a double free of the pty's
    // internals.
    pty.close();
    step("closed twice");
}

test "spawnShell starts the user's shell and it responds" {
    step("spawn the user's shell");
    var pty = try Pty.spawnShell(80, 24);
    defer {
        step("close");
        pty.close();
        step("closed");
    }

    // A shell prints a prompt, so any output proves it reached the terminal;
    // `exit` then proves it is reading and can be reaped.
    step("ask it to exit");
    try pty.write("exit\r");
    step("drain what it said");

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
    step("assert it said something");
    try testing.expect(total > 0);
    step("wait for it to be reapable");

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
    step("assert it was reapable");
    try testing.expect(exited);
    step("body done");
}
