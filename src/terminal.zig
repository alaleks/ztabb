const std = @import("std");

pub const Cell = struct {
    ch: u21,
    fg: u32,
    bg: u32,
    bold: bool,
    inverse: bool,
};

pub const Terminal = struct {
    cols: u32,
    rows: u32,
    cells: []Cell,
    cursor_row: u32,
    cursor_col: u32,
    cursor_visible: bool,
    fg: u32,
    bg: u32,
    bold: bool,
    inverse: bool,
    scrollback: []u21,
    scrollback_len: u32,

    pub const MAX_SCROLLBACK: u32 = 10000;

    pub fn init(cols: u32, rows: u32, gpa: std.mem.Allocator) !Terminal {
        const total = cols * rows;
        const cells = try gpa.alloc(Cell, total);
        const scrollback = try gpa.alloc(u21, MAX_SCROLLBACK);
        for (cells) |*c| {
            c.* = Cell{ .ch = ' ', .fg = 0xCCCCCC, .bg = 0x1E1E1E, .bold = false, .inverse = false };
        }
        for (scrollback) |*c| c.* = 0;
        return Terminal{
            .cols = cols,
            .rows = rows,
            .cells = cells,
            .cursor_row = 0,
            .cursor_col = 0,
            .cursor_visible = true,
            .fg = 0xCCCCCC,
            .bg = 0x1E1E1E,
            .bold = false,
            .inverse = false,
            .scrollback = scrollback,
            .scrollback_len = 0,
        };
    }

    pub fn deinit(self: *Terminal, gpa: std.mem.Allocator) void {
        gpa.free(self.cells);
        gpa.free(self.scrollback);
    }

    pub fn resize(self: *Terminal, cols: u32, rows: u32, gpa: std.mem.Allocator) !void {
        const old_cols = self.cols;
        const old_rows = self.rows;
        const old_cells = self.cells;
        const new_total = cols * rows;
        const new_cells = try gpa.alloc(Cell, new_total);
        for (new_cells) |*c| {
            c.* = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
        const copy_rows = @min(old_rows, rows);
        const copy_cols = @min(old_cols, cols);
        for (0..copy_rows) |r| {
            for (0..copy_cols) |c| {
                new_cells[r * cols + c] = old_cells[r * old_cols + c];
            }
        }
        gpa.free(old_cells);
        self.cells = new_cells;
        self.cols = cols;
        self.rows = rows;
        self.cursor_row = @min(self.cursor_row, rows - 1);
        self.cursor_col = @min(self.cursor_col, cols - 1);
    }

    pub fn putChar(self: *Terminal, ch: u21) void {
        if (ch == '\n') {
            self.newline();
            return;
        }
        if (ch == '\r') {
            self.cursor_col = 0;
            return;
        }
        if (ch == '\t') {
            self.cursor_col = ((self.cursor_col / 8) + 1) * 8;
            if (self.cursor_col >= self.cols) self.cursor_col = self.cols - 1;
            return;
        }
        if (ch < 32) return;
        const idx = self.cursor_row * self.cols + self.cursor_col;
        self.cells[idx].ch = ch;
        self.cells[idx].fg = self.fg;
        self.cells[idx].bg = self.bg;
        self.cells[idx].bold = self.bold;
        self.cells[idx].inverse = self.inverse;
        self.cursor_col += 1;
        if (self.cursor_col >= self.cols) {
            self.cursor_col = 0;
            self.cursor_row += 1;
            if (self.cursor_row >= self.rows) {
                self.cursor_row = self.rows - 1;
                self.scroll();
            }
        }
    }

    pub fn newline(self: *Terminal) void {
        self.cursor_col = 0;
        self.cursor_row += 1;
        if (self.cursor_row >= self.rows) {
            self.scroll();
        }
    }

    pub fn scroll(self: *Terminal) void {
        for (0..(self.rows - 1)) |r| {
            for (0..self.cols) |c| {
                self.cells[r * self.cols + c] = self.cells[(r + 1) * self.cols + c];
            }
        }
        for (0..self.cols) |c| {
            const idx = (self.rows - 1) * self.cols + c;
            self.cells[idx] = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
    }

    pub fn handleEscape(self: *Terminal, buf: []const u8, pos: *usize) void {
        if (pos.* >= buf.len) return;
        if (buf[pos.*] != 0x1b) return;
        pos.* += 1;
        if (pos.* >= buf.len) return;
        const c = buf[pos.*];
        pos.* += 1;
        switch (c) {
            '[' => self.handleCsi(buf, pos),
            ']' => self.handleOsc(buf, pos),
            'c' => self.reset(),
            'm' => self.handleSgr(buf, pos),
            else => {},
        }
    }

    pub fn handleCsi(self: *Terminal, buf: []const u8, pos: *usize) void {
        var params: [32]u32 = .{0} ** 32;
        var param_count: u32 = 0;
        var current_param: u32 = 0;
        var final_byte: u8 = 0;

        while (pos.* < buf.len) {
            const c = buf[pos.*];
            pos.* += 1;
            if (c >= '0' and c <= '9') {
                current_param = current_param * 10 + (c - '0');
            } else if (c == ';') {
                if (param_count < 32) {
                    params[param_count] = current_param;
                    param_count += 1;
                }
                current_param = 0;
            } else if (c >= '@' and c <= '~') {
                final_byte = c;
                break;
            }
        }
        if (param_count < 32) {
            params[param_count] = current_param;
            param_count += 1;
        }

        switch (final_byte) {
            'A' => {
                const n = if (param_count > 0 and params[0] > 0) params[0] else 1;
                self.cursor_row = if (self.cursor_row >= n) self.cursor_row - n else 0;
            },
            'B' => {
                const n = if (param_count > 0 and params[0] > 0) params[0] else 1;
                self.cursor_row = @min(self.rows - 1, self.cursor_row + n);
            },
            'C' => {
                const n = if (param_count > 0 and params[0] > 0) params[0] else 1;
                self.cursor_col = @min(self.cols - 1, self.cursor_col + n);
            },
            'D' => {
                const n = if (param_count > 0 and params[0] > 0) params[0] else 1;
                self.cursor_col = if (self.cursor_col >= n) self.cursor_col - n else 0;
            },
            'E' => self.cursor_col = 0,
            'F' => {
                self.cursor_col = 0;
                self.cursor_row = 0;
            },
            'G' => {
                const col = if (param_count > 0 and params[0] > 0) params[0] - 1 else 0;
                self.cursor_col = @min(self.cols - 1, col);
            },
            'H' => {
                const row = if (param_count > 0 and params[0] > 0) params[0] - 1 else 0;
                const col = if (param_count > 1 and params[1] > 0) params[1] - 1 else 0;
                self.cursor_row = @min(self.rows - 1, row);
                self.cursor_col = @min(self.cols - 1, col);
            },
            'J' => {
                const mode = if (param_count > 0) params[0] else 0;
                switch (mode) {
                    0 => self.clearFromCursor(),
                    1 => self.clearToCursor(),
                    2 => self.clearAll(),
                    3 => {},
                    else => {},
                }
            },
            'K' => {
                const mode = if (param_count > 0) params[0] else 0;
                switch (mode) {
                    0 => self.clearLineFromCursor(),
                    1 => self.clearLineToCursor(),
                    2 => self.clearLine(),
                    else => {},
                }
            },
            'm' => self.handleSgrParams(params, param_count),
            'r' => {},
            's' => {},
            'u' => {},
            else => {},
        }
    }

    pub fn handleOsc(_: *Terminal, buf: []const u8, pos: *usize) void {
        while (pos.* < buf.len) {
            const c = buf[pos.*];
            pos.* += 1;
            if (c == 0x07) {
                return;
            }
            if (c == 0x1b and pos.* < buf.len and buf[pos.*] == '\\') {
                pos.* += 1;
                return;
            }
        }
    }

    pub fn handleSgr(self: *Terminal, buf: []const u8, pos: *usize) void {
        var params: [32]u32 = .{0} ** 32;
        var param_count: u32 = 0;
        var current_param: u32 = 0;
        while (pos.* < buf.len) {
            const c = buf[pos.*];
            if (c >= '0' and c <= '9') {
                current_param = current_param * 10 + (c - '0');
            } else if (c == ';') {
                if (param_count < 32) {
                    params[param_count] = current_param;
                    param_count += 1;
                }
                current_param = 0;
            } else if (c == 'm') {
                pos.* += 1;
                break;
            } else {
                pos.* += 1;
            }
        }
        if (param_count < 32) {
            params[param_count] = current_param;
            param_count += 1;
        }
        self.handleSgrParams(params, param_count);
    }

    pub fn handleSgrParams(self: *Terminal, params: [32]u32, count: u32) void {
        if (count == 0 or (count == 1 and params[0] == 0)) {
            self.resetAttrs();
            return;
        }
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            switch (params[i]) {
                0 => self.resetAttrs(),
                1 => self.bold = true,
                2 => {},
                3 => {},
                4 => {},
                5 => {},
                7 => self.inverse = true,
                8 => {},
                9 => {},
                22 => self.bold = false,
                27 => self.inverse = false,
                30...37 => self.fg = self.colorFromCode(params[i] - 30),
                38 => {
                    if (i + 2 < count and params[i + 1] == 2) {
                        const r = @as(u32, params[i + 2]) * 255 / 255;
                        const g = if (i + 3 < count) @as(u32, params[i + 3]) * 255 / 255 else 0;
                        const b = if (i + 4 < count) @as(u32, params[i + 4]) * 255 / 255 else 0;
                        self.fg = (r << 16) | (g << 8) | b;
                        i += 4;
                    }
                },
                39 => self.fg = 0xCCCCCC,
                40...47 => self.bg = self.colorFromCode(params[i] - 40),
                48 => {
                    if (i + 2 < count and params[i + 1] == 2) {
                        const r = @as(u32, params[i + 2]) * 255 / 255;
                        const g = if (i + 3 < count) @as(u32, params[i + 3]) * 255 / 255 else 0;
                        const b = if (i + 4 < count) @as(u32, params[i + 4]) * 255 / 255 else 0;
                        self.bg = (r << 16) | (g << 8) | b;
                        i += 4;
                    }
                },
                49 => self.bg = 0x1E1E1E,
                90...97 => self.fg = self.brightColorFromCode(params[i] - 90),
                100...107 => self.bg = self.brightColorFromCode(params[i] - 100),
                else => {},
            }
        }
    }

    pub fn colorFromCode(_: *Terminal, code: u32) u32 {
        return switch (code) {
            0 => 0x000000,
            1 => 0x800000,
            2 => 0x008000,
            3 => 0x808000,
            4 => 0x000080,
            5 => 0x800080,
            6 => 0x008080,
            7 => 0xC0C0C0,
            else => 0xCCCCCC,
        };
    }

    pub fn brightColorFromCode(_: *Terminal, code: u32) u32 {
        return switch (code) {
            0 => 0x808080,
            1 => 0xFF0000,
            2 => 0x00FF00,
            3 => 0xFFFF00,
            4 => 0x0000FF,
            5 => 0xFF00FF,
            6 => 0x00FFFF,
            7 => 0xFFFFFF,
            else => 0xFFFFFF,
        };
    }

    pub fn reset(self: *Terminal) void {
        self.resetAttrs();
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_visible = true;
        self.clearAll();
    }

    pub fn resetAttrs(self: *Terminal) void {
        self.fg = 0xCCCCCC;
        self.bg = 0x1E1E1E;
        self.bold = false;
        self.inverse = false;
    }

    pub fn clearAll(self: *Terminal) void {
        for (self.cells) |*c| {
            c.* = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
    }

    pub fn clearFromCursor(self: *Terminal) void {
        const start = self.cursor_row * self.cols + self.cursor_col;
        const end = self.cursor_row * self.cols + self.cols;
        for (start..end) |i| {
            self.cells[i] = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
    }

    pub fn clearToCursor(self: *Terminal) void {
        const start = self.cursor_row * self.cols;
        const end = self.cursor_row * self.cols + self.cursor_col;
        for (start..end) |i| {
            self.cells[i] = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
    }

    pub fn clearLineFromCursor(self: *Terminal) void {
        const start = self.cursor_row * self.cols + self.cursor_col;
        const end = self.cursor_row * self.cols + self.cols;
        for (start..end) |i| {
            self.cells[i] = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
    }

    pub fn clearLineToCursor(self: *Terminal) void {
        const start = self.cursor_row * self.cols;
        const end = self.cursor_row * self.cols + self.cursor_col;
        for (start..end) |i| {
            self.cells[i] = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
    }

    pub fn clearLine(self: *Terminal) void {
        const start = self.cursor_row * self.cols;
        const end = start + self.cols;
        for (start..end) |i| {
            self.cells[i] = Cell{ .ch = ' ', .fg = self.fg, .bg = self.bg, .bold = false, .inverse = false };
        }
    }

    pub fn write(self: *Terminal, buf: []const u8) void {
        var i: usize = 0;
        while (i < buf.len) {
            if (buf[i] == 0x1b) {
                self.handleEscape(buf, &i);
            } else {
                self.putChar(buf[i]);
                i += 1;
            }
        }
    }
};

test "terminal init" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    try std.testing.expect(term.cols == 80);
    try std.testing.expect(term.rows == 24);
    try std.testing.expect(term.cells.len == 80 * 24);
}

test "terminal put char" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.putChar('H');
    term.putChar('i');
    try std.testing.expect(term.cells[0].ch == 'H');
    try std.testing.expect(term.cells[1].ch == 'i');
    try std.testing.expect(term.cursor_col == 2);
}

test "terminal newline" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('\n');
    try std.testing.expect(term.cursor_row == 1);
    try std.testing.expect(term.cursor_col == 0);
    try std.testing.expect(term.cells[80].ch == ' ');
}

test "terminal carriage return" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('B');
    term.putChar('\r');
    try std.testing.expect(term.cursor_col == 0);
    term.putChar('C');
    try std.testing.expect(term.cells[0].ch == 'C');
}

test "terminal tab" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('\t');
    try std.testing.expect(term.cursor_col == 8);
}

test "terminal cursor movement" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.cursor_row = 5;
    term.cursor_col = 10;
    var buf: [4]u8 = .{0} ** 4;
    std.mem.copyForwards(u8, &buf, "\x1b[1A");
    var pos: usize = 0;
    term.handleEscape(buf[0..4], &pos);
    try std.testing.expect(term.cursor_row == 4);

    std.mem.copyForwards(u8, &buf, "\x1b[2B");
    pos = 0;
    term.handleEscape(buf[0..4], &pos);
    try std.testing.expect(term.cursor_row == 6);

    std.mem.copyForwards(u8, &buf, "\x1b[3C");
    pos = 0;
    term.handleEscape(buf[0..4], &pos);
    try std.testing.expect(term.cursor_col == 13);

    std.mem.copyForwards(u8, &buf, "\x1b[4D");
    pos = 0;
    term.handleEscape(buf[0..4], &pos);
    try std.testing.expect(term.cursor_col == 9);
}

