//! Built-in antialiased bitmap font.
//!
//! Glyphs are baked from Menlo by `tools/genfont.c` into `font.dat`: one byte
//! of coverage per pixel, two weights per cell size. Two sizes are stored —
//! 8x16 and 16x32 — because a small bitmap stretched onto a HiDPI backbuffer
//! loses every trace of the antialiasing and reads as a typewriter impression.
//! The renderer picks the largest baked size that fits the cell it is drawing.

const std = @import("std");
const data = @import("font_data.zig");

/// Raw coverage bytes, laid out as `sizes` x weight x glyph x row x column.
const blob = @embedFile("font.dat");

pub const glyph_count = data.glyph_count;

/// `medium` is weight 500, used for interface text: it reads at a smaller size
/// than regular without the heaviness of bold.
pub const Weight = enum(u8) { regular, bold, medium };

/// One baked (size, weight) section of `font.dat`.
pub const Size = struct {
    w: u32,
    h: u32,
    weight: Weight,
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
        .offset = sct.offset,
    };
}

/// The section for `weight` at exactly `w` x `h`, if one was baked.
fn find(weight: Weight, w: u32, h: u32) ?Size {
    for (0..section_count) |i| {
        const sct = sectionAt(i);
        if (sct.weight == weight and sct.w == w and sct.h == h) return sct;
    }
    return null;
}

/// The largest baked set of `weight` that fits a `cell_w` x `cell_h` box, so
/// glyphs are only upscaled once the user has zoomed past the largest one.
pub fn bestSize(weight: Weight, cell_w: u32, cell_h: u32) Size {
    var best: ?Size = null;
    var smallest: ?Size = null;
    for (0..section_count) |i| {
        const sct = sectionAt(i);
        if (sct.weight != weight) continue;
        if (smallest == null or sct.w < smallest.?.w) smallest = sct;
        if (sct.w <= cell_w and sct.h <= cell_h) {
            if (best == null or sct.w > best.?.w) best = sct;
        }
    }
    // Every weight is baked at at least one size, so one of these always hits.
    return best orelse smallest orelse sectionAt(0);
}

/// The regular terminal face, which defines the cell the grid is laid out on.
pub const base_w: u32 = 8;
pub const base_h: u32 = 16;

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
pub fn isBlank(cp: u21, size: Size) bool {
    for (glyph(cp, size)) |v| {
        if (v != 0) return false;
    }
    return true;
}

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

fn allSections() usize {
    return section_count;
}

