//! Window, event loop and key bindings.

const std = @import("std");
const sdl = @import("sdl");
const tabs_mod = @import("tabs");
const term = @import("term");
const theme = @import("theme");
const ssh = @import("ssh");
const rnd = @import("render");
const font = @import("font");

const log = std.log.scoped(.ztabb);

/// Idle wait between frames when nothing is happening, in milliseconds. Short
/// enough to feel instant, long enough that an idle window costs ~0% CPU.
const IDLE_MS: i32 = 16;
const TOAST_MS: u64 = 2200;

pub const App = struct {
    gpa: std.mem.Allocator,
    /// Owned here so the whole app shares one I/O backend.
    io_backend: *std.Io.Threaded,
    window: *sdl.Window,
    renderer: rnd.Renderer,
    tabs: tabs_mod.Tabs,
    hosts: ssh.Config,

    theme_kind: theme.Kind,
    highlight_enabled: bool = true,
    zoom: u32 = 1,
    dpi_scale: u32 = 1,

    win_w: i32 = 0,
    win_h: i32 = 0,
    cols: u32 = 80,
    rows: u32 = 24,

    running: bool = true,
    /// Set when a key press already produced the bytes for a character, so the
    /// TEXT_INPUT event that follows must not send them a second time.
    swallow_text: bool = false,
    /// Something outside the terminal grid changed and the window must be
    /// redrawn even though no pty produced output.
    ui_dirty: bool = true,
    /// The title last handed to SDL, so it is not reset every frame.
    title_buf: [tabs_mod.MAX_LABEL + 16:0]u8 = [_:0]u8{0} ** (tabs_mod.MAX_LABEL + 16),

    picker: ?Picker = null,
    toast: ?Toast = null,

    const Picker = struct {
        selected: usize = 0,
        rows: []rnd.HostRow,
    };

    const Toast = struct {
        buf: [96]u8,
        len: usize,
        until: u64,
    };

    pub fn init(gpa: std.mem.Allocator) !App {
        const io_backend = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(io_backend);
        io_backend.* = .init(gpa, .{});
        errdefer io_backend.deinit();

        try sdl.init();
        errdefer sdl.quit();

        const window = try sdl.createWindow("ztabb", 960, 600);
        errdefer sdl.destroyWindow(window);

        const sdl_renderer = try sdl.createRenderer(window);
        errdefer sdl.destroyRenderer(sdl_renderer);
        // Without vsync the loop spins as fast as the GPU allows, which is
        // what made the first version peg a core while sitting idle.
        sdl.setVSync(sdl_renderer, true);

        var renderer = try rnd.Renderer.init(gpa, sdl_renderer);
        errdefer renderer.deinit();

        sdl.startTextInput(window);

        // A missing or unreadable ~/.ssh/config is normal, not an error.
        var hosts = ssh.load(gpa, io_backend.io()) catch ssh.Config{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .hosts = &.{},
        };
        errdefer hosts.deinit();

        var app = App{
            .gpa = gpa,
            .io_backend = io_backend,
            .window = window,
            .renderer = renderer,
            .tabs = tabs_mod.Tabs.init(gpa),
            .hosts = hosts,
            .theme_kind = theme.fromEnv(),
        };
        app.measure();
        _ = try app.tabs.addShell(app.cols, app.rows);
        return app;
    }

    pub fn deinit(self: *App) void {
        if (self.picker) |p| self.gpa.free(p.rows);
        self.tabs.deinit();
        self.hosts.deinit();
        const r = self.renderer.r;
        self.renderer.deinit();
        sdl.stopTextInput(self.window);
        sdl.destroyRenderer(r);
        sdl.destroyWindow(self.window);
        sdl.quit();
        self.io_backend.deinit();
        self.gpa.destroy(self.io_backend);
    }

    fn th(self: *const App) *const theme.Theme {
        return theme.byKind(self.theme_kind);
    }

    /// Recomputes the pixel grid and the resulting character grid.
    fn measure(self: *App) void {
        var px_w: i32 = 0;
        var px_h: i32 = 0;
        sdl.getRenderOutputSize(self.renderer.r, &px_w, &px_h);
        if (px_w <= 0 or px_h <= 0) sdl.getWindowSize(self.window, &px_w, &px_h);

        var logical_w: i32 = 0;
        var logical_h: i32 = 0;
        sdl.getWindowSize(self.window, &logical_w, &logical_h);
        // On a HiDPI display the backbuffer is larger than the window in
        // points; scaling the cell by that ratio keeps glyphs physically the
        // same size and pixel-aligned.
        self.dpi_scale = if (logical_w > 0)
            @max(1, @as(u32, @intCast(@divTrunc(px_w, logical_w))))
        else
            1;

        self.win_w = px_w;
        self.win_h = px_h;
        self.renderer.setScale(self.dpi_scale * self.zoom);

        const cw: i32 = @intCast(self.renderer.cellW());
        const ch: i32 = @intCast(self.renderer.cellH());
        const bar = ch * @as(i32, @intCast(rnd.TAB_BAR_CELLS));
        self.cols = @intCast(@max(1, @divTrunc(px_w, cw)));
        self.rows = @intCast(@max(1, @divTrunc(px_h - bar, ch)));
    }

    fn applyGeometry(self: *App) void {
        self.measure();
        self.tabs.resizeAll(self.cols, self.rows);
        self.ui_dirty = true;
    }

    pub fn run(self: *App) void {
        while (self.running) {
            const had_input = self.pumpEvents();
            const had_output = self.tabs.pumpAll();
            if (self.tabs.reapExited() > 0) {
                self.ui_dirty = true;
                if (self.tabs.count == 0) self.running = false;
            }
            self.expireToast();
            self.render();

            // Nothing moving: block briefly instead of spinning.
            if (!had_input and !had_output) {
                var event: sdl.Event = undefined;
                if (sdl.waitEventTimeout(&event, IDLE_MS)) self.handleEvent(&event);
            }
        }
    }

    fn pumpEvents(self: *App) bool {
        var event: sdl.Event = undefined;
        var any = false;
        while (sdl.pollEvent(&event)) {
            self.handleEvent(&event);
            any = true;
        }
        return any;
    }

    fn handleEvent(self: *App, event: *const sdl.Event) void {
        // Any event at all can change what the window should show.
        self.ui_dirty = true;
        switch (event.type_) {
            sdl.EVENT_QUIT => self.running = false,
            sdl.EVENT_WINDOW_RESIZED, sdl.EVENT_WINDOW_PIXEL_SIZE_CHANGED => self.applyGeometry(),
            sdl.EVENT_KEY_DOWN => self.onKeyDown(event.key),
            sdl.EVENT_TEXT_INPUT => self.onTextInput(event.text),
            sdl.EVENT_MOUSE_BUTTON_DOWN => self.onMouseDown(event.button),
            sdl.EVENT_MOUSE_WHEEL => self.onWheel(event.wheel),
            else => {},
        }
    }

    // -- input -------------------------------------------------------------

    fn onKeyDown(self: *App, ev: sdl.KeyboardEvent) void {
        const mods = ev.mod;
        const key = ev.key;

        if (self.picker != null) {
            self.pickerKey(key);
            return;
        }

        if (shortcutFor(key, mods)) |action| {
            self.run_action(action);
            self.swallow_text = true;
            return;
        }

        const tab = self.tabs.active() orelse return;
        tab.terminal.scrollToBottom();

        // Shift+PageUp/PageDown scroll the history rather than reaching the shell.
        if (mods & sdl.KMOD_SHIFT != 0) {
            const page: i32 = @intCast(self.rows);
            switch (key) {
                sdl.SDLK_PAGEUP => {
                    tab.terminal.scrollView(page);
                    return;
                },
                sdl.SDLK_PAGEDOWN => {
                    tab.terminal.scrollView(-page);
                    return;
                },
                else => {},
            }
        }

        var buf: [16]u8 = undefined;
        const bytes = encodeKey(key, mods, &buf) orelse return;
        if (bytes.len == 0) return;
        // A key that produced its own bytes must not also arrive as text.
        self.swallow_text = true;
        tab.pty.write(bytes) catch {};
    }

    fn run_action(self: *App, action: Action) void {
        switch (action) {
            .new_tab => self.newShellTab(),
            .close_tab => self.closeActiveTab(),
            .ssh_picker => self.openPicker(),
            .paste => self.paste(),
            .copy_line => if (self.tabs.active()) |tab| {
                // No selection model yet, so copy takes the current line.
                self.copyCursorLine(tab);
            },
            .prev_tab => self.tabs.prev(),
            .next_tab => self.tabs.next(),
            .select_tab => |i| self.tabs.switchTo(i) catch {},
            .zoom_in => self.setZoom(self.zoom + 1),
            .zoom_out => self.setZoom(self.zoom -| 1),
            .zoom_reset => self.setZoom(1),
            .toggle_theme => {
                self.theme_kind = theme.toggle(self.theme_kind);
                self.showToast("theme: {s}", .{self.th().name});
            },
            .toggle_highlight => {
                self.highlight_enabled = !self.highlight_enabled;
                self.showToast("highlighting: {s}", .{
                    if (self.highlight_enabled) "on" else "off",
                });
            },
        }
    }

    fn setZoom(self: *App, zoom: u32) void {
        const clamped = std.math.clamp(zoom, 1, 4);
        if (clamped == self.zoom) return;
        self.zoom = clamped;
        self.applyGeometry();
        self.showToast("zoom: {d}x", .{clamped});
    }

    fn onTextInput(self: *App, ev: sdl.TextInputEvent) void {
        if (self.swallow_text) {
            self.swallow_text = false;
            return;
        }
        if (self.picker != null) return;
        const text = ev.text orelse return;
        const tab = self.tabs.active() orelse return;
        tab.terminal.scrollToBottom();
        tab.pty.write(std.mem.span(text)) catch {};
    }

    /// Mouse positions arrive in window points; the grid is laid out in
    /// backbuffer pixels, so they have to be scaled on a HiDPI display.
    fn onMouseDown(self: *App, ev: sdl.MouseButtonEvent) void {
        if (self.picker != null) return;
        if (ev.button != sdl.BUTTON_LEFT) return;

        const scale: f32 = @floatFromInt(self.dpi_scale);
        const x = ev.x * scale;
        const y = ev.y * scale;

        const bar = self.renderer.tabBar(self.tabs.count, @floatFromInt(self.win_w));
        switch (bar.hit(x, y)) {
            .new_tab => self.newShellTab(),
            .tab => |i| self.tabs.switchTo(i) catch {},
            .close => |i| {
                self.tabs.closeTab(i) catch {};
                if (self.tabs.count == 0) self.running = false;
            },
            .none => {},
        }
    }

    fn onWheel(self: *App, ev: sdl.MouseWheelEvent) void {
        const tab = self.tabs.active() orelse return;
        // Three lines per notch, the usual convention.
        const lines: i32 = @intFromFloat(@round(ev.y * 3));
        if (lines != 0) tab.terminal.scrollView(lines);
    }

    // -- commands ----------------------------------------------------------

    fn newShellTab(self: *App) void {
        _ = self.tabs.addShell(self.cols, self.rows) catch |err| {
            self.showToast("new tab failed: {s}", .{@errorName(err)});
            return;
        };
    }

    fn closeActiveTab(self: *App) void {
        if (self.tabs.count == 0) {
            self.running = false;
            return;
        }
        self.tabs.closeTab(self.tabs.active_idx) catch {};
        if (self.tabs.count == 0) self.running = false;
    }

    fn paste(self: *App) void {
        const tab = self.tabs.active() orelse return;
        const text = sdl.getClipboardText();
        defer sdl.freeClipboardText(text);
        if (text.len == 0) return;
        tab.terminal.scrollToBottom();
        // Bracketed paste is not negotiated yet, so send the text as typed but
        // strip the newlines that would run a command the user did not submit.
        var buf: [4096]u8 = undefined;
        var n: usize = 0;
        for (text) |c| {
            if (n == buf.len) break;
            buf[n] = if (c == '\n') '\r' else c;
            n += 1;
        }
        tab.pty.write(buf[0..n]) catch {};
    }

    fn copyCursorLine(self: *App, tab: *tabs_mod.Tab) void {
        var buf: [1024:0]u8 = undefined;
        var n: usize = 0;
        const t = &tab.terminal;
        for (0..t.cols) |c| {
            const cp = t.cellAt(t.cursor_row, @intCast(c)).ch;
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
            if (n + len >= buf.len) break;
            n += std.unicode.utf8Encode(cp, buf[n..]) catch break;
        }
        while (n > 0 and buf[n - 1] == ' ') n -= 1;
        buf[n] = 0;
        sdl.setClipboardText(@ptrCast(&buf));
        self.showToast("copied {d} chars", .{n});
    }

    // -- ssh picker --------------------------------------------------------

    fn openPicker(self: *App) void {
        if (self.picker != null) return;
        var usable: [ssh.MAX_HOSTS]ssh.Host = undefined;
        const hosts = self.hosts.connectable(&usable);

        const rows = self.gpa.alloc(rnd.HostRow, hosts.len) catch return;
        for (hosts, 0..) |h, i| {
            rows[i] = .{
                .alias = h.alias,
                // The arena backing these strings outlives the picker.
                .detail = if (h.hostname.len > 0) h.hostname else h.user,
            };
        }
        self.picker = .{ .rows = rows };
        if (rows.len == 0) self.showToast("no hosts in ~/.ssh/config", .{});
    }

    fn closePicker(self: *App) void {
        const p = self.picker orelse return;
        self.gpa.free(p.rows);
        self.picker = null;
    }

    fn pickerKey(self: *App, key: u32) void {
        const p = &(self.picker.?);
        switch (key) {
            sdl.SDLK_ESCAPE => self.closePicker(),
            sdl.SDLK_UP => {
                if (p.rows.len > 0) {
                    p.selected = (p.selected + p.rows.len - 1) % p.rows.len;
                }
            },
            sdl.SDLK_DOWN => {
                if (p.rows.len > 0) p.selected = (p.selected + 1) % p.rows.len;
            },
            sdl.SDLK_RETURN => {
                const selected = p.selected;
                if (p.rows.len == 0) {
                    self.closePicker();
                    return;
                }
                var usable: [ssh.MAX_HOSTS]ssh.Host = undefined;
                const hosts = self.hosts.connectable(&usable);
                if (selected < hosts.len) {
                    const host = hosts[selected];
                    self.closePicker();
                    _ = self.tabs.addSsh(host, self.cols, self.rows) catch |err| {
                        self.showToast("ssh failed: {s}", .{@errorName(err)});
                        return;
                    };
                } else {
                    self.closePicker();
                }
            },
            else => {},
        }
        self.swallow_text = true;
    }

    // -- toast -------------------------------------------------------------

    fn showToast(self: *App, comptime fmt: []const u8, args: anytype) void {
        var t = Toast{ .buf = undefined, .len = 0, .until = sdl.ticks() + TOAST_MS };
        const written = std.fmt.bufPrint(&t.buf, fmt, args) catch t.buf[0..0];
        t.len = written.len;
        self.toast = t;
        self.ui_dirty = true;
    }

    fn expireToast(self: *App) void {
        const t = self.toast orelse return;
        if (sdl.ticks() >= t.until) {
            self.toast = null;
            self.ui_dirty = true;
        }
    }

    // -- rendering ---------------------------------------------------------

    fn render(self: *App) void {
        // Redraw only when something actually changed. With vsync on, an
        // unconditional redraw would burn a GPU frame 60 times a second for a
        // window that is simply sitting at a prompt.
        const grid_dirty = if (self.tabs.active()) |tab| tab.terminal.dirty else false;
        if (!self.ui_dirty and !grid_dirty) return;
        self.ui_dirty = false;

        const th_ = self.th();
        sdl.setRenderDrawRgb(self.renderer.r, th_.bg);
        sdl.renderClear(self.renderer.r) catch return;

        const width: f32 = @floatFromInt(self.win_w);
        const height: f32 = @floatFromInt(self.win_h);
        const bar_h: f32 = @floatFromInt(self.renderer.cellH() * rnd.TAB_BAR_CELLS);

        self.renderer.drawTabBar(&self.tabs, th_, width);

        if (self.tabs.active()) |tab| {
            var text_buf: [512]u8 = undefined;
            var color_buf: [512]u32 = undefined;
            const overlay = if (self.highlight_enabled)
                rnd.shellLineOverlay(&tab.terminal, th_, &text_buf, &color_buf)
            else
                null;
            self.renderer.drawTerminal(&tab.terminal, th_, bar_h, overlay);
            self.updateWindowTitle(tab);
            if (tab.terminal.bell) tab.terminal.bell = false;
            tab.terminal.dirty = false;
        }

        if (self.picker) |p| {
            self.renderer.drawHostPicker(p.rows, p.selected, th_, width, height);
        }
        if (self.toast) |t| {
            self.renderer.drawToast(t.buf[0..t.len], th_, width, height);
        }

        sdl.renderPresent(self.renderer.r);
    }

    fn updateWindowTitle(self: *App, tab: *tabs_mod.Tab) void {
        var buf: [tabs_mod.MAX_LABEL + 16:0]u8 = undefined;
        const name = tab.displayName();
        const written = std.fmt.bufPrintZ(&buf, "ztabb \u{2014} {s}", .{name}) catch return;
        if (std.mem.eql(u8, written, std.mem.sliceTo(&self.title_buf, 0))) return;
        @memcpy(self.title_buf[0..written.len], written);
        self.title_buf[written.len] = 0;
        sdl.setWindowTitle(self.window, &self.title_buf);
    }
};

