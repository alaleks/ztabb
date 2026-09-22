//! Drawing: the font atlas, the terminal grid, the tab bar and the overlays.
//!
//! The renderer owns two GPU textures (regular and bold weights of the baked
//! bitmap font) and draws every glyph as a textured quad tinted by a colour
//! mod, so one atlas serves the whole 256-colour palette in either theme.

const std = @import("std");
const sdl = @import("sdl");
const font = @import("font");
const term = @import("term");
const theme = @import("theme");
const highlight = @import("highlight");
const tabs_mod = @import("tabs");

pub const TAB_BAR_CELLS: u32 = 2;
/// Preferred width of a tab, in character cells.
pub const TAB_WIDTH_CELLS: u32 = 18;
/// A tab narrower than this loses its close button; below it there is no room
/// for a label as well.
const TAB_MIN_CELLS: u32 = 8;
const TAB_CLOSE_CELLS: u32 = 3;
const PLUS_CELLS: u32 = 3;

/// What sits under a point in the tab bar. Pure geometry, so the hit testing
/// the mouse handler depends on can be tested without a window.
pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    new_tab,
};

pub const TabBar = struct {
    cell_w: f32,
    cell_h: f32,
    width: f32,
    count: usize,

    pub fn height(self: TabBar) f32 {
        return self.cell_h * @as(f32, @floatFromInt(TAB_BAR_CELLS));
    }

    pub fn plusWidth(self: TabBar) f32 {
        return self.cell_w * @as(f32, @floatFromInt(PLUS_CELLS));
    }

    /// Tabs share what is left after the "+" button, shrinking as more open
    /// rather than marching off the right edge.
    pub fn tabWidth(self: TabBar) f32 {
        if (self.count == 0) return 0;
        const preferred = self.cell_w * @as(f32, @floatFromInt(TAB_WIDTH_CELLS));
        const available = @max(self.width - self.plusWidth(), 0);
        const share = available / @as(f32, @floatFromInt(self.count));
        const min = self.cell_w * @as(f32, @floatFromInt(TAB_MIN_CELLS));
        return @max(@min(preferred, share), min);
    }

    pub fn tabX(self: TabBar, i: usize) f32 {
        return @as(f32, @floatFromInt(i)) * self.tabWidth();
    }

    pub fn plusX(self: TabBar) f32 {
        return @min(self.tabX(self.count), @max(self.width - self.plusWidth(), 0));
    }

    /// True when tabs are wide enough to carry a close button.
    pub fn hasClose(self: TabBar) bool {
        return self.tabWidth() >= self.cell_w * @as(f32, @floatFromInt(TAB_MIN_CELLS + TAB_CLOSE_CELLS));
    }

    pub fn closeX(self: TabBar, i: usize) f32 {
        return self.tabX(i) + self.tabWidth() - self.cell_w * @as(f32, @floatFromInt(TAB_CLOSE_CELLS));
    }

    pub fn hit(self: TabBar, x: f32, y: f32) Hit {
        if (y < 0 or y >= self.height() or x < 0) return .none;

        const plus_x = self.plusX();
        if (x >= plus_x and x < plus_x + self.plusWidth()) return .new_tab;

        const tw = self.tabWidth();
        if (tw <= 0) return .none;
        const i: usize = @intFromFloat(x / tw);
        if (i >= self.count) return .none;
        if (self.hasClose() and x >= self.closeX(i)) return .{ .close = i };
        return .{ .tab = i };
    }
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    r: *sdl.Renderer,
    regular: *sdl.Texture,
    bold: *sdl.Texture,
    /// The baked glyph set currently uploaded to the textures.
    atlas_size: font.Size,
    /// Multiplies the 8x16 glyph box; covers both HiDPI and the user's zoom.
    scale: u32 = 1,

    pub fn init(gpa: std.mem.Allocator, r: *sdl.Renderer) !Renderer {
        var self = Renderer{
            .gpa = gpa,
            .r = r,
            .regular = undefined,
            .bold = undefined,
            .atlas_size = font.sizeAt(0),
        };
        try self.uploadAtlas(font.sizeAt(0));
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        sdl.destroyTexture(self.bold);
        sdl.destroyTexture(self.regular);
    }

    fn uploadAtlas(self: *Renderer, size: font.Size) !void {
        const pixels = try self.gpa.alloc(u32, font.atlasPixels(size));
        defer self.gpa.free(pixels);

        const w: i32 = @intCast(font.atlasW(size));
        const h: i32 = @intCast(font.atlasH(size));

        font.buildAtlas(.regular, size, pixels);
        const regular = try sdl.createTexture(self.r, w, h);
        errdefer sdl.destroyTexture(regular);
        sdl.updateTexture(regular, pixels, w * 4);

        font.buildAtlas(.bold, size, pixels);
        const bold = try sdl.createTexture(self.r, w, h);
        errdefer sdl.destroyTexture(bold);
        sdl.updateTexture(bold, pixels, w * 4);

        self.regular = regular;
        self.bold = bold;
        self.atlas_size = size;
    }

    /// Re-bakes the atlas when the cell size moves to a different glyph set,
    /// so text is rasterized at the resolution it is drawn at rather than
    /// stretched up from the smallest baked size.
    pub fn setScale(self: *Renderer, scale: u32) void {
        self.scale = @max(scale, 1);
        const wanted = font.bestSize(self.cellW(), self.cellH());
        if (wanted.index == self.atlas_size.index) return;

        const old_regular = self.regular;
        const old_bold = self.bold;
        self.uploadAtlas(wanted) catch return;
        sdl.destroyTexture(old_regular);
        sdl.destroyTexture(old_bold);
    }

    pub fn cellW(self: *const Renderer) u32 {
        return font.base_w * self.scale;
    }

    pub fn cellH(self: *const Renderer) u32 {
        return font.base_h * self.scale;
    }

    fn drawGlyph(self: *Renderer, cp: u21, x: f32, y: f32, color: u32, bold: bool) void {
        if (cp == ' ' or cp == 0) return;
        const weight: font.Weight = if (bold) .bold else .regular;
        if (font.isBlank(cp, weight, self.atlas_size)) return;

        const tex = if (bold) self.bold else self.regular;
        const rect = font.atlasRect(cp, self.atlas_size);
        const src = sdl.FRect{
            .x = @floatFromInt(rect.x),
            .y = @floatFromInt(rect.y),
            .w = @floatFromInt(self.atlas_size.w),
            .h = @floatFromInt(self.atlas_size.h),
        };
        const dst = sdl.FRect{
            .x = x,
            .y = y,
            .w = @floatFromInt(self.cellW()),
            .h = @floatFromInt(self.cellH()),
        };
        sdl.setTextureColorMod(tex, color);
        sdl.renderTexture(self.r, tex, &src, &dst);
    }

    /// Draws a UTF-8 string starting at a pixel position, one cell per code
    /// point. Returns the number of cells consumed.
    pub fn drawText(self: *Renderer, text: []const u8, x: f32, y: f32, color: u32, bold: bool) u32 {
        var view = std.unicode.Utf8View.init(text) catch return 0;
        var it = view.iterator();
        var col: u32 = 0;
        while (it.nextCodepoint()) |cp| : (col += 1) {
            self.drawGlyph(cp, x + @as(f32, @floatFromInt(col * self.cellW())), y, color, bold);
        }
        return col;
    }

    fn fill(self: *Renderer, x: f32, y: f32, w: f32, h: f32, color: u32) void {
        sdl.setRenderDrawRgb(self.r, color);
        const rect = sdl.FRect{ .x = x, .y = y, .w = w, .h = h };
        sdl.renderFillRect(self.r, &rect);
    }

    // -- terminal grid -----------------------------------------------------

    /// Draws one terminal screen below the tab bar.
    ///
    /// `hl` supplies a per-column colour override for the shell input line, or
    /// null when highlighting is off.
    pub fn drawTerminal(
        self: *Renderer,
        t: *const term.Terminal,
        th: *const theme.Theme,
        top: f32,
        hl: ?HighlightOverlay,
    ) void {
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());

        for (0..t.rows) |ri| {
            const row: u32 = @intCast(ri);
            const cells = t.viewRow(row);
            const y = top + @as(f32, @floatFromInt(row)) * ch;

            // Background first, merging horizontal runs of one colour so a
            // full-width bar costs one draw call instead of `cols` of them.
            var run_start: u32 = 0;
            var run_color: u32 = term.Terminal.resolve(cells[0], th).bg;
            for (1..t.cols + 1) |ci| {
                const c: u32 = @intCast(ci);
                const color = if (c < t.cols) term.Terminal.resolve(cells[c], th).bg else ~run_color;
                if (color == run_color) continue;
                if (run_color != th.bg) {
                    self.fill(
                        @as(f32, @floatFromInt(run_start)) * cw,
                        y,
                        @as(f32, @floatFromInt(c - run_start)) * cw,
                        ch,
                        run_color,
                    );
                }
                run_start = c;
                run_color = color;
            }

            for (0..t.cols) |ci| {
                const col: u32 = @intCast(ci);
                const cell = cells[col];
                if (cell.ch == ' ' or cell.ch == 0) continue;
                var fg = term.Terminal.resolve(cell, th).fg;
                if (hl) |o| {
                    if (o.row == row) {
                        if (o.colorAt(col)) |c| fg = c;
                    }
                }
                const x = @as(f32, @floatFromInt(col)) * cw;
                self.drawGlyph(cell.ch, x, y, fg, cell.attrs.bold);
                if (cell.attrs.underline) {
                    self.fill(x, y + ch - @as(f32, @floatFromInt(self.scale)), cw, @floatFromInt(self.scale), fg);
                }
                if (cell.attrs.strike) {
                    self.fill(x, y + ch / 2, cw, @floatFromInt(self.scale), fg);
                }
            }
        }

        self.drawCursor(t, th, top);
        self.drawScrollIndicator(t, th, top);
    }

    fn drawCursor(self: *Renderer, t: *const term.Terminal, th: *const theme.Theme, top: f32) void {
        // While scrolled back, the cursor belongs to a screen the user is not
        // looking at, so hide it rather than drawing it at the wrong row.
        if (!t.cursor_visible or t.view_offset != 0) return;
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const x = @as(f32, @floatFromInt(t.cursor_col)) * cw;
        const y = top + @as(f32, @floatFromInt(t.cursor_row)) * ch;
        self.fill(x, y, cw, ch, th.cursor);

        const cell = t.cellAt(t.cursor_row, t.cursor_col);
        self.drawGlyph(cell.ch, x, y, th.cursor_text, cell.attrs.bold);
    }

    /// A slim bar on the right edge showing the scrollback position.
    fn drawScrollIndicator(self: *Renderer, t: *const term.Terminal, th: *const theme.Theme, top: f32) void {
        if (t.view_offset == 0 or t.sb_len == 0) return;
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const height = @as(f32, @floatFromInt(t.rows)) * ch;
        const width = @max(2.0, cw / 4.0);
        const x = @as(f32, @floatFromInt(t.cols)) * cw - width;

        const total: f32 = @floatFromInt(t.sb_len + t.rows);
        const thumb = @max(ch, height * @as(f32, @floatFromInt(t.rows)) / total);
        const back: f32 = @floatFromInt(t.sb_len - t.view_offset);
        const y = top + (height - thumb) * back / @as(f32, @floatFromInt(t.sb_len));
        self.fill(x, y, width, thumb, th.ansi[8]);
    }

    // -- tab bar -----------------------------------------------------------

    pub fn drawTabBar(self: *Renderer, tabs: *tabs_mod.Tabs, th: *const theme.Theme, width: f32) void {
        const ch: f32 = @floatFromInt(self.cellH());
        const cw: f32 = @floatFromInt(self.cellW());
        const bar = self.tabBar(tabs.count, width);
        const bar_h = bar.height();
        const tab_w = bar.tabWidth();
        self.fill(0, 0, width, bar_h, th.tab_bar_bg);

        for (tabs.slice(), 0..) |*tab, i| {
            const x = bar.tabX(i);
            if (x >= width) break;
            const is_active = tabs.isActive(i);
            self.fill(x, 0, tab_w - 1, bar_h, if (is_active) th.tab_active_bg else th.tab_inactive_bg);
            self.fill(x + tab_w - 1, 0, 1, bar_h, th.tab_border);
            if (is_active) {
                // An accent strip along the top marks the focused tab.
                self.fill(x, 0, tab_w - 1, @max(2.0, @as(f32, @floatFromInt(self.scale)) * 2), th.ansi[4]);
            }

            const fg = if (is_active) th.tab_active_fg else th.tab_inactive_fg;

            var label_buf: [tabs_mod.MAX_LABEL + 8]u8 = undefined;
            const prefix: []const u8 = if (tab.kind == .ssh) "\u{2387} " else "";
            const cells: u32 = @intFromFloat(tab_w / cw);
            const reserved: u32 = if (bar.hasClose()) TAB_CLOSE_CELLS + 1 else 1;
            const budget = cells -| reserved;
            const label = fitLabel(&label_buf, prefix, tab.displayName(), budget);
            _ = self.drawText(label, x + cw / 2, ch / 2, fg, is_active);

            if (bar.hasClose()) {
                _ = self.drawText("\u{00D7}", bar.closeX(i) + cw / 2, ch / 2, th.tab_inactive_fg, false);
            }
        }

        // The "+" button: without it there is no way to open a tab except the
        // keyboard shortcut.
        const plus_x = bar.plusX();
        self.fill(plus_x, 0, bar.plusWidth(), bar_h, th.tab_bar_bg);
        _ = self.drawText("+", plus_x + cw, ch / 2, th.tab_active_fg, true);

        self.fill(0, bar_h - 1, width, 1, th.tab_border);
    }

    /// The tab-bar geometry for the current cell size, shared by drawing and
    /// mouse hit testing so the two can never disagree.
    pub fn tabBar(self: *const Renderer, count: usize, width: f32) TabBar {
        return .{
            .cell_w = @floatFromInt(self.cellW()),
            .cell_h = @floatFromInt(self.cellH()),
            .width = width,
            .count = count,
        };
    }

    // -- overlays ----------------------------------------------------------

    /// Centred modal listing ssh hosts.
    pub fn drawHostPicker(
        self: *Renderer,
        hosts: []const HostRow,
        selected: usize,
        th: *const theme.Theme,
        width: f32,
        height: f32,
    ) void {
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());

        const box_cols: u32 = 52;
        const visible = @min(hosts.len, 14);
        const box_rows: u32 = @intCast(visible + 4);
        const box_w = @as(f32, @floatFromInt(box_cols)) * cw;
        const box_h = @as(f32, @floatFromInt(box_rows)) * ch;
        const x = @max(0, (width - box_w) / 2);
        const y = @max(0, (height - box_h) / 2);

        // Dim the terminal behind the modal.
        self.fill(0, 0, width, height, th.tab_bar_bg);
        self.fill(x - 2, y - 2, box_w + 4, box_h + 4, th.tab_border);
        self.fill(x, y, box_w, box_h, th.bg);

        _ = self.drawText("SSH hosts  (\u{2191}/\u{2193} select, Enter open, Esc cancel)", x + cw, y + ch / 2, th.ansi[4], true);

        if (hosts.len == 0) {
            _ = self.drawText("no hosts in ~/.ssh/config", x + cw, y + ch * 2.5, th.tab_inactive_fg, false);
            return;
        }

        // Keep the selection on screen when the list is longer than the box.
        const first = if (selected >= visible) selected - visible + 1 else 0;
        for (hosts[first..][0..visible], 0..) |host, i| {
            const row_y = y + ch * (2.0 + @as(f32, @floatFromInt(i)));
            const is_sel = first + i == selected;
            if (is_sel) self.fill(x + cw / 2, row_y, box_w - cw, ch, th.selection);

            const fg = if (is_sel) th.fg else th.hl_command;
            var used = self.drawText(host.alias, x + cw, row_y, fg, is_sel);
            if (host.detail.len > 0) {
                used += 1;
                const detail_x = x + cw + @as(f32, @floatFromInt(@max(used, 16) * self.cellW()));
                _ = self.drawText(host.detail, detail_x, row_y, th.tab_inactive_fg, false);
            }
        }
    }

    /// A transient message strip at the bottom of the window.
    pub fn drawToast(self: *Renderer, text: []const u8, th: *const theme.Theme, width: f32, height: f32) void {
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const y = height - ch * 1.5;
        self.fill(0, y, width, ch * 1.5, th.tab_bar_bg);
        _ = self.drawText(text, cw, y + ch / 4, th.fg, false);
    }
};

