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
        .weight = @fromBackingInt(@intCast(sct.weight)),
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
/// Scans the glyph, so it is not for per-cell use in a render loop: a `Cache`
/// remembers the answer.
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

// -- glyph cache -----------------------------------------------------------

/// Slots in one cache texture. A session draws a few hundred distinct glyphs,
/// so uploading all of them up front would hold megabytes of texture nobody
/// looks at.
pub const cache_cols: u32 = 32;
pub const cache_slots: u32 = cache_cols * cache_cols;

pub fn cacheW(size: Size) u32 {
    return cache_cols * size.w;
}

pub fn cacheH(size: Size) u32 {
    return (cache_slots / cache_cols) * size.h;
}

/// The largest glyph any section holds, so callers can expand one on the stack.
pub const max_glyph_pixels: usize = blk: {
    var m: usize = 0;
    for (data.sections) |sct| m = @max(m, sct.w * sct.h);
    break :blk m;
};

/// Expands one glyph to white ARGB whose alpha carries the coverage, ready for
/// `SDL_UpdateTexture`. Colour comes from a per-draw colour mod, so one texture
/// serves every palette entry and both themes.
pub fn expandGlyph(cp: u21, size: Size, out: []u32) void {
    for (glyph(cp, size), out[0..size.pixels()]) |a, *px| {
        // Straight (non-premultiplied) alpha over white, which is what
        // SDL_BLENDMODE_BLEND with a colour mod expects.
        px.* = (@as(u32, a) << 24) | 0x00FFFFFF;
    }
}

/// Which glyphs of one section are resident in its texture, and where.
/// Glyphs are placed on first use; when every slot is taken the cache starts
/// over, which only a screen of more distinct glyphs than slots can cause.
pub const Cache = struct {
    size: Size,
    slot_of: [glyph_count]u16 = @splat(unseen),
    used: u16 = 0,

    const unseen = std.math.maxInt(u16);
    const blank = unseen - 1;

    pub const Slot = struct {
        x: u32,
        y: u32,
        /// The texture does not hold this glyph yet: the caller must upload it.
        fresh: bool,
    };

    pub fn init(size: Size) Cache {
        return .{ .size = size };
    }

    /// Where `cp` lives in the texture, or null when it has nothing to draw.
    pub fn slot(self: *Cache, cp: u21) ?Slot {
        const idx = resolveIndex(cp);
        var s = self.slot_of[idx];
        if (s == blank) return null;
        const fresh = s == unseen;
        if (fresh) {
            if (std.mem.allEqual(u8, glyph(cp, self.size), 0)) {
                self.slot_of[idx] = blank;
                return null;
            }
            if (self.used == cache_slots) {
                @memset(&self.slot_of, unseen);
                self.used = 0;
            }
            s = self.used;
            self.used += 1;
            self.slot_of[idx] = s;
        }
        return .{
            .x = (s % cache_cols) * self.size.w,
            .y = (s / cache_cols) * self.size.h,
            .fresh = fresh,
        };
    }
};


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

test "Braille progress spinners have glyphs" {
    for (0x2800..0x2900) |cp| {
        try testing.expect(indexOf(@intCast(cp)) != null);
        if (cp == 0x2800) continue; // Braille blank is intentionally empty.
        for (0..section_count) |i| try testing.expect(!isBlank(@intCast(cp), sectionAt(i)));
    }
}

test "Powerline and prompt-theme symbols are covered" {
    for ([_]u21{ 0xE0A0, 0xE0A1, 0xE0A2, 0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3 }) |cp| {
        try testing.expect(indexOf(cp) != null);
        for (0..section_count) |i| try testing.expect(!isBlank(cp, sectionAt(i)));
    }
    for ([_]u21{ 0x00B1, 0x21B0, 0x21B1, 0x2691, 0x2699, 0x26A1, 0x2718, 0x271A, 0x272D, 0x27A6 }) |cp| {
        try testing.expect(indexOf(cp) != null);
        try testing.expect(!isBlank(cp, termSize(default_points, 2, .regular)));
    }
}

test "macOS Apple menu symbol is drawn" {
    try testing.expect(indexOf(0xF8FF) != null);
    for (0..section_count) |i| try testing.expect(!isBlank(0xF8FF, sectionAt(i)));
}