test "font.dat is exactly as large as the metrics say" {
    var expected: usize = 0;
    for (0..section_count) |i| {
        const sct = sectionAt(i);
        expected += sct.pixels() * glyph_count;
    }
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

test "the terminal face is baked at both densities, in both weights" {
    for ([_]Weight{ .regular, .bold }) |w| {
        try testing.expect(find(w, 8, 16) != null);
        try testing.expect(find(w, 16, 32) != null);
    }
}

test "interface text is baked at weight 500, smaller than the terminal cell" {
    // Tab labels need to read at a smaller size than terminal text; medium
    // carries at that size where regular goes faint and bold goes heavy.
    const ui_1x = find(.medium, 6, 12).?;
    const ui_2x = find(.medium, 12, 24).?;
    try testing.expect(ui_1x.w < base_w);
    try testing.expect(ui_2x.w < base_w * 2);
    try testing.expectEqual(Weight.medium, ui_1x.weight);
    try testing.expectEqual(Weight.medium, ui_2x.weight);
}

test "medium sits between regular and bold in weight" {
    // Compared at the same cell so the measurement is like for like: medium is
    // baked at 12x24, so scale the 16x32 terminal faces by area.
    var medium_ink: f64 = 0;
    var regular_ink: f64 = 0;
    var bold_ink: f64 = 0;
    const med = find(.medium, 12, 24).?;
    const reg = find(.regular, 16, 32).?;
    const bld = find(.bold, 16, 32).?;
    for ('a'..'z' + 1) |cp| {
        for (glyph(@intCast(cp), med)) |v| medium_ink += @floatFromInt(v);
        for (glyph(@intCast(cp), reg)) |v| regular_ink += @floatFromInt(v);
        for (glyph(@intCast(cp), bld)) |v| bold_ink += @floatFromInt(v);
    }
    // Normalise by cell area.
    medium_ink /= @floatFromInt(med.pixels());
    regular_ink /= @floatFromInt(reg.pixels());
    bold_ink /= @floatFromInt(bld.pixels());
    try testing.expect(medium_ink > regular_ink);
    try testing.expect(medium_ink < bold_ink);
}

test "bestSize picks the largest set that fits and never overshoots" {
    try testing.expectEqual(@as(u32, 8), bestSize(.regular, 8, 16).w);
    try testing.expectEqual(@as(u32, 8), bestSize(.regular, 15, 31).w);
    try testing.expectEqual(@as(u32, 16), bestSize(.regular, 16, 32).w);
    // Zoomed past the largest baked set: use it and upscale.
    try testing.expectEqual(@as(u32, 16), bestSize(.regular, 64, 128).w);
    // Smaller than anything baked: fall back to the smallest.
    try testing.expectEqual(@as(u32, 8), bestSize(.regular, 4, 8).w);

    try testing.expectEqual(@as(u32, 6), bestSize(.medium, 6, 12).w);
    try testing.expectEqual(@as(u32, 12), bestSize(.medium, 14, 28).w);
}

test "bestSize always returns the weight it was asked for" {
    for ([_]Weight{ .regular, .bold, .medium }) |w| {
        for ([_]u32{ 1, 6, 8, 12, 16, 100 }) |cell| {
            try testing.expectEqual(w, bestSize(w, cell, cell * 2).weight);
        }
    }
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
    try testing.expectEqual(@as(usize, '~' - 0x20), indexOf('~').?);
    try testing.expect(indexOf(0x7F) == null);
    try testing.expect(indexOf(0x1F) == null);
    try testing.expect(indexOf(0x4E00) == null);
}

test "ASCII, Cyrillic and box drawing are all covered" {
    for (0x20..0x7F) |cp| try testing.expect(indexOf(@intCast(cp)) != null);
    try testing.expect(indexOf('Ж') != null);
    try testing.expect(indexOf('я') != null);
    try testing.expect(indexOf('Ё') != null);
    try testing.expect(indexOf(0x2500) != null); // ─
    try testing.expect(indexOf(0x2588) != null); // █
}

test "Powerline and prompt-theme symbols are covered" {
    // agnoster and friends draw their separators from the Powerline private
    // use area; without these the prompt renders as a row of boxes.
    for ([_]u21{ 0xE0A0, 0xE0A1, 0xE0A2, 0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3 }) |cp| {
        try testing.expect(indexOf(cp) != null);
        for (0..section_count) |i| {
            try testing.expect(!isBlank(cp, sectionAt(i)));
        }
    }
    for ([_]u21{ 0x00B1, 0x2691, 0x2699, 0x26A1, 0x2718, 0x271A, 0x272D, 0x27A6 }) |cp| {
        try testing.expect(indexOf(cp) != null);
        try testing.expect(!isBlank(cp, bestSize(.regular, 16, 32)));
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

test "bold is heavier than regular at the same size" {
    for ([_]u32{ 8, 16 }) |w| {
        var regular_ink: usize = 0;
        var bold_ink: usize = 0;
        const reg = find(.regular, w, w * 2).?;
        const bld = find(.bold, w, w * 2).?;
        for ('A'..'Z' + 1) |cp| {
            for (glyph(@intCast(cp), reg)) |v| regular_ink += v;
            for (glyph(@intCast(cp), bld)) |v| bold_ink += v;
        }
        try testing.expect(bold_ink > regular_ink);
    }
}

test "unmapped codepoints fall back to the replacement box" {
    const size = bestSize(.regular, 8, 16);
    try testing.expectEqualSlices(u8, glyph(replacement, size), glyph(0x4E00, size));
    try testing.expect(!isBlank(0x4E00, size));
}

test "full block covers every pixel of the cell" {
    // Adjacent full blocks must tile with no seam.
    for (0..section_count) |i| {
        for (glyph(0x2588, sectionAt(i))) |v| {
            try testing.expectEqual(@as(u8, 255), v);
        }
    }
}

test "shade blocks are evenly tinted and ordered light to dark" {
    const size = bestSize(.regular, 8, 16);
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

        // Space sits at cell 0 and must be fully transparent.
        for (0..size.h) |y| {
            for (0..size.w) |x| {
                try testing.expectEqual(@as(u32, 0x00FFFFFF), pixels[y * atlasW(size) + x]);
            }
        }

        // 'A' must match its coverage bytes pixel for pixel.
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