pub const HostRow = struct {
    alias: []const u8,
    detail: []const u8,
};

/// Per-column foreground overrides for one row, used by the shell-line
/// highlighter. Columns outside `start..start + len` keep their own colour.
pub const HighlightOverlay = struct {
    row: u32,
    start: u32,
    colors: []const u32,

    pub fn colorAt(self: HighlightOverlay, col: u32) ?u32 {
        if (col < self.start) return null;
        const i = col - self.start;
        if (i >= self.colors.len) return null;
        return self.colors[i];
    }
};

/// Builds a tab label that fits `budget` cells, eliding the middle of a long
/// name so both the leading context and the trailing component stay visible.
pub fn fitLabel(buf: []u8, prefix: []const u8, name: []const u8, budget: u32) []const u8 {
    var n: usize = 0;
    const take = struct {
        fn f(dst: []u8, at: *usize, src: []const u8) void {
            const room = @min(dst.len - at.*, src.len);
            @memcpy(dst[at.*..][0..room], src[0..room]);
            at.* += room;
        }
    }.f;

    take(buf, &n, prefix);
    const prefix_cells = cellLen(prefix);
    if (prefix_cells >= budget) return buf[0..n];
    const room = budget - prefix_cells;

    if (cellLen(name) <= room) {
        take(buf, &n, name);
        return buf[0..n];
    }

    // Keep the tail: for a path-like title the last component identifies it.
    const ellipsis = "\u{2026}";
    const tail_cells = room - 1;
    const tail = tailCells(name, tail_cells);
    take(buf, &n, ellipsis);
    take(buf, &n, tail);
    return buf[0..n];
}

