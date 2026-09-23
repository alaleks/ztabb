//! The built-in typeface: JetBrains Mono, baked to antialiased coverage maps.
//!
//! Glyphs come from `tools/genfont.c` into `font.dat`, one byte of coverage per
//! pixel. Each supported point size is baked at 1x and again at exactly double
//! for HiDPI, because a bitmap stretched onto a denser backbuffer loses the
//! antialiasing that makes small text legible.
//!
//! Interface text is baked separately in Medium, one point size below the
//! terminal: tab labels want to read smaller than terminal text, and at that
//! size Regular goes faint while Bold goes heavy.

const std = @import("std");
const data = @import("font_data.zig");

/// Raw coverage bytes, laid out section by section as `sections` lists them.
const blob = @embedFile("font.dat");

pub const glyph_count = data.glyph_count;

pub const Weight = enum(u8) { regular, bold, medium };

/// The point sizes the terminal can be set to, smallest first.
pub const term_points = data.term_points;
/// The size a fresh window opens at.
pub const default_points: u32 = data.term_points[data.term_points.len / 2];

/// One baked (cell, weight) section of `font.dat`.
pub const Size = struct {
    w: u32,
    h: u32,
    weight: Weight,
    points: u32,
    density: u32,
    offset: usize,

    pub fn pixels(self: Size) usize {
        return self.w * self.h;
    }
};

pub const section_count = data.sections.len;

fn sectionAt(i: usize) Size {
    const sct = data.sections[i];
    return .{
        .w = sct.w,
        .h = sct.h,
        .weight = @enumFromInt(sct.weight),
        .points = sct.points,
        .density = sct.density,
        .offset = sct.offset,
    };
}

/// The next point size up or down the ladder, clamped at both ends.
pub fn stepPoints(points: u32, delta: i32) u32 {
    var at: usize = 0;
    for (term_points, 0..) |p, i| {
        if (p == points) at = i;
    }
    const moved = @as(i64, @intCast(at)) + delta;
    const clamped: usize = @intCast(std.math.clamp(moved, 0, @as(i64, term_points.len - 1)));
    return term_points[clamped];
}

/// Picks the section closest to what was asked for. An exact match is the
/// normal case; the search only matters when the caller zooms past the ends of
/// the ladder, where the nearest baked size is scaled to fit.
fn nearest(weight: Weight, points: u32, density: u32) Size {
    var best: ?Size = null;
    var best_cost: u64 = std.math.maxInt(u64);
    for (0..section_count) |i| {
        const sct = sectionAt(i);
        if (sct.weight != weight) continue;
        // Matching the density matters more than matching the size: a 1x set
        // drawn on a 2x backbuffer is the blurry case worth avoiding.
        const density_cost: u64 = if (sct.density == density) 0 else 1000;
        const size_cost: u64 = @abs(@as(i64, sct.points) - @as(i64, points));
        const cost = density_cost + size_cost;
        if (cost < best_cost) {
            best_cost = cost;
            best = sct;
        }
    }
    return best orelse sectionAt(0);
}

/// The terminal face for a cell at `points`, on a display of `density`.
pub fn termSize(points: u32, density: u32, weight: Weight) Size {
    return nearest(weight, points, density);
}

/// The interface face that goes with a terminal set to `points`: one step down
/// the ladder, in Medium.
pub fn uiSize(points: u32, density: u32) Size {
    var ui = data.ui_points[0];
    for (term_points, 0..) |p, i| {
        if (p == points and i < data.ui_points.len) ui = data.ui_points[i];
    }
    return nearest(.medium, ui, density);
}

/// The glyph index for `cp`, or null when the font has no coverage.
pub fn indexOf(cp: u21) ?usize {
    for (data.ranges) |r| {
        if (cp >= r.lo and cp <= r.hi) return r.base + (cp - r.lo);
    }
    return null;
}

/// U+25A1 WHITE SQUARE — what unmapped codepoints render as.
pub const replacement: u21 = 0x25A1;

fn resolveIndex(cp: u21) usize {
    return indexOf(cp) orelse indexOf(replacement).?;
}

/// Coverage bytes for one glyph, row-major, `size.pixels()` long.
pub fn glyph(cp: u21, size: Size) []const u8 {
    const per_glyph = size.pixels();
    const start = size.offset + resolveIndex(cp) * per_glyph;
    return blob[start..][0..per_glyph];
}

