//! Screen model and VT/xterm escape-sequence parser.
//!
//! The parser is a state machine that survives buffer boundaries: a pty read
//! can split an escape sequence or a UTF-8 code point anywhere, so no decoding
//! state may live on the stack of `write`.
//!
//! Cells store *palette references* rather than resolved RGB, so switching the
//! theme recolours text that is already on screen.

const std = @import("std");
const theme = @import("theme");

/// How a cell's colour is chosen. Only 256-colour and truecolor escapes pin a
/// literal value; everything else defers to the active theme.
pub const Color = union(enum) {
    default,
    /// Index into the 256-colour cube; 0-15 come from the theme's ANSI palette.
    indexed: u8,
    rgb: u24,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |x| b == .indexed and b.indexed == x,
            .rgb => |x| b == .rgb and b.rgb == x,
        };
    }
};

pub const Attrs = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strike: bool = false,
    hidden: bool = false,
    _pad: u1 = 0,
};

pub const Cell = struct {
    ch: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    pub const blank = Cell{};
};

/// Cursor position plus the attributes saved by DECSC / restored by DECRC.
const SavedCursor = struct {
    row: u32 = 0,
    col: u32 = 0,
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
};

const ParseState = enum {
    ground,
    esc,
    csi,
    osc,
    /// DCS/SOS/PM/APC: consumed and discarded up to the string terminator.
    dcs,
    /// Character-set designators such as `ESC ( B` — one byte to swallow.
    charset,
};

pub const MAX_PARAMS = 16;
pub const MAX_TITLE = 128;