test "terminal home and end" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.cursor_row = 5;
    term.cursor_col = 10;
    var buf: [8]u8 = .{0} ** 8;
    std.mem.copyForwards(u8, &buf, "\x1b[H");
    var pos: usize = 0;
    term.handleEscape(buf[0..3], &pos);
    try std.testing.expect(term.cursor_row == 0);
    try std.testing.expect(term.cursor_col == 0);

    std.mem.copyForwards(u8, &buf, "\x1b[10;5H");
    pos = 0;
    term.handleEscape(buf[0..8], &pos);
    try std.testing.expect(term.cursor_row == 9);
    try std.testing.expect(term.cursor_col == 4);
}

test "terminal clear screen" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('B');
    const buf = "\x1b[2J";
    var pos: usize = 0;
    term.handleEscape(buf[0..], &pos);
    try std.testing.expect(term.cells[0].ch == ' ');
    try std.testing.expect(term.cells[1].ch == ' ');
}

test "terminal clear line" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('B');
    term.putChar('C');
    const buf = "\x1b[2K";
    var pos: usize = 0;
    term.handleEscape(buf[0..], &pos);
    try std.testing.expect(term.cells[0].ch == ' ');
    try std.testing.expect(term.cells[1].ch == ' ');
    try std.testing.expect(term.cells[2].ch == ' ');
}

