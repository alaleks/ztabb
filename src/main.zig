const std = @import("std");
const sdl = @import("sdl");
const tabs = @import("tabs");
const term = @import("term");

const CHAR_W: u32 = 8;
const CHAR_H: u32 = 16;
const TAB_BAR_H: u32 = 28;

pub const App = struct {
    window: *void,
    renderer: *void,
    tab_mgr: tabs.Tabs,
    gpa: std.mem.Allocator,
    win_w: i32,
    win_h: i32,
    cols: u32,
    rows: u32,
    running: bool,

    pub fn init(gpa: std.mem.Allocator) !App {
        try sdl.init();
        const win = try sdl.createWindow("ztabb", 800, 600);
        const renderer = try sdl.createRenderer(win);
        sdl.startTextInput(win);

        var w: i32 = 0;
        var h: i32 = 0;
        _ = sdl.getWindowSize(win, &w, &h);

        const cols = @max(1, @as(u32, @intCast(@divTrunc(w - 20, @as(i32, CHAR_W)))));
        const rows = @max(1, @as(u32, @intCast(@divTrunc(h - @as(i32, TAB_BAR_H) - 20, @as(i32, CHAR_H)))));

        var tab_mgr = tabs.Tabs.init(gpa);
        _ = try tab_mgr.addTab(cols, rows);

        return App{
            .window = win,
            .renderer = renderer,
            .tab_mgr = tab_mgr,
            .gpa = gpa,
            .win_w = w,
            .win_h = h,
            .cols = cols,
            .rows = rows,
            .running = true,
        };
    }

    pub fn deinit(self: *App) void {
        self.tab_mgr.deinit();
        sdl.stopTextInput(self.window);
        sdl.destroyRenderer(self.renderer);
        sdl.destroyWindow(self.window);
        sdl.quit();
    }

    pub fn run(self: *App) void {
        while (self.running) {
            self.processEvents();
            self.readPty();
            self.render();
        }
    }

    fn processEvents(self: *App) void {
        var event: sdl.Event = undefined;
        while (sdl.pollEvent(&event)) {
            switch (event.key.type_) {
                sdl.SDL_EVENT_QUIT => self.running = false,
                sdl.SDL_EVENT_WINDOW_RESIZED => self.onResize(event.window.data1, event.window.data2),
                sdl.SDL_EVENT_KEY_DOWN => self.onKeyDown(event.key.key, event.key.modifiers),
                sdl.SDL_EVENT_TEXT_INPUT => self.onTextInput(event.text.text),
                sdl.SDL_EVENT_MOUSE_WHEEL => self.onMouseWheel(event.wheel.y),
                else => {},
            }
        }
    }

    fn onResize(self: *App, w: i32, h: i32) void {
        self.win_w = w;
        self.win_h = h;
        const new_cols = @max(1, @as(u32, @intCast(@divTrunc(w - 20, @as(i32, CHAR_W)))));
        const new_rows = @max(1, @as(u32, @intCast(@divTrunc(h - @as(i32, TAB_BAR_H) - 20, @as(i32, CHAR_H)))));
        if (new_cols != self.cols or new_rows != self.rows) {
            const tab = self.tab_mgr.activeMut();
            tab.terminal.resize(new_cols, new_rows, self.gpa) catch return;
            tab.pty.resize(@as(u16, @intCast(new_cols)), @as(u16, @intCast(new_rows))) catch {};
            self.cols = new_cols;
            self.rows = new_rows;
        }
    }

    fn onKeyDown(self: *App, key: u32, mods: u32) void {
        const tab = self.tab_mgr.activeMut();
        const ctrl = (mods & (sdl.SDL_KMOD_LCTRL | sdl.SDL_KMOD_RCTRL)) != 0;
        const alt = (mods & (sdl.SDL_KMOD_LALT | sdl.SDL_KMOD_RALT)) != 0;

        if (ctrl and key == sdl.SDLK_T) {
            self.newTab() catch {};
            return;
        }
        if (ctrl and key == sdl.SDLK_W) {
            self.closeTab() catch {};
            return;
        }
        if (ctrl and (key >= sdl.SDLK_1 and key <= sdl.SDLK_9)) {
            const idx = key - sdl.SDLK_1;
            if (idx < self.tab_mgr.count) {
                self.tab_mgr.switchTo(idx) catch {};
            }
            return;
        }

        var buf: [8]u8 = .{0} ** 8;
        var n: usize = 0;

        if (alt) {
            buf[n] = 0x1b;
            n += 1;
        }

        if (ctrl) {
            switch (key) {
                sdl.SDLK_A => buf[n] = 1,
                sdl.SDLK_B => buf[n] = 2,
                sdl.SDLK_C => buf[n] = 3,
                sdl.SDLK_D => buf[n] = 4,
                sdl.SDLK_E => buf[n] = 5,
                sdl.SDLK_F => buf[n] = 6,
                sdl.SDLK_G => buf[n] = 7,
                sdl.SDLK_H => buf[n] = 8,
                sdl.SDLK_I => buf[n] = 9,
                sdl.SDLK_J => buf[n] = 10,
                sdl.SDLK_K => buf[n] = 11,
                sdl.SDLK_L => buf[n] = 12,
                sdl.SDLK_M => buf[n] = 13,
                sdl.SDLK_N => buf[n] = 14,
                sdl.SDLK_O => buf[n] = 15,
                sdl.SDLK_P => buf[n] = 16,
                sdl.SDLK_Q => buf[n] = 17,
                sdl.SDLK_R => buf[n] = 18,
                sdl.SDLK_S => buf[n] = 19,
                sdl.SDLK_T => buf[n] = 20,
                sdl.SDLK_U => buf[n] = 21,
                sdl.SDLK_V => buf[n] = 22,
                sdl.SDLK_W => buf[n] = 23,
                sdl.SDLK_X => buf[n] = 24,
                sdl.SDLK_Y => buf[n] = 25,
                sdl.SDLK_Z => buf[n] = 26,
                sdl.SDLK_SPACE => buf[n] = 0,
                sdl.SDLK_BACKSLASH => buf[n] = 28,
                sdl.SDLK_BRACKETLEFT => buf[n] = 27,
                sdl.SDLK_BRACKETRIGHT => buf[n] = 30,
                sdl.SDLK_MINUS => buf[n] = 15,
                sdl.SDLK_EQUALS => buf[n] = 18,
                sdl.SDLK_0 => buf[n] = 24,
                else => return,
            }
            n += 1;
        } else {
            switch (key) {
                sdl.SDLK_RETURN => {
                    buf[n] = '\r';
                    n += 1;
                },
                sdl.SDLK_BACKSPACE => {
                    buf[n] = 0x7f;
                    n += 1;
                },
                sdl.SDLK_TAB => {
                    buf[n] = '\t';
                    n += 1;
                },
                sdl.SDLK_ESCAPE => {
                    buf[n] = 0x1b;
                    n += 1;
                },
                sdl.SDLK_UP => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = 'A';
                    n += 1;
                },
                sdl.SDLK_DOWN => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = 'B';
                    n += 1;
                },
                sdl.SDLK_RIGHT => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = 'C';
                    n += 1;
                },
                sdl.SDLK_LEFT => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = 'D';
                    n += 1;
                },
                sdl.SDLK_HOME => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = 'H';
                    n += 1;
                },
                sdl.SDLK_END => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = 'F';
                    n += 1;
                },
                sdl.SDLK_PAGEUP => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = '5';
                    n += 1;
                    buf[n] = '~';
                    n += 1;
                },
                sdl.SDLK_PAGEDOWN => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = '6';
                    n += 1;
                    buf[n] = '~';
                    n += 1;
                },
                sdl.SDLK_DELETE => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = '3';
                    n += 1;
                    buf[n] = '~';
                    n += 1;
                },
                sdl.SDLK_INSERT => {
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = '2';
                    n += 1;
                    buf[n] = '~';
                    n += 1;
                },
                @as(u32, sdl.SDLK_F1)...@as(u32, sdl.SDLK_F4) => {
                    const code = key - sdl.SDLK_F1;
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = '1';
                    n += 1;
                    if (code > 0) {
                        buf[n] = @as(u8, ';') + @as(u8, @intCast(code));
                        n += 1;
                    }
                    buf[n] = '~';
                    n += 1;
                },
                @as(u32, sdl.SDLK_F5)...@as(u32, sdl.SDLK_F8) => {
                    const code = key - sdl.SDLK_F5;
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = '1';
                    n += 1;
                    buf[n] = '5';
                    n += 1;
                    if (code > 0) {
                        buf[n] = @as(u8, ';') + @as(u8, @intCast(code + 1));
                        n += 1;
                    }
                    buf[n] = '~';
                    n += 1;
                },
                @as(u32, sdl.SDLK_F9)...@as(u32, sdl.SDLK_F12) => {
                    const code = key - sdl.SDLK_F9;
                    buf[n] = 0x1b;
                    n += 1;
                    buf[n] = '[';
                    n += 1;
                    buf[n] = '2';
                    n += 1;
                    if (code == 0) {
                        buf[n] = '0';
                    } else {
                        buf[n] = @as(u8, '0') + @as(u8, @intCast(code));
                    }
                    buf[n] = '~';
                    n += 1;
                },
                else => {
                    if (key >= 32 and key < 127) {
                        buf[n] = @as(u8, @intCast(key));
                        n += 1;
                    } else {
                        return;
                    }
                },
            }
        }

        if (n > 0) {
            tab.pty.write(buf[0..n]) catch {};
        }
    }

    fn onTextInput(self: *App, text: [*]u8) void {
        const tab = self.tab_mgr.activeMut();
        var i: usize = 0;
        while (text[i] != 0) : (i += 1) {}
        if (i > 0) {
            tab.pty.write(text[0..i]) catch {};
        }
    }

    fn onMouseWheel(self: *App, y: i32) void {
        if (y > 0) {
            const tab = self.tab_mgr.activeMut();
            _ = tab;
        }
    }

    fn readPty(self: *App) void {
        const tab = self.tab_mgr.activeMut();
        var buf: [4096]u8 = undefined;
        const n = tab.pty.read(&buf) catch return;
        if (n > 0) {
            tab.terminal.write(buf[0..n]);
        }
    }

    fn newTab(self: *App) !void {
        _ = try self.tab_mgr.addTab(self.cols, self.rows);
        const tab = self.tab_mgr.activeMut();
        tab.pty.resize(@as(u16, @intCast(self.cols)), @as(u16, @intCast(self.rows))) catch {};
    }

    fn closeTab(self: *App) !void {
        if (self.tab_mgr.count <= 1) {
            self.running = false;
            return;
        }
        try self.tab_mgr.closeTab(self.tab_mgr.active_idx);
    }

    fn render(self: *App) void {
        sdl.setRenderDrawColor(self.renderer, 0x1e, 0x1e, 0x1e, 255) catch return;
        sdl.renderClear(self.renderer) catch return;

        self.renderTabBar();
        self.renderTerminal();

        sdl.renderPresent(self.renderer) catch return;
    }

    fn renderTabBar(self: *App) void {
        sdl.setRenderDrawColor(self.renderer, 0x2d, 0x2d, 0x2d, 255) catch return;
        var rect = sdl.Rect{ .x = 0, .y = 0, .w = self.win_w, .h = @as(i32, TAB_BAR_H) };
        sdl.renderFillRect(self.renderer, &rect) catch return;

        for (0..self.tab_mgr.count) |i| {
            const tab = &self.tab_mgr.tabs[i];
            const x = @as(i32, @intCast(i * 120));
            const bg: u32 = if (tab.active) 0x3c3f41 else 0x2d2d2d;
            sdl.setRenderDrawColor(self.renderer, @as(u8, @intCast((bg >> 16) & 0xff)), @as(u8, @intCast((bg >> 8) & 0xff)), @as(u8, @intCast(bg & 0xff)), 255) catch return;
            rect = sdl.Rect{ .x = x, .y = 0, .w = 120, .h = @as(i32, TAB_BAR_H) };
            sdl.renderFillRect(self.renderer, &rect) catch return;
        }
    }

    fn renderTerminal(self: *App) void {
        const tab = self.tab_mgr.active();
        const t = &tab.terminal;
        const offset_y = @as(i32, TAB_BAR_H);

        for (0..t.rows) |r| {
            for (0..t.cols) |c| {
                const cell = t.cells[r * t.cols + c];
                var fg = cell.fg;
                var bg = cell.bg;
                if (cell.inverse) {
                    const tmp = fg;
                    fg = bg;
                    bg = tmp;
                }
                if (cell.ch != ' ') {
                    sdl.setRenderDrawColor(self.renderer, @as(u8, @intCast((bg >> 16) & 0xff)), @as(u8, @intCast((bg >> 8) & 0xff)), @as(u8, @intCast(bg & 0xff)), 255) catch return;
                    var rect = sdl.Rect{
                        .x = @as(i32, @intCast(c * CHAR_W)),
                        .y = offset_y + @as(i32, @intCast(r * CHAR_H)),
                        .w = @as(i32, CHAR_W),
                        .h = @as(i32, CHAR_H),
                    };
                    sdl.renderFillRect(self.renderer, &rect) catch return;
                }
            }
        }

        if (t.cursor_visible) {
            sdl.setRenderDrawColor(self.renderer, @as(u8, @intCast((t.fg >> 16) & 0xff)), @as(u8, @intCast((t.fg >> 8) & 0xff)), @as(u8, @intCast(t.fg & 0xff)), 255) catch return;
            var rect = sdl.Rect{
                .x = @as(i32, @intCast(t.cursor_col * CHAR_W)),
                .y = offset_y + @as(i32, @intCast(t.cursor_row * CHAR_H)),
                .w = @as(i32, CHAR_W),
                .h = @as(i32, CHAR_H),
            };
            sdl.renderFillRect(self.renderer, &rect) catch return;
        }
    }
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var app = try App.init(allocator);
    defer app.deinit();
    app.run();
}