pub const Terminal = struct {
    gpa: std.mem.Allocator,

    cols: u32,
    rows: u32,
    cells: []Cell,

    cursor_row: u32 = 0,
    cursor_col: u32 = 0,
    cursor_visible: bool = true,
    /// Set by the last printed glyph reaching the right margin; the wrap only
    /// happens when another glyph arrives (DEC "pending wrap").
    wrap_pending: bool = false,

    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    /// Inclusive scrolling region (DECSTBM).
    scroll_top: u32 = 0,
    scroll_bot: u32 = 0,

    saved: SavedCursor = .{},

    /// Alternate screen buffer (DECSET 1049), used by full-screen programs.
    alt: ?[]Cell = null,
    alt_saved: SavedCursor = .{},

    /// Ring of scrolled-off rows, `sb_cap` rows of `cols` cells.
    sb: []Cell,
    sb_cap: u32,
    sb_head: u32 = 0,
    sb_len: u32 = 0,
    /// Rows the viewport is scrolled back from the live screen.
    view_offset: u32 = 0,

    /// Window title from OSC 0/1/2, used as the tab label.
    title: [MAX_TITLE]u8 = [_]u8{0} ** MAX_TITLE,
    title_len: usize = 0,

    /// True whenever the screen changed since the renderer last cleared it.
    dirty: bool = true,
    /// Set by BEL; the caller may flash the tab.
    bell: bool = false,

    state: ParseState = .ground,
    params: [MAX_PARAMS]u32 = [_]u32{0} ** MAX_PARAMS,
    param_count: usize = 0,
    param_active: bool = false,
    /// CSI private marker such as `?` in `ESC [ ? 25 l`.
    csi_private: u8 = 0,
    osc_buf: [MAX_TITLE]u8 = [_]u8{0} ** MAX_TITLE,
    osc_len: usize = 0,
    /// Partially received UTF-8 sequence carried across `write` calls.
    utf8: [4]u8 = [_]u8{0} ** 4,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,

    pub const DEFAULT_SCROLLBACK: u32 = 2000;

    pub fn init(gpa: std.mem.Allocator, cols: u32, rows: u32, scrollback_rows: u32) !Terminal {
        const c = @max(cols, 1);
        const r = @max(rows, 1);

        const cells = try gpa.alloc(Cell, c * r);
        errdefer gpa.free(cells);
        @memset(cells, Cell.blank);

        const sb = try gpa.alloc(Cell, c * scrollback_rows);
        errdefer gpa.free(sb);
        @memset(sb, Cell.blank);

        return .{
            .gpa = gpa,
            .cols = c,
            .rows = r,
            .cells = cells,
            .scroll_bot = r - 1,
            .sb = sb,
            .sb_cap = scrollback_rows,
        };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.alt) |a| self.gpa.free(a);
        self.gpa.free(self.sb);
        self.gpa.free(self.cells);
        self.* = undefined;
    }

    // -- geometry ----------------------------------------------------------

    fn idx(self: *const Terminal, row: u32, col: u32) usize {
        return @as(usize, row) * self.cols + col;
    }

    pub fn cellAt(self: *const Terminal, row: u32, col: u32) Cell {
        if (row >= self.rows or col >= self.cols) return Cell.blank;
        return self.cells[self.idx(row, col)];
    }

    /// Resizes the grid, keeping the top-left content. Scrollback is dropped
    /// when the width changes because stored rows are width-indexed.
    pub fn resize(self: *Terminal, cols: u32, rows: u32) !void {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        if (c == self.cols and r == self.rows) return;

        // Every buffer is allocated before any of them is installed, so a
        // failure part-way through leaves the terminal exactly as it was
        // rather than with buffers of mismatched sizes.
        const new_cells = try self.gpa.alloc(Cell, c * r);
        errdefer self.gpa.free(new_cells);
        @memset(new_cells, Cell.blank);

        const new_alt: ?[]Cell = if (self.alt != null) blk: {
            const a = try self.gpa.alloc(Cell, c * r);
            @memset(a, Cell.blank);
            break :blk a;
        } else null;
        errdefer if (new_alt) |a| self.gpa.free(a);

        const new_sb: ?[]Cell = if (c != self.cols) blk: {
            const sb = try self.gpa.alloc(Cell, c * self.sb_cap);
            @memset(sb, Cell.blank);
            break :blk sb;
        } else null;

        const copy_rows = @min(self.rows, r);
        const copy_cols = @min(self.cols, c);
        for (0..copy_rows) |row| {
            const src = self.cells[self.idx(@intCast(row), 0)..][0..copy_cols];
            @memcpy(new_cells[row * c ..][0..copy_cols], src);
        }

        if (new_alt) |a| {
            self.gpa.free(self.alt.?);
            self.alt = a;
        }
        if (new_sb) |sb| {
            // Stored rows are indexed by width, so a width change invalidates
            // the whole history.
            self.gpa.free(self.sb);
            self.sb = sb;
            self.sb_head = 0;
            self.sb_len = 0;
            self.view_offset = 0;
        }

        self.gpa.free(self.cells);
        self.cells = new_cells;
        self.cols = c;
        self.rows = r;
        self.cursor_row = @min(self.cursor_row, r - 1);
        self.cursor_col = @min(self.cursor_col, c - 1);
        self.scroll_top = 0;
        self.scroll_bot = r - 1;
        self.wrap_pending = false;
        self.dirty = true;
    }

    // -- scrollback --------------------------------------------------------

    fn pushScrollback(self: *Terminal, row: u32) void {
        if (self.sb_cap == 0 or self.alt != null) return;
        const dst = @as(usize, self.sb_head) * self.cols;
        @memcpy(self.sb[dst..][0..self.cols], self.cells[self.idx(row, 0)..][0..self.cols]);
        self.sb_head = (self.sb_head + 1) % self.sb_cap;
        if (self.sb_len < self.sb_cap) self.sb_len += 1;
        // Keep the viewport anchored to the same text while it is scrolled back.
        if (self.view_offset > 0 and self.view_offset < self.sb_len) self.view_offset += 1;
    }

    /// Row `n` rows above the live screen top; null once past the history.
    pub fn scrollbackRow(self: *const Terminal, n: u32) ?[]const Cell {
        if (n == 0 or n > self.sb_len) return null;
        const slot = (self.sb_head + self.sb_cap - n) % self.sb_cap;
        return self.sb[@as(usize, slot) * self.cols ..][0..self.cols];
    }

    /// Visible row `row`, honouring the scrollback viewport.
    pub fn viewRow(self: *const Terminal, row: u32) []const Cell {
        if (self.view_offset > row) {
            const back = self.view_offset - row;
            if (self.scrollbackRow(back)) |r| return r;
        }
        const live = row - @min(self.view_offset, row);
        return self.cells[self.idx(live, 0)..][0..self.cols];
    }

    pub fn scrollView(self: *Terminal, delta: i32) void {
        const max_off = self.sb_len;
        var off: i64 = @as(i64, self.view_offset) + delta;
        off = std.math.clamp(off, 0, @as(i64, max_off));
        const new: u32 = @intCast(off);
        if (new != self.view_offset) {
            self.view_offset = new;
            self.dirty = true;
        }
    }

    pub fn scrollToBottom(self: *Terminal) void {
        if (self.view_offset != 0) {
            self.view_offset = 0;
            self.dirty = true;
        }
    }

    // -- screen operations -------------------------------------------------

    fn blankCell(self: *const Terminal) Cell {
        // Erased cells keep the current background (so `clear` on a coloured
        // background fills correctly) but never inherit text attributes.
        return .{ .ch = ' ', .fg = .default, .bg = self.bg, .attrs = .{} };
    }

    fn eraseRange(self: *Terminal, start: usize, end: usize) void {
        const blank = self.blankCell();
        for (self.cells[start..end]) |*c| c.* = blank;
    }

    /// Scrolls the scrolling region up by one, retiring the top row to history
    /// when the region covers the whole screen.
    pub fn scrollUp(self: *Terminal) void {
        self.scrollUpRegion(true);
    }

    /// `to_history` is false for the line-editing operations (IL/DL), which
    /// rearrange the screen rather than advancing past content: rows they push
    /// off the region are discarded, not scrolled back into.
    fn scrollUpRegion(self: *Terminal, to_history: bool) void {
        if (to_history and self.scroll_top == 0 and self.scroll_bot == self.rows - 1) {
            self.pushScrollback(0);
        }
        var r = self.scroll_top;
        while (r < self.scroll_bot) : (r += 1) {
            const dst = self.idx(r, 0);
            const src = self.idx(r + 1, 0);
            @memcpy(self.cells[dst..][0..self.cols], self.cells[src..][0..self.cols]);
        }
        const last = self.idx(self.scroll_bot, 0);
        self.eraseRange(last, last + self.cols);
        self.dirty = true;
    }

    pub fn scrollDown(self: *Terminal) void {
        var r = self.scroll_bot;
        while (r > self.scroll_top) : (r -= 1) {
            const dst = self.idx(r, 0);
            const src = self.idx(r - 1, 0);
            @memcpy(self.cells[dst..][0..self.cols], self.cells[src..][0..self.cols]);
        }
        const first = self.idx(self.scroll_top, 0);
        self.eraseRange(first, first + self.cols);
        self.dirty = true;
    }

    pub fn newline(self: *Terminal) void {
        self.wrap_pending = false;
        if (self.cursor_row == self.scroll_bot) {
            self.scrollUp();
        } else if (self.cursor_row + 1 < self.rows) {
            self.cursor_row += 1;
        }
    }

    pub fn putChar(self: *Terminal, ch: u21) void {
        if (self.wrap_pending) {
            self.cursor_col = 0;
            self.newline();
        }
        self.cells[self.idx(self.cursor_row, self.cursor_col)] = .{
            .ch = ch,
            .fg = self.fg,
            .bg = self.bg,
            .attrs = self.attrs,
        };
        if (self.cursor_col + 1 >= self.cols) {
            self.wrap_pending = true;
        } else {
            self.cursor_col += 1;
        }
        self.dirty = true;
    }

    fn backspace(self: *Terminal) void {
        self.wrap_pending = false;
        if (self.cursor_col > 0) self.cursor_col -= 1;
    }

    fn tab(self: *Terminal) void {
        self.wrap_pending = false;
        const next = ((self.cursor_col / 8) + 1) * 8;
        self.cursor_col = @min(next, self.cols - 1);
    }

    pub fn eraseInDisplay(self: *Terminal, mode: u32) void {
        const cur = self.idx(self.cursor_row, self.cursor_col);
        switch (mode) {
            0 => self.eraseRange(cur, self.cells.len),
            1 => self.eraseRange(0, cur + 1),
            2, 3 => self.eraseRange(0, self.cells.len),
            else => {},
        }
        self.dirty = true;
    }

    pub fn eraseInLine(self: *Terminal, mode: u32) void {
        const row_start = self.idx(self.cursor_row, 0);
        const row_end = row_start + self.cols;
        const cur = row_start + self.cursor_col;
        switch (mode) {
            0 => self.eraseRange(cur, row_end),
            1 => self.eraseRange(row_start, cur + 1),
            2 => self.eraseRange(row_start, row_end),
            else => {},
        }
        self.dirty = true;
    }

    /// ICH: shifts the rest of the line right, inserting `n` blanks.
    fn insertChars(self: *Terminal, n: u32) void {
        const count = @min(n, self.cols - self.cursor_col);
        const row = self.idx(self.cursor_row, 0);
        var c = self.cols;
        while (c > self.cursor_col + count) {
            c -= 1;
            self.cells[row + c] = self.cells[row + c - count];
        }
        self.eraseRange(row + self.cursor_col, row + self.cursor_col + count);
        self.dirty = true;
    }

    /// DCH: shifts the rest of the line left over `n` characters.
    fn deleteChars(self: *Terminal, n: u32) void {
        const count = @min(n, self.cols - self.cursor_col);
        const row = self.idx(self.cursor_row, 0);
        var c = self.cursor_col;
        while (c + count < self.cols) : (c += 1) {
            self.cells[row + c] = self.cells[row + c + count];
        }
        self.eraseRange(row + self.cols - count, row + self.cols);
        self.dirty = true;
    }

    /// ECH: overwrites `n` characters with blanks, leaving the cursor put.
    fn eraseChars(self: *Terminal, n: u32) void {
        const count = @min(n, self.cols - self.cursor_col);
        const start = self.idx(self.cursor_row, self.cursor_col);
        self.eraseRange(start, start + count);
        self.dirty = true;
    }

    /// IL / DL, which operate within the scrolling region.
    fn insertLines(self: *Terminal, n: u32) void {
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bot) return;
        const saved_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        for (0..@min(n, self.scroll_bot - self.cursor_row + 1)) |_| self.scrollDown();
        self.scroll_top = saved_top;
    }

    fn deleteLines(self: *Terminal, n: u32) void {
        if (self.cursor_row < self.scroll_top or self.cursor_row > self.scroll_bot) return;
        const saved_top = self.scroll_top;
        self.scroll_top = self.cursor_row;
        for (0..@min(n, self.scroll_bot - self.cursor_row + 1)) |_| self.scrollUpRegion(false);
        self.scroll_top = saved_top;
    }

    pub fn resetAttrs(self: *Terminal) void {
        self.fg = .default;
        self.bg = .default;
        self.attrs = .{};
    }

    pub fn reset(self: *Terminal) void {
        self.resetAttrs();
        self.leaveAltScreen();
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_visible = true;
        self.wrap_pending = false;
        self.scroll_top = 0;
        self.scroll_bot = self.rows - 1;
        self.saved = .{};
        self.eraseRange(0, self.cells.len);
        self.dirty = true;
    }

    fn enterAltScreen(self: *Terminal) void {
        if (self.alt != null) return;
        const alt = self.gpa.alloc(Cell, self.cells.len) catch return;
        @memset(alt, Cell.blank);
        self.alt_saved = .{
            .row = self.cursor_row,
            .col = self.cursor_col,
            .fg = self.fg,
            .bg = self.bg,
            .attrs = self.attrs,
        };
        // `alt` holds the buffer being swapped out; `cells` stays the live one.
        @memcpy(alt, self.cells);
        self.alt = alt;
        self.eraseRange(0, self.cells.len);
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.view_offset = 0;
        self.dirty = true;
    }

    fn leaveAltScreen(self: *Terminal) void {
        const alt = self.alt orelse return;
        @memcpy(self.cells, alt);
        self.gpa.free(alt);
        self.alt = null;
        self.cursor_row = @min(self.alt_saved.row, self.rows - 1);
        self.cursor_col = @min(self.alt_saved.col, self.cols - 1);
        self.fg = self.alt_saved.fg;
        self.bg = self.alt_saved.bg;
        self.attrs = self.alt_saved.attrs;
        self.dirty = true;
    }

    pub fn onAltScreen(self: *const Terminal) bool {
        return self.alt != null;
    }

    pub fn titleSlice(self: *const Terminal) []const u8 {
        return self.title[0..self.title_len];
    }

    // -- colour resolution -------------------------------------------------

    /// Resolves a cell's colours against `th`, applying inverse and dim.
    pub fn resolve(cell: Cell, th: *const theme.Theme) struct { fg: u32, bg: u32 } {
        var fg = resolveColor(cell.fg, th, th.fg);
        var bg = resolveColor(cell.bg, th, th.bg);
        if (cell.attrs.inverse) std.mem.swap(u32, &fg, &bg);
        if (cell.attrs.hidden) fg = bg;
        if (cell.attrs.dim) fg = blend(fg, bg, 0.55);
        return .{ .fg = fg, .bg = bg };
    }

    fn resolveColor(c: Color, th: *const theme.Theme, fallback: u32) u32 {
        return switch (c) {
            .default => fallback,
            .rgb => |v| @intCast(v),
            .indexed => |i| xterm256(i, th),
        };
    }

    /// The xterm 256-colour cube: 0-15 from the theme, 16-231 a 6x6x6 cube,
    /// 232-255 a 24-step greyscale ramp.
    pub fn xterm256(i: u8, th: *const theme.Theme) u32 {
        if (i < 16) return th.ansi[i];
        if (i < 232) {
            const n = i - 16;
            const levels = [_]u32{ 0, 95, 135, 175, 215, 255 };
            const r = levels[n / 36];
            const g = levels[(n / 6) % 6];
            const b = levels[n % 6];
            return (r << 16) | (g << 8) | b;
        }
        const v: u32 = 8 + @as(u32, i - 232) * 10;
        return (v << 16) | (v << 8) | v;
    }

    fn blend(a: u32, b: u32, t: f32) u32 {
        const mix = struct {
            fn f(x: u32, y: u32, k: f32) u32 {
                const fx = @as(f32, @floatFromInt(x));
                const fy = @as(f32, @floatFromInt(y));
                return @intFromFloat(@round(fx * k + fy * (1 - k)));
            }
        }.f;
        const r = mix((a >> 16) & 0xff, (b >> 16) & 0xff, t);
        const g = mix((a >> 8) & 0xff, (b >> 8) & 0xff, t);
        const bl = mix(a & 0xff, b & 0xff, t);
        return (r << 16) | (g << 8) | bl;
    }

    // -- parser ------------------------------------------------------------

    /// Feeds bytes from the pty. Safe to call with a sequence split anywhere.
    pub fn write(self: *Terminal, buf: []const u8) void {
        for (buf) |byte| self.feed(byte);
    }

    fn feed(self: *Terminal, byte: u8) void {
        switch (self.state) {
            .ground => self.feedGround(byte),
            .esc => self.feedEsc(byte),
            .csi => self.feedCsi(byte),
            .osc => self.feedOsc(byte),
            .dcs => self.feedString(byte),
            .charset => self.state = .ground,
        }
    }

    fn feedGround(self: *Terminal, byte: u8) void {
        if (self.utf8_need > 0) {
            if (byte & 0xC0 == 0x80) {
                self.utf8[self.utf8_len] = byte;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    const cp = std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch
                        std.unicode.replacement_character;
                    self.utf8_len = 0;
                    self.utf8_need = 0;
                    self.putChar(cp);
                }
                return;
            }
            // Malformed: abandon the partial sequence and reprocess this byte.
            self.utf8_len = 0;
            self.utf8_need = 0;
            self.putChar(std.unicode.replacement_character);
        }

        switch (byte) {
            0x00 => {},
            0x07 => self.bell = true,
            0x08 => self.backspace(),
            0x09 => self.tab(),
            0x0A, 0x0B, 0x0C => self.newline(),
            0x0D => {
                self.cursor_col = 0;
                self.wrap_pending = false;
            },
            0x0E, 0x0F => {}, // shift out / shift in: charsets are not tracked
            0x1B => {
                self.state = .esc;
                self.scrollToBottom();
            },
            0x7F => {}, // DEL is ignored, as on a real terminal
            else => {
                if (byte < 0x20) return;
                if (byte < 0x80) {
                    self.putChar(byte);
                    return;
                }
                const need = std.unicode.utf8ByteSequenceLength(byte) catch {
                    self.putChar(std.unicode.replacement_character);
                    return;
                };
                self.utf8[0] = byte;
                self.utf8_len = 1;
                self.utf8_need = @intCast(need);
            },
        }
    }

    fn feedEsc(self: *Terminal, byte: u8) void {
        switch (byte) {
            '[' => {
                self.params = [_]u32{0} ** MAX_PARAMS;
                self.param_count = 0;
                self.param_active = false;
                self.csi_private = 0;
                self.state = .csi;
            },
            ']' => {
                self.osc_len = 0;
                self.state = .osc;
            },
            'P', 'X', '^', '_' => self.state = .dcs,
            '(', ')', '*', '+' => self.state = .charset,
            'c' => {
                self.reset();
                self.state = .ground;
            },
            '7' => {
                self.saveCursor();
                self.state = .ground;
            },
            '8' => {
                self.restoreCursor();
                self.state = .ground;
            },
            'D' => {
                self.newline();
                self.state = .ground;
            },
            'E' => {
                self.cursor_col = 0;
                self.newline();
                self.state = .ground;
            },
            'M' => {
                // Reverse index: scroll down when already at the top margin.
                if (self.cursor_row == self.scroll_top) {
                    self.scrollDown();
                } else if (self.cursor_row > 0) {
                    self.cursor_row -= 1;
                }
                self.state = .ground;
            },
            else => self.state = .ground,
        }
    }

    fn feedCsi(self: *Terminal, byte: u8) void {
        switch (byte) {
            '0'...'9' => {
                if (self.param_count < MAX_PARAMS) {
                    if (!self.param_active) {
                        self.params[self.param_count] = 0;
                        self.param_count += 1;
                        self.param_active = true;
                    }
                    const p = &self.params[self.param_count - 1];
                    // Saturate rather than wrap on absurd parameter values.
                    p.* = std.math.mul(u32, p.*, 10) catch std.math.maxInt(u32);
                    p.* = std.math.add(u32, p.*, byte - '0') catch std.math.maxInt(u32);
                }
            },
            ';' => {
                if (!self.param_active and self.param_count < MAX_PARAMS) {
                    self.params[self.param_count] = 0;
                    self.param_count += 1;
                }
                self.param_active = false;
            },
            '?', '>', '<', '=' => self.csi_private = byte,
            // Intermediate bytes (space through '/') carry no meaning here.
            0x20...0x2F => {},
            0x40...0x7E => {
                self.dispatchCsi(byte);
                self.state = .ground;
            },
            else => self.state = .ground,
        }
    }

    /// Parameter `n`, defaulting to `def` when absent or zero.
    fn param(self: *const Terminal, n: usize, def: u32) u32 {
        if (n >= self.param_count) return def;
        const v = self.params[n];
        return if (v == 0) def else v;
    }

    fn paramRaw(self: *const Terminal, n: usize, def: u32) u32 {
        if (n >= self.param_count) return def;
        return self.params[n];
    }

    fn dispatchCsi(self: *Terminal, final: u8) void {
        if (self.csi_private == '?') {
            switch (final) {
                'h' => self.setPrivateMode(true),
                'l' => self.setPrivateMode(false),
                else => {},
            }
            return;
        }
        if (self.csi_private != 0) return;

        self.wrap_pending = false;
        switch (final) {
            'A' => self.cursor_row -|= self.param(0, 1),
            'B' => self.cursor_row = @min(self.rows - 1, self.cursor_row + self.param(0, 1)),
            'C' => self.cursor_col = @min(self.cols - 1, self.cursor_col + self.param(0, 1)),
            'D' => self.cursor_col -|= self.param(0, 1),
            'E' => { // CNL
                self.cursor_col = 0;
                self.cursor_row = @min(self.rows - 1, self.cursor_row + self.param(0, 1));
            },
            'F' => { // CPL
                self.cursor_col = 0;
                self.cursor_row -|= self.param(0, 1);
            },
            'G', '`' => self.cursor_col = @min(self.cols - 1, self.param(0, 1) - 1),
            'd' => self.cursor_row = @min(self.rows - 1, self.param(0, 1) - 1),
            'H', 'f' => {
                self.cursor_row = @min(self.rows - 1, self.param(0, 1) - 1);
                self.cursor_col = @min(self.cols - 1, self.param(1, 1) - 1);
            },
            'J' => self.eraseInDisplay(self.paramRaw(0, 0)),
            'K' => self.eraseInLine(self.paramRaw(0, 0)),
            'L' => self.insertLines(self.param(0, 1)),
            'M' => self.deleteLines(self.param(0, 1)),
            'P' => self.deleteChars(self.param(0, 1)),
            'X' => self.eraseChars(self.param(0, 1)),
            '@' => self.insertChars(self.param(0, 1)),
            'S' => for (0..self.param(0, 1)) |_| self.scrollUp(),
            'T' => for (0..self.param(0, 1)) |_| self.scrollDown(),
            'm' => self.applySgr(),
            'r' => {
                const top = self.param(0, 1) - 1;
                const bot = self.param(1, self.rows) - 1;
                if (top < bot and bot < self.rows) {
                    self.scroll_top = top;
                    self.scroll_bot = bot;
                    self.cursor_row = top;
                    self.cursor_col = 0;
                }
            },
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            else => {},
        }
        self.dirty = true;
    }

    fn setPrivateMode(self: *Terminal, on: bool) void {
        for (self.params[0..self.param_count]) |mode| {
            switch (mode) {
                25 => self.cursor_visible = on, // DECTCEM
                1049, 1047, 47 => if (on) self.enterAltScreen() else self.leaveAltScreen(),
                else => {},
            }
        }
        self.dirty = true;
    }

    fn saveCursor(self: *Terminal) void {
        self.saved = .{
            .row = self.cursor_row,
            .col = self.cursor_col,
            .fg = self.fg,
            .bg = self.bg,
            .attrs = self.attrs,
        };
    }

    fn restoreCursor(self: *Terminal) void {
        self.cursor_row = @min(self.saved.row, self.rows - 1);
        self.cursor_col = @min(self.saved.col, self.cols - 1);
        self.fg = self.saved.fg;
        self.bg = self.saved.bg;
        self.attrs = self.saved.attrs;
        self.wrap_pending = false;
    }

    fn applySgr(self: *Terminal) void {
        if (self.param_count == 0) {
            self.resetAttrs();
            return;
        }
        var i: usize = 0;
        while (i < self.param_count) : (i += 1) {
            switch (self.params[i]) {
                0 => self.resetAttrs(),
                1 => self.attrs.bold = true,
                2 => self.attrs.dim = true,
                3 => self.attrs.italic = true,
                4 => self.attrs.underline = true,
                7 => self.attrs.inverse = true,
                8 => self.attrs.hidden = true,
                9 => self.attrs.strike = true,
                21, 22 => {
                    self.attrs.bold = false;
                    self.attrs.dim = false;
                },
                23 => self.attrs.italic = false,
                24 => self.attrs.underline = false,
                27 => self.attrs.inverse = false,
                28 => self.attrs.hidden = false,
                29 => self.attrs.strike = false,
                30...37 => self.fg = .{ .indexed = @intCast(self.params[i] - 30) },
                38 => self.fg = self.extendedColor(&i) orelse self.fg,
                39 => self.fg = .default,
                40...47 => self.bg = .{ .indexed = @intCast(self.params[i] - 40) },
                48 => self.bg = self.extendedColor(&i) orelse self.bg,
                49 => self.bg = .default,
                90...97 => self.fg = .{ .indexed = @intCast(self.params[i] - 90 + 8) },
                100...107 => self.bg = .{ .indexed = @intCast(self.params[i] - 100 + 8) },
                else => {},
            }
        }
    }

    /// Consumes the tail of `38;…` / `48;…`, advancing `i` past what it uses.
    fn extendedColor(self: *const Terminal, i: *usize) ?Color {
        if (i.* + 1 >= self.param_count) return null;
        switch (self.params[i.* + 1]) {
            2 => { // 38;2;R;G;B
                if (i.* + 4 >= self.param_count) {
                    i.* = self.param_count;
                    return null;
                }
                const r: u24 = @intCast(@min(self.params[i.* + 2], 255));
                const g: u24 = @intCast(@min(self.params[i.* + 3], 255));
                const b: u24 = @intCast(@min(self.params[i.* + 4], 255));
                i.* += 4;
                return .{ .rgb = (r << 16) | (g << 8) | b };
            },
            5 => { // 38;5;N
                if (i.* + 2 >= self.param_count) {
                    i.* = self.param_count;
                    return null;
                }
                const n: u8 = @intCast(@min(self.params[i.* + 2], 255));
                i.* += 2;
                return .{ .indexed = n };
            },
            else => {
                i.* += 1;
                return null;
            },
        }
    }

    fn feedOsc(self: *Terminal, byte: u8) void {
        if (byte == 0x07) { // BEL terminator
            self.finishOsc();
            self.state = .ground;
            return;
        }
        if (byte == 0x1B) { // ST is ESC \ ; the backslash is swallowed next
            self.finishOsc();
            self.state = .esc;
            return;
        }
        if (byte == 0x18 or byte == 0x1A) { // CAN / SUB abort the string
            self.osc_len = 0;
            self.state = .ground;
            return;
        }
        if (self.osc_len < self.osc_buf.len) {
            self.osc_buf[self.osc_len] = byte;
            self.osc_len += 1;
        }
    }

    /// OSC 0, 1 and 2 all carry a window/icon title; anything else is ignored.
    fn finishOsc(self: *Terminal) void {
        const s = self.osc_buf[0..self.osc_len];
        self.osc_len = 0;
        const sep = std.mem.indexOfScalar(u8, s, ';') orelse return;
        const code = s[0..sep];
        if (!(std.mem.eql(u8, code, "0") or
            std.mem.eql(u8, code, "1") or
            std.mem.eql(u8, code, "2"))) return;

        const text = s[sep + 1 ..];
        const n = @min(text.len, MAX_TITLE);
        @memcpy(self.title[0..n], text[0..n]);
        self.title_len = n;
        self.dirty = true;
    }

    fn feedString(self: *Terminal, byte: u8) void {
        if (byte == 0x07) {
            self.state = .ground;
        } else if (byte == 0x1B) {
            self.state = .esc;
        }
    }
};

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn testTerm(cols: u32, rows: u32) !Terminal {
    return Terminal.init(testing.allocator, cols, rows, 8);
}