/// Length in cells, counting code points rather than bytes.
fn cellLen(s: []const u8) u32 {
    var view = std.unicode.Utf8View.init(s) catch return @intCast(s.len);
    var it = view.iterator();
    var n: u32 = 0;
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

/// The last `cells` code points of `s`, on a code-point boundary.
fn tailCells(s: []const u8, cells: u32) []const u8 {
    const total = cellLen(s);
    if (total <= cells) return s;
    var skip = total - cells;
    var i: usize = 0;
    while (i < s.len and skip > 0) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += len;
        skip -= 1;
    }
    return s[i..];
}

/// Locates the shell input on the cursor's row and computes a colour per
/// column for it.
///
/// The shell, not ztabb, owns the input line, so the command is recovered from
/// what is on screen: everything after the last prompt terminator up to the
/// cursor. Returns null when no prompt is recognisable, which leaves the line
/// in its normal colours rather than guessing.
pub fn shellLineOverlay(
    t: *const term.Terminal,
    th: *const theme.Theme,
    text_buf: []u8,
    color_buf: []u32,
) ?HighlightOverlay {
    if (t.onAltScreen() or t.view_offset != 0) return null;
    if (t.cursor_col == 0) return null;

    // Read the cursor row up to the cursor into a byte buffer, remembering
    // which column each byte came from.
    var col_of_byte: [512]u32 = undefined;
    var n: usize = 0;
    const upto = @min(t.cursor_col, t.cols);
    for (0..upto) |ci| {
        const col: u32 = @intCast(ci);
        const cp = t.cellAt(t.cursor_row, col).ch;
        const len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
        if (n + len > @min(text_buf.len, col_of_byte.len)) break;
        n += std.unicode.utf8Encode(cp, text_buf[n..]) catch break;
        for (n - len..n) |b| col_of_byte[b] = col;
    }
    const line = text_buf[0..n];

    const start_byte = promptEnd(line) orelse return null;
    const command = line[start_byte..];
    if (command.len == 0) return null;

    var byte_colors: [512]u32 = undefined;
    const m = @min(command.len, byte_colors.len);
    highlight.colorize(command, th, th.fg, byte_colors[0..m]);

    // Collapse per-byte colours to per-column, taking each column's first byte.
    const start_col = col_of_byte[start_byte];
    var written: usize = 0;
    var last_col: ?u32 = null;
    for (0..m) |b| {
        const col = col_of_byte[start_byte + b];
        if (last_col != null and col == last_col.?) continue;
        last_col = col;
        const slot = col - start_col;
        if (slot >= color_buf.len) break;
        color_buf[slot] = byte_colors[b];
        written = slot + 1;
    }
    if (written == 0) return null;

    return .{ .row = t.cursor_row, .start = start_col, .colors = color_buf[0..written] };
}