/// True when the glyph has no coverage at all — used to skip drawing entirely.
///
/// Scans the glyph, so it is not for per-cell use in a render loop: build a
/// `BlankSet` once per atlas instead.
pub fn isBlank(cp: u21, size: Size) bool {
    for (glyph(cp, size)) |v| {
        if (v != 0) return false;
    }
    return true;
}

/// The band of the cell that text visually occupies: the top of the capitals
/// down to the baseline.
///
/// The cell holds the whole font box -- full ascent plus descent -- so text
/// does not fill it, and the room above the capitals is not matched below.
/// Centring the cell therefore sets a label low against an icon centred on its
/// own outline. Descenders and tall punctuation are deliberately left out:
/// the eye lines text up on the capitals, not on the tail of a `g` or the top
/// of a bracket.
pub const Ink = struct {
    /// First row of the capitals, and the baseline.
    top: u32,
    bottom: u32,

    pub fn height(self: Ink) u32 {
        return self.bottom - self.top;
    }

    pub fn measure(size: Size) Ink {
        var top: u32 = size.h;
        var bottom: u32 = 0;
        for ("ABEHMNTXZ0123456789") |cp| {
            const g = glyph(cp, size);
            for (0..size.h) |y| {
                for (0..size.w) |x| {
                    if (g[y * size.w + x] <= 40) continue;
                    const row: u32 = @intCast(y);
                    if (row < top) top = row;
                    if (row >= bottom) bottom = row + 1;
                }
            }
        }
        if (bottom <= top) return .{ .top = 0, .bottom = size.h };
        return .{ .top = top, .bottom = bottom };
    }
};

