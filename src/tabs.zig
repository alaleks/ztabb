//! Tab list: one pty plus one terminal screen per tab.

const std = @import("std");
const pty = @import("pty");
const term = @import("term");
const ssh = @import("ssh");
const panes = @import("panes");

pub const MAX_TABS: usize = 32;
pub const MAX_LABEL: usize = 48;

pub const Kind = enum { shell, ssh };

/// One shell inside a tab. A tab starts with a single pane and gains more
/// when it is split.
pub const Pane = struct {
    pty: pty.Pty,
    terminal: term.Terminal,

    fn close(self: *Pane) void {
        self.pty.close();
        self.terminal.deinit();
    }
};

pub const Tab = struct {
    slots: [panes.MAX_PANES]?Pane = @splat(null),
    tree: panes.Tree,
    focused: u8 = 0,
    kind: Kind,
    /// Name set when the tab was opened; the OSC title overrides it for
    /// display when the program sets one.
    label: [MAX_LABEL]u8,
    label_len: usize,

    /// A tab label split into the part that carries the identity and the part
    /// that is only context. The renderer draws `name` in the foreground
    /// colour and the rest greyed, so the eye lands on the directory rather
    /// than on the path leading to it.
    pub const Label = struct {
        /// Drawn dim, before the name.
        prefix: []const u8 = "",
        /// Drawn bright: the directory, or the ssh profile.
        name: []const u8 = "",
        /// Drawn dim, after the name.
        suffix: []const u8 = "",

        pub fn len(self: Label) usize {
            return self.prefix.len + self.name.len + self.suffix.len;
        }
    };

    /// The name the tab was opened under: the ssh profile, or the shell.
    ///
    /// For an ssh tab this always wins over the window title: the remote shell
    /// sets the title to something like `user@host:~`, which buries the
    /// profile the connection was actually opened with.
    pub fn profileName(self: *const Tab) []const u8 {
        return self.label[0..self.label_len];
    }

    /// The working directory's last component, taken from the window title the
    /// shell sets. Empty when the title carries no path.
    pub fn folderName(self: *const Tab) []const u8 {
        return folderOf(self.titleSlice());
    }

    fn titleSlice(self: *const Tab) []const u8 {
        // Captured by pointer. Unwrapping the optional by value copies the
        // whole pane, terminal and all, and the title slice would point into
        // that copy -- which dies on return, leaving a slice that sometimes
        // still reads correctly and sometimes does not.
        if (self.slots[self.focused]) |*p| return p.terminal.titleSlice();
        return "";
    }

    /// The pane the keyboard is talking to.
    pub fn active(self: *Tab) *Pane {
        return &self.slots[self.focused].?;
    }

    pub fn paneCount(self: *const Tab) usize {
        return self.tree.count();
    }

    /// Whether any pane holds output the window has not drawn yet.
    ///
    /// Every pane, not only the focused one: a split left running a build is
    /// watched rather than typed into, and asking only the focused pane left
    /// its output sitting until something else happened to force a redraw.
    pub fn anyDirty(self: *const Tab) bool {
        for (&self.slots) |*slot| {
            if (slot.*) |*p| {
                if (p.terminal.dirty) return true;
            }
        }
        return false;
    }

    /// The ids of the panes this tab holds, in order.
    pub fn paneIds(self: *const Tab, out: []u8) []u8 {
        return self.tree.panes(out);
    }

    pub fn pane(self: *Tab, id: u8) ?*Pane {
        if (id >= panes.MAX_PANES) return null;
        if (self.slots[id]) |*p| return p;
        return null;
    }

    /// The terminal the tab's name and title come from: the focused one.
    pub fn terminalOf(self: *Tab) *term.Terminal {
        return &self.active().terminal;
    }

    /// What the tab bar shows.
    ///
    /// An ssh tab leads with its profile and trails the remote directory; a
    /// shell tab shows the directory it is sitting in, preceded by its parent
    /// so two tabs in sibling directories can be told apart.
    pub fn labelParts(self: *const Tab) Label {
        if (self.kind == .ssh) {
            return .{ .name = self.profileName(), .suffix = self.folderName() };
        }

        const title = self.titleSlice();
        const path = pathOf(title);
        if (path.len == 0) return .{ .name = self.profileName() };

        const leaf = folderOf(title);
        if (leaf.len == 0 or leaf.len >= path.len) return .{ .name = path };
        // Everything up to and including the slash before the leaf.
        return .{ .prefix = path[0 .. path.len - leaf.len], .name = leaf };
    }

    /// The label as one string, for the window title, which has no colours to
    /// separate the path from the directory.
    pub fn displayName(self: *const Tab, buf: []u8) []const u8 {
        const parts = self.labelParts();
        var n: usize = 0;
        for ([_][]const u8{ parts.prefix, parts.name }) |part| {
            const room = @min(buf.len - n, part.len);
            @memcpy(buf[n..][0..room], part[0..room]);
            n += room;
        }
        if (parts.suffix.len > 0 and n < buf.len) {
            buf[n] = ' ';
            n += 1;
            const room = @min(buf.len - n, parts.suffix.len);
            @memcpy(buf[n..][0..room], parts.suffix[0..room]);
            n += room;
        }
        return buf[0..n];
    }

    fn setLabel(self: *Tab, name: []const u8) void {
        const n = @min(name.len, MAX_LABEL);
        @memcpy(self.label[0..n], name[0..n]);
        self.label_len = n;
    }
};

