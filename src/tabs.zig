//! Tab list: one pty plus one terminal screen per tab.

const std = @import("std");
const pty = @import("pty");
const term = @import("term");
const ssh = @import("ssh");

pub const MAX_TABS: usize = 32;
pub const MAX_LABEL: usize = 48;

pub const Kind = enum { shell, ssh };

pub const Tab = struct {
    pty: pty.Pty,
    terminal: term.Terminal,
    kind: Kind,
    /// Name set when the tab was opened; the OSC title overrides it for
    /// display when the program sets one.
    label: [MAX_LABEL]u8,
    label_len: usize,

    /// What the tab bar shows: the program's own title if it set one, else the
    /// name the tab was opened with.
    pub fn displayName(self: *const Tab) []const u8 {
        const title = self.terminal.titleSlice();
        if (title.len > 0) return title[0..@min(title.len, MAX_LABEL)];
        return self.label[0..self.label_len];
    }

    fn setLabel(self: *Tab, name: []const u8) void {
        const n = @min(name.len, MAX_LABEL);
        @memcpy(self.label[0..n], name[0..n]);
        self.label_len = n;
    }
};

pub const Error = error{ TooManyTabs, InvalidIndex, NoTabs } ||
    pty.SpawnError || std.mem.Allocator.Error;

