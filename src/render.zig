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
const icons = @import("icons");
const tabs_mod = @import("tabs");
const panes = @import("panes");

pub const TAB_BAR_CELLS: u32 = 2;
/// Breathing room around the terminal grid, in cells. Text hard against the
/// window edge is tiring to read and hides the cursor at column zero.
pub const PAD_X_CELLS: f32 = 0.75;
pub const PAD_Y_CELLS: f32 = 0.5;
/// Preferred width of a tab, in character cells.
pub const TAB_WIDTH_CELLS: u32 = 18;
/// A tab narrower than this loses its close button; below it there is no room
/// for a label as well.
const TAB_MIN_CELLS: u32 = 8;
const TAB_CLOSE_CELLS: u32 = 3;
const PLUS_CELLS: u32 = 3;
/// Space before the tab's icon, and between that icon and the label, in
/// terminal cells.
const TAB_PAD_CELLS: f32 = 1.0;
const TAB_GAP_CELLS: f32 = 0.85;

/// The SSH button beside "+". Wide enough to carry the larger icon: it is the
/// entry point to every saved connection, not a decoration.
const SSH_CELLS: u32 = 4;
/// The connection button is drawn a size up from the rest of the set.
const SSH_ICON_SCALE: f32 = 1.35;

/// What sits under a point in the tab bar. Pure geometry, so the hit testing
/// the mouse handler depends on can be tested without a window.
pub const Hit = union(enum) {
    none,
    tab: usize,
    close: usize,
    new_tab,
    ssh_menu,
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

    pub fn sshWidth(self: TabBar) f32 {
        return self.cell_w * @as(f32, @floatFromInt(SSH_CELLS));
    }

    /// Width of the button cluster tabs must leave room for.
    fn buttonsWidth(self: TabBar) f32 {
        return self.plusWidth() + self.sshWidth();
    }

    /// Tabs share what is left after the "+" button, shrinking as more open
    /// rather than marching off the right edge.
    pub fn tabWidth(self: TabBar) f32 {
        if (self.count == 0) return 0;
        const preferred = self.cell_w * @as(f32, @floatFromInt(TAB_WIDTH_CELLS));
        const available = @max(self.width - self.buttonsWidth(), 0);
        const share = available / @as(f32, @floatFromInt(self.count));
        const min = self.cell_w * @as(f32, @floatFromInt(TAB_MIN_CELLS));
        return @max(@min(preferred, share), min);
    }

    pub fn tabX(self: TabBar, i: usize) f32 {
        return @as(f32, @floatFromInt(i)) * self.tabWidth();
    }

    pub fn plusX(self: TabBar) f32 {
        return @min(self.tabX(self.count), @max(self.width - self.buttonsWidth(), 0));
    }

    pub fn sshX(self: TabBar) f32 {
        return self.plusX() + self.plusWidth();
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
        const ssh_x = self.sshX();
        if (x >= ssh_x and x < ssh_x + self.sshWidth()) return .ssh_menu;

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
    /// Terminal text, in the weights the grid uses.
    atlas_size: font.Size,
    /// The point size and display density the atlases were baked for.
    points: u32,
    density: u32,
    /// Where the interface face's marks sit inside its cell.
    ui_ink: font.Ink = .{ .top = 0, .bottom = 0 },
    /// Which glyphs have nothing to draw, for each atlas in use.
    blank_regular: font.BlankSet = .{},
    blank_bold: font.BlankSet = .{},
    blank_ui: font.BlankSet = .{},
    /// Interface text: weight 500 at a smaller size, for tab labels and
    /// dialogs. Terminal text has to stay on the grid; chrome does not, and
    /// reads better a step down in size and a step up in weight.
    ui: *sdl.Texture,
    ui_size: font.Size,
    /// One texture holding every UI icon, rasterized at the current cell size.
    icon_strip: *sdl.Texture,
    icon_size: u32,

    pub fn init(gpa: std.mem.Allocator, r: *sdl.Renderer) !Renderer {
        var self = Renderer{
            .gpa = gpa,
            .r = r,
            .regular = undefined,
            .bold = undefined,
            .atlas_size = font.termSize(font.default_points, 1, .regular),
            .points = font.default_points,
            .density = 1,
            .ui = undefined,
            .ui_size = font.uiSize(font.default_points, 1),
            .icon_strip = undefined,
            .icon_size = 0,
        };
        try self.uploadAtlas(self.atlas_size);
        errdefer {
            sdl.destroyTexture(self.bold);
            sdl.destroyTexture(self.regular);
        }
        try self.uploadUi(self.ui_size);
        errdefer sdl.destroyTexture(self.ui);
        try self.uploadIcons(self.iconSize());
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        sdl.destroyTexture(self.icon_strip);
        sdl.destroyTexture(self.ui);
        sdl.destroyTexture(self.bold);
        sdl.destroyTexture(self.regular);
    }

    fn uploadUi(self: *Renderer, size: font.Size) !void {
        const pixels = try self.gpa.alloc(u32, font.atlasPixels(size));
        defer self.gpa.free(pixels);
        const w: i32 = @intCast(font.atlasW(size));
        font.buildAtlas(size, pixels);
        const tex = try sdl.createTexture(self.r, w, @intCast(font.atlasH(size)), false);
        sdl.updateTexture(tex, pixels, w * 4);
        self.ui = tex;
        self.ui_size = size;
        self.blank_ui = font.BlankSet.build(size);
        self.ui_ink = font.Ink.measure(size);
    }

    /// Icons are sized off the interface text, not the tab bar: an icon a
    /// little taller than the label beside it sits with the text instead of
    /// looming over it.
    fn iconDrawSize(self: *const Renderer) f32 {
        return @round(self.uiCellH() * 0.85);
    }

    /// The size icons are rasterized at. It matches the largest they are drawn
    /// so nothing is scaled up on screen.
    fn iconSize(self: *const Renderer) u32 {
        return @max(10, @as(u32, @intFromFloat(self.iconDrawSize() * SSH_ICON_SCALE)));
    }

    fn uploadIcons(self: *Renderer, size: u32) !void {
        const pixels = try self.gpa.alloc(u32, icons.stripPixels(size));
        defer self.gpa.free(pixels);
        icons.buildStrip(size, pixels);

        const w: i32 = @intCast(icons.stripW(size));
        // Icons are drawn smaller than they are rasterized, so they want the
        // smoothing filter; the glyph atlases are drawn 1:1 and do not.
        const tex = try sdl.createTexture(self.r, w, @intCast(size), true);
        sdl.updateTexture(tex, pixels, w * 4);
        self.icon_strip = tex;
        self.icon_size = size;
    }

    /// Draws an icon centred in the box at (x, y, w, h), at `scale` times the
    /// standard icon size.
    fn drawIcon(
        self: *Renderer,
        icon: icons.Icon,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        color: u32,
        scale: f32,
    ) void {
        const s: f32 = @floatFromInt(self.icon_size);
        const src = sdl.FRect{
            .x = @floatFromInt(icons.stripX(icon, self.icon_size)),
            .y = 0,
            .w = s,
            .h = s,
        };
        // Square, and never larger than the box it is centred in.
        const side = @min(self.iconDrawSize() * scale, @min(w, h));
        const dst = sdl.FRect{
            .x = @round(x + (w - side) / 2),
            .y = @round(y + (h - side) / 2),
            .w = side,
            .h = side,
        };
        sdl.setTextureColorMod(self.icon_strip, color);
        sdl.renderTexture(self.r, self.icon_strip, &src, &dst);
    }

    fn uploadAtlas(self: *Renderer, size: font.Size) !void {
        const pixels = try self.gpa.alloc(u32, font.atlasPixels(size));
        defer self.gpa.free(pixels);

        const w: i32 = @intCast(font.atlasW(size));
        const h: i32 = @intCast(font.atlasH(size));

        font.buildAtlas(size, pixels);
        const regular = try sdl.createTexture(self.r, w, h, false);
        errdefer sdl.destroyTexture(regular);
        sdl.updateTexture(regular, pixels, w * 4);

        font.buildAtlas(font.termSize(size.points, size.density, .bold), pixels);
        const bold = try sdl.createTexture(self.r, w, h, false);
        errdefer sdl.destroyTexture(bold);
        sdl.updateTexture(bold, pixels, w * 4);

        self.regular = regular;
        self.bold = bold;
        self.atlas_size = size;
        self.blank_regular = font.BlankSet.build(size);
        self.blank_bold = font.BlankSet.build(font.termSize(size.points, size.density, .bold));
    }

    /// Re-bakes the atlas when the cell size moves to a different glyph set,
    /// so text is rasterized at the resolution it is drawn at rather than
    /// stretched up from the smallest baked size.
    /// Switches to a terminal face at `points` on a display of `density`,
    /// re-baking whatever changed. The interface face and the icons follow the
    /// terminal size, so all three stay in proportion.
    pub fn setFont(self: *Renderer, points: u32, density: u32) void {
        self.points = points;
        self.density = density;
        defer self.refreshIcons();
        defer self.refreshUi();

        const wanted = font.termSize(points, density, .regular);
        if (wanted.offset == self.atlas_size.offset) return;

        const old_regular = self.regular;
        const old_bold = self.bold;
        self.uploadAtlas(wanted) catch return;
        sdl.destroyTexture(old_regular);
        sdl.destroyTexture(old_bold);
    }

    fn refreshUi(self: *Renderer) void {
        const wanted = font.uiSize(self.points, self.density);
        if (wanted.offset == self.ui_size.offset) return;
        const old = self.ui;
        self.uploadUi(wanted) catch return;
        sdl.destroyTexture(old);
    }

    /// Re-rasterizes the icons when the cell size changes, so they stay sharp
    /// rather than being scaled up from the size they were first built at.
    fn refreshIcons(self: *Renderer) void {
        const wanted = self.iconSize();
        if (wanted == self.icon_size) return;
        const old = self.icon_strip;
        self.uploadIcons(wanted) catch return;
        sdl.destroyTexture(old);
    }

    /// The inset the grid is drawn at, in pixels.
    pub fn padX(self: *const Renderer) f32 {
        return @round(@as(f32, @floatFromInt(self.cellW())) * PAD_X_CELLS);
    }

    pub fn padY(self: *const Renderer) f32 {
        return @round(@as(f32, @floatFromInt(self.cellH())) * PAD_Y_CELLS);
    }

    /// The terminal cell, in backbuffer pixels.
    pub fn cellW(self: *const Renderer) u32 {
        return self.atlas_size.w;
    }

    pub fn cellH(self: *const Renderer) u32 {
        return self.atlas_size.h;
    }

    /// Queues one glyph. The caller owns the colour state, so a run of cells
    /// sharing a colour costs one state change instead of one per cell --
    /// every change flushes SDL's batch, and a full window of ordinary output
    /// is thousands of cells in a single colour.
    fn queueGlyph(self: *Renderer, tex: *sdl.Texture, cp: u21, x: f32, y: f32) void {
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
        sdl.renderTexture(self.r, tex, &src, &dst);
    }

    fn blankSet(self: *const Renderer, bold: bool) *const font.BlankSet {
        return if (bold) &self.blank_bold else &self.blank_regular;
    }

    fn drawGlyph(self: *Renderer, cp: u21, x: f32, y: f32, color: u32, bold: bool) void {
        if (cp == ' ' or cp == 0) return;
        if (self.blankSet(bold).has(cp)) return;

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

    /// Draws interface text -- tab labels, dialogs -- in the medium face at
    /// its own smaller cell. Returns the width used, in pixels.
    pub fn drawUiText(self: *Renderer, text: []const u8, x: f32, y: f32, color: u32) f32 {
        var view = std.unicode.Utf8View.init(text) catch return 0;
        var it = view.iterator();
        const cw: f32 = @floatFromInt(self.ui_size.w);
        const ch: f32 = @floatFromInt(self.ui_size.h);
        var col: f32 = 0;
        while (it.nextCodepoint()) |cp| : (col += 1) {
            if (cp == ' ' or cp == 0 or self.blank_ui.has(cp)) continue;
            const rect = font.atlasRect(cp, self.ui_size);
            const src = sdl.FRect{
                .x = @floatFromInt(rect.x),
                .y = @floatFromInt(rect.y),
                .w = cw,
                .h = ch,
            };
            const dst = sdl.FRect{ .x = @round(x + col * cw), .y = @round(y), .w = cw, .h = ch };
            sdl.setTextureColorMod(self.ui, color);
            sdl.renderTexture(self.r, self.ui, &src, &dst);
        }
        return col * cw;
    }

    pub fn uiCellW(self: *const Renderer) f32 {
        return @floatFromInt(self.ui_size.w);
    }

    pub fn uiCellH(self: *const Renderer) f32 {
        return @floatFromInt(self.ui_size.h);
    }

    /// The y to hand `drawUiText` so its marks sit centred in a box, level
    /// with an icon centred in the same box.
    ///
    /// Centring the cell instead leaves text low: the cell carries the whole
    /// font box, and the room above the capitals is not matched below.
    pub fn uiTextY(self: *const Renderer, box_top: f32, box_h: f32) f32 {
        const ink_h: f32 = @floatFromInt(self.ui_ink.height());
        const ink_top: f32 = @floatFromInt(self.ui_ink.top);
        return @round(box_top + (box_h - ink_h) / 2 - ink_top);
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

    /// One device pixel, so rules stay a hair wide on any display.
    fn hairline(self: *const Renderer) f32 {
        return @floatFromInt(@max(self.density, 1));
    }

    fn fill(self: *Renderer, x: f32, y: f32, w: f32, h: f32, color: u32) void {
        sdl.setRenderDrawRgb(self.r, color);
        const rect = sdl.FRect{ .x = x, .y = y, .w = w, .h = h };
        sdl.renderFillRect(self.r, &rect);
    }

    /// A vertical gradient, drawn as one-pixel bands.
    ///
    /// SDL's fill takes a single colour, so the sweep is built from strips;
    /// at tab-bar height that is a few dozen rectangles for the one focused
    /// tab, which costs nothing next to the glyphs on screen.
    fn fillVGradient(
        self: *Renderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        top: u32,
        bottom: u32,
    ) void {
        const bands: u32 = @intFromFloat(@max(1, @min(h, 64)));
        const step = h / @as(f32, @floatFromInt(bands));
        for (0..bands) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(bands - 1 | 1));
            self.fill(
                x,
                y + @as(f32, @floatFromInt(i)) * step,
                w,
                // Overlap by a hair so rounding cannot leave seams between bands.
                step + 1,
                theme.mix(bottom, top, t),
            );
        }
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
        sel: ?term.Selection,
    ) void {
        self.drawPane(t, th, .{ .x = 0, .y = 0, .w = t.cols, .h = t.rows }, top, hl, sel);
    }

    /// Draws one pane's grid at its place in the tab.
    pub fn drawPane(
        self: *Renderer,
        t: *const term.Terminal,
        th: *const theme.Theme,
        rect: panes.Rect,
        top: f32,
        hl: ?HighlightOverlay,
        sel: ?term.Selection,
    ) void {
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const left = self.padX() + @as(f32, @floatFromInt(rect.x)) * cw;
        const origin = top + self.padY() + @as(f32, @floatFromInt(rect.y)) * ch;

        for (0..t.rows) |ri| {
            const row: u32 = @intCast(ri);
            const cells = t.viewRow(row);
            const y = origin + @as(f32, @floatFromInt(row)) * ch;

            // Background first, merging horizontal runs of one colour so a
            // full-width bar costs one draw call instead of `cols` of them.
            var run_start: u32 = 0;
            var run_color: u32 = if (sel != null and sel.?.contains(row, 0))
                th.selection
            else
                term.Terminal.resolve(cells[0], th).bg;
            for (1..t.cols + 1) |ci| {
                const c: u32 = @intCast(ci);
                const color = if (c < t.cols) blk: {
                    if (sel) |sl| {
                        if (sl.contains(row, c)) break :blk th.selection;
                    }
                    break :blk term.Terminal.resolve(cells[c], th).bg;
                } else ~run_color;
                if (color == run_color) continue;
                if (run_color != th.bg) {
                    self.fill(
                        left + @as(f32, @floatFromInt(run_start)) * cw,
                        y,
                        @as(f32, @floatFromInt(c - run_start)) * cw,
                        ch,
                        run_color,
                    );
                }
                run_start = c;
                run_color = color;
            }

            // Glyphs, batched by colour and weight: the colour mod is what
            // breaks SDL's batching, so it is set once per run rather than
            // once per cell.
            var bound_tex: ?*sdl.Texture = null;
            var bound_color: u32 = 0;
            for (0..t.cols) |ci| {
                const col: u32 = @intCast(ci);
                const cell = cells[col];
                if (cell.ch == ' ' or cell.ch == 0) continue;
                const bold = cell.attrs.bold;
                if (self.blankSet(bold).has(cell.ch)) continue;

                var fg = term.Terminal.resolve(cell, th).fg;
                if (hl) |o| {
                    if (o.row == row) {
                        if (o.colorAt(col)) |c| fg = c;
                    }
                }

                const tex = if (bold) self.bold else self.regular;
                if (bound_tex != tex or bound_color != fg) {
                    sdl.setTextureColorMod(tex, fg);
                    bound_tex = tex;
                    bound_color = fg;
                }

                const x = left + @as(f32, @floatFromInt(col)) * cw;
                self.queueGlyph(tex, cell.ch, x, y);

                if (cell.attrs.underline) {
                    self.fill(x, y + ch - self.hairline(), cw, self.hairline(), fg);
                    bound_tex = null; // the fill reset the batch
                }
                if (cell.attrs.strike) {
                    self.fill(x, y + ch / 2, cw, self.hairline(), fg);
                    bound_tex = null;
                }
            }
        }

        self.drawCursor(t, th, origin, left);
        self.drawScrollIndicator(t, th, origin, left);
    }

    /// The rule between two panes.
    pub fn drawDivider(self: *Renderer, th: *const theme.Theme, rect: panes.Rect, top: f32, vertical: bool) void {
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const x = self.padX() + @as(f32, @floatFromInt(rect.x)) * cw;
        const y = top + self.padY() + @as(f32, @floatFromInt(rect.y)) * ch;
        if (vertical) {
            self.fill(x + cw / 2 - self.hairline() / 2, y, self.hairline(), @as(f32, @floatFromInt(rect.h)) * ch, th.tab_border);
        } else {
            self.fill(x, y + ch / 2 - self.hairline() / 2, @as(f32, @floatFromInt(rect.w)) * cw, self.hairline(), th.tab_border);
        }
    }

    fn drawCursor(self: *Renderer, t: *const term.Terminal, th: *const theme.Theme, top: f32, left: f32) void {
        // While scrolled back, the cursor belongs to a screen the user is not
        // looking at, so hide it rather than drawing it at the wrong row.
        if (!t.cursor_visible or t.view_offset != 0) return;
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const x = left + @as(f32, @floatFromInt(t.cursor_col)) * cw;
        const y = top + @as(f32, @floatFromInt(t.cursor_row)) * ch;
        self.fill(x, y, cw, ch, th.cursor);

        const cell = t.cellAt(t.cursor_row, t.cursor_col);
        self.drawGlyph(cell.ch, x, y, th.cursor_text, cell.attrs.bold);
    }

    /// A slim bar on the right edge showing the scrollback position.
    fn drawScrollIndicator(self: *Renderer, t: *const term.Terminal, th: *const theme.Theme, top: f32, left: f32) void {
        if (t.view_offset == 0 or t.sb_len == 0) return;
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const height = @as(f32, @floatFromInt(t.rows)) * ch;
        const width = @max(2.0, cw / 4.0);
        const x = left + @as(f32, @floatFromInt(t.cols)) * cw - width;

        const total: f32 = @floatFromInt(t.sb_len + t.rows);
        const thumb = @max(ch, height * @as(f32, @floatFromInt(t.rows)) / total);
        const back: f32 = @floatFromInt(t.sb_len - t.view_offset);
        const y = top + (height - thumb) * back / @as(f32, @floatFromInt(t.sb_len));
        self.fill(x, y, width, thumb, th.ansi[8]);
    }

    // -- tab bar -----------------------------------------------------------

    pub fn drawTabBar(
        self: *Renderer,
        tabs: *tabs_mod.Tabs,
        th: *const theme.Theme,
        width: f32,
        top: f32,
    ) void {
        const cw: f32 = @floatFromInt(self.cellW());
        const bar = self.tabBar(tabs.count, width);
        const bar_h = bar.height();
        const tab_w = bar.tabWidth();
        self.fill(0, top, width, bar_h, th.tab_bar_bg);

        for (tabs.slice(), 0..) |*tab, i| {
            const x = bar.tabX(i);
            if (x >= width) break;
            const is_active = tabs.isActive(i);
            if (is_active) {
                // The focused tab is washed with the accent at the top and
                // settles into the terminal's own ground at the bottom, so it
                // reads as the front-most tab without a hard outline.
                self.fillVGradient(
                    x,
                    top,
                    tab_w - 1,
                    bar_h,
                    theme.tabGradientTop(th),
                    th.tab_active_bg,
                );
                self.fill(x, top, tab_w - 1, @max(2.0, self.hairline() * 2), th.ansi[4]);
            } else {
                self.fill(x, top, tab_w - 1, bar_h, th.tab_inactive_bg);
            }
            self.fill(x + tab_w - 1, top, 1, bar_h, th.tab_border);

            const fg = if (is_active) th.tab_active_fg else th.tab_inactive_fg;

            // A globe or prompt icon marks what kind of tab this is, set in
            // from the edge and given room before the label starts.
            self.drawIcon(
                if (tab.kind == .ssh) .remote else .terminal,
                x + TAB_PAD_CELLS * cw,
                top,
                self.iconDrawSize(),
                bar_h,
                if (is_active) th.ansi[4] else th.tab_inactive_fg,
                1.0,
            );

            // The label is set in the smaller interface face, so its budget is
            // counted in that cell rather than the terminal's.
            const label_x = x + TAB_PAD_CELLS * cw + self.iconDrawSize() + TAB_GAP_CELLS * cw;
            const room = tab_w - (label_x - x) - if (bar.hasClose())
                cw * @as(f32, @floatFromInt(TAB_CLOSE_CELLS))
            else
                cw / 2;
            const budget: u32 = @intFromFloat(@max(0, room / self.uiCellW()));
            self.drawTabLabel(
                tab.labelParts(),
                label_x,
                self.uiTextY(top, bar_h),
                budget,
                fg,
                th.tab_inactive_fg,
            );

            if (bar.hasClose()) {
                self.drawIcon(
                    .close,
                    bar.closeX(i),
                    top,
                    cw * @as(f32, @floatFromInt(TAB_CLOSE_CELLS)),
                    bar_h,
                    if (is_active) th.tab_active_fg else th.tab_inactive_fg,
                    0.85,
                );
            }
        }

        // "+" opens a shell tab; the caret beside it drops down the SSH host
        // list. Without them neither is discoverable without the shortcuts.
        const plus_x = bar.plusX();
        self.fill(plus_x, top, bar.plusWidth(), bar_h, th.tab_bar_bg);
        self.drawIcon(.plus, plus_x, top, bar.plusWidth(), bar_h, th.tab_active_fg, 1.0);

        // The SSH button carries the connection icon at full size with a small
        // caret under it, so it reads as "open the list of connections".
        const ssh_x = bar.sshX();
        const ssh_w = bar.sshWidth();
        self.fill(ssh_x, top, ssh_w, bar_h, th.tab_bar_bg);
        self.drawIcon(.remote, ssh_x, top, ssh_w - cw * 0.8, bar_h, th.ansi[4], SSH_ICON_SCALE);
        self.drawIcon(
            .chevron_down,
            ssh_x + ssh_w - cw,
            top + bar_h * 0.34,
            cw * 0.8,
            bar_h * 0.5,
            th.tab_inactive_fg,
            0.6,
        );

        self.fill(0, top + bar_h - 1, width, 1, th.tab_border);
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

    /// The cell under a point in the tab's own coordinates, before any pane
    /// is taken into account. Not clamped: a point on a divider has no cell.
    pub fn cellAtTab(self: *const Renderer, top: f32, x: f32, y: f32) struct { row: u32, col: u32 } {
        const col_f = (x - self.padX()) / @as(f32, @floatFromInt(self.cellW()));
        const row_f = (y - top - self.padY()) / @as(f32, @floatFromInt(self.cellH()));
        return .{
            .row = if (row_f <= 0) 0 else @intFromFloat(row_f),
            .col = if (col_f <= 0) 0 else @intFromFloat(col_f),
        };
    }

    /// The grid cell under a point, clamped to the grid. `top` is where the
    /// terminal area begins.
    pub fn cellAt(self: *const Renderer, t: *const term.Terminal, top: f32, x: f32, y: f32) struct { row: u32, col: u32 } {
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const col_f = (x - self.padX()) / cw;
        const row_f = (y - top - self.padY()) / ch;
        const col: u32 = if (col_f <= 0) 0 else @intFromFloat(col_f);
        const row: u32 = if (row_f <= 0) 0 else @intFromFloat(row_f);
        return .{ .row = @min(row, t.rows - 1), .col = @min(col, t.cols) };
    }

    /// Draws a split label: the path dim, the directory bright.
    ///
    /// When the parts do not fit, the trailing context goes first and the
    /// leading path is elided from the left, because the last component is
    /// what tells two tabs apart.
    fn drawTabLabel(
        self: *Renderer,
        parts: tabs_mod.Tab.Label,
        x: f32,
        y: f32,
        budget: u32,
        bright: u32,
        dim: u32,
    ) void {
        const fitted = fitParts(parts, budget);
        var at = x;
        var buf: [tabs_mod.MAX_LABEL * 2 + 8]u8 = undefined;

        if (fitted.prefix.len > 0) {
            const text = if (fitted.elided) blk: {
                const ell = "\u{2026}";
                @memcpy(buf[0..ell.len], ell);
                @memcpy(buf[ell.len..][0..fitted.prefix.len], fitted.prefix);
                break :blk buf[0 .. ell.len + fitted.prefix.len];
            } else fitted.prefix;
            at += self.drawUiText(text, at, y, dim);
        }
        at += self.drawUiText(fitted.name, at, y, bright);
        if (fitted.suffix.len > 0) {
            at += self.uiCellW();
            _ = self.drawUiText(fitted.suffix, at, y, dim);
        }
    }

    /// Draws the title into the strip the system title bar left transparent:
    /// a terminal mark, the active tab bright, then the program name dimmed.
    /// The dimming is what separates the two, so no punctuation between them.
    ///
    /// `inset` is where the window's own buttons end; the title starts there.
    pub fn drawTitle(
        self: *Renderer,
        name: []const u8,
        kind_icon: icons.Icon,
        th: *const theme.Theme,
        width: f32,
        height: f32,
        inset: f32,
    ) void {
        if (height <= 0) return;
        const cw: f32 = @floatFromInt(self.cellW());
        self.fill(0, 0, width, height, th.tab_bar_bg);

        const icon = self.iconDrawSize() * 0.8;
        var at = inset + cw / 2;
        self.drawIcon(kind_icon, at, 0, icon, height, th.ansi[4], 0.8);
        at += icon + cw / 3;

        const y = self.uiTextY(0, height);
        at += self.drawUiText(name, at, y, th.tab_active_fg);
        _ = self.drawUiText(" ztabb", at, y, th.tab_inactive_fg);
    }

    /// Geometry of the host picker, shared by drawing and mouse hit testing.
    pub fn picker(self: *const Renderer, count: usize, width: f32, height: f32) Picker {
        return .{
            .cell_w = @floatFromInt(self.cellW()),
            .cell_h = @floatFromInt(self.cellH()),
            .width = width,
            .height = height,
            .count = count,
        };
    }

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
        const p = self.picker(hosts.len, width, height);
        const x = p.boxX();
        const y = p.boxY();

        // Dim the terminal behind the modal.
        self.fill(0, 0, width, height, th.tab_bar_bg);
        self.fill(x - 2, y - 2, p.boxW() + 4, p.boxH() + 4, th.tab_border);
        self.fill(x, y, p.boxW(), p.boxH(), th.bg);

        _ = self.drawUiText(
            "SSH hosts  (\u{2191}/\u{2193} or click, Enter open, Esc cancel)",
            x + cw,
            self.uiTextY(y, ch),
            th.ansi[4],
        );

        if (hosts.len == 0) {
            _ = self.drawUiText("no hosts in ~/.ssh/config", x + cw, y + ch * 2, th.tab_inactive_fg);
            return;
        }

        const first = p.firstVisible(selected);
        for (hosts[first..][0..p.visible()], 0..) |host, i| {
            const row_y = p.rowY(i);
            const is_sel = first + i == selected;
            if (is_sel) self.fill(x + cw / 2, row_y, p.boxW() - cw, ch, th.selection);

            const fg = if (is_sel) th.fg else th.hl_command;
            const text_y = self.uiTextY(row_y, ch);
            const used = self.drawUiText(host.alias, x + cw, text_y, fg);
            if (host.detail.len > 0) {
                const gap = @max(used + self.uiCellW(), self.uiCellW() * 18);
                _ = self.drawUiText(host.detail, x + cw + gap, text_y, th.tab_inactive_fg);
            }
        }
    }

    /// A transient message strip at the bottom of the window.
    pub fn drawToast(self: *Renderer, text: []const u8, th: *const theme.Theme, width: f32, height: f32) void {
        const cw: f32 = @floatFromInt(self.cellW());
        const ch: f32 = @floatFromInt(self.cellH());
        const y = height - ch * 1.5;
        self.fill(0, y, width, ch * 1.5, th.tab_bar_bg);
        _ = self.drawUiText(text, cw, self.uiTextY(y, ch * 1.5), th.fg);
    }
};

/// Layout of the SSH host modal. Pure geometry so the click handling can be
/// tested without a window.
pub const Picker = struct {
    cell_w: f32,
    cell_h: f32,
    width: f32,
    height: f32,
    count: usize,

    /// Rows the box will show at once, before the window's own height is
    /// taken into account. A list that fits should not have to be scrolled.
    pub const MAX_ROWS: usize = 32;
    const BOX_COLS: u32 = 52;
    /// Title row plus padding above and below the list.
    const CHROME_ROWS: usize = 4;
    const FIRST_ROW: f32 = 2.0;

    pub fn visible(self: Picker) usize {
        // Never taller than the window it sits in, leaving space for the box's
        // own chrome and a margin top and bottom. Clamped in floating point:
        // a window shorter than the chrome would otherwise go negative.
        const fits = self.height / self.cell_h - @as(f32, CHROME_ROWS + 2);
        const room: usize = if (fits < 1) 1 else @intFromFloat(fits);
        return @max(@min(@min(self.count, MAX_ROWS), room), 1);
    }

    pub fn boxW(self: Picker) f32 {
        return @as(f32, @floatFromInt(BOX_COLS)) * self.cell_w;
    }

    pub fn boxH(self: Picker) f32 {
        return @as(f32, @floatFromInt(self.visible() + CHROME_ROWS)) * self.cell_h;
    }

    pub fn boxX(self: Picker) f32 {
        return @max(0, (self.width - self.boxW()) / 2);
    }

    pub fn boxY(self: Picker) f32 {
        return @max(0, (self.height - self.boxH()) / 2);
    }

    /// Index of the first host on screen, scrolled so `selected` is visible.
    pub fn firstVisible(self: Picker, selected: usize) usize {
        const v = self.visible();
        return if (selected >= v) selected - v + 1 else 0;
    }

    /// Top edge of the i-th *visible* row.
    pub fn rowY(self: Picker, i: usize) f32 {
        return self.boxY() + self.cell_h * (FIRST_ROW + @as(f32, @floatFromInt(i)));
    }

    /// The host index under a point, or null when the click missed the list.
    pub fn hitRow(self: Picker, x: f32, y: f32, selected: usize) ?usize {
        if (self.count == 0) return null;
        if (x < self.boxX() or x >= self.boxX() + self.boxW()) return null;
        const top = self.rowY(0);
        if (y < top) return null;
        const i: usize = @intFromFloat((y - top) / self.cell_h);
        if (i >= self.visible()) return null;
        return self.firstVisible(selected) + i;
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

pub const FittedLabel = struct {
    prefix: []const u8 = "",
    name: []const u8 = "",
    suffix: []const u8 = "",
    /// The prefix was cut from the left and wants an ellipsis in front of it.
    elided: bool = false,
};

/// Trims a split label down to `budget` cells, giving up the least useful part
/// first: the trailing context, then the leading path, and only then the name.
pub fn fitParts(parts: tabs_mod.Tab.Label, budget: u32) FittedLabel {
    var out = FittedLabel{ .prefix = parts.prefix, .name = parts.name, .suffix = parts.suffix };
    if (budget == 0) return .{};

    // The suffix is context; drop it whole rather than cutting into it.
    if (cellLen(out.prefix) + cellLen(out.name) + cellLen(out.suffix) + 1 > budget) {
        out.suffix = "";
    }
    if (cellLen(out.prefix) + cellLen(out.name) <= budget) return out;

    // Cut the path from the left, keeping the components nearest the name.
    const name_cells = cellLen(out.name);
    if (name_cells + 2 <= budget) {
        const room = budget - name_cells - 1; // one cell for the ellipsis
        out.prefix = tailCells(out.prefix, room);
        out.elided = true;
        return out;
    }

    // Not even the name fits: keep its tail, which is the part that differs.
    out.prefix = "";
    out.elided = false;
    out.name = tailCells(out.name, budget);
    return out;
}

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

test "the SSH button is the larger of the two, being the connection entry point" {
    const bar = testBar(3, 800);
    try testing.expect(bar.sshWidth() > bar.plusWidth());
    // Its icon is drawn a size up from the rest of the set, and the button has
    // to be wide enough to hold it.
    try testing.expect(SSH_ICON_SCALE > 1.0);
}

test "the buttons sit side by side, in order, without overlapping" {
    // The globe is drawn from the same geometry the hit test reads, so the two
    // cannot drift apart: it was drawn at the window top while its click area
    // stayed on the tab bar, which left it looking misplaced and dead.
    for ([_]usize{ 0, 1, 5, 40 }) |count| {
        const bar = testBar(count, 800);
        try testing.expectEqual(bar.plusX() + bar.plusWidth(), bar.sshX());
        try testing.expect(bar.sshX() + bar.sshWidth() <= 800);

        // Every point of each button answers as that button.
        var x = bar.plusX();
        while (x < bar.plusX() + bar.plusWidth()) : (x += 1) {
            try testing.expectEqual(Hit.new_tab, bar.hit(x, bar.height() / 2));
        }
        x = bar.sshX();
        while (x < bar.sshX() + bar.sshWidth()) : (x += 1) {
            try testing.expectEqual(Hit.ssh_menu, bar.hit(x, bar.height() / 2));
        }
    }
}

test "the buttons answer across the full height of the bar" {
    const bar = testBar(3, 800);
    var y: f32 = 0;
    while (y < bar.height()) : (y += 1) {
        try testing.expectEqual(Hit.ssh_menu, bar.hit(bar.sshX() + 1, y));
    }
    // ...and not below it, where the terminal starts.
    try testing.expectEqual(Hit.none, bar.hit(bar.sshX() + 1, bar.height()));
}

test "the SSH caret sits beside the plus and opens the host list" {
    const bar = testBar(3, 800);
    try testing.expectEqual(bar.plusX() + bar.plusWidth(), bar.sshX());
    try testing.expectEqual(Hit.ssh_menu, bar.hit(bar.sshX() + 4, 8));
    // The two buttons must not overlap.
    try testing.expectEqual(Hit.new_tab, bar.hit(bar.sshX() - 1, 8));
    try testing.expectEqual(Hit.ssh_menu, bar.hit(bar.sshX(), 8));
}

test "both buttons stay on screen when tabs overflow" {
    const bar = testBar(100, 400);
    try testing.expect(bar.sshX() + bar.sshWidth() <= 400);
    try testing.expectEqual(Hit.new_tab, bar.hit(bar.plusX() + 1, 8));
    try testing.expectEqual(Hit.ssh_menu, bar.hit(bar.sshX() + 1, 8));
}

fn testPicker(count: usize) Picker {
    return .{ .cell_w = 8, .cell_h = 16, .width = 800, .height = 600, .count = count };
}

test "the picker box is centred and sized to its list" {
    const small = testPicker(3);
    try testing.expectEqual(@as(usize, 3), small.visible());
    try testing.expectEqual(@as(f32, 16 * 7), small.boxH()); // 3 rows + chrome
    try testing.expectEqual((800 - small.boxW()) / 2, small.boxX());
}

test "a long list uses the window rather than scrolling early" {
    // 600px of window at a 16px cell leaves room for well over the 14 rows
    // the box used to stop at.
    const big = testPicker(100);
    try testing.expect(big.visible() > 14);
    try testing.expect(big.boxH() <= 600);
}

test "the picker never grows past the window it sits in" {
    for ([_]f32{ 200, 400, 600, 1200 }) |height| {
        const p: Picker = .{ .cell_w = 8, .cell_h = 16, .width = 800, .height = height, .count = 500 };
        try testing.expect(p.visible() >= 1);
        try testing.expect(p.boxH() <= height);
        // ...and the rows it does show all land inside the box.
        try testing.expect(p.rowY(p.visible() - 1) + p.cell_h <= p.boxY() + p.boxH());
    }
}

test "a tiny window still shows one row" {
    const p: Picker = .{ .cell_w = 8, .cell_h = 16, .width = 200, .height = 40, .count = 50 };
    try testing.expectEqual(@as(usize, 1), p.visible());
}

test "the picker scrolls to keep the selection visible" {
    const p: Picker = .{ .cell_w = 8, .cell_h = 16, .width = 800, .height = 600, .count = 100 };
    const v = p.visible();
    try testing.expectEqual(@as(usize, 0), p.firstVisible(0));
    try testing.expectEqual(@as(usize, 0), p.firstVisible(v - 1));
    try testing.expectEqual(@as(usize, 1), p.firstVisible(v));
    try testing.expectEqual(100 - v, p.firstVisible(99));
}

test "clicking a row in the picker names the right host" {
    const p = testPicker(5);
    try testing.expectEqual(@as(usize, 0), p.hitRow(p.boxX() + 10, p.rowY(0) + 2, 0).?);
    try testing.expectEqual(@as(usize, 2), p.hitRow(p.boxX() + 10, p.rowY(2) + 2, 0).?);
    try testing.expectEqual(@as(usize, 4), p.hitRow(p.boxX() + 10, p.rowY(4) + 2, 0).?);
}

test "a click in a scrolled picker accounts for the offset" {
    const p = testPicker(100);
    const selected = p.visible() + 4; // scrolled down by 5
    try testing.expectEqual(@as(usize, 5), p.hitRow(p.boxX() + 10, p.rowY(0) + 2, selected).?);
}

test "clicks outside the picker list hit nothing" {
    const p = testPicker(5);
    try testing.expect(p.hitRow(p.boxX() - 1, p.rowY(0) + 2, 0) == null);
    try testing.expect(p.hitRow(p.boxX() + p.boxW(), p.rowY(0) + 2, 0) == null);
    try testing.expect(p.hitRow(p.boxX() + 10, p.boxY(), 0) == null); // title row
    try testing.expect(p.hitRow(p.boxX() + 10, p.rowY(5) + 2, 0) == null); // past the end
    try testing.expect(testPicker(0).hitRow(400, 300, 0) == null);
}

test "every point in the picker resolves without panicking" {
    for ([_]usize{ 0, 1, 5, 14, 60 }) |count| {
        const p = testPicker(count);
        var y: f32 = 0;
        while (y < 600) : (y += 3) {
            var x: f32 = 0;
            while (x < 800) : (x += 17) {
                if (p.hitRow(x, y, 0)) |i| try testing.expect(i < count);
            }
        }
    }
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
                .new_tab, .ssh_menu, .none => {},
            }
        }
    }
}