/// The text of one row, trailing blanks trimmed.
fn rowText(t: *const Terminal, row: u32, buf: []u8) []const u8 {
    var n: usize = 0;
    for (0..t.cols) |c| {
        const cp = t.cellAt(row, @intCast(c)).ch;
        n += std.unicode.utf8Encode(cp, buf[n..]) catch 0;
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

test "init clears the grid and sets a full-screen scroll region" {
    var t = try testTerm(80, 24);
    defer t.deinit();
    try testing.expectEqual(@as(u32, 80), t.cols);
    try testing.expectEqual(@as(u32, 24), t.rows);
    try testing.expectEqual(@as(usize, 80 * 24), t.cells.len);
    try testing.expectEqual(@as(u32, 0), t.scroll_top);
    try testing.expectEqual(@as(u32, 23), t.scroll_bot);
    for (t.cells) |c| try testing.expectEqual(@as(u21, ' '), c.ch);
}

test "init clamps a zero-sized grid to one cell" {
    var t = try Terminal.init(testing.allocator, 0, 0, 0);
    defer t.deinit();
    try testing.expectEqual(@as(u32, 1), t.cols);
    try testing.expectEqual(@as(u32, 1), t.rows);
}

test "printable text lands on the grid" {
    var t = try testTerm(20, 4);
    defer t.deinit();
    t.write("Hello");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Hello", rowText(&t, 0, &buf));
    try testing.expectEqual(@as(u32, 5), t.cursor_col);
}

test "carriage return, newline and backspace move the cursor" {
    var t = try testTerm(20, 4);
    defer t.deinit();
    t.write("AB\r\nC");
    try testing.expectEqual(@as(u32, 1), t.cursor_row);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("AB", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("C", rowText(&t, 1, &buf));

    t.write("\x08X");
    try testing.expectEqualStrings("X", rowText(&t, 1, &buf));
}

test "backspace stops at the left margin" {
    var t = try testTerm(20, 4);
    defer t.deinit();
    t.write("\x08\x08\x08");
    try testing.expectEqual(@as(u32, 0), t.cursor_col);
}

test "tab advances to the next eight-column stop and clamps at the edge" {
    var t = try testTerm(20, 4);
    defer t.deinit();
    t.write("A\t");
    try testing.expectEqual(@as(u32, 8), t.cursor_col);
    t.write("\t");
    try testing.expectEqual(@as(u32, 16), t.cursor_col);
    t.write("\t");
    try testing.expectEqual(@as(u32, 19), t.cursor_col);
}

test "the last column holds a glyph before wrapping" {
    // A character printed in the final column must stay there; the wrap only
    // takes effect when the next character arrives.
    var t = try testTerm(4, 3);
    defer t.deinit();
    t.write("ABCD");
    try testing.expectEqual(@as(u32, 0), t.cursor_row);
    try testing.expectEqual(@as(u21, 'D'), t.cellAt(0, 3).ch);
    try testing.expect(t.wrap_pending);

    t.write("E");
    try testing.expectEqual(@as(u32, 1), t.cursor_row);
    try testing.expectEqual(@as(u21, 'E'), t.cellAt(1, 0).ch);
}

test "a carriage return cancels a pending wrap" {
    var t = try testTerm(4, 3);
    defer t.deinit();
    t.write("ABCD\rX");
    try testing.expectEqual(@as(u32, 0), t.cursor_row);
    try testing.expectEqual(@as(u21, 'X'), t.cellAt(0, 0).ch);
}

test "content scrolls up when the bottom row overflows" {
    var t = try testTerm(5, 3);
    defer t.deinit();
    t.write("one\r\ntwo\r\nthree\r\nfour");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("two", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("three", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("four", rowText(&t, 2, &buf));
}

test "scrolled-off rows are kept in scrollback" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc\r\nddd");
    try testing.expectEqual(@as(u32, 2), t.sb_len);

    var buf: [64]u8 = undefined;
    const one_back = t.scrollbackRow(1).?;
    var n: usize = 0;
    for (one_back) |c| n += std.unicode.utf8Encode(c.ch, buf[n..]) catch 0;
    try testing.expectEqualStrings("bbb", std.mem.trimEnd(u8, buf[0..n], " "));
    try testing.expect(t.scrollbackRow(3) == null);
}

test "scrollback ring overwrites the oldest rows" {
    var t = try Terminal.init(testing.allocator, 4, 1, 2);
    defer t.deinit();
    t.write("a\r\nb\r\nc\r\nd\r\ne");
    try testing.expectEqual(@as(u32, 2), t.sb_len);
    try testing.expectEqual(@as(u21, 'd'), t.scrollbackRow(1).?[0].ch);
    try testing.expectEqual(@as(u21, 'c'), t.scrollbackRow(2).?[0].ch);
}

test "scrollView clamps to the available history" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc\r\nddd");
    t.scrollView(-10);
    try testing.expectEqual(@as(u32, 0), t.view_offset);
    t.scrollView(10);
    try testing.expectEqual(t.sb_len, t.view_offset);

    // The viewport now shows history at the top.
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (t.viewRow(0)) |c| n += std.unicode.utf8Encode(c.ch, buf[n..]) catch 0;
    try testing.expectEqualStrings("aaa", std.mem.trimEnd(u8, buf[0..n], " "));

    t.scrollToBottom();
    try testing.expectEqual(@as(u32, 0), t.view_offset);
}

test "cursor movement sequences" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    t.cursor_row = 5;
    t.cursor_col = 10;
    t.write("\x1b[2A");
    try testing.expectEqual(@as(u32, 3), t.cursor_row);
    t.write("\x1b[3B");
    try testing.expectEqual(@as(u32, 6), t.cursor_row);
    t.write("\x1b[4C");
    try testing.expectEqual(@as(u32, 14), t.cursor_col);
    t.write("\x1b[5D");
    try testing.expectEqual(@as(u32, 9), t.cursor_col);
    // No parameter means one.
    t.write("\x1b[A");
    try testing.expectEqual(@as(u32, 5), t.cursor_row);
}

test "cursor movement saturates at the edges instead of wrapping" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    t.write("\x1b[99A\x1b[99D");
    try testing.expectEqual(@as(u32, 0), t.cursor_row);
    try testing.expectEqual(@as(u32, 0), t.cursor_col);
    t.write("\x1b[99B\x1b[99C");
    try testing.expectEqual(@as(u32, 9), t.cursor_row);
    try testing.expectEqual(@as(u32, 19), t.cursor_col);
}

test "absolute positioning is one-based and clamped" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    t.write("\x1b[3;7H");
    try testing.expectEqual(@as(u32, 2), t.cursor_row);
    try testing.expectEqual(@as(u32, 6), t.cursor_col);
    t.write("\x1b[H");
    try testing.expectEqual(@as(u32, 0), t.cursor_row);
    try testing.expectEqual(@as(u32, 0), t.cursor_col);
    t.write("\x1b[999;999H");
    try testing.expectEqual(@as(u32, 9), t.cursor_row);
    try testing.expectEqual(@as(u32, 19), t.cursor_col);
}