/// Byte offset just past the shell prompt, or null when none is found.
///
/// Recognises the conventional terminators (`$ `, `% `, `# `, `> `) plus the
/// `❯ ` used by starship and friends, taking the *last* one so a prompt that
/// embeds a path with a `#` in it still works.
pub fn promptEnd(line: []const u8) ?usize {
    const markers = [_][]const u8{ "$ ", "% ", "# ", "> ", "\u{276F} ", "\u{27A4} ", "\u{03BB} " };
    var best: ?usize = null;
    for (markers) |m| {
        if (std.mem.lastIndexOf(u8, line, m)) |at| {
            const end = at + m.len;
            if (best == null or end > best.?) best = end;
        }
    }
    return best;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn testBar(count: usize, width: f32) TabBar {
    return .{ .cell_w = 8, .cell_h = 16, .width = width, .count = count };
}

test "tab bar gives tabs their preferred width when there is room" {
    const bar = testBar(2, 800);
    try testing.expectEqual(@as(f32, 8 * 18), bar.tabWidth());
    try testing.expectEqual(@as(f32, 0), bar.tabX(0));
    try testing.expectEqual(@as(f32, 144), bar.tabX(1));
}

test "tabs shrink instead of running off the edge" {
    const bar = testBar(12, 800);
    try testing.expect(bar.tabWidth() < 8 * 18);
    try testing.expect(bar.tabX(11) + bar.tabWidth() <= 800);
}

test "tabs stop shrinking at a readable minimum" {
    const bar = testBar(100, 400);
    try testing.expectEqual(@as(f32, 8 * 8), bar.tabWidth());
}

test "the new-tab button stays on screen when tabs overflow" {
    const bar = testBar(100, 400);
    try testing.expect(bar.plusX() + bar.plusWidth() <= 400);
    const roomy = testBar(2, 800);
    // With room to spare it sits directly after the last tab.
    try testing.expectEqual(roomy.tabX(2), roomy.plusX());
}

test "clicking a tab selects it" {
    const bar = testBar(3, 800);
    try testing.expectEqual(@as(usize, 0), bar.hit(10, 8).tab);
    try testing.expectEqual(@as(usize, 1), bar.hit(150, 8).tab);
    try testing.expectEqual(@as(usize, 2), bar.hit(300, 8).tab);
}

test "clicking the right edge of a tab closes it" {
    const bar = testBar(3, 800);
    try testing.expect(bar.hasClose());
    try testing.expectEqual(@as(usize, 1), bar.hit(bar.closeX(1) + 2, 8).close);
    // Just left of the close box is still a plain selection.
    try testing.expectEqual(@as(usize, 1), bar.hit(bar.closeX(1) - 2, 8).tab);
}

test "narrow tabs drop the close button rather than overlap the label" {
    const bar = testBar(100, 400);
    try testing.expect(!bar.hasClose());
    try testing.expectEqual(@as(usize, 0), bar.hit(4, 8).tab);
}

test "clicking the plus button asks for a new tab" {
    const bar = testBar(3, 800);
    try testing.expectEqual(Hit.new_tab, bar.hit(bar.plusX() + 4, 8));
}

test "clicks outside the bar hit nothing" {
    const bar = testBar(3, 800);
    try testing.expectEqual(Hit.none, bar.hit(10, bar.height())); // below the bar
    try testing.expectEqual(Hit.none, bar.hit(10, 1000));
    try testing.expectEqual(Hit.none, bar.hit(-1, 8));
    // Past the last tab and the button: empty bar.
    try testing.expectEqual(Hit.none, bar.hit(700, 8));
}

test "the tab bar is safe with no tabs at all" {
    const bar = testBar(0, 800);
    try testing.expectEqual(@as(f32, 0), bar.tabWidth());
    try testing.expectEqual(Hit.new_tab, bar.hit(4, 8));
    try testing.expectEqual(Hit.none, bar.hit(400, 8));
}

test "every point in the bar resolves without panicking" {
    for ([_]usize{ 0, 1, 3, 12, 64 }) |count| {
        const bar = testBar(count, 640);
        var x: f32 = 0;
        while (x < 640) : (x += 1) {
            switch (bar.hit(x, 8)) {
                .tab, .close => |i| try testing.expect(i < count),
                .new_tab, .none => {},
            }
        }
    }
}

test "fitLabel keeps a short name intact" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("zsh", fitLabel(&buf, "", "zsh", 16));
}