test "terminal sgr bold" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    var buf: [6]u8 = .{0} ** 6;
    std.mem.copyForwards(u8, &buf, "\x1b[1m");
    var pos: usize = 0;
    term.handleEscape(buf[0..4], &pos);
    try std.testing.expect(term.bold == true);
    term.putChar('X');
    try std.testing.expect(term.cells[0].bold == true);

    std.mem.copyForwards(u8, &buf, "\x1b[22m");
    pos = 0;
    term.handleEscape(buf[0..5], &pos);
    try std.testing.expect(term.bold == false);
}

test "terminal sgr color" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    var buf: [19]u8 = .{0} ** 19;
    std.mem.copyForwards(u8, &buf, "\x1b[31m");
    var pos: usize = 0;
    term.handleEscape(buf[0..5], &pos);
    try std.testing.expect(term.fg == 0x800000);

    std.mem.copyForwards(u8, &buf, "\x1b[38;2;255;128;0m");
    pos = 0;
    term.handleEscape(buf[0..19], &pos);
    try std.testing.expect(term.fg == 0xFF8000);
}

test "terminal sgr inverse" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    var buf: [6]u8 = .{0} ** 6;
    std.mem.copyForwards(u8, &buf, "\x1b[7m");
    var pos: usize = 0;
    term.handleEscape(buf[0..4], &pos);
    try std.testing.expect(term.inverse == true);

    std.mem.copyForwards(u8, &buf, "\x1b[27m");
    pos = 0;
    term.handleEscape(buf[0..5], &pos);
    try std.testing.expect(term.inverse == false);
}