/// One bit per glyph, marking those with nothing to draw.
///
/// The renderer asks this for every cell on screen; scanning the glyph each
/// time costs a few hundred byte reads per cell, which on a full window is
/// millions per frame for an answer that never changes.
pub const BlankSet = struct {
    bits: [(glyph_count + 63) / 64]u64 = @splat(0),

    pub fn build(size: Size) BlankSet {
        var set = BlankSet{};
        for (0..glyph_count) |i| {
            const per_glyph = size.pixels();
            const px = blob[size.offset + i * per_glyph ..][0..per_glyph];
            var blank = true;
            for (px) |v| {
                if (v != 0) {
                    blank = false;
                    break;
                }
            }
            if (blank) set.bits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
        }
        return set;
    }

    pub fn has(self: *const BlankSet, cp: u21) bool {
        const i = resolveIndex(cp);
        return self.bits[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
    }
};

// -- atlas -----------------------------------------------------------------

pub const atlas_cols: u32 = 32;
pub const atlas_rows: u32 = (glyph_count + atlas_cols - 1) / atlas_cols;

pub fn atlasW(size: Size) u32 {
    return atlas_cols * size.w;
}

pub fn atlasH(size: Size) u32 {
    return atlas_rows * size.h;
}

pub fn atlasPixels(size: Size) usize {
    return atlasW(size) * atlasH(size);
}

/// Expands one weight into a white ARGB atlas whose alpha carries the glyph
/// coverage, ready for `SDL_UpdateTexture`. Colour comes from a per-draw
/// colour mod, so one atlas serves every palette entry and both themes.
///
/// `out` must hold `atlasPixels(size)` entries; the caller owns it.
pub fn buildAtlas(size: Size, out: []u32) void {
    const w = atlasW(size);
    std.debug.assert(out.len >= atlasPixels(size));
    @memset(out[0..atlasPixels(size)], 0x00000000);

    for (0..glyph_count) |i| {
        const per_glyph = size.pixels();
        const src = blob[size.offset + i * per_glyph ..][0..per_glyph];

        const cell_x = (i % atlas_cols) * size.w;
        const cell_y = (i / atlas_cols) * size.h;
        for (0..size.h) |y| {
            const row_base = (cell_y + y) * w + cell_x;
            for (0..size.w) |x| {
                const a: u32 = src[y * size.w + x];
                // Straight (non-premultiplied) alpha over white, which is what
                // SDL_BLENDMODE_BLEND with a colour mod expects.
                out[row_base + x] = (a << 24) | 0x00FFFFFF;
            }
        }
    }
}

/// Top-left corner of `cp` within the atlas, in pixels.
pub const AtlasRect = struct { x: u32, y: u32 };

pub fn atlasRect(cp: u21, size: Size) AtlasRect {
    const idx = resolveIndex(cp);
    return .{
        .x = @intCast((idx % atlas_cols) * size.w),
        .y = @intCast((idx / atlas_cols) * size.h),
    };
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

/// The exact section for a cell, or null when nothing was baked at that size.
fn exact(weight: Weight, w: u32, h: u32) ?Size {
    for (0..section_count) |i| {
        const sct = sectionAt(i);
        if (sct.weight == weight and sct.w == w and sct.h == h) return sct;
    }
    return null;
}

test "font.dat is exactly as large as the metrics say" {
    var expected: usize = 0;
    for (0..section_count) |i| expected += sectionAt(i).pixels() * glyph_count;
    try testing.expectEqual(expected, blob.len);
}

test "sections are laid out back to back in the order listed" {
    var at: usize = 0;
    for (0..section_count) |i| {
        const sct = sectionAt(i);
        try testing.expectEqual(at, sct.offset);
        at += sct.pixels() * glyph_count;
    }
}

test "the default point size is on the ladder, with room either side" {
    try testing.expect(term_points.len >= 3);
    var found = false;
    for (term_points) |p| {
        if (p == default_points) found = true;
    }
    try testing.expect(found);
    try testing.expect(term_points[0] < default_points);
    try testing.expect(term_points[term_points.len - 1] > default_points);
}

test "every terminal size is baked in both weights at both densities" {
    for (term_points) |points| {
        for ([_]u32{ 1, 2 }) |density| {
            for ([_]Weight{ .regular, .bold }) |w| {
                const sct = termSize(points, density, w);
                try testing.expectEqual(points, sct.points);
                try testing.expectEqual(density, sct.density);
                try testing.expectEqual(w, sct.weight);
            }
        }
    }
}

test "the 2x set is exactly double the 1x set" {
    // Anything else and the same point size would not line up between a
    // built-in display and an external one.
    for (term_points) |points| {
        const one = termSize(points, 1, .regular);
        const two = termSize(points, 2, .regular);
        try testing.expectEqual(one.w * 2, two.w);
        try testing.expectEqual(one.h * 2, two.h);
    }
}

test "the cell follows the typeface's own proportions" {
    // JetBrains Mono: 0.60em advance, 1.32em from ascender to descender.
    for (term_points) |points| {
        const sct = termSize(points, 1, .regular);
        const w: f64 = @floatFromInt(sct.w);
        const h: f64 = @floatFromInt(sct.h);
        const pt: f64 = @floatFromInt(points);
        try testing.expect(@abs(w - 0.60 * pt) <= 0.5);
        try testing.expect(@abs(h - 1.32 * pt) <= 0.5);
    }
}

test "the default size gives the cell it always did" {
    const sct = termSize(default_points, 1, .regular);
    try testing.expectEqual(@as(u32, 13), default_points);
    try testing.expectEqual(@as(u32, 8), sct.w);
}

test "interface text is a step smaller than the terminal, in medium" {
    for (term_points) |points| {
        for ([_]u32{ 1, 2 }) |density| {
            const term = termSize(points, density, .regular);
            const ui = uiSize(points, density);
            try testing.expectEqual(Weight.medium, ui.weight);
            try testing.expectEqual(density, ui.density);
            try testing.expect(ui.h < term.h);
            try testing.expect(ui.points < points);
        }
    }
}

test "stepPoints walks the ladder and stops at its ends" {
    const smallest = term_points[0];
    const largest = term_points[term_points.len - 1];
    try testing.expectEqual(largest, stepPoints(default_points, 1));
    try testing.expectEqual(smallest, stepPoints(default_points, -1));
    try testing.expectEqual(largest, stepPoints(largest, 1));
    try testing.expectEqual(smallest, stepPoints(smallest, -1));
    try testing.expectEqual(default_points, stepPoints(default_points, 0));
}

test "an unsupported size falls back to the nearest baked one" {
    const huge = termSize(99, 2, .regular);
    try testing.expectEqual(term_points[term_points.len - 1], huge.points);
    try testing.expectEqual(@as(u32, 2), huge.density);

    const tiny = termSize(1, 1, .regular);
    try testing.expectEqual(term_points[0], tiny.points);
}

test "density is matched before size" {
    // A 1x set drawn onto a 2x backbuffer is the blurry case; the search must
    // prefer keeping the density even if the size is then further off.
    const sct = termSize(term_points[0], 2, .regular);
    try testing.expectEqual(@as(u32, 2), sct.density);
}

test "ranges are sorted, disjoint and contiguously based" {
    var expected_base: usize = 0;
    var prev_hi: u21 = 0;
    for (data.ranges, 0..) |r, i| {
        try testing.expect(r.lo <= r.hi);
        if (i > 0) try testing.expect(r.lo > prev_hi);
        try testing.expectEqual(expected_base, @as(usize, r.base));
        expected_base += r.hi - r.lo + 1;
        prev_hi = r.hi;
    }
    try testing.expectEqual(glyph_count, expected_base);
}

test "indexOf maps range boundaries exactly" {
    try testing.expectEqual(@as(usize, 0), indexOf(' ').?);
    try testing.expectEqual(@as(usize, 'A' - 0x20), indexOf('A').?);
    try testing.expect(indexOf(0x7F) == null);
    try testing.expect(indexOf(0x4E00) == null);
}

test "ASCII, Cyrillic and box drawing are all covered" {
    for (0x20..0x7F) |cp| try testing.expect(indexOf(@intCast(cp)) != null);
    for ([_]u21{ 'Ж', 'я', 'Ё', 0x2500, 0x2588 }) |cp| {
        try testing.expect(indexOf(cp) != null);
    }
}

test "Powerline and prompt-theme symbols are covered" {
    for ([_]u21{ 0xE0A0, 0xE0A1, 0xE0A2, 0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3 }) |cp| {
        try testing.expect(indexOf(cp) != null);
        for (0..section_count) |i| try testing.expect(!isBlank(cp, sectionAt(i)));
    }
    for ([_]u21{ 0x00B1, 0x2691, 0x2699, 0x26A1, 0x2718, 0x271A, 0x272D, 0x27A6 }) |cp| {
        try testing.expect(indexOf(cp) != null);
        try testing.expect(!isBlank(cp, termSize(default_points, 2, .regular)));
    }
}

test "Powerline separators span the full cell so they tile" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        const g = glyph(0xE0B0, size);
        try testing.expect(g[0] > 0);
        try testing.expect(g[(size.h - 1) * size.w] > 0);
        try testing.expect(g[(size.h / 2) * size.w + size.w - 1] > 0);

        const left = glyph(0xE0B2, size);
        try testing.expect(left[size.w - 1] > 0);
        try testing.expect(left[(size.h / 2) * size.w] > 0);
    }
}