/// The path buried in a window title such as `user@host:~/src/app`,
/// `~/src/app` or `app — zsh`, with the decoration stripped off.
pub fn pathOf(title: []const u8) []const u8 {
    var s = std.mem.trim(u8, title, " \t");
    if (s.len == 0) return "";

    // Some shells append the program name after a dash; drop that first.
    for ([_][]const u8{ " \u{2014} ", " - " }) |sep| {
        if (std.mem.indexOf(u8, s, sep)) |at| s = std.mem.trim(u8, s[0..at], " ");
    }
    // `user@host:path` -- keep the path.
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |at| s = s[at + 1 ..];
    s = std.mem.trim(u8, s, " ");
    // Trailing slashes name the same directory as the component before them.
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    return s;
}

/// The last component of that path. A title that is not a path at all
/// (`vim`, `htop`) is its own last component.
pub fn folderOf(title: []const u8) []const u8 {
    const s = pathOf(title);
    if (s.len == 0) return "";
    if (std.mem.eql(u8, s, "/")) return "/";
    const at = std.mem.lastIndexOfScalar(u8, s, '/') orelse return s;
    const base = s[at + 1 ..];
    return if (base.len > 0) base else s;
}

pub const Error = error{ TooManyTabs, InvalidIndex, NoTabs } ||
    panes.Error || pty.SpawnError || std.mem.Allocator.Error;