test "erase in display clears the whole screen, not just one line" {
    // The original implementation aliased ED onto EL, so rows below the cursor
    // survived a `clear`.
    var t = try testTerm(5, 3);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc");
    t.write("\x1b[2;2H\x1b[0J");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aaa", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("b", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("", rowText(&t, 2, &buf));
}

test "erase in display mode 1 clears up to and including the cursor" {
    var t = try testTerm(5, 3);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc");
    t.write("\x1b[2;2H\x1b[1J");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("  b", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("ccc", rowText(&t, 2, &buf));
}

test "erase in display mode 2 clears everything" {
    var t = try testTerm(5, 3);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc\x1b[2J");
    for (t.cells) |c| try testing.expectEqual(@as(u21, ' '), c.ch);
}

test "erase in line respects its three modes" {
    var t = try testTerm(6, 2);
    defer t.deinit();
    var buf: [64]u8 = undefined;

    t.write("abcdef\x1b[1;4H\x1b[0K");
    try testing.expectEqualStrings("abc", rowText(&t, 0, &buf));

    t.write("\x1b[2J\x1b[1;1Habcdef\x1b[1;4H\x1b[1K");
    try testing.expectEqualStrings("    ef", rowText(&t, 0, &buf));

    t.write("\x1b[2J\x1b[1;1Habcdef\x1b[1;4H\x1b[2K");
    try testing.expectEqualStrings("", rowText(&t, 0, &buf));
}

test "insert and delete characters shift the line" {
    var t = try testTerm(8, 2);
    defer t.deinit();
    var buf: [64]u8 = undefined;

    t.write("abcdef\x1b[1;3H\x1b[2@");
    try testing.expectEqualStrings("ab  cdef", rowText(&t, 0, &buf));

    t.write("\x1b[2J\x1b[1;1Habcdef\x1b[1;3H\x1b[2P");
    try testing.expectEqualStrings("abef", rowText(&t, 0, &buf));

    t.write("\x1b[2J\x1b[1;1Habcdef\x1b[1;3H\x1b[2X");
    try testing.expectEqualStrings("ab  ef", rowText(&t, 0, &buf));
}

test "deleting lines does not push them into scrollback" {
    // DL rearranges the screen; only content scrolled past by a newline
    // belongs in the history.
    var t = try testTerm(4, 4);
    defer t.deinit();
    t.write("aa\r\nbb\r\ncc\r\ndd");
    try testing.expectEqual(@as(u32, 0), t.sb_len);
    t.write("\x1b[1;1H\x1b[2M");
    try testing.expectEqual(@as(u32, 0), t.sb_len);
}

test "resize failure leaves the terminal untouched" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var t = try Terminal.init(testing.allocator, 10, 4, 8);
    defer t.deinit();
    t.write("abc");

    // Swap in an allocator that refuses, then confirm nothing was committed.
    const good = t.gpa;
    t.gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, t.resize(20, 8));
    t.gpa = good;

    try testing.expectEqual(@as(u32, 10), t.cols);
    try testing.expectEqual(@as(u32, 4), t.rows);
    try testing.expectEqual(@as(usize, 40), t.cells.len);
    try testing.expectEqual(@as(u21, 'a'), t.cellAt(0, 0).ch);
}