/// Something the key press asks ztabb itself to do, as opposed to bytes bound
/// for the shell.
pub const Action = union(enum) {
    new_tab,
    close_tab,
    ssh_picker,
    paste,
    copy_line,
    prev_tab,
    next_tab,
    select_tab: usize,
    zoom_in,
    zoom_out,
    zoom_reset,
    toggle_theme,
    toggle_highlight,
};

/// The modifier that addresses ztabb rather than the shell.
///
/// Command, or Ctrl+Shift. Plain Ctrl is never enough: the shell needs Ctrl+C,
/// Ctrl+W and Ctrl+R. Both forms are accepted on every platform so there is a
/// working shortcut even where the system claims a Command combination for
/// itself (macOS binds Cmd+W to the window menu, for one).
pub fn isAppMod(mods: u16) bool {
    if (mods & sdl.KMOD_GUI != 0) return true;
    return mods & sdl.KMOD_CTRL != 0 and mods & sdl.KMOD_SHIFT != 0;
}

/// The application action a key press maps to, or null when the press belongs
/// to the shell.
/// No binding uses Shift as an extra modifier: under the Ctrl+Shift form of
/// the app modifier, Shift is already spoken for, so a Shift variant would be
/// unreachable there. Every action gets its own key instead.
pub fn shortcutFor(key: u32, mods: u16) ?Action {
    if (!isAppMod(mods)) return null;

    return switch (key) {
        sdl.SDLK_T, sdl.SDLK_N => .new_tab,
        sdl.SDLK_W => .close_tab,
        sdl.SDLK_S => .ssh_picker,
        sdl.SDLK_V => .paste,
        sdl.SDLK_C => .copy_line,
        sdl.SDLK_D => .toggle_theme,
        sdl.SDLK_L => .toggle_highlight,
        sdl.SDLK_LEFTBRACKET => .prev_tab,
        sdl.SDLK_RIGHTBRACKET => .next_tab,
        sdl.SDLK_EQUALS => .zoom_in,
        sdl.SDLK_MINUS => .zoom_out,
        sdl.SDLK_0 => .zoom_reset,
        sdl.SDLK_1...sdl.SDLK_9 => .{ .select_tab = key - sdl.SDLK_1 },
        else => null,
    };
}