test "terminal scroll" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(5, 3, gpa);
    defer term.deinit(gpa);
    for (0..15) |i| {
        term.putChar(@as(u21, @intCast('A' + (i % 26))));
    }
    try std.testing.expect(term.cursor_row == 2);
    try std.testing.expect(term.cells[0].ch == 'F');
    try std.testing.expect(term.cells[1].ch == 'G');
    try std.testing.expect(term.cells[2].ch == 'H');
    try std.testing.expect(term.cells[3].ch == 'I');
    try std.testing.expect(term.cells[4].ch == 'J');
    try std.testing.expect(term.cells[5].ch == 'K');
    try std.testing.expect(term.cells[6].ch == 'L');
    try std.testing.expect(term.cells[7].ch == 'M');
    try std.testing.expect(term.cells[8].ch == 'N');
    try std.testing.expect(term.cells[9].ch == 'O');
    try std.testing.expect(term.cells[10].ch == ' ');
    try std.testing.expect(term.cells[14].ch == ' ');
}

test "terminal write" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    const input = "Hello\nWorld";
    term.write(input);
    try std.testing.expect(term.cells[0].ch == 'H');
    try std.testing.expect(term.cells[1].ch == 'e');
    try std.testing.expect(term.cells[2].ch == 'l');
    try std.testing.expect(term.cells[3].ch == 'l');
    try std.testing.expect(term.cells[4].ch == 'o');
    try std.testing.expect(term.cells[80].ch == 'W');
    try std.testing.expect(term.cells[81].ch == 'o');
    try std.testing.expect(term.cells[82].ch == 'r');
    try std.testing.expect(term.cells[83].ch == 'l');
    try std.testing.expect(term.cells[84].ch == 'd');
}