test "insert and delete lines shift within the screen" {
    var t = try testTerm(4, 4);
    defer t.deinit();
    var buf: [64]u8 = undefined;

    t.write("aa\r\nbb\r\ncc\r\ndd");
    t.write("\x1b[2;1H\x1b[1L");
    try testing.expectEqualStrings("aa", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("bb", rowText(&t, 2, &buf));

    t.write("\x1b[2;1H\x1b[1M");
    try testing.expectEqualStrings("bb", rowText(&t, 1, &buf));
}

test "a scrolling region confines scrolling to its rows" {
    var t = try testTerm(4, 5);
    defer t.deinit();
    var buf: [64]u8 = undefined;
    t.write("1\r\n2\r\n3\r\n4\r\n5");
    // Region rows 2..4 (one-based), i.e. indices 1..3.
    t.write("\x1b[2;4r\x1b[4;1H\r\nX");
    try testing.expectEqualStrings("1", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("3", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("4", rowText(&t, 2, &buf));
    try testing.expectEqualStrings("X", rowText(&t, 3, &buf));
    try testing.expectEqualStrings("5", rowText(&t, 4, &buf));
}

test "SGR sets and clears attributes" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[1;4;7mX\x1b[0mY");
    const x = t.cellAt(0, 0);
    try testing.expect(x.attrs.bold);
    try testing.expect(x.attrs.underline);
    try testing.expect(x.attrs.inverse);
    const y = t.cellAt(0, 1);
    try testing.expect(!y.attrs.bold);
    try testing.expect(!y.attrs.underline);
    try testing.expect(!y.attrs.inverse);
}

test "SGR 22 clears bold and dim without touching the rest" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[1;2;4m\x1b[22mX");
    const c = t.cellAt(0, 0);
    try testing.expect(!c.attrs.bold);
    try testing.expect(!c.attrs.dim);
    try testing.expect(c.attrs.underline);
}

test "SGR colours: basic, bright, 256 and truecolor" {
    var t = try testTerm(10, 2);
    defer t.deinit();

    t.write("\x1b[31mA");
    try testing.expect(t.cellAt(0, 0).fg.eql(.{ .indexed = 1 }));

    t.write("\x1b[92mB");
    try testing.expect(t.cellAt(0, 1).fg.eql(.{ .indexed = 10 }));

    t.write("\x1b[38;5;208mC");
    try testing.expect(t.cellAt(0, 2).fg.eql(.{ .indexed = 208 }));

    t.write("\x1b[38;2;255;128;0mD");
    try testing.expect(t.cellAt(0, 3).fg.eql(.{ .rgb = 0xFF8000 }));

    t.write("\x1b[48;2;1;2;3mE");
    try testing.expect(t.cellAt(0, 4).bg.eql(.{ .rgb = 0x010203 }));

    t.write("\x1b[39;49mF");
    try testing.expect(t.cellAt(0, 5).fg.eql(.default));
    try testing.expect(t.cellAt(0, 5).bg.eql(.default));
}

test "a truncated extended colour does not consume later parameters" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    // 38;2 with too few components: the colour is dropped, not misparsed.
    t.write("\x1b[38;2;255mX");
    try testing.expect(t.cellAt(0, 0).fg.eql(.default));
}

test "colours resolve against the active theme" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[31mX");
    const cell = t.cellAt(0, 0);
    try testing.expectEqual(theme.dark.ansi[1], Terminal.resolve(cell, &theme.dark).fg);
    try testing.expectEqual(theme.light.ansi[1], Terminal.resolve(cell, &theme.light).fg);
    // Default colours follow the theme too, which is what makes a live theme
    // switch recolour text already on screen.
    const plain = Cell.blank;
    try testing.expectEqual(theme.dark.bg, Terminal.resolve(plain, &theme.dark).bg);
    try testing.expectEqual(theme.light.bg, Terminal.resolve(plain, &theme.light).bg);
}

test "inverse swaps foreground and background at resolve time" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[7mX");
    const r = Terminal.resolve(t.cellAt(0, 0), &theme.dark);
    try testing.expectEqual(theme.dark.bg, r.fg);
    try testing.expectEqual(theme.dark.fg, r.bg);
}

test "xterm256 covers the cube and the grey ramp" {
    try testing.expectEqual(theme.dark.ansi[3], Terminal.xterm256(3, &theme.dark));
    try testing.expectEqual(@as(u32, 0x000000), Terminal.xterm256(16, &theme.dark));
    try testing.expectEqual(@as(u32, 0xFFFFFF), Terminal.xterm256(231, &theme.dark));
    try testing.expectEqual(@as(u32, 0x080808), Terminal.xterm256(232, &theme.dark));
    try testing.expectEqual(@as(u32, 0xEEEEEE), Terminal.xterm256(255, &theme.dark));
}

test "DECTCEM toggles the cursor" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[?25l");
    try testing.expect(!t.cursor_visible);
    t.write("\x1b[?25h");
    try testing.expect(t.cursor_visible);
}

test "the alternate screen is swapped in and restored" {
    var t = try testTerm(6, 2);
    defer t.deinit();
    var buf: [64]u8 = undefined;
    t.write("main");
    try testing.expect(!t.onAltScreen());

    t.write("\x1b[?1049h");
    try testing.expect(t.onAltScreen());
    try testing.expectEqualStrings("", rowText(&t, 0, &buf));
    t.write("alt");
    try testing.expectEqualStrings("alt", rowText(&t, 0, &buf));

    t.write("\x1b[?1049l");
    try testing.expect(!t.onAltScreen());
    try testing.expectEqualStrings("main", rowText(&t, 0, &buf));
}

test "the alternate screen does not pollute scrollback" {
    var t = try testTerm(4, 2);
    defer t.deinit();
    t.write("\x1b[?1049h");
    t.write("a\r\nb\r\nc\r\nd");
    try testing.expectEqual(@as(u32, 0), t.sb_len);
    t.write("\x1b[?1049l");
}

test "save and restore cursor, both DECSC and CSI s" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    t.write("\x1b[3;5H\x1b7\x1b[9;9H\x1b8");
    try testing.expectEqual(@as(u32, 2), t.cursor_row);
    try testing.expectEqual(@as(u32, 4), t.cursor_col);

    t.write("\x1b[2;3H\x1b[s\x1b[9;9H\x1b[u");
    try testing.expectEqual(@as(u32, 1), t.cursor_row);
    try testing.expectEqual(@as(u32, 2), t.cursor_col);
}

test "reset restores the initial state" {
    var t = try testTerm(10, 4);
    defer t.deinit();
    t.write("\x1b[31;1mtext\x1b[?25l\x1bc");
    try testing.expectEqual(@as(u32, 0), t.cursor_row);
    try testing.expectEqual(@as(u32, 0), t.cursor_col);
    try testing.expect(t.cursor_visible);
    try testing.expect(!t.attrs.bold);
    try testing.expect(t.fg.eql(.default));
    for (t.cells) |c| try testing.expectEqual(@as(u21, ' '), c.ch);
}

test "OSC 0 and 2 set the window title" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b]0;first\x07");
    try testing.expectEqualStrings("first", t.titleSlice());

    // ST-terminated form.
    t.write("\x1b]2;second\x1b\\");
    try testing.expectEqualStrings("second", t.titleSlice());
    try testing.expectEqual(ParseState.ground, t.state);
}

test "an unrelated OSC code leaves the title alone" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b]0;keep\x07");
    t.write("\x1b]52;c;cGF5bG9hZA==\x07");
    try testing.expectEqualStrings("keep", t.titleSlice());
}

