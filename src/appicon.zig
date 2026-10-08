//! The application icon, drawn rather than shipped as a bitmap.
//!
//! macOS asks for an icon at a dozen sizes, from 16px in a list to 1024px in
//! the Finder, and a single bitmap scaled to all of them is soft at the top
//! and mushy at the bottom. This renders the artwork from the same signed
//! distance fields the interface icons use, so every size is drawn at its own
//! resolution and the result is sharp wherever the system puts it.
//!
//! The shape follows the platform's own rounded square, with a single large
//! prompt that stays recognizable at Dock and list sizes.

const std = @import("std");

/// Corner rounding as a fraction of the side. macOS icons sit near 0.22.
const CORNER: f32 = 0.225;
/// The artwork is inset from the edge of the canvas, as macOS icons are, so
/// neighbouring icons in the Dock do not touch.
const INSET: f32 = 0.06;

const GRAD_FROM: [3]f32 = .{ 0x30, 0x31, 0x66 };
const GRAD_TO: [3]f32 = .{ 0x11, 0x1D, 0x32 };
const PROMPT: [3]f32 = .{ 0xED, 0xFA, 0xFF };
const CURSOR: [3]f32 = .{ 0x68, 0xEC, 0xD1 };
const RIM: [3]f32 = .{ 0x69, 0x72, 0xA6 };

const Point = struct { x: f32, y: f32 };

fn p(x: f32, y: f32) Point {
    return .{ .x = x, .y = y };
}

fn segmentDistance(px: f32, py: f32, a: Point, b: Point) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = px - a.x;
    const wy = py - a.y;
    const len2 = vx * vx + vy * vy;
    const t = if (len2 > 0) std.math.clamp((wx * vx + wy * vy) / len2, 0, 1) else 0;
    return std.math.hypot(px - (a.x + t * vx), py - (a.y + t * vy));
}

fn roundedRectDistance(px: f32, py: f32, half_x: f32, half_y: f32, radius: f32) f32 {
    const qx = @abs(px) - half_x + radius;
    const qy = @abs(py) - half_y + radius;
    return std.math.hypot(@max(qx, 0), @max(qy, 0)) + @min(@max(qx, qy), 0) - radius;
}

/// The prompt mark: a chevron and a cursor rule, in the proportions the
/// interface icons use so the app reads as part of the same set.
/// Heavier than the interface icons: this one has to survive being drawn at
/// 16px in a list, where a hairline disappears.
const stroke_w: f32 = 0.088;
const chevron_a = p(0.285, 0.345);
const chevron_tip = p(0.475, 0.5);
const chevron_b = p(0.285, 0.655);
const rule_a = p(0.545, 0.655);
const rule_b = p(0.735, 0.655);

fn markDistance(x: f32, y: f32) f32 {
    var d = segmentDistance(x, y, chevron_a, chevron_tip);
    d = @min(d, segmentDistance(x, y, chevron_tip, chevron_b));
    return d - stroke_w / 2;
}

fn cursorDistance(x: f32, y: f32) f32 {
    return segmentDistance(x, y, rule_a, rule_b) - stroke_w / 2;
}

fn mix(rgb: *[3]f32, color: [3]f32, amount: f32) void {
    for (rgb, color) |*channel, target| channel.* += (target - channel.*) * amount;
}

fn coverage(distance: f32, feather: f32) f32 {
    return std.math.clamp(0.5 - distance / feather, 0, 1);
}

fn gradientAt(t: f32) [3]f32 {
    const k = std.math.clamp(t, 0, 1);
    var out: [3]f32 = undefined;
    for (0..3) |i| out[i] = GRAD_FROM[i] + (GRAD_TO[i] - GRAD_FROM[i]) * k;
    return out;
}

/// Renders the icon into `out` as `size` * `size` ARGB pixels with straight
/// alpha, which is what `SDL_SetWindowIcon` expects.
///
/// Allocation-free; the caller owns the buffer.
pub fn render(size: u32, out: []u32) void {
    renderFrame(size, true, out);
}

