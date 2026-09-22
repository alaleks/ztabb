const std = @import("std");
const pty = @import("pty");
const term = @import("term");

const MAX_TABS: usize = 16;

pub const Tab = struct {
    title: [64]u8,
    title_len: usize,
    pty: pty.Pty,
    terminal: term.Terminal,
    active: bool,
};

pub const Tabs = struct {
    tabs: [MAX_TABS]Tab,
    count: usize,
    active_idx: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Tabs {
        return Tabs{
            .tabs = undefined,
            .count = 0,
            .active_idx = 0,
            .gpa = gpa,
        };
    }

    pub fn addTab(self: *Tabs, cols: u32, rows: u32) !usize {
        if (self.count >= MAX_TABS) return error.TooManyTabs;
        const p = try pty.Pty.open();
        const t = try term.Terminal.init(cols, rows, self.gpa);
        self.tabs[self.count] = Tab{
            .title = [_]u8{0} ** 64,
            .title_len = 0,
            .pty = p,
            .terminal = t,
            .active = true,
        };
        const idx = self.count;
        self.count += 1;
        self.active_idx = idx;
        for (0..self.count) |i| {
            if (i != idx) self.tabs[i].active = false;
        }
        return idx;
    }

    pub fn closeTab(self: *Tabs, idx: usize) !void {
        if (idx >= self.count) return error.InvalidIndex;
        self.tabs[idx].terminal.deinit(self.gpa);
        self.tabs[idx].pty.close();
        var i = idx;
        while (i + 1 < self.count) : (i += 1) {
            self.tabs[i] = self.tabs[i + 1];
        }
        self.count -= 1;
        if (self.active_idx == idx) {
            self.active_idx = if (self.count == 0) 0 else self.count - 1;
        } else if (self.active_idx > idx) {
            self.active_idx -= 1;
        }
        for (0..self.count) |j| {
            self.tabs[j].active = (j == self.active_idx);
        }
    }

    pub fn switchTo(self: *Tabs, idx: usize) !void {
        if (idx >= self.count) return error.InvalidIndex;
        for (0..self.count) |i| {
            self.tabs[i].active = (i == idx);
        }
        self.active_idx = idx;
    }

    pub fn active(self: *const Tabs) *const Tab {
        return &self.tabs[self.active_idx];
    }

    pub fn activeMut(self: *Tabs) *Tab {
        return &self.tabs[self.active_idx];
    }

    pub fn deinit(self: *Tabs) void {
        for (0..self.count) |i| {
            self.tabs[i].terminal.deinit(self.gpa);
            self.tabs[i].pty.close();
        }
        self.count = 0;
        self.active_idx = 0;
    }
};

test "tabs add and close" {
    const gpa = std.testing.allocator;
    var tabs = Tabs.init(gpa);
    defer tabs.deinit();
    const idx = try tabs.addTab(80, 24);
    try std.testing.expect(idx == 0);
    try std.testing.expect(tabs.count == 1);
    try std.testing.expect(tabs.active_idx == 0);
    try std.testing.expect(tabs.tabs[0].active);
    try tabs.closeTab(0);
    try std.testing.expect(tabs.count == 0);
}

test "tabs multiple" {
    const gpa = std.testing.allocator;
    var tabs = Tabs.init(gpa);
    defer tabs.deinit();
    _ = try tabs.addTab(80, 24);
    _ = try tabs.addTab(80, 24);
    try std.testing.expect(tabs.count == 2);
    try std.testing.expect(tabs.active_idx == 1);
    try std.testing.expect(tabs.tabs[0].active == false);
    try std.testing.expect(tabs.tabs[1].active == true);
    try tabs.switchTo(0);
    try std.testing.expect(tabs.active_idx == 0);
    try std.testing.expect(tabs.tabs[0].active == true);
    try std.testing.expect(tabs.tabs[1].active == false);
}

test "tabs close middle" {
    const gpa = std.testing.allocator;
    var tabs = Tabs.init(gpa);
    defer tabs.deinit();
    _ = try tabs.addTab(80, 24);
    _ = try tabs.addTab(80, 24);
    _ = try tabs.addTab(80, 24);
    try std.testing.expect(tabs.count == 3);
    try tabs.closeTab(1);
    try std.testing.expect(tabs.count == 2);
    try std.testing.expect(tabs.active_idx == 1);
}

test "tabs write to terminal" {
    const gpa = std.testing.allocator;
    var tabs = Tabs.init(gpa);
    defer tabs.deinit();
    _ = try tabs.addTab(80, 24);
    const tab = tabs.activeMut();
    tab.terminal.write("Hello");
    try std.testing.expect(tab.terminal.cells[0].ch == 'H');
    try std.testing.expect(tab.terminal.cells[4].ch == 'o');
}