test "fitLabel elides the head of a long name" {
    var buf: [64]u8 = undefined;
    const out = fitLabel(&buf, "", "/very/long/path/to/project", 10);
    try testing.expectEqual(@as(u32, 10), cellLen(out));
    try testing.expect(std.mem.startsWith(u8, out, "\u{2026}"));
    try testing.expect(std.mem.endsWith(u8, out, "project"));
}

test "fitLabel accounts for the prefix" {
    var buf: [64]u8 = undefined;
    const out = fitLabel(&buf, "\u{2387} ", "prod", 16);
    try testing.expectEqualStrings("\u{2387} prod", out);
    try testing.expectEqual(@as(u32, 6), cellLen(out));
}

test "fitLabel drops the name when the prefix already fills the budget" {
    var buf: [64]u8 = undefined;
    const out = fitLabel(&buf, "abcd", "name", 4);
    try testing.expectEqualStrings("abcd", out);
}

test "fitLabel never writes past the buffer" {
    var buf: [4]u8 = undefined;
    const out = fitLabel(&buf, "", "a much longer name than fits", 20);
    try testing.expect(out.len <= 4);
}

test "cellLen counts code points, not bytes" {
    try testing.expectEqual(@as(u32, 3), cellLen("abc"));
    try testing.expectEqual(@as(u32, 6), cellLen("Привет"));
    try testing.expectEqual(@as(u32, 1), cellLen("\u{2387}"));
}

