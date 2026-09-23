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
/// The tag is pinned to a byte and truecolor is stored as three bytes rather
/// than a `u24`: a `u24` payload forces the union to 4-byte alignment, which
/// costs it 8 bytes and every `Cell` 24 -- a size the scrollback then
/// multiplies by every row it keeps.
pub const Color = union(enum(u8)) {
    default,
    /// Index into the 256-colour cube; 0-15 come from the theme's ANSI palette.
    indexed: u8,
    rgb: [3]u8,

    pub fn fromRgb(v: u24) Color {
        return .{ .rgb = .{
            @truncate(v >> 16),
            @truncate(v >> 8),
            @truncate(v),
        } };
    }

    pub fn eql(a: Color, b: Color) bool {
        // Compare the tags explicitly: `b == .rgb` on a union with a pinned
        // tag type does not mean "b holds an rgb".
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .default => true,
            .indexed => |x| x == b.indexed,
            .rgb => |x| std.mem.eql(u8, &x, &b.rgb),
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
    /// One flag per screen row: the row ran to the right margin and continues
    /// on the next one. Re-wrapping on resize needs it to tell a wrapped
    /// continuation from a line of its own.
    wrapped: []bool,

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
    /// The primary screen's wrap flags while the alternate screen is up.
    alt_wrapped: []bool = &.{},
    alt_saved: SavedCursor = .{},

    /// Ring of scrolled-off rows. `sb_rows` are allocated and grow on demand up
    /// to `sb_cap`, so a tab that never scrolls pays nothing for its history.
    sb: []Cell = &.{},
    /// Wrap flags for the history ring, indexed by the same slots as `sb`.
    sb_wrapped: []bool = &.{},
    sb_cap: u32,
    sb_rows: u32 = 0,
    sb_head: u32 = 0,
    sb_len: u32 = 0,
    /// Rows the viewport is scrolled back from the live screen.
    view_offset: u32 = 0,
    /// Once the history passes this many bytes, the oldest half is dropped.
    memory_budget: usize = DEFAULT_MEMORY_BUDGET,
    /// How many times that has happened, so the caller can say so.
    compactions: u32 = 0,

    /// Window title from OSC 0/1/2, used as the tab label.
    title: [MAX_TITLE]u8 = [_]u8{0} ** MAX_TITLE,
    title_len: usize = 0,

    /// True whenever the screen changed since the renderer last cleared it.
    dirty: bool = true,
    /// Set by BEL; the caller may flash the tab.
    bell: bool = false,
    /// DECSET 2004. When on, pasted text is wrapped in markers so the program
    /// can tell it from typing and refuse to run it.
    bracketed_paste: bool = false,
    /// What the program wants to hear about the mouse, and how.
    mouse: MouseMode = .{},

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
    /// Rows in the first scrollback allocation; it doubles from there.
    const SCROLLBACK_SEED: u32 = 128;
    /// Bytes a single tab's history may hold. The row cap alone does not
    /// bound it: a wide window makes every row expensive, so a tab tailing a
    /// log on a full-screen terminal could hold tens of megabytes.
    pub const DEFAULT_MEMORY_BUDGET: usize = 4 << 20;
    /// History never shrinks below this, however little the budget allows.
    const MIN_HISTORY_ROWS: u32 = 64;

    pub fn init(gpa: std.mem.Allocator, cols: u32, rows: u32, scrollback_rows: u32) !Terminal {
        const c = @max(cols, 1);
        const r = @max(rows, 1);

        const cells = try gpa.alloc(Cell, c * r);
        errdefer gpa.free(cells);
        @memset(cells, Cell.blank);

        const wrapped = try gpa.alloc(bool, r);
        errdefer gpa.free(wrapped);
        @memset(wrapped, false);

        return .{
            .gpa = gpa,
            .cols = c,
            .rows = r,
            .cells = cells,
            .wrapped = wrapped,
            .scroll_bot = r - 1,
            .sb_cap = scrollback_rows,
        };
    }

    pub fn deinit(self: *Terminal) void {
        if (self.alt) |a| self.gpa.free(a);
        self.gpa.free(self.alt_wrapped);
        self.gpa.free(self.sb_wrapped);
        self.gpa.free(self.sb);
        self.gpa.free(self.wrapped);
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

    /// Resizes the grid.
    ///
    /// On the primary screen the content is re-wrapped: logical lines are
    /// rebuilt from the wrap flags and laid out again at the new width, so
    /// text does not stay boxed into the column count it was printed at. The
    /// alternate screen is only clipped -- the program that owns it redraws
    /// when it hears about the new size.
    pub fn resize(self: *Terminal, cols: u32, rows: u32) !void {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        if (c == self.cols and r == self.rows) return;

        if (self.alt == null) try self.reflow(c, r) else try self.clipResize(c, r);

        self.scroll_top = 0;
        self.scroll_bot = r - 1;
        self.wrap_pending = false;
        self.dirty = true;

        // Wider rows cost more, so a history that fitted before may not now.
        self.compactHistory();
    }

    /// Resize without re-wrapping: rows keep their columns, clipped or padded.
    fn clipResize(self: *Terminal, c: u32, r: u32) !void {
        // Every buffer is allocated before any of them is installed, so a
        // failure part-way through leaves the terminal exactly as it was
        // rather than with buffers of mismatched sizes.
        const new_cells = try self.gpa.alloc(Cell, c * r);
        errdefer self.gpa.free(new_cells);
        @memset(new_cells, Cell.blank);

        const new_wrapped = try self.gpa.alloc(bool, r);
        errdefer self.gpa.free(new_wrapped);
        @memset(new_wrapped, false);

        const new_alt: ?[]Cell = if (self.alt != null) blk: {
            const a = try self.gpa.alloc(Cell, c * r);
            @memset(a, Cell.blank);
            break :blk a;
        } else null;
        errdefer if (new_alt) |a| self.gpa.free(a);

        const new_alt_wrapped: []bool = if (self.alt != null)
            try self.gpa.alloc(bool, r)
        else
            &.{};
        errdefer self.gpa.free(new_alt_wrapped);
        @memset(new_alt_wrapped, false);

        // Stored rows are width-indexed. Rather than throwing the history
        // away on every resize -- which loses the scrollback the moment the
        // window is dragged -- re-lay it at the new width, clipping or padding
        // each row. Slots keep their positions, so the ring stays valid.
        const rewidth = c != self.cols and self.sb_rows > 0;
        const new_sb: ?[]Cell = if (rewidth) blk: {
            const sb = try self.gpa.alloc(Cell, @as(usize, self.sb_rows) * c);
            @memset(sb, Cell.blank);
            const keep = @min(self.cols, c);
            for (0..self.sb_rows) |row| {
                @memcpy(
                    sb[row * c ..][0..keep],
                    self.sb[row * self.cols ..][0..keep],
                );
            }
            break :blk sb;
        } else null;

        const copy_rows = @min(self.rows, r);
        const copy_cols = @min(self.cols, c);
        for (0..copy_rows) |row| {
            const src = self.cells[self.idx(@intCast(row), 0)..][0..copy_cols];
            @memcpy(new_cells[row * c ..][0..copy_cols], src);
            new_wrapped[row] = self.wrapped[row];
        }

        if (new_alt) |a| {
            self.gpa.free(self.alt.?);
            self.alt = a;
            const keep = @min(self.alt_wrapped.len, new_alt_wrapped.len);
            @memcpy(new_alt_wrapped[0..keep], self.alt_wrapped[0..keep]);
            self.gpa.free(self.alt_wrapped);
            self.alt_wrapped = new_alt_wrapped;
        }
        if (new_sb) |sb| {
            self.gpa.free(self.sb);
            self.sb = sb;
        }

        self.gpa.free(self.cells);
        self.gpa.free(self.wrapped);
        self.cells = new_cells;
        self.wrapped = new_wrapped;
        self.cols = c;
        self.rows = r;
        self.cursor_row = @min(self.cursor_row, r - 1);
        self.cursor_col = @min(self.cursor_col, c - 1);
    }

    // -- reflow ------------------------------------------------------------

    /// A cell carrying nothing: reflow trims these off the end of a logical
    /// line so the old width's padding does not become content at the new one.
    fn isPadding(cell: Cell) bool {
        return cell.ch == ' ' and
            Color.eql(cell.bg, .default) and
            @as(u8, @bitCast(cell.attrs)) == @as(u8, @bitCast(Attrs{}));
    }

    /// Source row `i` for reflow: history first, oldest at 0, then the screen.
    fn srcRow(self: *const Terminal, i: u32) []const Cell {
        if (i < self.sb_len) return self.scrollbackRow(self.sb_len - i).?;
        return self.cells[self.idx(i - self.sb_len, 0)..][0..self.cols];
    }

    fn srcWrapped(self: *const Terminal, i: u32) bool {
        if (i < self.sb_len) {
            const slot = (self.sb_head + self.sb_rows - (self.sb_len - i)) % self.sb_rows;
            return self.sb_wrapped[slot];
        }
        return self.wrapped[i - self.sb_len];
    }

    /// The logical line starting at source row `start`: how many rows it
    /// spans, and how many cells it holds once trailing padding is dropped.
    const Logical = struct { rows: u32, len: usize };

    fn logicalAt(self: *const Terminal, start: u32, total: u32) Logical {
        var n: u32 = 1;
        while (start + n < total and self.srcWrapped(start + n - 1)) n += 1;
        const last = self.srcRow(start + n - 1);
        var len: usize = last.len;
        while (len > 0 and isPadding(last[len - 1])) len -= 1;
        return .{ .rows = n, .len = @as(usize, n - 1) * self.cols + len };
    }

    /// Copies `dst.len` cells of the logical line at `start`, beginning at
    /// cell `from`.
    fn copyLogical(self: *const Terminal, start: u32, from: usize, dst: []Cell) void {
        for (dst, 0..) |*out, i| {
            const at = from + i;
            out.* = self.srcRow(start + @as(u32, @intCast(at / self.cols)))[at % self.cols];
        }
    }

    /// Rows one logical line occupies at width `c`, never fewer than one.
    fn outRows(line: Logical, c: u32) u32 {
        return @intCast(@max(1, (line.len + c - 1) / c));
    }

    /// Rebuilds history and screen at `c` x `r`, re-wrapping logical lines.
    ///
    /// Two passes: the first counts the rows the new width produces and finds
    /// where the cursor lands among them, the second writes only the rows that
    /// survive into freshly sized buffers. Counting first means no temporary
    /// copy of the whole history.
    fn reflow(self: *Terminal, c: u32, r: u32) !void {
        const total_src = self.sb_len + self.rows;
        const cursor_abs = self.sb_len + self.cursor_row;

        var total_out: u32 = 0;
        var cur_out_row: u32 = 0;
        var cur_out_col: u32 = 0;
        {
            var at: u32 = 0;
            while (at < total_src) {
                const line = self.logicalAt(at, total_src);
                var out = outRows(line, c);
                if (cursor_abs >= at and cursor_abs < at + line.rows) {
                    const off = @as(usize, cursor_abs - at) * self.cols + self.cursor_col;
                    const within: u32 = @intCast(off / c);
                    cur_out_row = total_out + within;
                    cur_out_col = @intCast(off % c);
                    // The cursor may sit past the end of what the line holds;
                    // its row still has to exist.
                    out = @max(out, within + 1);
                }
                total_out += out;
                at += line.rows;
            }
        }

        // The screen shows the last `r` rows, pulled up if that would leave
        // the cursor above them.
        var screen_start: u32 = if (total_out > r) total_out - r else 0;
        screen_start = @min(screen_start, cur_out_row);
        const hist_keep = @min(screen_start, self.maxHistoryRowsFor(c));
        const drop_before = screen_start - hist_keep;
        // Re-wrapping at a wider size can push the history past its budget;
        // dropping the oldest rows here is the same event `compactHistory`
        // reports, so it is counted the same way.
        if (hist_keep < screen_start) self.compactions += 1;

        const new_cells = try self.gpa.alloc(Cell, @as(usize, c) * r);
        errdefer self.gpa.free(new_cells);
        @memset(new_cells, Cell.blank);

        const new_wrapped = try self.gpa.alloc(bool, r);
        errdefer self.gpa.free(new_wrapped);
        @memset(new_wrapped, false);

        const new_sb: []Cell = if (hist_keep > 0)
            try self.gpa.alloc(Cell, @as(usize, hist_keep) * c)
        else
            &.{};
        errdefer self.gpa.free(new_sb);
        @memset(new_sb, Cell.blank);

        const new_sb_wrapped: []bool = if (hist_keep > 0)
            try self.gpa.alloc(bool, hist_keep)
        else
            &.{};
        errdefer self.gpa.free(new_sb_wrapped);
        @memset(new_sb_wrapped, false);

        const screen_end = screen_start + r;
        var out_at: u32 = 0;
        var at: u32 = 0;
        while (at < total_src and out_at < screen_end) {
            const line = self.logicalAt(at, total_src);
            var out = outRows(line, c);
            if (cursor_abs >= at and cursor_abs < at + line.rows) {
                const off = @as(usize, cursor_abs - at) * self.cols + self.cursor_col;
                out = @max(out, @as(u32, @intCast(off / c)) + 1);
            }
            var k: u32 = 0;
            while (k < out) : (k += 1) {
                const slot = out_at + k;
                if (slot < drop_before) continue;
                if (slot >= screen_end) break;
                const to_history = slot < screen_start;
                const dst = if (to_history)
                    new_sb[@as(usize, slot - drop_before) * c ..][0..c]
                else
                    new_cells[@as(usize, slot - screen_start) * c ..][0..c];
                const from = @as(usize, k) * c;
                const take = if (from < line.len) @min(@as(usize, c), line.len - from) else 0;
                self.copyLogical(at, from, dst[0..take]);
                @memset(dst[take..], Cell.blank);
                if (to_history)
                    new_sb_wrapped[slot - drop_before] = k + 1 < out
                else
                    new_wrapped[slot - screen_start] = k + 1 < out;
            }
            out_at += out;
            at += line.rows;
        }

        self.gpa.free(self.cells);
        self.gpa.free(self.wrapped);
        self.gpa.free(self.sb);
        self.gpa.free(self.sb_wrapped);
        self.cells = new_cells;
        self.wrapped = new_wrapped;
        self.sb = new_sb;
        self.sb_wrapped = new_sb_wrapped;
        self.cols = c;
        self.rows = r;
        self.sb_rows = hist_keep;
        self.sb_len = hist_keep;
        self.sb_head = 0;
        self.view_offset = 0;
        self.cursor_row = @min(cur_out_row -| screen_start, r - 1);
        self.cursor_col = @min(cur_out_col, c - 1);
    }

    // -- scrollback --------------------------------------------------------

    /// Doubles the history ring, up to `sb_cap`. Rows are re-laid oldest-first
    /// so the ring stays in order across the move.
    fn growScrollback(self: *Terminal) void {
        const want = @min(
            if (self.sb_rows == 0) SCROLLBACK_SEED else self.sb_rows * 2,
            self.maxHistoryRows(),
        );
        if (want <= self.sb_rows) return;

        const new = self.gpa.alloc(Cell, @as(usize, want) * self.cols) catch return;
        const new_wrapped = self.gpa.alloc(bool, want) catch {
            self.gpa.free(new);
            return;
        };
        @memset(new, Cell.blank);
        @memset(new_wrapped, false);
        for (0..self.sb_len) |i| {
            const slot = (self.sb_head + self.sb_rows - self.sb_len + i) % self.sb_rows;
            @memcpy(
                new[i * self.cols ..][0..self.cols],
                self.sb[@as(usize, slot) * self.cols ..][0..self.cols],
            );
            new_wrapped[i] = self.sb_wrapped[slot];
        }
        self.gpa.free(self.sb);
        self.gpa.free(self.sb_wrapped);
        self.sb = new;
        self.sb_wrapped = new_wrapped;
        self.sb_rows = want;
        self.sb_head = self.sb_len;
    }

    /// Bytes the history currently occupies.
    pub fn historyBytes(self: *const Terminal) usize {
        return self.sb.len * @sizeOf(Cell);
    }

    /// Rows the history may hold: whichever of the row cap and the memory
    /// budget binds first.
    pub fn maxHistoryRows(self: *const Terminal) u32 {
        return self.maxHistoryRowsFor(self.cols);
    }

    /// The same, for a width the terminal has not taken on yet.
    fn maxHistoryRowsFor(self: *const Terminal, cols: u32) u32 {
        const row_bytes = @as(usize, cols) * @sizeOf(Cell);
        const by_budget = self.memory_budget / @max(row_bytes, 1);
        const capped = @min(by_budget, self.sb_cap);
        return @intCast(@max(capped, @min(MIN_HISTORY_ROWS, self.sb_cap)));
    }

    /// Shrinks the history back inside its budget, keeping the newest rows.
    ///
    /// Growing the window makes every stored row more expensive, so a history
    /// that fitted before a resize may not after. Dropping the oldest rows --
    /// the ones furthest from anything anyone scrolls back to -- returns that
    /// memory rather than holding it for the rest of the session.
    pub fn compactHistory(self: *Terminal) void {
        const target = self.maxHistoryRows();
        if (self.sb_rows <= target) return;

        const keep_rows = @max(target, 1);
        const new = self.gpa.alloc(Cell, @as(usize, keep_rows) * self.cols) catch return;
        const new_wrapped = self.gpa.alloc(bool, keep_rows) catch {
            self.gpa.free(new);
            return;
        };
        @memset(new, Cell.blank);
        @memset(new_wrapped, false);

        // Copy the newest `keep` rows, oldest first, so the ring stays ordered.
        const keep = @min(self.sb_len, keep_rows);
        for (0..keep) |i| {
            const back = keep - i; // rows back from the newest
            const slot = (self.sb_head + self.sb_rows - back) % self.sb_rows;
            @memcpy(
                new[i * self.cols ..][0..self.cols],
                self.sb[@as(usize, slot) * self.cols ..][0..self.cols],
            );
            new_wrapped[i] = self.sb_wrapped[slot];
        }

        self.gpa.free(self.sb);
        self.gpa.free(self.sb_wrapped);
        self.sb = new;
        self.sb_wrapped = new_wrapped;
        self.sb_rows = keep_rows;
        self.sb_len = keep;
        self.sb_head = keep % keep_rows;
        self.view_offset = @min(self.view_offset, self.sb_len);
        self.compactions += 1;
        self.dirty = true;
    }

    fn pushScrollback(self: *Terminal, row: u32) void {
        if (self.sb_cap == 0 or self.alt != null) return;
        // Full: try to grow. Once the budget binds, growth stops and the ring
        // simply evicts its oldest row, which is the behaviour that keeps a
        // log-tailing tab from running away.
        if (self.sb_len == self.sb_rows) self.growScrollback();
        if (self.sb_rows == 0) return; // growth failed; drop the row
        const dst = @as(usize, self.sb_head) * self.cols;
        @memcpy(self.sb[dst..][0..self.cols], self.cells[self.idx(row, 0)..][0..self.cols]);
        self.sb_wrapped[self.sb_head] = self.wrapped[row];
        self.sb_head = (self.sb_head + 1) % self.sb_rows;
        if (self.sb_len < self.sb_rows) self.sb_len += 1;
        // Keep the viewport anchored to the same text while it is scrolled back.
        if (self.view_offset > 0 and self.view_offset < self.sb_len) self.view_offset += 1;
    }

    /// Row `n` rows above the live screen top; null once past the history.
    pub fn scrollbackRow(self: *const Terminal, n: u32) ?[]const Cell {
        if (n == 0 or n > self.sb_len) return null;
        const slot = (self.sb_head + self.sb_rows - n) % self.sb_rows;
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
            self.wrapped[r] = self.wrapped[r + 1];
        }
        const last = self.idx(self.scroll_bot, 0);
        self.eraseRange(last, last + self.cols);
        self.wrapped[self.scroll_bot] = false;
        self.dirty = true;
    }

    pub fn scrollDown(self: *Terminal) void {
        var r = self.scroll_bot;
        while (r > self.scroll_top) : (r -= 1) {
            const dst = self.idx(r, 0);
            const src = self.idx(r - 1, 0);
            @memcpy(self.cells[dst..][0..self.cols], self.cells[src..][0..self.cols]);
            self.wrapped[r] = self.wrapped[r - 1];
        }
        const first = self.idx(self.scroll_top, 0);
        self.eraseRange(first, first + self.cols);
        self.wrapped[self.scroll_top] = false;
        self.dirty = true;
    }

    /// LF, IND and NEL: the line ends here, so whatever the row was marked as
    /// stops being a wrap. `newline` itself cannot clear the flag -- the
    /// autowrap path sets it and then calls through here.
    fn lineFeed(self: *Terminal) void {
        self.wrapped[self.cursor_row] = false;
        self.newline();
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
            // The row ran out of columns rather than ending: mark it as
            // continuing before `newline` possibly retires it to history.
            self.wrapped[self.cursor_row] = true;
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
            0 => {
                self.eraseRange(cur, self.cells.len);
                @memset(self.wrapped[self.cursor_row..], false);
            },
            1 => self.eraseRange(0, cur + 1),
            2, 3 => {
                self.eraseRange(0, self.cells.len);
                @memset(self.wrapped, false);
            },
            else => {},
        }
        self.dirty = true;
    }

    pub fn eraseInLine(self: *Terminal, mode: u32) void {
        const row_start = self.idx(self.cursor_row, 0);
        const row_end = row_start + self.cols;
        const cur = row_start + self.cursor_col;
        switch (mode) {
            0 => {
                self.eraseRange(cur, row_end);
                self.wrapped[self.cursor_row] = false;
            },
            1 => self.eraseRange(row_start, cur + 1),
            2 => {
                self.eraseRange(row_start, row_end);
                self.wrapped[self.cursor_row] = false;
            },
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
        self.bracketed_paste = false;
        self.mouse = .{};
        self.wrap_pending = false;
        self.scroll_top = 0;
        self.scroll_bot = self.rows - 1;
        self.saved = .{};
        self.eraseRange(0, self.cells.len);
        @memset(self.wrapped, false);
        self.dirty = true;
    }

    fn enterAltScreen(self: *Terminal) void {
        if (self.alt != null) return;
        const alt = self.gpa.alloc(Cell, self.cells.len) catch return;
        const alt_wrapped = self.gpa.alloc(bool, self.rows) catch {
            self.gpa.free(alt);
            return;
        };
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
        @memcpy(alt_wrapped, self.wrapped);
        self.alt = alt;
        self.gpa.free(self.alt_wrapped);
        self.alt_wrapped = alt_wrapped;
        self.eraseRange(0, self.cells.len);
        @memset(self.wrapped, false);
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.view_offset = 0;
        self.dirty = true;
    }

    fn leaveAltScreen(self: *Terminal) void {
        const alt = self.alt orelse return;
        @memcpy(self.cells, alt);
        @memcpy(self.wrapped, self.alt_wrapped[0..@min(self.alt_wrapped.len, self.wrapped.len)]);
        self.gpa.free(alt);
        self.gpa.free(self.alt_wrapped);
        self.alt_wrapped = &.{};
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
            .rgb => |v| (@as(u32, v[0]) << 16) | (@as(u32, v[1]) << 8) | v[2],
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
            0x0A, 0x0B, 0x0C => self.lineFeed(),
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
                self.lineFeed();
                self.state = .ground;
            },
            'E' => {
                self.cursor_col = 0;
                self.lineFeed();
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
                1000 => self.mouse.buttons = on,
                1002 => self.mouse.drag = on,
                1003 => self.mouse.any_motion = on,
                1006 => self.mouse.sgr = on,
                2004 => self.bracketed_paste = on,
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
                const rgb = [3]u8{
                    @intCast(@min(self.params[i.* + 2], 255)),
                    @intCast(@min(self.params[i.* + 3], 255)),
                    @intCast(@min(self.params[i.* + 4], 255)),
                };
                i.* += 4;
                return .{ .rgb = rgb };
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

/// Which mouse events a program asked for, and in which encoding.
///
/// A program that has asked wants to handle the mouse itself -- `less` scrolls
/// with the wheel, `vim` moves the cursor on a click -- so the terminal must
/// forward events rather than act on them.
pub const MouseMode = struct {
    /// DECSET 1000: button presses and releases.
    buttons: bool = false,
    /// DECSET 1002: also movement while a button is held.
    drag: bool = false,
    /// DECSET 1003: also movement with no button held.
    any_motion: bool = false,
    /// DECSET 1006: the SGR encoding, which has no 223-column limit.
    sgr: bool = false,

    pub fn wants(self: MouseMode) bool {
        return self.buttons or self.drag or self.any_motion;
    }

    /// Encodes one event for the program.
    ///
    /// `button` is the code the protocol uses: 0-2 for the buttons, 64 and 65
    /// for the wheel; `row` and `col` are zero-based here and one-based on the
    /// wire. Returns the bytes written into `buf`.
    pub fn encode(
        self: MouseMode,
        buf: []u8,
        button: u8,
        col: u32,
        row: u32,
        pressed: bool,
    ) []const u8 {
        if (self.sgr) {
            return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{
                button,
                col + 1,
                row + 1,
                @as(u8, if (pressed) 'M' else 'm'),
            }) catch buf[0..0];
        }

        // The original encoding adds 32 to every field so each lands in a
        // printable byte, which also caps it at column 223.
        if (col > 222 or row > 222) return buf[0..0];
        if (buf.len < 6) return buf[0..0];
        const code: u8 = if (pressed) button else 3;
        buf[0] = 0x1b;
        buf[1] = '[';
        buf[2] = 'M';
        buf[3] = 32 + code;
        buf[4] = @intCast(32 + col + 1);
        buf[5] = @intCast(32 + row + 1);
        return buf[0..6];
    }
};

/// A range of the visible grid, as the mouse drew it.
///
/// Anchored where the drag began and headed where it is now, so dragging
/// backwards selects the same span as dragging forwards.
pub const Selection = struct {
    anchor_row: u32,
    anchor_col: u32,
    head_row: u32,
    head_col: u32,
    /// Set once the pointer has moved; a click alone selects nothing.
    active: bool = false,

    const Point = struct { row: u32, col: u32 };

    fn ordered(self: Selection) struct { start: Point, end: Point } {
        const a = Point{ .row = self.anchor_row, .col = self.anchor_col };
        const b = Point{ .row = self.head_row, .col = self.head_col };
        const a_first = a.row < b.row or (a.row == b.row and a.col <= b.col);
        return if (a_first) .{ .start = a, .end = b } else .{ .start = b, .end = a };
    }

    /// Whether a cell of the viewport falls inside the selection. The end
    /// column is exclusive, so a drag that has not left its cell selects
    /// nothing.
    pub fn contains(self: Selection, row: u32, col: u32) bool {
        if (!self.active) return false;
        const r = self.ordered();
        if (row < r.start.row or row > r.end.row) return false;
        if (row == r.start.row and col < r.start.col) return false;
        if (row == r.end.row and col >= r.end.col) return false;
        return true;
    }

    pub fn isEmpty(self: Selection) bool {
        if (!self.active) return true;
        const r = self.ordered();
        return r.start.row == r.end.row and r.start.col == r.end.col;
    }
};

/// Writes the selected text into `buf`, as UTF-8.
///
/// Trailing blanks are dropped from every line but the last, because a
/// terminal pads its rows with spaces and pasting them back is never wanted.
pub fn selectedText(t: *const Terminal, sel: Selection, buf: []u8) []const u8 {
    if (sel.isEmpty()) return buf[0..0];
    const r = sel.ordered();
    var n: usize = 0;

    var row = r.start.row;
    while (row <= r.end.row and row < t.rows) : (row += 1) {
        const cells = t.viewRow(row);
        const from = if (row == r.start.row) r.start.col else 0;
        const to = if (row == r.end.row) @min(r.end.col, t.cols) else t.cols;

        var line_start = n;
        var col = from;
        while (col < to) : (col += 1) {
            const cp = cells[col].ch;
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch 1;
            if (n + len > buf.len) return buf[0..n];
            n += std.unicode.utf8Encode(cp, buf[n..]) catch break;
        }
        while (n > line_start and buf[n - 1] == ' ') n -= 1;
        line_start = n;

        if (row != r.end.row) {
            if (n == buf.len) return buf[0..n];
            buf[n] = '\n';
            n += 1;
        }
    }
    return buf[0..n];
}

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

/// The text of an arbitrary row slice, trailing blanks trimmed.
fn sliceText(row: []const Cell, buf: []u8) []const u8 {
    var n: usize = 0;
    for (row) |cell| n += std.unicode.utf8Encode(cell.ch, buf[n..]) catch 0;
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

test "a Cell stays small enough for a long history" {
    // The scrollback multiplies this by every stored row, so a regression here
    // costs megabytes per tab.
    try testing.expect(@sizeOf(Cell) <= 16);
    try testing.expect(@sizeOf(Color) <= 4);
}

test "a tab that never scrolls allocates no history" {
    var t = try testTerm(80, 24);
    defer t.deinit();
    try testing.expectEqual(@as(usize, 0), t.sb.len);
    try testing.expectEqual(@as(u32, 0), t.sb_rows);

    // Writing without overflowing the screen must not reserve anything.
    t.write("hello\r\nworld");
    try testing.expectEqual(@as(usize, 0), t.sb.len);
}

test "history grows on demand and stops at the cap" {
    var t = try Terminal.init(testing.allocator, 4, 1, 300);
    defer t.deinit();
    for (0..40) |_| t.write("x\r\n");
    try testing.expect(t.sb_rows > 0);
    try testing.expect(t.sb_rows <= 300);
    const grown_once = t.sb_rows;

    for (0..400) |_| t.write("y\r\n");
    try testing.expectEqual(@as(u32, 300), t.sb_rows);
    try testing.expectEqual(@as(u32, 300), t.sb_len);
    try testing.expect(t.sb_rows > grown_once);
}

test "growing the history keeps the rows in order" {
    var t = try Terminal.init(testing.allocator, 4, 1, 400);
    defer t.deinit();
    // Enough lines to cross at least one growth step.
    for (0..200) |i| {
        var buf: [8]u8 = undefined;
        t.write(std.fmt.bufPrint(&buf, "{d}\r\n", .{i % 10}) catch unreachable);
    }
    // The most recent scrolled-off row must be the one written just before it.
    const last = t.scrollbackRow(1).?;
    const prev = t.scrollbackRow(2).?;
    try testing.expectEqual(@as(u21, '9'), last[0].ch);
    try testing.expectEqual(@as(u21, '8'), prev[0].ch);
}

test "a tab tailing a log stops growing at its memory budget" {
    // The row cap alone does not bound this: on a wide window each row is
    // expensive, and the tab would hold tens of megabytes for the session.
    var t = try Terminal.init(testing.allocator, 200, 4, 100_000);
    defer t.deinit();
    t.memory_budget = 1 << 20;

    for (0..40_000) |_| t.write("x\r\n");

    try testing.expect(t.historyBytes() <= t.memory_budget);
    try testing.expect(t.sb_rows <= t.maxHistoryRows());
    // The recent output is what survives, and it is still there.
    try testing.expect(t.sb_len > 0);
    try testing.expectEqual(@as(u21, 'x'), t.scrollbackRow(1).?[0].ch);
}

test "widening the window shrinks the history back inside the budget" {
    var t = try Terminal.init(testing.allocator, 40, 4, 100_000);
    defer t.deinit();
    t.memory_budget = 512 * 1024;
    for (0..20_000) |_| t.write("x\r\n");
    const rows_before = t.sb_rows;
    try testing.expect(rows_before > 0);
    try testing.expect(t.historyBytes() <= t.memory_budget);

    // Ten times the width: every stored row now costs ten times as much, so
    // the rows that fitted before no longer do.
    try t.resize(400, 4);
    try testing.expect(t.historyBytes() <= t.memory_budget);
    try testing.expect(t.sb_rows < rows_before);
    try testing.expect(t.compactions > 0);
    // What survives is the recent end of the history.
    try testing.expect(t.sb_len > 0);
    try testing.expectEqual(@as(u21, 'x'), t.scrollbackRow(1).?[0].ch);
}

test "the budget never squeezes the history below a usable size" {
    var t = try Terminal.init(testing.allocator, 500, 4, 5000);
    defer t.deinit();
    t.memory_budget = 1024; // absurdly small
    try testing.expect(t.maxHistoryRows() >= 64);
}

test "compaction keeps the newest rows, in order" {
    var t = try Terminal.init(testing.allocator, 4, 1, 4096);
    defer t.deinit();
    t.memory_budget = 4096 * 4 * @sizeOf(Cell) / 4; // forces a shrink below
    for (0..600) |i| {
        var buf: [8]u8 = undefined;
        t.write(std.fmt.bufPrint(&buf, "{d}\r\n", .{i % 10}) catch unreachable);
    }
    const before = t.sb_len;
    const newest = t.scrollbackRow(1).?[0].ch;
    const second = t.scrollbackRow(2).?[0].ch;

    t.memory_budget = 64 * 4 * @sizeOf(Cell);
    t.compactHistory();

    try testing.expectEqual(@as(u32, 1), t.compactions);
    try testing.expect(t.sb_len < before);
    try testing.expect(t.sb_len > 0);
    // The most recent rows are untouched and still in order.
    try testing.expectEqual(newest, t.scrollbackRow(1).?[0].ch);
    try testing.expectEqual(second, t.scrollbackRow(2).?[0].ch);
}

test "compaction leaves a history that fits alone" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("a\r\nb\r\nc");
    const rows = t.sb_rows;
    t.compactHistory();
    try testing.expectEqual(rows, t.sb_rows);
    try testing.expectEqual(@as(u32, 0), t.compactions);
}

test "writing continues correctly after a compaction" {
    var t = try Terminal.init(testing.allocator, 4, 1, 4096);
    defer t.deinit();
    for (0..600) |_| t.write("a\r\n");
    t.memory_budget = 64 * 4 * @sizeOf(Cell);
    t.compactHistory();
    for (0..50) |_| t.write("b\r\n");
    try testing.expectEqual(@as(u21, 'b'), t.scrollbackRow(1).?[0].ch);
    try testing.expect(t.sb_len <= t.sb_rows);
    try testing.expect(t.sb_head < t.sb_rows);
}

test "a scrolled-back view survives a compaction" {
    var t = try Terminal.init(testing.allocator, 4, 1, 4096);
    defer t.deinit();
    for (0..600) |_| t.write("a\r\n");
    t.scrollView(400);
    t.memory_budget = 64 * 4 * @sizeOf(Cell);
    t.compactHistory();
    try testing.expect(t.view_offset <= t.sb_len);
    // The viewport still resolves to real rows rather than reading past the end.
    for (0..t.rows) |r| _ = t.viewRow(@intCast(r));
}

test "history still grows on demand after a resize" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc");
    try t.resize(9, 2);
    // Re-wrapping sizes the ring to what it actually holds; it has to be able
    // to grow again from there.
    const before = t.sb_len;
    try testing.expectEqual(t.sb_rows, before);
    t.write("\r\nddd\r\neee");
    // The history kept what it had and went on taking more: the newest row is
    // from after the resize, the oldest from before it.
    try testing.expect(t.sb_len > before);
    try testing.expectEqual(@as(u21, 'c'), t.scrollbackRow(1).?[0].ch);
    try testing.expectEqual(@as(u21, 'a'), t.scrollbackRow(t.sb_len).?[0].ch);
}

test "a selection covers the cells between its ends" {
    const sel = Selection{ .anchor_row = 1, .anchor_col = 2, .head_row = 1, .head_col = 5, .active = true };
    try testing.expect(!sel.contains(1, 1));
    try testing.expect(sel.contains(1, 2));
    try testing.expect(sel.contains(1, 4));
    try testing.expect(!sel.contains(1, 5)); // the end column is exclusive
    try testing.expect(!sel.contains(0, 3));
    try testing.expect(!sel.contains(2, 3));
}

test "dragging backwards selects the same span" {
    const forward = Selection{ .anchor_row = 0, .anchor_col = 1, .head_row = 2, .head_col = 4, .active = true };
    const backward = Selection{ .anchor_row = 2, .anchor_col = 4, .head_row = 0, .head_col = 1, .active = true };
    for (0..4) |row| {
        for (0..8) |col| {
            try testing.expectEqual(
                forward.contains(@intCast(row), @intCast(col)),
                backward.contains(@intCast(row), @intCast(col)),
            );
        }
    }
}

test "a selection spanning rows takes whole lines in the middle" {
    const sel = Selection{ .anchor_row = 0, .anchor_col = 3, .head_row = 2, .head_col = 2, .active = true };
    try testing.expect(!sel.contains(0, 2));
    try testing.expect(sel.contains(0, 3));
    try testing.expect(sel.contains(1, 0)); // middle row, start
    try testing.expect(sel.contains(1, 99)); // middle row, end
    try testing.expect(sel.contains(2, 1));
    try testing.expect(!sel.contains(2, 2));
}

test "a click that never moved selects nothing" {
    const idle = Selection{ .anchor_row = 1, .anchor_col = 1, .head_row = 1, .head_col = 1 };
    try testing.expect(idle.isEmpty());
    try testing.expect(!idle.contains(1, 1));

    const clicked = Selection{ .anchor_row = 1, .anchor_col = 1, .head_row = 1, .head_col = 1, .active = true };
    try testing.expect(clicked.isEmpty());
}

test "selected text comes back as it reads on screen" {
    var t = try testTerm(20, 4);
    defer t.deinit();
    t.write("hello world\r\nsecond line\r\nthird");

    var buf: [128]u8 = undefined;
    const one_row = Selection{ .anchor_row = 0, .anchor_col = 6, .head_row = 0, .head_col = 11, .active = true };
    try testing.expectEqualStrings("world", selectedText(&t, one_row, &buf));

    const across = Selection{ .anchor_row = 0, .anchor_col = 6, .head_row = 1, .head_col = 6, .active = true };
    try testing.expectEqualStrings("world\nsecond", selectedText(&t, across, &buf));
}

test "the padding a terminal writes is not copied with the text" {
    // Rows are space-filled to the width; pasting that back is never wanted.
    var t = try testTerm(20, 4);
    defer t.deinit();
    t.write("ab\r\ncd");

    var buf: [128]u8 = undefined;
    const sel = Selection{ .anchor_row = 0, .anchor_col = 0, .head_row = 1, .head_col = 20, .active = true };
    try testing.expectEqualStrings("ab\ncd", selectedText(&t, sel, &buf));
}

test "selected text handles multi-byte characters" {
    var t = try testTerm(20, 2);
    defer t.deinit();
    t.write("Привет мир");

    var buf: [128]u8 = undefined;
    const sel = Selection{ .anchor_row = 0, .anchor_col = 0, .head_row = 0, .head_col = 6, .active = true };
    try testing.expectEqualStrings("Привет", selectedText(&t, sel, &buf));
}

test "an empty selection yields no text" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("abc");
    var buf: [64]u8 = undefined;
    const empty = Selection{ .anchor_row = 0, .anchor_col = 1, .head_row = 0, .head_col = 1, .active = true };
    try testing.expectEqualStrings("", selectedText(&t, empty, &buf));
}