test "every glyph slice is the size the metrics promise" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        try testing.expectEqual(size.pixels(), glyph('A', size).len);
        try testing.expectEqual(size.pixels(), glyph(0x2718, size).len);
    }
}

test "the cap band sits inside the cell, clear of both edges" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        const ink = Ink.measure(size);
        try testing.expect(ink.top > 0);
        try testing.expect(ink.bottom < size.h); // the descender space below
        try testing.expect(ink.height() >= size.h / 3);
    }
}

test "the cap band excludes descenders and tall punctuation" {
    const size = uiSize(default_points, 2);
    const ink = Ink.measure(size);

    const bounds = struct {
        fn f(cp: u21, sz: Size) struct { top: u32, bottom: u32 } {
            const g = glyph(cp, sz);
            var t: u32 = sz.h;
            var b: u32 = 0;
            for (0..sz.h) |y| {
                for (0..sz.w) |x| {
                    if (g[y * sz.w + x] <= 40) continue;
                    const row: u32 = @intCast(y);
                    if (row < t) t = row;
                    if (row >= b) b = row + 1;
                }
            }
            return .{ .top = t, .bottom = b };
        }
    }.f;

    // A descender reaches below the baseline the band ends at...
    try testing.expect(bounds('g', size).bottom > ink.bottom);
    // ...and a bracket reaches above where the capitals start.
    try testing.expect(bounds('|', size).top < ink.top);
    // The band brackets a capital: round digits overshoot the baseline by a
    // hair, which is how they are drawn, so the band can reach a row lower.
    try testing.expect(ink.top <= bounds('A', size).top);
    try testing.expect(ink.bottom >= bounds('A', size).bottom);
    try testing.expect(ink.bottom <= bounds('A', size).bottom + 2);
}

test "the blank set agrees with a direct scan" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        const set = BlankSet.build(size);
        // Spot-check across the whole range rather than all 1067 at every size.
        for ([_]u21{ ' ', 'A', 'g', 'Ж', 0x2588, 0x2500, 0xE0B0, 0xE0A5, 0x4E00 }) |cp| {
            try testing.expectEqual(isBlank(cp, size), set.has(cp));
        }
    }
}