pub const Tabs = struct {
    gpa: std.mem.Allocator,
    items: [MAX_TABS]Tab = undefined,
    count: usize = 0,
    active_idx: usize = 0,
    scrollback_rows: u32 = term.Terminal.DEFAULT_SCROLLBACK,

    pub fn init(gpa: std.mem.Allocator) Tabs {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tabs) void {
        for (self.items[0..self.count]) |*t| {
            t.pty.close();
            t.terminal.deinit();
        }
        self.count = 0;
        self.active_idx = 0;
    }

    /// Opens a tab running the user's login shell.
    pub fn addShell(self: *Tabs, cols: u32, rows: u32) Error!usize {
        const shell = pty.defaultShell();
        const name = std.fs.path.basename(std.mem.span(shell));
        return self.add(.shell, name, cols, rows, null);
    }

    /// Opens a tab running `ssh <alias>`, labelled with the host alias.
    pub fn addSsh(self: *Tabs, host: ssh.Host, cols: u32, rows: u32) Error!usize {
        return self.add(.ssh, host.alias, cols, rows, host);
    }

    fn add(
        self: *Tabs,
        kind: Kind,
        name: []const u8,
        cols: u32,
        rows: u32,
        host: ?ssh.Host,
    ) Error!usize {
        if (self.count >= MAX_TABS) return error.TooManyTabs;

        const c: u16 = @intCast(@min(cols, std.math.maxInt(u16)));
        const r: u16 = @intCast(@min(rows, std.math.maxInt(u16)));

        var p = if (host) |h| blk: {
            var name_buf: [ssh.MAX_FIELD:0]u8 = undefined;
            const alias = h.command(&name_buf) catch return error.InvalidIndex;
            const argv = [_][*:0]const u8{ "ssh", alias };
            const env = [_][*:0]const u8{ "TERM=xterm-256color", "COLORTERM=truecolor" };
            break :blk try pty.Pty.spawn(&argv, &env, c, r);
        } else try pty.Pty.spawnShell(c, r);
        // The pty owns a live child process; if the screen fails to allocate it
        // must be torn down rather than left running headless.
        errdefer p.close();

        const t = try term.Terminal.init(self.gpa, cols, rows, self.scrollback_rows);

        self.items[self.count] = .{
            .pty = p,
            .terminal = t,
            .kind = kind,
            .label = [_]u8{0} ** MAX_LABEL,
            .label_len = 0,
        };
        self.items[self.count].setLabel(name);

        const idx = self.count;
        self.count += 1;
        self.active_idx = idx;
        return idx;
    }

    pub fn closeTab(self: *Tabs, idx: usize) Error!void {
        if (idx >= self.count) return error.InvalidIndex;
        self.items[idx].pty.close();
        self.items[idx].terminal.deinit();

        var i = idx;
        while (i + 1 < self.count) : (i += 1) {
            self.items[i] = self.items[i + 1];
        }
        self.count -= 1;

        if (self.count == 0) {
            self.active_idx = 0;
        } else if (self.active_idx > idx) {
            self.active_idx -= 1;
        } else if (self.active_idx == idx) {
            // Focus the tab that slid into this slot, or the new last tab.
            self.active_idx = @min(idx, self.count - 1);
        }
    }

    pub fn switchTo(self: *Tabs, idx: usize) Error!void {
        if (idx >= self.count) return error.InvalidIndex;
        self.active_idx = idx;
    }

    pub fn next(self: *Tabs) void {
        if (self.count == 0) return;
        self.active_idx = (self.active_idx + 1) % self.count;
    }

    pub fn prev(self: *Tabs) void {
        if (self.count == 0) return;
        self.active_idx = (self.active_idx + self.count - 1) % self.count;
    }

    pub fn isActive(self: *const Tabs, idx: usize) bool {
        return self.count > 0 and idx == self.active_idx;
    }

    /// Null when no tabs remain, which the caller must handle rather than
    /// dereferencing an undefined slot.
    pub fn active(self: *Tabs) ?*Tab {
        if (self.count == 0) return null;
        return &self.items[self.active_idx];
    }

    pub fn slice(self: *Tabs) []Tab {
        return self.items[0..self.count];
    }

    /// Drains every tab's pty, not just the focused one: a background shell
    /// whose output buffer fills up would otherwise block forever.
    /// Returns true if any tab produced output.
    pub fn pumpAll(self: *Tabs) bool {
        var buf: [16 * 1024]u8 = undefined;
        var any = false;
        for (self.slice()) |*t| {
            // Bound the per-frame work so one chatty tab cannot starve the UI.
            for (0..8) |_| {
                const n = t.pty.read(&buf) catch {
                    _ = t.pty.poll();
                    break;
                };
                if (n == 0) break;
                t.terminal.write(buf[0..n]);
                any = true;
                if (n < buf.len) break;
            }
        }
        return any;
    }

    /// Closes tabs whose child has exited. Returns the number closed.
    pub fn reapExited(self: *Tabs) usize {
        var closed: usize = 0;
        var i: usize = 0;
        while (i < self.count) {
            if (self.items[i].pty.poll()) {
                self.closeTab(i) catch break;
                closed += 1;
            } else {
                i += 1;
            }
        }
        return closed;
    }

    pub fn resizeAll(self: *Tabs, cols: u32, rows: u32) void {
        const c: u16 = @intCast(@min(cols, std.math.maxInt(u16)));
        const r: u16 = @intCast(@min(rows, std.math.maxInt(u16)));
        for (self.slice()) |*t| {
            t.terminal.resize(cols, rows) catch continue;
            t.pty.resize(c, r);
        }
    }
};

// -- tests -----------------------------------------------------------------

const testing = std.testing;

extern "c" fn usleep(usec: c_uint) c_int;

fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

/// Tabs that run `cat` rather than a login shell, so the tests do not depend on
/// the developer's shell configuration or startup time.
fn addTestTab(tabs: *Tabs, name: []const u8, cols: u32, rows: u32) !usize {
    if (tabs.count >= MAX_TABS) return error.TooManyTabs;
    const argv = [_][*:0]const u8{ "/bin/cat", "-u" };
    var p = try pty.Pty.spawn(&argv, &.{}, @intCast(cols), @intCast(rows));
    errdefer p.close();
    const t = try term.Terminal.init(tabs.gpa, cols, rows, 32);
    tabs.items[tabs.count] = .{
        .pty = p,
        .terminal = t,
        .kind = .shell,
        .label = [_]u8{0} ** MAX_LABEL,
        .label_len = 0,
    };
    tabs.items[tabs.count].setLabel(name);
    const idx = tabs.count;
    tabs.count += 1;
    tabs.active_idx = idx;
    return idx;
}