fn label(prefix: []const u8, name: []const u8, suffix: []const u8) tabs_mod.Tab.Label {
    return .{ .prefix = prefix, .name = name, .suffix = suffix };
}

test "a label that fits is left alone" {
    const f = fitParts(label("~/projects/", "ztabb", ""), 40);
    try testing.expectEqualStrings("~/projects/", f.prefix);
    try testing.expectEqualStrings("ztabb", f.name);
    try testing.expect(!f.elided);
}

test "the trailing context is the first thing dropped" {
    const f = fitParts(label("", "prod", "some/long/remote/dir"), 10);
    try testing.expectEqualStrings("prod", f.name);
    try testing.expectEqualStrings("", f.suffix);
}

test "the path is cut from the left, keeping what is nearest the name" {
    const f = fitParts(label("~/a/b/c/", "ztabb", ""), 12);
    try testing.expect(f.elided);
    try testing.expectEqualStrings("ztabb", f.name);
    // What survives is the tail of the path, not its head.
    try testing.expect(std.mem.endsWith(u8, f.prefix, "c/"));
    try testing.expect(cellLen(f.prefix) + cellLen(f.name) + 1 <= 12);
}

test "the name is never sacrificed while it still fits" {
    const f = fitParts(label("~/very/long/path/", "ztabb", ""), 8);
    try testing.expectEqualStrings("ztabb", f.name);
    try testing.expect(cellLen(f.prefix) + cellLen(f.name) + 1 <= 8);
}

test "a name too long for the tab keeps its tail" {
    const f = fitParts(label("~/x/", "averylongdirectoryname", ""), 6);
    try testing.expectEqualStrings("", f.prefix);
    try testing.expectEqual(@as(u32, 6), cellLen(f.name));
    try testing.expect(std.mem.endsWith(u8, "averylongdirectoryname", f.name));
}

test "a zero budget draws nothing" {
    const f = fitParts(label("~/a/", "b", "c"), 0);
    try testing.expectEqual(@as(usize, 0), f.prefix.len + f.name.len + f.suffix.len);
}

test "fitParts never exceeds its budget" {
    const cases = [_]tabs_mod.Tab.Label{
        label("~/projects/", "ztabb", ""),
        label("", "prod", "app"),
        label("/usr/local/share/", "doc", ""),
        label("", "htop", ""),
        label("~/", "Привет", ""),
    };
    for (cases) |c| {
        for (1..40) |budget| {
            const f = fitParts(c, @intCast(budget));
            var used = cellLen(f.prefix) + cellLen(f.name);
            if (f.elided) used += 1;
            if (f.suffix.len > 0) used += cellLen(f.suffix) + 1;
            try testing.expect(used <= budget);
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