test "the blank set is small enough to keep beside each atlas" {
    try testing.expect(@sizeOf(BlankSet) <= 256);
}

test "space is blank and letters are not, in every section" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        try testing.expect(isBlank(' ', size));
        try testing.expect(!isBlank('A', size));
        try testing.expect(!isBlank('Ж', size));
    }
}

test "glyphs are antialiased, not one-bit" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        var partial: usize = 0;
        for ("aoegsSOQ@") |cp| {
            for (glyph(cp, size)) |v| {
                if (v != 0 and v != 255) partial += 1;
            }
        }
        try testing.expect(partial > 15);
    }
}

test "the weights are ordered light to heavy" {
    for (term_points) |points| {
        var regular_ink: usize = 0;
        var bold_ink: usize = 0;
        const reg = termSize(points, 2, .regular);
        const bld = termSize(points, 2, .bold);
        for ('A'..'Z' + 1) |cp| {
            for (glyph(@intCast(cp), reg)) |v| regular_ink += v;
            for (glyph(@intCast(cp), bld)) |v| bold_ink += v;
        }
        try testing.expect(bold_ink > regular_ink);
    }
}

test "medium sits between regular and bold" {
    // Compared per pixel of cell, so the different cell sizes stay comparable.
    const ink = struct {
        fn f(size: Size) f64 {
            var total: f64 = 0;
            for ('a'..'z' + 1) |cp| {
                for (glyph(@intCast(cp), size)) |v| total += @floatFromInt(v);
            }
            return total / @as(f64, @floatFromInt(size.pixels()));
        }
    }.f;
    const med = ink(uiSize(default_points, 2));
    const reg = ink(termSize(default_points, 2, .regular));
    const bld = ink(termSize(default_points, 2, .bold));
    try testing.expect(med > reg);
    try testing.expect(med < bld);
}

test "unmapped codepoints fall back to the replacement box" {
    const size = termSize(default_points, 1, .regular);
    try testing.expectEqualSlices(u8, glyph(replacement, size), glyph(0x4E00, size));
    try testing.expect(!isBlank(0x4E00, size));
}

test "full block covers every pixel of the cell" {
    for (0..section_count) |i| {
        for (glyph(0x2588, sectionAt(i))) |v| try testing.expectEqual(@as(u8, 255), v);
    }
}

test "shade blocks are evenly tinted and ordered light to dark" {
    const size = termSize(default_points, 1, .regular);
    var prev: usize = 0;
    for ([_]u21{ 0x2591, 0x2592, 0x2593 }) |cp| {
        var ink: usize = 0;
        for (glyph(cp, size)) |v| ink += v;
        try testing.expect(ink > prev);
        prev = ink;
    }
}

test "buildAtlas lays glyphs out on the expected grid" {
    const gpa = testing.allocator;
    for (0..section_count) |i| {
        const size = sectionAt(i);
        const pixels = try gpa.alloc(u32, atlasPixels(size));
        defer gpa.free(pixels);
        buildAtlas(size, pixels);

        for (0..size.h) |y| {
            for (0..size.w) |x| {
                try testing.expectEqual(@as(u32, 0x00FFFFFF), pixels[y * atlasW(size) + x]);
            }
        }

        const rect = atlasRect('A', size);
        const bits = glyph('A', size);
        for (0..size.h) |y| {
            for (0..size.w) |x| {
                const a: u32 = bits[y * size.w + x];
                const px = pixels[(rect.y + y) * atlasW(size) + rect.x + x];
                try testing.expectEqual((a << 24) | 0x00FFFFFF, px);
            }
        }
    }
}

test "atlas is large enough for every glyph" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        try testing.expect(atlas_rows * atlas_cols >= glyph_count);
        const last = atlasRect(0x2718, size);
        try testing.expect(last.x + size.w <= atlasW(size));
        try testing.expect(last.y + size.h <= atlasH(size));
    }
}

test "exact lookups find the sections the ladder promises" {
    try testing.expect(exact(.regular, 8, 17) != null); // 13pt at 1x
    try testing.expect(exact(.regular, 16, 34) != null); // 13pt at 2x
    try testing.expect(exact(.bold, 16, 34) != null);
    try testing.expect(exact(.regular, 99, 99) == null);
}