/// Translates a key press into the bytes a terminal sends for it.
///
/// Returns null for keys that produce no bytes (modifiers, and printable keys,
/// which arrive as a TEXT_INPUT event instead so that dead keys, IME and
/// non-Latin layouts work).
pub fn encodeKey(key: u32, mods: u16, buf: []u8) ?[]const u8 {
    const ctrl = mods & sdl.KMOD_CTRL != 0;
    const alt = mods & sdl.KMOD_ALT != 0;
    var n: usize = 0;

    // Meta is sent as an ESC prefix, the convention every shell understands.
    if (alt) {
        buf[n] = 0x1b;
        n += 1;
    }

    if (ctrl) {
        const code: ?u8 = switch (key) {
            sdl.SDLK_A...sdl.SDLK_Z => @intCast(key - sdl.SDLK_A + 1),
            sdl.SDLK_SPACE, sdl.SDLK_2 => 0, // NUL
            sdl.SDLK_LEFTBRACKET, sdl.SDLK_3 => 27,
            sdl.SDLK_BACKSLASH, sdl.SDLK_4 => 28,
            sdl.SDLK_RIGHTBRACKET, sdl.SDLK_5 => 29,
            sdl.SDLK_6, sdl.SDLK_GRAVE => 30,
            sdl.SDLK_7, sdl.SDLK_MINUS => 31,
            sdl.SDLK_8 => 0x7f,
            else => null,
        };
        if (code) |c| {
            buf[n] = c;
            n += 1;
            return buf[0..n];
        }
    }

    const seq: []const u8 = switch (key) {
        sdl.SDLK_RETURN => "\r",
        sdl.SDLK_BACKSPACE => "\x7f",
        sdl.SDLK_TAB => "\t",
        sdl.SDLK_ESCAPE => "\x1b",
        sdl.SDLK_UP => "\x1b[A",
        sdl.SDLK_DOWN => "\x1b[B",
        sdl.SDLK_RIGHT => "\x1b[C",
        sdl.SDLK_LEFT => "\x1b[D",
        sdl.SDLK_HOME => "\x1b[H",
        sdl.SDLK_END => "\x1b[F",
        sdl.SDLK_PAGEUP => "\x1b[5~",
        sdl.SDLK_PAGEDOWN => "\x1b[6~",
        sdl.SDLK_INSERT => "\x1b[2~",
        sdl.SDLK_DELETE => "\x1b[3~",
        // F1-F4 are SS3-encoded; F5 upwards use CSI with a number.
        sdl.SDLK_F1 => "\x1bOP",
        sdl.SDLK_F2 => "\x1bOQ",
        sdl.SDLK_F3 => "\x1bOR",
        sdl.SDLK_F4 => "\x1bOS",
        sdl.SDLK_F5 => "\x1b[15~",
        sdl.SDLK_F6 => "\x1b[17~",
        sdl.SDLK_F7 => "\x1b[18~",
        sdl.SDLK_F8 => "\x1b[19~",
        sdl.SDLK_F9 => "\x1b[20~",
        sdl.SDLK_F10 => "\x1b[21~",
        sdl.SDLK_F11 => "\x1b[23~",
        sdl.SDLK_F12 => "\x1b[24~",
        else => {
            // Alt plus a printable key: TEXT_INPUT cannot carry the ESC, so
            // the byte is emitted here instead.
            if (alt and key >= 0x20 and key < 0x7f) {
                buf[n] = @intCast(key);
                n += 1;
                return buf[0..n];
            }
            return null;
        },
    };

    if (n + seq.len > buf.len) return null;
    @memcpy(buf[n..][0..seq.len], seq);
    return buf[0 .. n + seq.len];
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn expectKey(key: u32, mods: u16, expected: []const u8) !void {
    var buf: [16]u8 = undefined;
    const out = encodeKey(key, mods, &buf) orelse return error.NoBytes;
    try testing.expectEqualSlices(u8, expected, out);
}

test "printable keys produce no bytes and are left to TEXT_INPUT" {
    // Encoding them here as well as in onTextInput is what made every typed
    // character appear twice.
    var buf: [16]u8 = undefined;
    try testing.expect(encodeKey('a', 0, &buf) == null);
    try testing.expect(encodeKey('Z', 0, &buf) == null);
    try testing.expect(encodeKey(sdl.SDLK_1, 0, &buf) == null);
    try testing.expect(encodeKey(sdl.SDLK_SPACE, 0, &buf) == null);
}

test "control keys map to their ASCII codes" {
    try expectKey(sdl.SDLK_A, sdl.KMOD_LCTRL, "\x01");
    try expectKey(sdl.SDLK_C, sdl.KMOD_LCTRL, "\x03");
    try expectKey(sdl.SDLK_Z, sdl.KMOD_RCTRL, "\x1a");
    try expectKey(sdl.SDLK_SPACE, sdl.KMOD_LCTRL, "\x00");
}

test "the control punctuation codes are the standard ones" {
    // Ctrl+] is 29, not 30: the original table was off by one here and mapped
    // Ctrl+- and Ctrl+= to unrelated codes.
    try expectKey(sdl.SDLK_LEFTBRACKET, sdl.KMOD_LCTRL, "\x1b");
    try expectKey(sdl.SDLK_BACKSLASH, sdl.KMOD_LCTRL, "\x1c");
    try expectKey(sdl.SDLK_RIGHTBRACKET, sdl.KMOD_LCTRL, "\x1d");
    try expectKey(sdl.SDLK_GRAVE, sdl.KMOD_LCTRL, "\x1e");
    try expectKey(sdl.SDLK_MINUS, sdl.KMOD_LCTRL, "\x1f");
}

test "editing and navigation keys" {
    try expectKey(sdl.SDLK_RETURN, 0, "\r");
    try expectKey(sdl.SDLK_BACKSPACE, 0, "\x7f");
    try expectKey(sdl.SDLK_TAB, 0, "\t");
    try expectKey(sdl.SDLK_ESCAPE, 0, "\x1b");
    try expectKey(sdl.SDLK_UP, 0, "\x1b[A");
    try expectKey(sdl.SDLK_DOWN, 0, "\x1b[B");
    try expectKey(sdl.SDLK_RIGHT, 0, "\x1b[C");
    try expectKey(sdl.SDLK_LEFT, 0, "\x1b[D");
    try expectKey(sdl.SDLK_HOME, 0, "\x1b[H");
    try expectKey(sdl.SDLK_END, 0, "\x1b[F");
    try expectKey(sdl.SDLK_PAGEUP, 0, "\x1b[5~");
    try expectKey(sdl.SDLK_PAGEDOWN, 0, "\x1b[6~");
    try expectKey(sdl.SDLK_DELETE, 0, "\x1b[3~");
    try expectKey(sdl.SDLK_INSERT, 0, "\x1b[2~");
}

test "function keys use the xterm encodings" {
    // F1-F4 are SS3 sequences; the old code emitted `ESC [ 1 ~` variants for
    // all of them, and F9-F12 all collapsed onto the same bytes.
    try expectKey(sdl.SDLK_F1, 0, "\x1bOP");
    try expectKey(sdl.SDLK_F4, 0, "\x1bOS");
    try expectKey(sdl.SDLK_F5, 0, "\x1b[15~");
    try expectKey(sdl.SDLK_F9, 0, "\x1b[20~");
    try expectKey(sdl.SDLK_F10, 0, "\x1b[21~");
    try expectKey(sdl.SDLK_F11, 0, "\x1b[23~");
    try expectKey(sdl.SDLK_F12, 0, "\x1b[24~");
}

test "every function key encodes to a distinct sequence" {
    const keys = [_]u32{
        sdl.SDLK_F1, sdl.SDLK_F2,  sdl.SDLK_F3,  sdl.SDLK_F4,
        sdl.SDLK_F5, sdl.SDLK_F6,  sdl.SDLK_F7,  sdl.SDLK_F8,
        sdl.SDLK_F9, sdl.SDLK_F10, sdl.SDLK_F11, sdl.SDLK_F12,
    };
    var seen: [keys.len][16]u8 = undefined;
    var lens: [keys.len]usize = undefined;
    for (keys, 0..) |k, i| {
        const out = encodeKey(k, 0, &seen[i]).?;
        lens[i] = out.len;
    }
    for (0..keys.len) |i| {
        for (i + 1..keys.len) |j| {
            try testing.expect(!std.mem.eql(u8, seen[i][0..lens[i]], seen[j][0..lens[j]]));
        }
    }
}

test "alt prefixes the sequence with ESC" {
    try expectKey(sdl.SDLK_RETURN, sdl.KMOD_LALT, "\x1b\r");
    try expectKey('b', sdl.KMOD_LALT, "\x1bb");
    try expectKey(sdl.SDLK_LEFT, sdl.KMOD_RALT, "\x1b\x1b[D");
}

test "ctrl-alt combines the ESC prefix with the control code" {
    try expectKey(sdl.SDLK_A, sdl.KMOD_LCTRL | sdl.KMOD_LALT, "\x1b\x01");
}

test "unmapped keys produce nothing" {
    var buf: [16]u8 = undefined;
    try testing.expect(encodeKey(sdl.SDLK_CAPSLOCK, 0, &buf) == null);
    try testing.expect(encodeKey(sdl.SDLK_F13, 0, &buf) == null);
}

test "ctrl with a key that has no control code falls back to the plain sequence" {
    try expectKey(sdl.SDLK_F1, sdl.KMOD_LCTRL, "\x1bOP");
    try expectKey(sdl.SDLK_UP, sdl.KMOD_LCTRL, "\x1b[A");
}

test "encodeKey never writes past a short buffer" {
    var buf: [2]u8 = undefined;
    // "\x1b[5~" needs four bytes.
    try testing.expect(encodeKey(sdl.SDLK_PAGEUP, 0, &buf) == null);
}

test "the app modifier does not steal plain Ctrl from the shell" {
    // Ctrl+C must reach the shell, so it cannot also be an app shortcut.
    try testing.expect(!isAppMod(sdl.KMOD_LCTRL));
    try testing.expect(!isAppMod(sdl.KMOD_RCTRL));
    try testing.expect(!isAppMod(sdl.KMOD_LALT));
    try testing.expect(!isAppMod(0));

    try testing.expect(isAppMod(sdl.KMOD_LGUI));
    try testing.expect(isAppMod(sdl.KMOD_RGUI));
    try testing.expect(isAppMod(sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT));
    try testing.expect(isAppMod(sdl.KMOD_RCTRL | sdl.KMOD_RSHIFT));
}

test "a new tab has a keyboard shortcut under either modifier" {
    try testing.expectEqual(Action.new_tab, shortcutFor(sdl.SDLK_T, sdl.KMOD_LGUI).?);
    try testing.expectEqual(Action.new_tab, shortcutFor(sdl.SDLK_N, sdl.KMOD_LGUI).?);
    // The Ctrl+Shift form matters where the window manager claims Command.
    try testing.expectEqual(
        Action.new_tab,
        shortcutFor(sdl.SDLK_T, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT).?,
    );
}

test "shortcuts without the app modifier belong to the shell" {
    try testing.expect(shortcutFor(sdl.SDLK_T, 0) == null);
    try testing.expect(shortcutFor(sdl.SDLK_T, sdl.KMOD_LCTRL) == null);
    try testing.expect(shortcutFor(sdl.SDLK_C, sdl.KMOD_LCTRL) == null);
    try testing.expect(shortcutFor(sdl.SDLK_W, sdl.KMOD_LCTRL) == null);
}

test "the tab and window shortcuts map as documented" {
    const gui = sdl.KMOD_LGUI;
    try testing.expectEqual(Action.close_tab, shortcutFor(sdl.SDLK_W, gui).?);
    try testing.expectEqual(Action.ssh_picker, shortcutFor(sdl.SDLK_S, gui).?);
    try testing.expectEqual(Action.paste, shortcutFor(sdl.SDLK_V, gui).?);
    try testing.expectEqual(Action.copy_line, shortcutFor(sdl.SDLK_C, gui).?);
    try testing.expectEqual(Action.prev_tab, shortcutFor(sdl.SDLK_LEFTBRACKET, gui).?);
    try testing.expectEqual(Action.next_tab, shortcutFor(sdl.SDLK_RIGHTBRACKET, gui).?);
    try testing.expectEqual(Action.zoom_in, shortcutFor(sdl.SDLK_EQUALS, gui).?);
    try testing.expectEqual(Action.zoom_out, shortcutFor(sdl.SDLK_MINUS, gui).?);
    try testing.expectEqual(Action.zoom_reset, shortcutFor(sdl.SDLK_0, gui).?);
    try testing.expect(shortcutFor(sdl.SDLK_Z, gui) == null);
}

test "the toggles work under both forms of the app modifier" {
    // A Shift variant would be unreachable under the Ctrl+Shift form, so each
    // toggle owns a key of its own.
    for ([_]u16{ sdl.KMOD_LGUI, sdl.KMOD_LCTRL | sdl.KMOD_LSHIFT }) |mods| {
        try testing.expectEqual(Action.toggle_theme, shortcutFor(sdl.SDLK_D, mods).?);
        try testing.expectEqual(Action.toggle_highlight, shortcutFor(sdl.SDLK_L, mods).?);
        try testing.expectEqual(Action.new_tab, shortcutFor(sdl.SDLK_T, mods).?);
        try testing.expectEqual(Action.close_tab, shortcutFor(sdl.SDLK_W, mods).?);
    }
}

test "no binding depends on Shift" {
    // Every shortcut must resolve the same way with and without Shift held.
    const keys = [_]u32{
        sdl.SDLK_T, sdl.SDLK_N, sdl.SDLK_W,           sdl.SDLK_S,
        sdl.SDLK_V, sdl.SDLK_C, sdl.SDLK_D,           sdl.SDLK_L,
        sdl.SDLK_0, sdl.SDLK_1, sdl.SDLK_EQUALS,      sdl.SDLK_MINUS,
        sdl.SDLK_9, sdl.SDLK_A, sdl.SDLK_LEFTBRACKET, sdl.SDLK_RIGHTBRACKET,
    };
    for (keys) |k| {
        const plain = shortcutFor(k, sdl.KMOD_LGUI);
        const shifted = shortcutFor(k, sdl.KMOD_LGUI | sdl.KMOD_LSHIFT);
        try testing.expectEqual(plain == null, shifted == null);
        if (plain) |p| try testing.expectEqual(std.meta.activeTag(p), std.meta.activeTag(shifted.?));
    }
}

test "the digits select tabs one-based" {
    const gui = sdl.KMOD_LGUI;
    try testing.expectEqual(@as(usize, 0), shortcutFor(sdl.SDLK_1, gui).?.select_tab);
    try testing.expectEqual(@as(usize, 4), shortcutFor('5', gui).?.select_tab);
    try testing.expectEqual(@as(usize, 8), shortcutFor(sdl.SDLK_9, gui).?.select_tab);
}