test "a new list has no tabs and no active tab" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    try testing.expectEqual(@as(usize, 0), tabs.count);
    try testing.expect(tabs.active() == null);
    try testing.expect(!tabs.isActive(0));
}

test "adding a tab focuses it" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    const a = try addTestTab(&tabs, "one", 80, 24);
    try testing.expectEqual(@as(usize, 0), a);
    try testing.expectEqual(@as(usize, 1), tabs.count);
    try testing.expect(tabs.isActive(0));

    const b = try addTestTab(&tabs, "two", 80, 24);
    try testing.expectEqual(@as(usize, 1), b);
    try testing.expect(tabs.isActive(1));
    try testing.expect(!tabs.isActive(0));
}

test "switchTo rejects an out-of-range index" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 80, 24);
    try testing.expectError(error.InvalidIndex, tabs.switchTo(1));
    try testing.expectError(error.InvalidIndex, tabs.switchTo(99));
    try testing.expectEqual(@as(usize, 0), tabs.active_idx);
}

test "closing the last tab leaves an empty, safe list" {
    // The old code returned a pointer into undefined memory once count hit 0.
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 80, 24);
    try tabs.closeTab(0);
    try testing.expectEqual(@as(usize, 0), tabs.count);
    try testing.expect(tabs.active() == null);
    try testing.expectEqual(@as(usize, 0), tabs.slice().len);
}

test "closing a middle tab keeps focus on the same position" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "a", 80, 24);
    _ = try addTestTab(&tabs, "b", 80, 24);
    _ = try addTestTab(&tabs, "c", 80, 24);
    try tabs.switchTo(1);
    try tabs.closeTab(1);
    try testing.expectEqual(@as(usize, 2), tabs.count);
    // "c" slid into slot 1 and keeps the focus.
    try testing.expectEqual(@as(usize, 1), tabs.active_idx);
    try testing.expectEqualStrings("c", tabs.active().?.displayName());
}

test "closing the active last tab moves focus left" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "a", 80, 24);
    _ = try addTestTab(&tabs, "b", 80, 24);
    try tabs.switchTo(1);
    try tabs.closeTab(1);
    try testing.expectEqual(@as(usize, 0), tabs.active_idx);
    try testing.expectEqualStrings("a", tabs.active().?.displayName());
}

test "closing a tab before the active one shifts the index down" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "a", 80, 24);
    _ = try addTestTab(&tabs, "b", 80, 24);
    _ = try addTestTab(&tabs, "c", 80, 24);
    try tabs.switchTo(2);
    try tabs.closeTab(0);
    try testing.expectEqual(@as(usize, 1), tabs.active_idx);
    try testing.expectEqualStrings("c", tabs.active().?.displayName());
}

test "closeTab rejects an out-of-range index" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "a", 80, 24);
    try testing.expectError(error.InvalidIndex, tabs.closeTab(5));
    try testing.expectEqual(@as(usize, 1), tabs.count);
}

test "next and prev wrap around and are safe when empty" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    tabs.next();
    tabs.prev();
    try testing.expectEqual(@as(usize, 0), tabs.active_idx);

    _ = try addTestTab(&tabs, "a", 80, 24);
    _ = try addTestTab(&tabs, "b", 80, 24);
    _ = try addTestTab(&tabs, "c", 80, 24);
    try tabs.switchTo(2);
    tabs.next();
    try testing.expectEqual(@as(usize, 0), tabs.active_idx);
    tabs.prev();
    try testing.expectEqual(@as(usize, 2), tabs.active_idx);
}

test "the tab limit is enforced" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    for (0..MAX_TABS) |_| _ = try addTestTab(&tabs, "x", 20, 5);
    try testing.expectEqual(MAX_TABS, tabs.count);
    try testing.expectError(error.TooManyTabs, addTestTab(&tabs, "x", 20, 5));
}