test "tailCells splits on a code-point boundary" {
    try testing.expectEqualStrings("вет", tailCells("Привет", 3));
    try testing.expectEqualStrings("Привет", tailCells("Привет", 10));
    try testing.expectEqualStrings("cd", tailCells("abcd", 2));
}

test "promptEnd finds the conventional terminators" {
    try testing.expectEqual(@as(usize, 2), promptEnd("$ ").?);
    try testing.expectEqual(@as(usize, 8), promptEnd("user@mac% ").? - 2);
    try testing.expectEqual(@as(usize, 7), promptEnd("~/code> ").? - 1);
    try testing.expectEqual(@as(usize, 2), promptEnd("# ").?);
}

test "promptEnd takes the last marker on the line" {
    const line = "user@host:/tmp# ls -l # note$ ";
    const at = promptEnd(line).?;
    try testing.expectEqualStrings("", line[at..]);
}

test "promptEnd returns null without a prompt" {
    try testing.expect(promptEnd("") == null);
    try testing.expect(promptEnd("just some output") == null);
    try testing.expect(promptEnd("no$marker") == null);
}

test "promptEnd handles a multi-byte prompt character" {
    const line = "~/ztabb \u{276F} git status";
    const at = promptEnd(line).?;
    try testing.expectEqualStrings("git status", line[at..]);
}