pub const Tabs = struct {
    gpa: std.mem.Allocator,
    items: [MAX_TABS]Tab = undefined,
    count: usize = 0,
    active_idx: usize = 0,
    scrollback_rows: u32 = term.Terminal.DEFAULT_SCROLLBACK,
    /// The tab's area in cells, kept so a split can be laid out and each
    /// pane's pty told its new size.
    area: panes.Rect = .{ .w = 80, .h = 24 },

    pub fn init(gpa: std.mem.Allocator) Tabs {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Tabs) void {
        for (self.items[0..self.count]) |*t| {
            for (&t.slots) |*slot| {
                if (slot.*) |*p| p.close();
                slot.* = null;
            }
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
            .slots = @splat(null),
            .tree = panes.Tree.single(),
            .focused = 0,
            .kind = kind,
            .label = [_]u8{0} ** MAX_LABEL,
            .label_len = 0,
        };
        self.items[self.count].slots[0] = .{ .pty = p, .terminal = t };
        self.items[self.count].setLabel(name);

        const idx = self.count;
        self.count += 1;
        self.active_idx = idx;
        return idx;
    }

    pub fn closeTab(self: *Tabs, idx: usize) Error!void {
        if (idx >= self.count) return error.InvalidIndex;
        for (&self.items[idx].slots) |*slot| {
            if (slot.*) |*p| p.close();
            slot.* = null;
        }

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
            for (&t.slots) |*slot| {
                const p = if (slot.*) |*v| v else continue;
                // Bound the per-frame work so one chatty pane cannot starve
                // the rest of the window.
                for (0..8) |_| {
                    const n = p.pty.read(&buf) catch {
                        _ = p.pty.poll();
                        break;
                    };
                    if (n == 0) break;
                    p.terminal.write(buf[0..n]);
                    any = true;
                    if (n < buf.len) break;
                }
            }
        }
        return any;
    }

    /// Waits briefly for the focused tab's shell to answer.
    ///
    /// Called straight after a keystroke: the echo then lands in the same
    /// frame as the key press instead of the next one, which is the whole
    /// difference between typing that feels immediate and typing that lags.
    pub fn awaitEcho(self: *Tabs, timeout_ms: i32) void {
        const tab = self.active() orelse return;
        _ = tab.active().pty.waitReadable(timeout_ms);
    }

    /// Closes tabs whose child has exited. Returns the number closed.
    /// Closes panes whose shell has exited, and any tab left with none.
    /// Returns the number of tabs closed.
    pub fn reapExited(self: *Tabs) usize {
        var closed: usize = 0;
        var i: usize = 0;
        while (i < self.count) {
            var ids: [panes.MAX_PANES]u8 = undefined;
            var emptied = false;
            for (self.items[i].paneIds(&ids)) |id| {
                const p = self.items[i].pane(id) orelse continue;
                if (!p.pty.poll()) continue;
                if (self.closePane(i, id)) |_| {} else emptied = true;
            }
            if (emptied) {
                self.closeTab(i) catch break;
                closed += 1;
            } else {
                i += 1;
            }
        }
        return closed;
    }

    /// Splits the focused pane of the active tab, starting a shell in the new
    /// one. Returns its id.
    pub fn splitActive(self: *Tabs, dir: panes.Dir) Error!u8 {
        const tab = self.active() orelse return error.NoTabs;
        const id = try tab.tree.split(tab.focused, dir, self.area);
        errdefer _ = tab.tree.close(id);

        var rects: [panes.MAX_PANES]panes.Rect = @splat(.{});
        tab.tree.layout(self.area, &rects);
        const r = rects[id];

        var p = try pty.Pty.spawnShell(
            @intCast(@min(r.w, std.math.maxInt(u16))),
            @intCast(@min(r.h, std.math.maxInt(u16))),
        );
        errdefer p.close();
        const t = try term.Terminal.init(self.gpa, r.w, r.h, self.scrollback_rows);

        tab.slots[id] = .{ .pty = p, .terminal = t };
        tab.focused = id;
        self.layoutTab(tab);
        return id;
    }

    /// Closes one pane of a tab. Returns the pane that takes focus, or null
    /// when the tab has none left.
    pub fn closePane(self: *Tabs, tab_idx: usize, id: u8) ?u8 {
        const tab = &self.items[tab_idx];
        if (tab.slots[id]) |*p| p.close();
        tab.slots[id] = null;

        const survivor = tab.tree.close(id);
        if (survivor) |n| {
            tab.focused = n;
            self.layoutTab(tab);
        }
        return survivor;
    }

    /// Closes the focused pane of the active tab, and the tab with it when
    /// that was the only one.
    pub fn closeActivePane(self: *Tabs) Error!void {
        const tab = self.active() orelse return error.NoTabs;
        if (tab.paneCount() <= 1) return self.closeTab(self.active_idx);
        _ = self.closePane(self.active_idx, tab.focused);
    }

    /// Moves focus to whichever pane lies that way.
    pub fn focusPane(self: *Tabs, side: panes.Side) void {
        const tab = self.active() orelse return;
        if (tab.tree.neighbour(tab.focused, side, self.area)) |target| {
            tab.focused = target;
        }
    }

    /// Resizes every pane of a tab to the rectangle the tree gives it.
    fn layoutTab(self: *Tabs, tab: *Tab) void {
        var rects: [panes.MAX_PANES]panes.Rect = @splat(.{});
        tab.tree.layout(self.area, &rects);
        for (&tab.slots, 0..) |*slot, i| {
            const p = if (slot.*) |*v| v else continue;
            const r = rects[i];
            if (r.isEmpty()) continue;
            p.terminal.resize(r.w, r.h) catch continue;
            p.pty.resize(
                @intCast(@min(r.w, std.math.maxInt(u16))),
                @intCast(@min(r.h, std.math.maxInt(u16))),
            );
        }
    }

    pub fn resizeAll(self: *Tabs, cols: u32, rows: u32) void {
        self.area = .{ .x = 0, .y = 0, .w = cols, .h = rows };
        for (self.slice()) |*t| self.layoutTab(t);
    }
};

// -- tests -----------------------------------------------------------------

const testing = std.testing;