test "common status symbols are drawn" {
    for ([_]u21{
        0x1F3AF, // target
        0x1F41B, // bug
        0x1F440, // eyes
        0x1F4A1, // bulb
        0x1F4BB, // laptop
        0x1F4C1, // folder
        0x1F4CC, // pin
        0x1F4DD, // memo
        0x1F4E6, // package
        0x1F511, // key
        0x1F512, // lock
        0x1F525, // fire
        0x1F680, // rocket
        0x1F916, // robot
        0x1F9E0, // brain
        0x1F9EA, // test tube
        0x1F600, // grinning face
        0x1F44D, // thumbs up
        0x1F7E2, // green circle
        0x1FAE0, // melting face
        0x23FA, // record button
        0x23BF, // bottom-left corner, Claude Code's result marker
        0x20AC, // euro
        0x03BB, // lambda
        0xFFFD, // replacement character
    }) |cp| {
        try testing.expect(indexOf(cp) != null);
        for (0..section_count) |i| try testing.expect(!isBlank(cp, sectionAt(i)));
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

test "the cache skips blank glyphs and agrees with a direct scan" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        var cache = Cache.init(size);
        // Asked twice: the second answer comes from the cache, not a scan.
        for (0..2) |_| {
            for ([_]u21{ ' ', 'A', 'g', 'Ж', 0x2588, 0x2500, 0xE0B0, 0xE0A5, 0x4E00 }) |cp| {
                try testing.expectEqual(isBlank(cp, size), cache.slot(cp) == null);
            }
        }
    }
}

test "the cache is small enough to keep one per face" {
    try testing.expect(@sizeOf(Cache) <= 16 * 1024);
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

test "a glyph is fresh once, then found where it was put" {
    var cache = Cache.init(termSize(default_points, 1, .regular));
    const a = cache.slot('A').?;
    try testing.expect(a.fresh);
    const b = cache.slot('B').?;
    try testing.expect(b.fresh);
    try testing.expect(a.x != b.x or a.y != b.y);

    const again = cache.slot('A').?;
    try testing.expect(!again.fresh);
    try testing.expectEqual(a.x, again.x);
    try testing.expectEqual(a.y, again.y);
}

test "unmapped codepoints share the replacement box's slot" {
    var cache = Cache.init(termSize(default_points, 1, .regular));
    const box = cache.slot(replacement).?;
    const cjk = cache.slot(0x4E00).?;
    try testing.expect(!cjk.fresh);
    try testing.expectEqual(box.x, cjk.x);
    try testing.expectEqual(box.y, cjk.y);
}

test "every slot lies inside the cache texture, and a full cache starts over" {
    for (0..section_count) |i| {
        const size = sectionAt(i);
        var cache = Cache.init(size);
        var placed: u32 = 0;
        var cp: u21 = 0;
        while (placed < cache_slots) : (cp += 1) {
            if (indexOf(cp) == null) continue;
            const s = cache.slot(cp) orelse continue;
            try testing.expect(s.fresh);
            try testing.expect(s.x + size.w <= cacheW(size));
            try testing.expect(s.y + size.h <= cacheH(size));
            placed += 1;
        }
        // The next new glyph evicts everything and lands back at the start.
        while (indexOf(cp) == null or isBlank(cp, size)) cp += 1;
        const s = cache.slot(cp).?;
        try testing.expect(s.fresh);
        try testing.expectEqual(@as(u32, 0), s.x);
        try testing.expectEqual(@as(u32, 0), s.y);
        try testing.expect(cache.slot(' ') == null);
        try testing.expect(cache.slot('A').?.fresh); // evicted, so uploaded again
    }
}

test "expandGlyph carries coverage in alpha over white" {
    const size = termSize(default_points, 2, .regular);
    var px: [max_glyph_pixels]u32 = undefined;
    expandGlyph('A', size, &px);
    for (glyph('A', size), px[0..size.pixels()]) |a, p| {
        try testing.expectEqual((@as(u32, a) << 24) | 0x00FFFFFF, p);
    }
}

test "exact lookups find the sections the ladder promises" {
    try testing.expect(exact(.regular, 8, 17) != null); // 13pt at 1x
    try testing.expect(exact(.regular, 16, 34) != null); // 13pt at 2x
    try testing.expect(exact(.bold, 16, 34) != null);
    try testing.expect(exact(.regular, 99, 99) == null);
}