test "copying never runs past the buffer it was given" {
    var t = try testTerm(40, 6);
    defer t.deinit();
    for (0..6) |_| t.write("0123456789012345678901234567890123456789");

    var small: [10]u8 = undefined;
    const all = Selection{ .anchor_row = 0, .anchor_col = 0, .head_row = 5, .head_col = 40, .active = true };
    const out = selectedText(&t, all, &small);
    try testing.expect(out.len <= small.len);
}

test "selection reads the scrolled-back view, not the live screen" {
    var t = try testTerm(6, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc\r\nddd");
    t.scrollView(2);

    var buf: [64]u8 = undefined;
    const sel = Selection{ .anchor_row = 0, .anchor_col = 0, .head_row = 0, .head_col = 3, .active = true };
    try testing.expectEqualStrings("aaa", selectedText(&t, sel, &buf));
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
    try testing.expect(t.cellAt(0, 3).fg.eql(Color.fromRgb(0xFF8000)));

    t.write("\x1b[48;2;1;2;3mE");
    try testing.expect(t.cellAt(0, 4).bg.eql(Color.fromRgb(0x010203)));

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

test "mouse reporting modes are tracked" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    try testing.expect(!t.mouse.wants());

    t.write("\x1b[?1000h");
    try testing.expect(t.mouse.buttons);
    try testing.expect(t.mouse.wants());

    t.write("\x1b[?1002h\x1b[?1006h");
    try testing.expect(t.mouse.drag);
    try testing.expect(t.mouse.sgr);

    t.write("\x1b[?1000l\x1b[?1002l");
    try testing.expect(!t.mouse.wants());
    try testing.expect(t.mouse.sgr); // the encoding is not a request
}

test "a reset stops mouse reporting" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[?1003h\x1b[?1006h\x1bc");
    try testing.expect(!t.mouse.wants());
    try testing.expect(!t.mouse.sgr);
}

test "the SGR encoding writes a readable, unbounded report" {
    const mode = MouseMode{ .buttons = true, .sgr = true };
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("\x1b[<0;1;1M", mode.encode(&buf, 0, 0, 0, true));
    try testing.expectEqualStrings("\x1b[<0;1;1m", mode.encode(&buf, 0, 0, 0, false));
    // Wheel up, well past the column the old encoding could reach.
    try testing.expectEqualStrings("\x1b[<64;301;51M", mode.encode(&buf, 64, 300, 50, true));
}

test "the original encoding offsets its fields and gives up past its limit" {
    const mode = MouseMode{ .buttons = true };
    var buf: [32]u8 = undefined;

    const press = mode.encode(&buf, 0, 0, 0, true);
    try testing.expectEqualSlices(u8, &.{ 0x1b, '[', 'M', 32, 33, 33 }, press);

    // Release is button 3 whichever was let go.
    const release = mode.encode(&buf, 2, 4, 9, false);
    try testing.expectEqualSlices(u8, &.{ 0x1b, '[', 'M', 35, 37, 42 }, release);

    // Beyond 223 columns it cannot say where the pointer is, so it says
    // nothing rather than something wrong.
    try testing.expectEqual(@as(usize, 0), mode.encode(&buf, 0, 300, 5, true).len);
}

test "bracketed paste mode is tracked" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    try testing.expect(!t.bracketed_paste);
    t.write("\x1b[?2004h");
    try testing.expect(t.bracketed_paste);
    t.write("\x1b[?2004l");
    try testing.expect(!t.bracketed_paste);
}

test "a reset turns bracketed paste back off" {
    // Otherwise a shell that crashed with it on would leave the next one
    // receiving markers it never asked for.
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[?2004h\x1bc");
    try testing.expect(!t.bracketed_paste);
}

test "several private modes in one sequence all apply" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("\x1b[?25;2004h");
    try testing.expect(t.cursor_visible);
    try testing.expect(t.bracketed_paste);
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

test "a shorter window pushes the top into history and keeps the cursor" {
    var t = try testTerm(20, 10);
    defer t.deinit();
    t.write("abc");
    t.cursor_row = 9;
    t.cursor_col = 19;
    try t.resize(10, 5);
    try testing.expectEqual(@as(u32, 10), t.cols);
    try testing.expectEqual(@as(u32, 5), t.rows);
    try testing.expectEqual(@as(usize, 50), t.cells.len);
    try testing.expectEqual(@as(u32, 4), t.scroll_bot);
    // The cursor sat two rows into a line that is now twice as tall, and the
    // screen stays anchored to it.
    try testing.expectEqual(@as(u32, 4), t.cursor_row);
    try testing.expectEqual(@as(u32, 9), t.cursor_col);
    // The text scrolled off the top rather than being dropped.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc", sliceText(t.scrollbackRow(6).?, &buf));
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

test "a width change keeps the scrollback, re-laid at the new width" {
    // Dragging the window used to empty the history, which is exactly when
    // someone is trying to see more of it.
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc");
    const rows = t.sb_len;
    try testing.expect(rows > 0);

    try t.resize(9, 2);
    try testing.expectEqual(rows, t.sb_len);
    const row = t.scrollbackRow(1).?;
    try testing.expectEqual(@as(usize, 9), row.len);
    try testing.expectEqual(@as(u21, 'a'), row[0].ch);
    try testing.expectEqual(@as(u21, ' '), row[8].ch); // padded, not garbage
}

test "narrowing re-wraps the stored rows instead of clipping them" {
    var t = try testTerm(10, 2);
    defer t.deinit();
    t.write("abcdefghij\r\nklmnopqrst\r\nz");
    try t.resize(4, 2);
    // Each ten-column line becomes three four-column ones; nothing is lost.
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("abcd", sliceText(t.scrollbackRow(5).?, &buf));
    try testing.expectEqualStrings("efgh", sliceText(t.scrollbackRow(4).?, &buf));
    try testing.expectEqualStrings("ij", sliceText(t.scrollbackRow(3).?, &buf));
    try testing.expectEqualStrings("klmn", sliceText(t.scrollbackRow(2).?, &buf));
    try testing.expectEqualStrings("opqr", sliceText(t.scrollbackRow(1).?, &buf));
    try testing.expectEqualStrings("st", sliceText(t.viewRow(0), &buf));
    try testing.expectEqualStrings("z", sliceText(t.viewRow(1), &buf));
}

test "widening re-joins a line that only wrapped because it had to" {
    // The reported bug: zooming in left old output boxed into the column
    // count it happened to be printed at.
    var t = try testTerm(10, 4);
    defer t.deinit();
    t.write("the quick brown fox");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("the quick", rowText(&t, 0, &buf)); // trailing blank trimmed
    try testing.expectEqualStrings("brown fox", rowText(&t, 1, &buf));

    try t.resize(30, 4);
    try testing.expectEqualStrings("the quick brown fox", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("", rowText(&t, 1, &buf));
    try testing.expectEqual(@as(u32, 0), t.cursor_row);
    try testing.expectEqual(@as(u32, 19), t.cursor_col);
}

test "a line ended by a line feed is never joined to the next" {
    var t = try testTerm(10, 4);
    defer t.deinit();
    t.write("abcdefghij\r\nklm");
    // Ten columns exactly, then an explicit newline: two lines, not one wrap.
    try t.resize(30, 4);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcdefghij", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("klm", rowText(&t, 1, &buf));
}

test "a wrapped line comes back unchanged from a narrow round trip" {
    var t = try testTerm(20, 6);
    defer t.deinit();
    const line = "0123456789abcdefghijklmnopqrstuvwxyz";
    t.write(line);
    try t.resize(7, 6);
    try t.resize(20, 6);

    var buf: [128]u8 = undefined;
    var n: usize = 0;
    for (0..3) |row| {
        var row_buf: [64]u8 = undefined;
        const text = rowText(&t, @intCast(row), &row_buf);
        @memcpy(buf[n..][0..text.len], text);
        n += text.len;
    }
    try testing.expectEqualStrings(line, buf[0..n]);
}

test "re-wrapping carries colours and attributes with the text" {
    var t = try testTerm(6, 3);
    defer t.deinit();
    t.write("\x1b[31mredredred");
    try t.resize(20, 3);
    for (0..9) |c| {
        try testing.expect(Color.eql(.{ .indexed = 1 }, t.cellAt(0, @intCast(c)).fg));
    }
}

test "the alternate screen is clipped rather than re-wrapped" {
    // Programs that own the alternate screen redraw on SIGWINCH; re-wrapping
    // what they drew would only garble a frame they are about to replace.
    var t = try testTerm(10, 3);
    defer t.deinit();
    t.write("\x1b[?1049habcdefghij");
    try t.resize(20, 3);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcdefghij", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("", rowText(&t, 1, &buf));
}

test "the primary screen keeps its wrap flags across the alternate screen" {
    var t = try testTerm(10, 3);
    defer t.deinit();
    t.write("the quick brown fox");
    t.write("\x1b[?1049h");
    t.write("\x1b[?1049l");
    try t.resize(30, 3);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("the quick brown fox", rowText(&t, 0, &buf));
}

test "fuzzing writes against resizes never panics or loses the cursor" {
    var t = try Terminal.init(testing.allocator, 20, 6, 200);
    defer t.deinit();
    var prng = std.Random.DefaultPrng.init(0x5E51E);
    const rand = prng.random();
    var buf: [64]u8 = undefined;

    for (0..300) |_| {
        const n = rand.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = switch (rand.intRangeAtMost(u8, 0, 3)) {
            0 => '\n',
            1 => '\r',
            else => rand.intRangeAtMost(u8, 'a', 'z'),
        };
        t.write(buf[0..n]);
        try t.resize(
            rand.intRangeAtMost(u32, 1, 40),
            rand.intRangeAtMost(u32, 1, 12),
        );
        try testing.expect(t.cursor_row < t.rows);
        try testing.expect(t.cursor_col < t.cols);
        try testing.expectEqual(@as(usize, t.cols) * t.rows, t.cells.len);
        try testing.expectEqual(@as(usize, t.rows), t.wrapped.len);
        try testing.expect(t.sb_len <= t.sb_rows);
        try testing.expectEqual(@as(usize, t.sb_rows) * t.cols, t.sb.len);
        try testing.expectEqual(@as(usize, t.sb_rows), t.sb_wrapped.len);
        try testing.expect(t.historyBytes() <= t.memory_budget + @as(usize, t.cols) * @sizeOf(Cell));
    }
}

test "a taller window pulls rows back out of the history" {
    var t = try testTerm(5, 2);
    defer t.deinit();
    t.write("aaa\r\nbbb\r\nccc");
    try testing.expect(t.sb_len > 0);
    try t.resize(5, 4);
    // Two more rows of room, and the history had one row to give back.
    try testing.expectEqual(@as(u32, 0), t.sb_len);
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("aaa", rowText(&t, 0, &buf));
    try testing.expectEqualStrings("bbb", rowText(&t, 1, &buf));
    try testing.expectEqualStrings("ccc", rowText(&t, 2, &buf));
    try testing.expectEqual(@as(u32, 2), t.cursor_row);
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