extern "c" fn usleep(usec: c_uint) c_int;

fn sleepMs(ms: u32) void {
    _ = usleep(ms * 1000);
}

/// A command that echoes its input, spelled for the platform. Tests use this
/// rather than a login shell so they do not depend on the developer's shell
/// configuration or its startup time.
fn echoCommand() []const [*:0]const u8 {
    return if (@import("builtin").os.tag == .windows)
        &[_][*:0]const u8{"cmd.exe /c more"}
    else
        &[_][*:0]const u8{ "/bin/cat", "-u" };
}

fn addTestTab(tabs: *Tabs, name: []const u8, cols: u32, rows: u32) !usize {
    if (tabs.count >= MAX_TABS) return error.TooManyTabs;
    var p = try pty.Pty.spawn(echoCommand(), &.{}, @intCast(cols), @intCast(rows));
    errdefer p.close();
    const t = try term.Terminal.init(tabs.gpa, cols, rows, 32);
    tabs.items[tabs.count] = .{
        .slots = @splat(null),
        .tree = panes.Tree.single(),
        .focused = 0,
        .kind = .shell,
        .label = [_]u8{0} ** MAX_LABEL,
        .label_len = 0,
    };
    tabs.items[tabs.count].slots[0] = .{ .pty = p, .terminal = t };
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
    var name_buf: [MAX_LABEL * 2]u8 = undefined;
    try testing.expectEqualStrings("c", tabs.active().?.displayName(&name_buf));
}

test "closing the active last tab moves focus left" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "a", 80, 24);
    _ = try addTestTab(&tabs, "b", 80, 24);
    try tabs.switchTo(1);
    try tabs.closeTab(1);
    try testing.expectEqual(@as(usize, 0), tabs.active_idx);
    var name_buf: [MAX_LABEL * 2]u8 = undefined;
    try testing.expectEqualStrings("a", tabs.active().?.displayName(&name_buf));
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
    var name_buf: [MAX_LABEL * 2]u8 = undefined;
    try testing.expectEqualStrings("c", tabs.active().?.displayName(&name_buf));
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
    var name_buf: [MAX_LABEL * 2]u8 = undefined;
    try testing.expectEqualStrings("zsh", tabs.active().?.displayName(&name_buf));
}

test "a shell tab shows its directory under the path leading to it" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "zsh", 80, 24);
    const tab = tabs.active().?;

    tab.active().terminal.write("\x1b]0;~/projects/ztabb\x07");
    const parts = tab.labelParts();
    // The directory is what the eye should land on; the path is context.
    try testing.expectEqualStrings("ztabb", parts.name);
    try testing.expectEqualStrings("~/projects/", parts.prefix);
    try testing.expectEqualStrings("", parts.suffix);
}

test "a tab with no title yet falls back to the shell name" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "zsh", 80, 24);
    const parts = tabs.active().?.labelParts();
    try testing.expectEqualStrings("zsh", parts.name);
    try testing.expectEqualStrings("", parts.prefix);
}

test "a title that is not a path is shown whole and bright" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "zsh", 80, 24);
    const tab = tabs.active().?;
    tab.active().terminal.write("\x1b]0;htop\x07");
    const parts = tab.labelParts();
    try testing.expectEqualStrings("htop", parts.name);
    try testing.expectEqualStrings("", parts.prefix);
}

test "an ssh tab keeps showing its profile" {
    // The remote shell sets the title to user@host:~, which used to replace
    // the profile and leave no sign of which connection the tab was.
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "prod", 80, 24);
    const tab = tabs.active().?;
    tab.kind = .ssh;
    var name_buf: [MAX_LABEL * 2]u8 = undefined;

    try testing.expectEqualStrings("prod", tab.displayName(&name_buf));
    try testing.expectEqualStrings("prod", tab.labelParts().name);

    tab.active().terminal.write("\x1b]0;deploy@prod.example.com:~/app\x07");
    try testing.expectEqualStrings("prod app", tab.displayName(&name_buf));
    // The profile stays the bright part; the remote directory trails it.
    try testing.expectEqualStrings("prod", tab.labelParts().name);
    try testing.expectEqualStrings("app", tab.labelParts().suffix);
    try testing.expectEqualStrings("prod", tab.profileName());
    try testing.expectEqualStrings("app", tab.folderName());
}