test "HighlightOverlay maps only its own columns" {
    const colors = [_]u32{ 1, 2, 3 };
    const o = HighlightOverlay{ .row = 4, .start = 10, .colors = &colors };
    try testing.expect(o.colorAt(9) == null);
    try testing.expectEqual(@as(u32, 1), o.colorAt(10).?);
    try testing.expectEqual(@as(u32, 3), o.colorAt(12).?);
    try testing.expect(o.colorAt(13) == null);
}

test "shellLineOverlay colours the command after the prompt" {
    var t = try term.Terminal.init(testing.allocator, 40, 5, 8);
    defer t.deinit();
    t.write("$ git status");

    var text_buf: [256]u8 = undefined;
    var color_buf: [256]u32 = undefined;
    const o = shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf).?;
    try testing.expectEqual(@as(u32, 0), o.row);
    try testing.expectEqual(@as(u32, 2), o.start); // just past "$ "
    try testing.expectEqual(theme.dark.hl_command, o.colorAt(2).?); // 'g'
    try testing.expectEqual(theme.dark.hl_command, o.colorAt(4).?); // 't'
    try testing.expectEqual(theme.dark.fg, o.colorAt(5).?); // the space
    try testing.expectEqual(theme.dark.hl_unknown, o.colorAt(6).?); // 's'
}