test "terminal resize" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('B');
    try term.resize(40, 12, gpa);
    try std.testing.expect(term.cols == 40);
    try std.testing.expect(term.rows == 12);
    try std.testing.expect(term.cells.len == 40 * 12);
    try std.testing.expect(term.cells[0].ch == 'A');
    try std.testing.expect(term.cells[1].ch == 'B');
}

test "terminal clear from cursor" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(10, 3, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('B');
    term.putChar('C');
    term.putChar('D');
    term.putChar('E');
    const buf = "\x1b[0K";
    var pos: usize = 0;
    term.handleEscape(buf[0..], &pos);
    try std.testing.expect(term.cells[0].ch == 'A');
    try std.testing.expect(term.cells[1].ch == 'B');
    try std.testing.expect(term.cells[2].ch == 'C');
    try std.testing.expect(term.cells[3].ch == 'D');
    try std.testing.expect(term.cells[4].ch == 'E');
    try std.testing.expect(term.cells[5].ch == ' ');
    try std.testing.expect(term.cells[9].ch == ' ');
}

test "terminal clear to cursor" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(10, 3, gpa);
    defer term.deinit(gpa);
    term.putChar('A');
    term.putChar('B');
    term.putChar('C');
    term.putChar('D');
    term.putChar('E');
    const buf = "\x1b[1K";
    var pos: usize = 0;
    term.handleEscape(buf[0..], &pos);
    try std.testing.expect(term.cells[0].ch == ' ');
    try std.testing.expect(term.cells[1].ch == ' ');
    try std.testing.expect(term.cells[2].ch == ' ');
    try std.testing.expect(term.cells[3].ch == ' ');
    try std.testing.expect(term.cells[4].ch == ' ');
}

test "terminal reset" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    term.cursor_row = 10;
    term.cursor_col = 20;
    term.bold = true;
    term.fg = 0xFF0000;
    const buf = "\x1bc";
    var pos: usize = 0;
    term.handleEscape(buf[0..], &pos);
    try std.testing.expect(term.cursor_row == 0);
    try std.testing.expect(term.cursor_col == 0);
    try std.testing.expect(term.bold == false);
    try std.testing.expect(term.fg == 0xCCCCCC);
}

test "terminal osc" {
    const gpa = std.testing.allocator;
    var term = try Terminal.init(80, 24, gpa);
    defer term.deinit(gpa);
    const buf = "\x1b]0;title\x07";
    var pos: usize = 0;
    term.handleEscape(buf, &pos);
    try std.testing.expect(pos == buf.len);
}