test "pathOf strips the decoration around a path" {
    try testing.expectEqualStrings("~/projects/ztabb", pathOf("~/projects/ztabb"));
    try testing.expectEqualStrings("~/srv/app", pathOf("deploy@prod:~/srv/app"));
    try testing.expectEqualStrings("~/src/ztabb", pathOf("~/src/ztabb \u{2014} zsh"));
    try testing.expectEqualStrings("~/projects/ztabb", pathOf("~/projects/ztabb/"));
    try testing.expectEqualStrings("", pathOf(""));
}

test "folderOf pulls the last component out of a window title" {
    try testing.expectEqualStrings("ztabb", folderOf("~/projects/ztabb"));
    try testing.expectEqualStrings("app", folderOf("deploy@prod:~/srv/app"));
    try testing.expectEqualStrings("ztabb", folderOf("~/projects/ztabb/"));
    try testing.expectEqualStrings("/", folderOf("/"));
    try testing.expectEqualStrings("~", folderOf("~"));
    try testing.expectEqualStrings("etc", folderOf("/etc"));
}

test "folderOf leaves a title that is not a path alone" {
    try testing.expectEqualStrings("vim", folderOf("vim"));
    try testing.expectEqualStrings("htop", folderOf("htop"));
    try testing.expectEqualStrings("", folderOf(""));
    try testing.expectEqualStrings("", folderOf("   "));
}

test "folderOf drops a trailing program name" {
    try testing.expectEqualStrings("ztabb", folderOf("~/src/ztabb \u{2014} zsh"));
    try testing.expectEqualStrings("ztabb", folderOf("~/src/ztabb - bash"));
}

test "an over-long label is truncated" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    const long = "n" ** (MAX_LABEL * 2);
    _ = try addTestTab(&tabs, long, 80, 24);
    var name_buf: [MAX_LABEL * 2]u8 = undefined;
    try testing.expectEqual(MAX_LABEL, tabs.active().?.displayName(&name_buf).len);
}

test "pty output reaches the tab's screen" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "cat", 40, 8);
    const tab = tabs.active().?;
    try tab.active().pty.write("hello\n");

    var found = false;
    for (0..2000) |_| {
        _ = tabs.pumpAll();
        if (tab.active().terminal.cellAt(0, 0).ch == 'h') {
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
    try bg.active().pty.write("background\n");

    var found = false;
    for (0..2000) |_| {
        _ = tabs.pumpAll();
        if (bg.active().terminal.cellAt(0, 0).ch == 'b') {
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

    const argv: []const [*:0]const u8 = if (@import("builtin").os.tag == .windows)
        &.{"cmd.exe /c exit"}
    else
        &.{"/usr/bin/true"};
    const p = try pty.Pty.spawn(argv, &.{}, 40, 8);
    const t = try term.Terminal.init(tabs.gpa, 40, 8, 32);
    tabs.items[1] = .{
        .slots = @splat(null),
        .tree = panes.Tree.single(),
        .focused = 0,
        .kind = .shell,
        .label = [_]u8{0} ** MAX_LABEL,
        .label_len = 0,
    };
    tabs.items[1].slots[0] = .{ .pty = p, .terminal = t };
    tabs.items[1].setLabel("exits");
    tabs.count = 2;
    tabs.active_idx = 1;

    for (0..2000) |_| {
        if (tabs.reapExited() > 0) break;
        sleepMs(1);
    }
    try testing.expectEqual(@as(usize, 1), tabs.count);
    var name_buf: [MAX_LABEL * 2]u8 = undefined;
    try testing.expectEqualStrings("stays", tabs.active().?.displayName(&name_buf));
}

test "splitting the focused pane starts a second shell beside it" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 120, 40);
    tabs.area = .{ .w = 120, .h = 40 };

    const added = tabs.splitActive(.horizontal) catch |err| {
        // No shell to spawn on this machine: the bookkeeping is what matters.
        try testing.expect(err == error.OpenPtyFailed or err == error.ForkFailed);
        return;
    };
    const tab = tabs.active().?;
    try testing.expectEqual(@as(usize, 2), tab.paneCount());
    try testing.expectEqual(added, tab.focused);

    // Both panes are narrower than the tab and the same height.
    const a = tab.pane(0).?;
    const b = tab.pane(added).?;
    try testing.expect(a.terminal.cols < 120);
    try testing.expect(b.terminal.cols < 120);
    try testing.expectEqual(a.terminal.rows, b.terminal.rows);
}

test "closing a pane hands its space back and keeps the tab" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 120, 40);
    tabs.area = .{ .w = 120, .h = 40 };
    _ = tabs.splitActive(.vertical) catch return;

    try testing.expectEqual(@as(usize, 1), tabs.count);
    try tabs.closeActivePane();
    try testing.expectEqual(@as(usize, 1), tabs.count); // the tab survives
    const tab = tabs.active().?;
    try testing.expectEqual(@as(usize, 1), tab.paneCount());
    // The survivor is back to the full height of the tab.
    try testing.expectEqual(@as(u32, 40), tab.active().terminal.rows);
}