test "an over-long OSC title is truncated, not overflowed" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b]0;");
    for (0..MAX_TITLE * 3) |_| t.write("x");
    t.write("\x07");
    try testing.expect(t.title_len <= MAX_TITLE);
}

test "escape sequences split across writes still parse" {
    // A pty read can end anywhere, so the parser must hold its state.
    var t = try testTerm(20, 4);
    defer t.deinit();
    t.write("\x1b");
    t.write("[");
    t.write("3");
    t.write("1");
    t.write("m");
    t.write("X");
    try testing.expect(t.cellAt(0, 0).fg.eql(.{ .indexed = 1 }));

    t.write("\x1b[1;");
    t.write("5HY");
    try testing.expectEqual(@as(u21, 'Y'), t.cellAt(0, 4).ch);
}

test "UTF-8 is decoded, including across a write boundary" {
    var t = try testTerm(20, 2);
    defer t.deinit();
    t.write("Привет");
    try testing.expectEqual(@as(u21, 'П'), t.cellAt(0, 0).ch);
    try testing.expectEqual(@as(u21, 'т'), t.cellAt(0, 5).ch);
    try testing.expectEqual(@as(u32, 6), t.cursor_col);

    const snowman = "\xE2\x98\x83"; // U+2603
    t.write(snowman[0..1]);
    t.write(snowman[1..2]);
    t.write(snowman[2..3]);
    try testing.expectEqual(@as(u21, 0x2603), t.cellAt(0, 6).ch);
}