test "shellLineOverlay follows the theme" {
    var t = try term.Terminal.init(testing.allocator, 40, 5, 8);
    defer t.deinit();
    t.write("% ls /tmp");

    var text_buf: [256]u8 = undefined;
    var color_buf: [256]u32 = undefined;
    const o = shellLineOverlay(&t, &theme.light, &text_buf, &color_buf).?;
    try testing.expectEqual(theme.light.hl_command, o.colorAt(2).?);
    try testing.expectEqual(theme.light.hl_path, o.colorAt(5).?);
}

test "shellLineOverlay handles a multi-byte prompt and Cyrillic arguments" {
    var t = try term.Terminal.init(testing.allocator, 40, 5, 8);
    defer t.deinit();
    t.write("\u{276F} cat файл");

    var text_buf: [256]u8 = undefined;
    var color_buf: [256]u32 = undefined;
    const o = shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf).?;
    // The prompt glyph occupies one cell, so the command starts at column 2.
    try testing.expectEqual(@as(u32, 2), o.start);
    try testing.expectEqual(theme.dark.hl_command, o.colorAt(2).?);
    // Each Cyrillic code point must map to exactly one column.
    try testing.expectEqual(theme.dark.hl_unknown, o.colorAt(6).?);
    try testing.expectEqual(theme.dark.hl_unknown, o.colorAt(9).?);
    try testing.expect(o.colorAt(10) == null);
}

test "shellLineOverlay declines when there is no prompt or no input" {
    var t = try term.Terminal.init(testing.allocator, 40, 5, 8);
    defer t.deinit();
    var text_buf: [256]u8 = undefined;
    var color_buf: [256]u32 = undefined;

    try testing.expect(shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf) == null);

    t.write("some program output");
    try testing.expect(shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf) == null);

    // A prompt with nothing typed yet.
    t.write("\r\n$ ");
    try testing.expect(shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf) == null);
}

test "shellLineOverlay stays out of the way of full-screen programs" {
    var t = try term.Terminal.init(testing.allocator, 40, 5, 8);
    defer t.deinit();
    t.write("\x1b[?1049h$ vim");
    var text_buf: [256]u8 = undefined;
    var color_buf: [256]u32 = undefined;
    try testing.expect(shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf) == null);
    t.write("\x1b[?1049l");
}

test "shellLineOverlay stays out of the way while scrolled back" {
    var t = try term.Terminal.init(testing.allocator, 10, 2, 8);
    defer t.deinit();
    t.write("a\r\nb\r\n$ ls");
    t.scrollView(1);
    var text_buf: [256]u8 = undefined;
    var color_buf: [256]u32 = undefined;
    try testing.expect(shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf) == null);
}

test "shellLineOverlay tolerates a colour buffer shorter than the line" {
    var t = try term.Terminal.init(testing.allocator, 60, 3, 8);
    defer t.deinit();
    t.write("$ echo a long command line with many arguments here");
    var text_buf: [256]u8 = undefined;
    var color_buf: [4]u32 = undefined;
    const o = shellLineOverlay(&t, &theme.dark, &text_buf, &color_buf).?;
    try testing.expect(o.colors.len <= 4);
}