test "a tab is labelled by how it was opened" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "zsh", 80, 24);
    try testing.expectEqualStrings("zsh", tabs.active().?.displayName());
}

test "an OSC title overrides the tab label" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "zsh", 80, 24);
    const tab = tabs.active().?;
    tab.terminal.write("\x1b]0;~/projects/ztabb\x07");
    try testing.expectEqualStrings("~/projects/ztabb", tab.displayName());
}

test "an over-long label is truncated" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    const long = "n" ** (MAX_LABEL * 2);
    _ = try addTestTab(&tabs, long, 80, 24);
    try testing.expectEqual(MAX_LABEL, tabs.active().?.displayName().len);
}

test "pty output reaches the tab's screen" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "cat", 40, 8);
    const tab = tabs.active().?;
    try tab.pty.write("hello\n");

    var found = false;
    for (0..2000) |_| {
        _ = tabs.pumpAll();
        if (tab.terminal.cellAt(0, 0).ch == 'h') {
            found = true;
            break;
        }
        sleepMs(1);
    }
    try testing.expect(found);
}

test "pumpAll drains background tabs too" {
    // A background shell whose pty buffer fills would otherwise block.
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "bg", 40, 8);
    _ = try addTestTab(&tabs, "fg", 40, 8);
    const bg = &tabs.items[0];
    try bg.pty.write("background\n");

    var found = false;
    for (0..2000) |_| {
        _ = tabs.pumpAll();
        if (bg.terminal.cellAt(0, 0).ch == 'b') {
            found = true;
            break;
        }
        sleepMs(1);
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 1), tabs.active_idx);
}

test "reapExited closes tabs whose child is gone" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "stays", 40, 8);

    const argv = [_][*:0]const u8{"/usr/bin/true"};
    const p = try pty.Pty.spawn(&argv, &.{}, 40, 8);
    const t = try term.Terminal.init(tabs.gpa, 40, 8, 32);
    tabs.items[1] = .{
        .pty = p,
        .terminal = t,
        .kind = .shell,
        .label = [_]u8{0} ** MAX_LABEL,
        .label_len = 0,
    };
    tabs.items[1].setLabel("exits");
    tabs.count = 2;
    tabs.active_idx = 1;

    for (0..2000) |_| {
        if (tabs.reapExited() > 0) break;
        sleepMs(1);
    }
    try testing.expectEqual(@as(usize, 1), tabs.count);
    try testing.expectEqualStrings("stays", tabs.active().?.displayName());
}

test "resizeAll resizes every tab, not only the focused one" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "a", 80, 24);
    _ = try addTestTab(&tabs, "b", 80, 24);
    tabs.resizeAll(100, 30);
    for (tabs.slice()) |*t| {
        try testing.expectEqual(@as(u32, 100), t.terminal.cols);
        try testing.expectEqual(@as(u32, 30), t.terminal.rows);
    }
}

test "addSsh labels the tab with the host alias" {
    // `ssh` with an unresolvable alias exits quickly; the tab bookkeeping is
    // what this covers, not the connection itself.
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    const host = ssh.Host{ .alias = "ztabb-test-nonexistent" };
    const idx = tabs.addSsh(host, 80, 24) catch |err| {
        // No ssh binary on this machine: nothing to assert.
        try testing.expect(err == error.OpenPtyFailed or err == error.ForkFailed);
        return;
    };
    try testing.expectEqual(@as(usize, 0), idx);
    try testing.expectEqual(Kind.ssh, tabs.items[0].kind);
    try testing.expectEqualStrings("ztabb-test-nonexistent", tabs.items[0].label[0..tabs.items[0].label_len]);
}

test "no leaks when a tab is opened and closed repeatedly" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    for (0..8) |_| {
        _ = try addTestTab(&tabs, "churn", 60, 20);
        try tabs.closeTab(tabs.count - 1);
    }
    try testing.expectEqual(@as(usize, 0), tabs.count);
}