test "invalid UTF-8 becomes the replacement character" {
    var t = try testTerm(20, 2);
    defer t.deinit();
    t.write("\xFFA");
    try testing.expectEqual(std.unicode.replacement_character, t.cellAt(0, 0).ch);
    try testing.expectEqual(@as(u21, 'A'), t.cellAt(0, 1).ch);

    // A truncated multi-byte sequence followed by ASCII.
    t.write("\xE2\x98" ++ "B");
    try testing.expectEqual(std.unicode.replacement_character, t.cellAt(0, 2).ch);
    try testing.expectEqual(@as(u21, 'B'), t.cellAt(0, 3).ch);
}

test "an ESC m sequence terminates instead of hanging" {
    // The old hand-rolled SGR reader never advanced past digits, so any
    // `ESC m` followed by a number looped forever.
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1bm5X");
    try testing.expectEqual(ParseState.ground, t.state);
    try testing.expectEqual(@as(u21, '5'), t.cellAt(0, 0).ch);
}

test "absurd CSI parameters saturate instead of wrapping" {
    var t = try testTerm(10, 4);
    defer t.deinit();
    t.write("\x1b[99999999999999999999;1H");
    try testing.expectEqual(@as(u32, 3), t.cursor_row);
}

test "more CSI parameters than the limit are dropped safely" {
    var t = try testTerm(10, 4);
    defer t.deinit();
    t.write("\x1b[");
    for (0..MAX_PARAMS * 4) |_| t.write("1;");
    t.write("m");
    try testing.expectEqual(ParseState.ground, t.state);
    try testing.expect(t.param_count <= MAX_PARAMS);
}

