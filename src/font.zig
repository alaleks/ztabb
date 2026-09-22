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
pub const Weight = enum { regular, bold };

pub const Size = struct {
    w: u32,
    h: u32,
    index: usize,

    pub fn pixels(self: Size) usize {
        return self.w * self.h;
    }
};

/// The baked sizes, smallest first.
pub fn sizeAt(index: usize) Size {
    const s = data.sizes[index];
    return .{ .w = s.w, .h = s.h, .index = index };
}

pub const size_count = data.sizes.len;
pub const base_w: u32 = data.sizes[0].w;
pub const base_h: u32 = data.sizes[0].h;

/// The largest baked size whose cell fits `cell_w` x `cell_h`, so glyphs are
/// only ever upscaled when the user has zoomed past the largest baked set.
pub fn bestSize(cell_w: u32, cell_h: u32) Size {
    var best: usize = 0;
    for (data.sizes, 0..) |s, i| {
        if (s.w <= cell_w and s.h <= cell_h) best = i;
    }
    return sizeAt(best);
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

/// Coverage bytes for one glyph, row-major, `size.w * size.h` long.
pub fn glyph(cp: u21, weight: Weight, size: Size) []const u8 {
    const s = data.sizes[size.index];
    const per_glyph = s.w * s.h;
    const per_weight = per_glyph * glyph_count;
    const weight_offset: usize = if (weight == .bold) per_weight else 0;
    const start = s.offset + weight_offset + resolveIndex(cp) * per_glyph;
    return blob[start..][0..per_glyph];
}

/// True when the glyph has no coverage at all — used to skip drawing entirely.
pub fn isBlank(cp: u21, weight: Weight, size: Size) bool {
    for (glyph(cp, weight, size)) |v| {
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
pub fn buildAtlas(weight: Weight, size: Size, out: []u32) void {
    const w = atlasW(size);
    std.debug.assert(out.len >= atlasPixels(size));
    @memset(out[0..atlasPixels(size)], 0x00000000);

    for (0..glyph_count) |i| {
        const s = data.sizes[size.index];
        const per_glyph = s.w * s.h;
        const per_weight = per_glyph * glyph_count;
        const weight_offset: usize = if (weight == .bold) per_weight else 0;
        const src = blob[s.offset + weight_offset + i * per_glyph ..][0..per_glyph];

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

test "the baked sizes are ordered and share an aspect ratio" {
    try testing.expect(size_count >= 2);
    var prev: u32 = 0;
    for (0..size_count) |i| {
        const s = sizeAt(i);
        try testing.expect(s.w > prev);
        try testing.expectEqual(s.h, s.w * 2); // cells are 1:2
        prev = s.w;
    }
    try testing.expectEqual(@as(u32, 8), base_w);
    try testing.expectEqual(@as(u32, 16), base_h);
}

test "font.dat is exactly as large as the metrics say" {
    var expected: usize = 0;
    for (data.sizes) |s| expected += s.w * s.h * glyph_count * 2;
    try testing.expectEqual(expected, blob.len);
}

test "bestSize picks the largest set that fits and never overshoots" {
    try testing.expectEqual(@as(u32, 8), bestSize(8, 16).w);
    try testing.expectEqual(@as(u32, 8), bestSize(15, 31).w);
    try testing.expectEqual(@as(u32, 16), bestSize(16, 32).w);
    // Zoomed past the largest baked set: use it and upscale.
    try testing.expectEqual(@as(u32, 16), bestSize(32, 64).w);
    // Smaller than anything baked: fall back to the smallest.
    try testing.expectEqual(@as(u32, 8), bestSize(4, 8).w);
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

test "every glyph slice is the size the metrics promise" {
    for (0..size_count) |i| {
        const size = sizeAt(i);
        try testing.expectEqual(size.pixels(), glyph('A', .regular, size).len);
        try testing.expectEqual(size.pixels(), glyph('A', .bold, size).len);
        // The last glyph must still lie inside the blob.
        try testing.expectEqual(size.pixels(), glyph(0x2718, .bold, size).len);
    }
}

test "Powerline and prompt-theme symbols are covered" {
    // agnoster and friends draw their separators from the Powerline private
    // use area; without these the prompt renders as a row of boxes.
    for ([_]u21{
        0xE0A0, // branch
        0xE0A1, // line number
        0xE0A2, // padlock
        0xE0B0, // solid right separator
        0xE0B1, // thin right separator
        0xE0B2, // solid left separator
        0xE0B3, // thin left separator
    }) |cp| {
        try testing.expect(indexOf(cp) != null);
        for (0..size_count) |i| {
            try testing.expect(!isBlank(cp, .regular, sizeAt(i)));
        }
    }

    // Other glyphs those themes reach for.
    for ([_]u21{
        0x00B1, // ±
        0x2691, // ⚑
        0x2699, // ⚙
        0x26A1, // ⚡
        0x2718, // ✘
        0x271A, // ✚
        0x272D, // ✭
        0x27A6, // ➦
    }) |cp| {
        try testing.expect(indexOf(cp) != null);
        try testing.expect(!isBlank(cp, .regular, sizeAt(0)));
    }
}

test "Powerline separators span the full cell so they tile" {
    // The solid separator's base must reach both the top and bottom edge,
    // otherwise a seam shows between the prompt segments.
    for (0..size_count) |i| {
        const size = sizeAt(i);
        const g = glyph(0xE0B0, .regular, size);
        try testing.expect(g[0] > 0); // top-left corner
        try testing.expect(g[(size.h - 1) * size.w] > 0); // bottom-left corner
        // The apex reaches the right edge at the vertical middle.
        try testing.expect(g[(size.h / 2) * size.w + size.w - 1] > 0);

        // The mirrored form is the same shape flipped horizontally.
        const left = glyph(0xE0B2, .regular, size);
        try testing.expect(left[size.w - 1] > 0);
        try testing.expect(left[(size.h / 2) * size.w] > 0);
    }
}

test "space is blank and letters are not, at every size" {
    for (0..size_count) |i| {
        const size = sizeAt(i);
        try testing.expect(isBlank(' ', .regular, size));
        try testing.expect(!isBlank('A', .regular, size));
        try testing.expect(!isBlank('A', .bold, size));
        try testing.expect(!isBlank('Ж', .regular, size));
    }
}

test "glyphs are antialiased, not one-bit" {
    // The whole point of the rebake: partial coverage must exist, otherwise
    // the text renders as hard-edged blocks.
    for (0..size_count) |i| {
        const size = sizeAt(i);
        var partial: usize = 0;
        for ("aoegsSOQ@") |cp| {
            for (glyph(cp, .regular, size)) |v| {
                if (v != 0 and v != 255) partial += 1;
            }
        }
        try testing.expect(partial > 20);
    }
}

test "bold is heavier than regular" {
    for (0..size_count) |i| {
        const size = sizeAt(i);
        var regular_ink: usize = 0;
        var bold_ink: usize = 0;
        for ('A'..'Z' + 1) |cp| {
            for (glyph(@intCast(cp), .regular, size)) |v| regular_ink += v;
            for (glyph(@intCast(cp), .bold, size)) |v| bold_ink += v;
        }
        try testing.expect(bold_ink > regular_ink);
    }
}

test "unmapped codepoints fall back to the replacement box" {
    const size = sizeAt(0);
    try testing.expectEqualSlices(
        u8,
        glyph(replacement, .regular, size),
        glyph(0x4E00, .regular, size),
    );
    try testing.expect(!isBlank(0x4E00, .regular, size));
}

test "full block covers every pixel of the cell" {
    // Adjacent full blocks must tile with no seam.
    for (0..size_count) |i| {
        const size = sizeAt(i);
        for (glyph(0x2588, .regular, size)) |v| {
            try testing.expectEqual(@as(u8, 255), v);
        }
    }
}

test "shade blocks are evenly tinted and ordered light to dark" {
    const size = sizeAt(0);
    var prev: usize = 0;
    for ([_]u21{ 0x2591, 0x2592, 0x2593 }) |cp| {
        var ink: usize = 0;
        for (glyph(cp, .regular, size)) |v| ink += v;
        try testing.expect(ink > prev);
        prev = ink;
    }
}

test "buildAtlas lays glyphs out on the expected grid" {
    const gpa = testing.allocator;
    for (0..size_count) |i| {
        const size = sizeAt(i);
        const pixels = try gpa.alloc(u32, atlasPixels(size));
        defer gpa.free(pixels);
        buildAtlas(.regular, size, pixels);

        // Space sits at cell 0 and must be fully transparent.
        for (0..size.h) |y| {
            for (0..size.w) |x| {
                try testing.expectEqual(@as(u32, 0x00FFFFFF), pixels[y * atlasW(size) + x]);
            }
        }

        // 'A' must match its coverage bytes pixel for pixel.
        const rect = atlasRect('A', size);
        const bits = glyph('A', .regular, size);
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
    for (0..size_count) |i| {
        const size = sizeAt(i);
        try testing.expect(atlas_rows * atlas_cols >= glyph_count);
        const last = atlasRect(0x2718, size);
        try testing.expect(last.x + size.w <= atlasW(size));
        try testing.expect(last.y + size.h <= atlasH(size));
    }
}