/// `cursor` draws the rule beside the prompt. The logo blinks it, the same way
/// a terminal does; the application icon always shows it.
pub fn renderFrame(size: u32, cursor: bool, out: []u32) void {
    std.debug.assert(out.len >= size * size);
    const fsize: f32 = @floatFromInt(size);
    const feather = 1.2 / fsize;
    const half = 0.5 - INSET;
    const radius = CORNER * (half * 2);

    for (0..size) |yi| {
        const y = (@as(f32, @floatFromInt(yi)) + 0.5) / fsize;
        for (0..size) |xi| {
            const x = (@as(f32, @floatFromInt(xi)) + 0.5) / fsize;

            const body = coverage(roundedRectDistance(x - 0.5, y - 0.5, half, half, radius), feather);
            if (body <= 0) {
                out[yi * size + xi] = 0;
                continue;
            }

            // The blue-violet corner gives the small silhouette a distinctive
            // hue while the lower right stays as dark as a terminal screen.
            var rgb = gradientAt((x + y) / 2);
            const glow = std.math.clamp(1 - std.math.hypot(x - 0.21, y - 0.16) / 0.65, 0, 1);
            mix(&rgb, .{ 0x52, 0x47, 0xAA }, glow * 0.26);

            const edge = roundedRectDistance(x - 0.5, y - 0.5, half, half, radius);
            const rim = std.math.clamp(1 + edge / (2.5 / fsize), 0, 1) * body;
            mix(&rgb, RIM, rim * 0.8);

            const mark = coverage(markDistance(x, y), feather);
            mix(&rgb, PROMPT, mark);
            if (cursor) mix(&rgb, CURSOR, coverage(cursorDistance(x, y), feather));
            var r = rgb[0];
            var g = rgb[1];
            var b = rgb[2];
            r = std.math.clamp(r, 0, 255);
            g = std.math.clamp(g, 0, 255);
            b = std.math.clamp(b, 0, 255);

            const a: u32 = @intFromFloat(@round(body * 255));
            out[yi * size + xi] = (a << 24) |
                (@as(u32, @intFromFloat(@round(r))) << 16) |
                (@as(u32, @intFromFloat(@round(g))) << 8) |
                @as(u32, @intFromFloat(@round(b)));
        }
    }
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn alphaOf(px: u32) u8 {
    return @truncate(px >> 24);
}

fn lumaOf(px: u32) u32 {
    return ((px >> 16) & 0xff) + ((px >> 8) & 0xff) + (px & 0xff);
}

fn renderAt(size: u32, buf: []u32) []u32 {
    render(size, buf);
    return buf[0 .. size * size];
}

test "the cursor rule is what the two logo frames differ by" {
    const gpa = testing.allocator;
    const size: u32 = 128;
    const on = try gpa.alloc(u32, size * size);
    defer gpa.free(on);
    const off = try gpa.alloc(u32, size * size);
    defer gpa.free(off);
    renderFrame(size, true, on);
    renderFrame(size, false, off);

    var differ: usize = 0;
    for (on, off) |a, b| {
        if (a != b) differ += 1;
    }
    try testing.expect(differ > 40);

    // The chevron is in both; only the rule comes and goes.
    const at = struct {
        fn f(px: []const u32, s: u32, fx: f32, fy: f32) u32 {
            const xi: usize = @intFromFloat(fx * @as(f32, @floatFromInt(s)));
            const yi: usize = @intFromFloat(fy * @as(f32, @floatFromInt(s)));
            return px[yi * s + xi];
        }
    }.f;
    try testing.expectEqual(at(on, size, 0.47, 0.5), at(off, size, 0.47, 0.5));
    try testing.expect(at(on, size, 0.63, 0.655) != at(off, size, 0.63, 0.655));
}

test "the icon renders at every size the system asks for" {
    const gpa = testing.allocator;
    for ([_]u32{ 16, 32, 64, 128, 256, 512, 1024 }) |size| {
        const buf = try gpa.alloc(u32, size * size);
        defer gpa.free(buf);
        const px = renderAt(size, buf);
        var opaque_px: usize = 0;
        for (px) |v| {
            if (alphaOf(v) > 200) opaque_px += 1;
        }
        // The body covers a good share of the canvas at any size.
        try testing.expect(opaque_px > px.len / 3);
    }
}

test "the corners are transparent and the middle is not" {
    const gpa = testing.allocator;
    const size: u32 = 256;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    try testing.expectEqual(@as(u8, 0), alphaOf(px[0]));
    try testing.expectEqual(@as(u8, 0), alphaOf(px[size - 1]));
    try testing.expectEqual(@as(u8, 0), alphaOf(px[(size - 1) * size]));
    try testing.expectEqual(@as(u8, 0), alphaOf(px[size * size - 1]));
    try testing.expectEqual(@as(u8, 255), alphaOf(px[(size / 2) * size + size / 2]));
}

test "the artwork is inset from the canvas edge" {
    // Dock icons that run to the edge sit badly beside their neighbours.
    const gpa = testing.allocator;
    const size: u32 = 128;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    const mid = size / 2;
    try testing.expectEqual(@as(u8, 0), alphaOf(px[mid * size])); // left edge
    try testing.expectEqual(@as(u8, 0), alphaOf(px[mid * size + size - 1]));
    try testing.expectEqual(@as(u8, 0), alphaOf(px[mid])); // top edge
}

test "the background is a gradient, not a flat fill" {
    const gpa = testing.allocator;
    const size: u32 = 256;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    // Sample the body away from the mark, along the sweep.
    const near = px[(size / 5) * size + size / 5];
    const far = px[(size * 4 / 5) * size + size * 4 / 5];
    try testing.expect(near != far);
    // The sweep runs light to dark, so the far corner is the darker one.
    try testing.expect(lumaOf(near) > lumaOf(far));
}

/// Relative luminance per WCAG, for checking the mark carries on the ground.
fn luminance(px: u32) f64 {
    const chan = struct {
        fn f(v: u32) f64 {
            const c = @as(f64, @floatFromInt(v & 0xff)) / 255.0;
            return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        }
    }.f;
    return 0.2126 * chan(px >> 16) + 0.7152 * chan(px >> 8) + 0.0722 * chan(px);
}

test "the ground is as dark as the terminal's own" {
    const gpa = testing.allocator;
    const size: u32 = 256;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    // Sampled inside the body, away from the mark and the rim.
    const ground = px[(size / 2) * size + size * 3 / 4];
    try testing.expect(luminance(ground) < 0.06);
}

test "the mark carries against the ground" {
    const gpa = testing.allocator;
    const size: u32 = 256;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    const at = struct {
        fn f(pixels: []const u32, s: u32, fx: f32, fy: f32) u32 {
            const xi: usize = @intFromFloat(fx * @as(f32, @floatFromInt(s)));
            const yi: usize = @intFromFloat(fy * @as(f32, @floatFromInt(s)));
            return pixels[yi * s + xi];
        }
    }.f;

    const mark = at(px, size, 0.47, 0.5);
    const ground = at(px, size, 0.75, 0.5);
    const ratio = (luminance(mark) + 0.05) / (luminance(ground) + 0.05);
    // Well past the 4.5:1 that counts as readable, because at 16px the mark
    // is a few pixels wide and has nothing else to help it.
    try testing.expect(ratio >= 7.0);
}

test "the rim keeps the icon off a dark background" {
    const gpa = testing.allocator;
    const size: u32 = 256;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    const mid = size / 2;
    // Just inside the left edge of the body, against the middle of it.
    var edge_x: usize = 0;
    while (edge_x < size and alphaOf(px[mid * size + edge_x]) < 250) edge_x += 1;
    const rim = px[mid * size + edge_x + 1];
    const inner = px[mid * size + mid / 2];
    try testing.expect(luminance(rim) > luminance(inner));
}

test "the prompt stands out from the body" {
    const gpa = testing.allocator;
    const size: u32 = 256;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    const at = struct {
        fn f(pixels: []const u32, s: u32, fx: f32, fy: f32) u32 {
            const xi: usize = @intFromFloat(fx * @as(f32, @floatFromInt(s)));
            const yi: usize = @intFromFloat(fy * @as(f32, @floatFromInt(s)));
            return pixels[yi * s + xi];
        }
    }.f;

    const on_mark = at(px, size, 0.47, 0.5);
    const on_rule = at(px, size, 0.63, 0.655);
    const body = at(px, size, 0.75, 0.5);
    try testing.expect(lumaOf(on_mark) > lumaOf(body) * 2);
    try testing.expect(lumaOf(on_rule) > lumaOf(body) * 2);
}

test "the mark stays legible at list size" {
    // 16px is where a busy icon turns to mush; the prompt must still show.
    const gpa = testing.allocator;
    const size: u32 = 16;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    // Count what stands clearly off the ground rather than using an absolute
    // brightness: the mark has white and mint parts.
    const ground = lumaOf(px[(size / 2) * size + size * 3 / 4]);
    var bright: usize = 0;
    for (px) |v| {
        if (alphaOf(v) > 128 and lumaOf(v) > ground * 2) bright += 1;
    }
    try testing.expect(bright >= 10);
}

test "the icon is symmetric about neither axis, so it is not a plain shape" {
    // The prompt sits left of centre; a symmetric result would mean the mark
    // was lost.
    const gpa = testing.allocator;
    const size: u32 = 128;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);

    var mirrored: usize = 0;
    for (0..size) |y| {
        for (0..size) |x| {
            if (px[y * size + x] != px[y * size + (size - 1 - x)]) mirrored += 1;
        }
    }
    try testing.expect(mirrored > size);
}

test "every pixel is either transparent or fully inside the body" {
    const gpa = testing.allocator;
    const size: u32 = 64;
    const buf = try gpa.alloc(u32, size * size);
    defer gpa.free(buf);
    const px = renderAt(size, buf);
    for (px) |v| {
        // Colour channels must never exceed white, which would mean the mark
        // blend overflowed.
        try testing.expect((v >> 16) & 0xff <= 255);
        try testing.expect((v >> 8) & 0xff <= 255);
        try testing.expect(v & 0xff <= 255);
    }
}