test "unknown and private sequences are swallowed whole" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[>4;2mA");
    try testing.expectEqual(@as(u21, 'A'), t.cellAt(0, 0).ch);
    try testing.expectEqual(@as(u32, 1), t.cursor_col);

    t.write("\x1bP1;2|payload\x1b\\B");
    try testing.expectEqual(@as(u21, 'B'), t.cellAt(0, 1).ch);

    t.write("\x1b(0C");
    try testing.expectEqual(@as(u21, 'C'), t.cellAt(0, 2).ch);
}

test "BEL raises the bell flag without printing" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x07");
    try testing.expect(t.bell);
    try testing.expectEqual(@as(u32, 0), t.cursor_col);
}

test "resize keeps the top-left content and clamps the cursor" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    t.write("abc");
    t.cursor_row = 9;
    t.cursor_col = 19;
    try t.resize(10, 5);
    try testing.expectEqual(@as(u32, 10), t.cols);
    try testing.expectEqual(@as(u32, 5), t.rows);
    try testing.expectEqual(@as(usize, 50), t.cells.len);
    try testing.expectEqual(@as(u32, 4), t.cursor_row);
    try testing.expectEqual(@as(u32, 9), t.cursor_col);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc", rowText(&t, 0, &buf));
    try testing.expectEqual(@as(u32, 4), t.scroll_bot);
}

test "resize to zero is clamped rather than underflowing" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    try t.resize(0, 0);
    try testing.expectEqual(@as(u32, 1), t.cols);
    try testing.expectEqual(@as(u32, 1), t.rows);
    try testing.expectEqual(@as(u32, 0), t.scroll_bot);
    t.write("x");
    try testing.expectEqual(@as(u21, 'x'), t.cellAt(0, 0).ch);
}

test "resize while on the alternate screen keeps both buffers sized" {
    var t = try testTerm(10, 4);
    defer t.deinit();
    t.write("\x1b[?1049h");
    try t.resize(20, 8);
    try testing.expectEqual(@as(usize, 160), t.cells.len);
    try testing.expectEqual(@as(usize, 160), t.alt.?.len);
    t.write("\x1b[?1049l");
}

test "a width change drops scrollback rather than misreading it" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc");
    try testing.expect(t.sb_len > 0);
    try t.resize(9, 2);
    try testing.expectEqual(@as(u32, 0), t.sb_len);
    try testing.expect(t.scrollbackRow(1) == null);
}

test "a height-only change preserves scrollback" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc");
    const before = t.sb_len;
    try t.resize(5, 4);
    try testing.expectEqual(before, t.sb_len);
}

test "fuzzing the parser with arbitrary bytes never panics" {
    var t = try testTerm(20, 6);
    defer t.deinit();
    var prng = std.Random.DefaultPrng.init(0x7A7ABB);
    const rand = prng.random();
    var buf: [256]u8 = undefined;
    for (0..400) |_| {
        rand.bytes(&buf);
        t.write(&buf);
    }
    // The invariants the rest of the code relies on must still hold.
    try testing.expect(t.cursor_row < t.rows);
    try testing.expect(t.cursor_col < t.cols);
    try testing.expect(t.scroll_top <= t.scroll_bot);
    try testing.expect(t.scroll_bot < t.rows);
    if (t.onAltScreen()) t.write("\x1b[?1049l");
}

test "fuzzing with escape-heavy input never panics" {
    var t = try testTerm(12, 4);
    defer t.deinit();
    var prng = std.Random.DefaultPrng.init(99);
    const rand = prng.random();
    const alphabet = "\x1b[];?0123456789mHJKABCDsuhlr\x07\\P(";
    var buf: [128]u8 = undefined;
    for (0..2000) |_| {
        for (&buf) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        t.write(&buf);
    }
    try testing.expect(t.cursor_row < t.rows);
    try testing.expect(t.cursor_col < t.cols);
    if (t.onAltScreen()) t.write("\x1b[?1049l");
}