test "closing the only pane closes the tab" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 80, 24);
    try tabs.closeActivePane();
    try testing.expectEqual(@as(usize, 0), tabs.count);
}

test "focus moves between panes by direction" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 120, 40);
    tabs.area = .{ .w = 120, .h = 40 };
    const right = tabs.splitActive(.horizontal) catch return;

    const tab = tabs.active().?;
    try testing.expectEqual(right, tab.focused);
    tabs.focusPane(.left);
    try testing.expectEqual(@as(u8, 0), tab.focused);
    tabs.focusPane(.right);
    try testing.expectEqual(right, tab.focused);
    // Nothing that way: focus stays put rather than wrapping.
    tabs.focusPane(.right);
    try testing.expectEqual(right, tab.focused);
}

test "an unfocused pane's output still marks the tab as needing a redraw" {
    // The window redraws when something changed, and it used to ask only the
    // focused pane. Output from a split left running something -- a build, a
    // log -- then sat unseen until an unrelated event forced a frame.
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 120, 40);
    tabs.area = .{ .w = 120, .h = 40 };
    const right = tabs.splitActive(.horizontal) catch return;

    const tab = tabs.active().?;
    // Focus the other pane, so the one being written to is in the background.
    tabs.focusPane(.left);
    try testing.expect(tab.focused != right);

    for (&tab.slots) |*slot| {
        if (slot.*) |*pane| pane.terminal.dirty = false;
    }
    try testing.expect(!tab.anyDirty());

    try tab.pane(right).?.pty.write("echo background\n");
    var seen = false;
    for (0..2000) |_| {
        _ = tabs.pumpAll();
        if (tab.anyDirty()) {
            seen = true;
            break;
        }
        sleepMs(1);
    }
    try testing.expect(seen);
    // And it is the background pane that is dirty, not the focused one.
    try testing.expect(tab.pane(right).?.terminal.dirty);
}

test "keys and output go to the focused pane only" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 120, 40);
    tabs.area = .{ .w = 120, .h = 40 };
    const right = tabs.splitActive(.horizontal) catch return;

    const tab = tabs.active().?;
    try tab.active().pty.write("echo pane\n");
    for (0..2000) |_| {
        _ = tabs.pumpAll();
        if (tab.pane(right).?.terminal.cellAt(0, 0).ch != ' ') break;
        sleepMs(1);
    }
    // The other pane never saw it.
    try testing.expectEqual(@as(u21, ' '), tab.pane(0).?.terminal.cellAt(0, 0).ch);
}

test "resizing the window re-lays every pane" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "one", 120, 40);
    tabs.area = .{ .w = 120, .h = 40 };
    _ = tabs.splitActive(.horizontal) catch return;

    tabs.resizeAll(200, 60);
    const tab = tabs.active().?;
    var ids: [panes.MAX_PANES]u8 = undefined;
    for (tab.paneIds(&ids)) |id| {
        const p = tab.pane(id).?;
        try testing.expectEqual(@as(u32, 60), p.terminal.rows);
        try testing.expect(p.terminal.cols < 200);
        try testing.expect(p.terminal.cols > 60);
    }
}

test "resizeAll resizes every tab, not only the focused one" {
    var tabs = Tabs.init(testing.allocator);
    defer tabs.deinit();
    _ = try addTestTab(&tabs, "a", 80, 24);
    _ = try addTestTab(&tabs, "b", 80, 24);
    tabs.resizeAll(100, 30);
    for (tabs.slice()) |*t| {
        try testing.expectEqual(@as(u32, 100), t.active().terminal.cols);
        try testing.expectEqual(@as(u32, 30), t.active().terminal.rows);
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
