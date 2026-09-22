//! UI icons, rasterized from signed distance fields at the size they are drawn.
//!
//! Icons are geometry, not text. Glyphs borrowed from the font (`+`, `×`, `▾`)
//! are tied to its metrics, sit on a baseline meant for letters, and read as
//! punctuation rather than as controls. These are described once on a unit
//! square and evaluated at whatever pixel size the current cell calls for, so
//! they look the same on every display instead of being a bitmap stretched to
//! fit one.
//!
//! Strokes are capsules, which gives them the round caps and joins that modern
//! icon sets use.

const std = @import("std");

pub const Icon = enum {
    /// New tab.
    plus,
    /// Close.
    close,
    /// Opens a drop-down.
    chevron_down,
    /// A remote connection: two nodes joined by a link.
    remote,
    /// A local shell: a screen with a prompt in it.
    terminal,
};

pub const count = @typeInfo(Icon).@"enum".fields.len;

/// The largest icon `buildStrip` rasterizes; bigger cells upscale from this.
pub const max_size: u32 = 96;

const Point = struct { x: f32, y: f32 };

fn p(x: f32, y: f32) Point {
    return .{ .x = x, .y = y };
}

/// A drawing primitive on the unit square. Each reports a signed distance,
/// negative inside, so overlapping primitives combine by taking the minimum.
const Prim = union(enum) {
    /// A line with round caps.
    stroke: struct { a: Point, b: Point, w: f32 },
    /// A filled circle.
    disc: struct { c: Point, r: f32 },
    /// The outline of a circle or ellipse.
    ring: struct { c: Point, rx: f32, ry: f32, w: f32 },
    /// The outline of a rounded rectangle.
    frame: struct { a: Point, b: Point, radius: f32, w: f32 },

    fn distance(self: Prim, x: f32, y: f32) f32 {
        return switch (self) {
            .stroke => |s| segmentDistance(x, y, s.a, s.b) - s.w / 2,
            .disc => |d| std.math.hypot(x - d.c.x, y - d.c.y) - d.r,
            .ring => |r| blk: {
                // An ellipse has no closed-form distance; scaling the point
                // into a circle's frame and back is accurate enough at the
                // sizes an icon is drawn, and keeps the stroke even.
                const k = r.rx / r.ry;
                const dx = x - r.c.x;
                const dy = (y - r.c.y) * k;
                break :blk @abs(std.math.hypot(dx, dy) - r.rx) - r.w / 2;
            },
            .frame => |f| blk: {
                const cx = (f.a.x + f.b.x) / 2;
                const cy = (f.a.y + f.b.y) / 2;
                const hx = (f.b.x - f.a.x) / 2;
                const hy = (f.b.y - f.a.y) / 2;
                const box = roundedBoxDistance(x - cx, y - cy, hx, hy, f.radius);
                break :blk @abs(box) - f.w / 2;
            },
        };
    }
};

fn segmentDistance(px: f32, py: f32, a: Point, b: Point) f32 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const wx = px - a.x;
    const wy = py - a.y;
    const len2 = vx * vx + vy * vy;
    const t = if (len2 > 0) std.math.clamp((wx * vx + wy * vy) / len2, 0, 1) else 0;
    return std.math.hypot(px - (a.x + t * vx), py - (a.y + t * vy));
}

fn roundedBoxDistance(px: f32, py: f32, hx: f32, hy: f32, radius: f32) f32 {
    const qx = @abs(px) - hx + radius;
    const qy = @abs(py) - hy + radius;
    const outside = std.math.hypot(@max(qx, 0), @max(qy, 0));
    return outside + @min(@max(qx, qy), 0) - radius;
}

/// One stroke weight across the set, so no icon reads heavier than the one
/// beside it. Chosen to land on the stem width of the interface face at the
/// size icons are drawn beside it, so the two read as one piece of typography
/// rather than as text with pictures next to it.
const W: f32 = 0.07;

const plus_shape = [_]Prim{
    .{ .stroke = .{ .a = p(0.5, 0.23), .b = p(0.5, 0.77), .w = W } },
    .{ .stroke = .{ .a = p(0.23, 0.5), .b = p(0.77, 0.5), .w = W } },
};

const close_shape = [_]Prim{
    .{ .stroke = .{ .a = p(0.28, 0.28), .b = p(0.72, 0.72), .w = W } },
    .{ .stroke = .{ .a = p(0.72, 0.28), .b = p(0.28, 0.72), .w = W } },
};

const chevron_shape = [_]Prim{
    .{ .stroke = .{ .a = p(0.24, 0.41), .b = p(0.5, 0.65), .w = W } },
    .{ .stroke = .{ .a = p(0.76, 0.41), .b = p(0.5, 0.65), .w = W } },
};

/// Two nodes joined by a link: the shape interfaces use for "connected to
/// something elsewhere", which is what an ssh session is.
/// A globe: what native interfaces use for "somewhere on the network", which
/// is what an ssh host is. Rim, meridian and equator in the set's line weight.
const remote_shape = [_]Prim{
    .{ .ring = .{ .c = p(0.5, 0.5), .rx = 0.36, .ry = 0.36, .w = W } },
    .{ .ring = .{ .c = p(0.5, 0.5), .rx = 0.16, .ry = 0.36, .w = W } },
    .{ .stroke = .{ .a = p(0.15, 0.5), .b = p(0.85, 0.5), .w = W } },
};

/// A screen with a prompt chevron in it.
const terminal_shape = [_]Prim{
    .{ .frame = .{ .a = p(0.13, 0.19), .b = p(0.87, 0.81), .radius = 0.14, .w = W } },
    .{ .stroke = .{ .a = p(0.31, 0.39), .b = p(0.45, 0.5), .w = W } },
    .{ .stroke = .{ .a = p(0.31, 0.61), .b = p(0.45, 0.5), .w = W } },
    .{ .stroke = .{ .a = p(0.55, 0.62), .b = p(0.69, 0.62), .w = W } },
};

fn shapeOf(icon: Icon) []const Prim {
    return switch (icon) {
        .plus => &plus_shape,
        .close => &close_shape,
        .chevron_down => &chevron_shape,
        .remote => &remote_shape,
        .terminal => &terminal_shape,
    };
}

/// Coverage of `icon` at a point on its unit square.
fn coverageAt(icon: Icon, x: f32, y: f32, px_size: f32) f32 {
    var d: f32 = std.math.floatMax(f32);
    for (shapeOf(icon)) |prim| d = @min(d, prim.distance(x, y));

    // One pixel of feathering, expressed in unit-square terms.
    const feather = 1.0 / px_size;
    return std.math.clamp(0.5 - d / feather, 0, 1);
}

/// Renders `icon` into `out` as white pixels carrying coverage in the alpha
/// channel: `size` * `size` ARGB values, matching the font atlas so the same
/// colour mod tints both.
///
/// Allocation-free; the caller owns the buffer.
pub fn render(icon: Icon, size: u32, out: []u32) void {
    std.debug.assert(out.len >= size * size);
    const fsize: f32 = @floatFromInt(size);
    for (0..size) |yi| {
        for (0..size) |xi| {
            const x = (@as(f32, @floatFromInt(xi)) + 0.5) / fsize;
            const y = (@as(f32, @floatFromInt(yi)) + 0.5) / fsize;
            const a: u32 = @intFromFloat(@round(coverageAt(icon, x, y, fsize) * 255));
            out[yi * size + xi] = (a << 24) | 0x00FFFFFF;
        }
    }
}

// -- atlas strip -----------------------------------------------------------

/// Every icon in one horizontal strip, so the whole set costs one texture.
pub fn stripW(size: u32) u32 {
    return size * @as(u32, @intCast(count));
}

pub fn stripPixels(size: u32) usize {
    return stripW(size) * size;
}

pub fn buildStrip(size: u32, out: []u32) void {
    std.debug.assert(out.len >= stripPixels(size));
    const w = stripW(size);
    // Annotated: `@min` against a literal narrows the result type, and the
    // squared value then overflows it.
    const capped: u32 = @min(size, max_size);
    var cell: [max_size * max_size]u32 = undefined;

    @memset(out[0..stripPixels(size)], 0x00FFFFFF);
    for (0..count) |i| {
        const icon: Icon = @enumFromInt(i);
        render(icon, capped, cell[0 .. capped * capped]);
        for (0..capped) |y| {
            const dst = y * w + i * size;
            @memcpy(out[dst..][0..capped], cell[y * capped ..][0..capped]);
        }
    }
}

/// X offset of `icon` within the strip.
pub fn stripX(icon: Icon, size: u32) u32 {
    return @as(u32, @intFromEnum(icon)) * size;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn alphaOf(px: u32) u8 {
    return @truncate(px >> 24);
}

fn renderIcon(icon: Icon, size: u32, buf: []u32) []u32 {
    render(icon, size, buf);
    return buf[0 .. size * size];
}

fn inkOf(icon: Icon, size: u32, buf: []u32) usize {
    var ink: usize = 0;
    for (renderIcon(icon, size, buf)) |px| ink += alphaOf(px);
    return ink;
}

test "every icon draws something at every size it is used at" {
    var buf: [max_size * max_size]u32 = undefined;
    for ([_]u32{ 12, 16, 24, 32, 48, 64, 96 }) |size| {
        for (0..count) |i| {
            try testing.expect(inkOf(@enumFromInt(i), size, &buf) > 0);
        }
    }
}

test "the set shares one stroke weight" {
    // What makes a set look like a set is the line weight, not the amount of
    // ink: a framed icon covers more of its box than a chevron does either way.
    for (0..count) |i| {
        for (shapeOf(@enumFromInt(i))) |prim| {
            const w = switch (prim) {
                .stroke => |x| x.w,
                .frame => |x| x.w,
                .ring => |x| x.w,
                .disc => continue,
            };
            try testing.expect(w >= W * 0.75 and w <= W * 1.25);
        }
    }
}

test "icons are antialiased rather than hard-edged" {
    var buf: [max_size * max_size]u32 = undefined;
    for (0..count) |i| {
        var partial: usize = 0;
        for (renderIcon(@enumFromInt(i), 32, &buf)) |px| {
            const a = alphaOf(px);
            if (a != 0 and a != 255) partial += 1;
        }
        try testing.expect(partial > 20);
    }
}

test "strokes have round caps" {
    // A capsule end is rounded, so a pixel diagonally off a stroke tip must be
    // lighter than the one straight off it.
    const size: u32 = 64;
    var buf: [max_size * max_size]u32 = undefined;
    const px = renderIcon(.plus, size, &buf);
    const centre = size / 2;
    const tip: usize = @intFromFloat(0.77 * @as(f32, @floatFromInt(size)));
    const on_axis = alphaOf(px[(tip - 2) * size + centre]);
    const diagonal = alphaOf(px[(tip - 2) * size + centre + 4]);
    try testing.expect(on_axis > diagonal);
}

test "icon pixels are white with coverage in the alpha channel" {
    var buf: [max_size * max_size]u32 = undefined;
    for (0..count) |i| {
        for (renderIcon(@enumFromInt(i), 24, &buf)) |px| {
            try testing.expectEqual(@as(u32, 0x00FFFFFF), px & 0x00FFFFFF);
        }
    }
}

test "plus is symmetric about both axes" {
    const size: u32 = 32;
    var buf: [max_size * max_size]u32 = undefined;
    const px = renderIcon(.plus, size, &buf);
    for (0..size) |y| {
        for (0..size) |x| {
            try testing.expectEqual(px[y * size + x], px[y * size + (size - 1 - x)]);
            try testing.expectEqual(px[y * size + x], px[(size - 1 - y) * size + x]);
        }
    }
}

test "close is symmetric about the diagonal" {
    const size: u32 = 32;
    var buf: [max_size * max_size]u32 = undefined;
    const px = renderIcon(.close, size, &buf);
    for (0..size) |y| {
        for (0..size) |x| {
            try testing.expectEqual(px[y * size + x], px[x * size + y]);
        }
    }
}

test "the chevron points down" {
    const size: u32 = 32;
    var buf: [max_size * max_size]u32 = undefined;
    const px = renderIcon(.chevron_down, size, &buf);

    var lowest_row: usize = 0;
    var lowest_col: usize = 0;
    for (0..size) |y| {
        for (0..size) |x| {
            if (alphaOf(px[y * size + x]) > 128 and y >= lowest_row) {
                lowest_row = y;
                lowest_col = x;
            }
        }
    }
    try testing.expect(lowest_row > size / 2);
    const centre = size / 2;
    try testing.expect(lowest_col >= centre - 2 and lowest_col <= centre + 1);
}

test "the remote icon reads as a globe" {
    // A globe crossed by a meridian shows four bands of ink a quarter of the
    // way down -- rim, meridian, meridian, rim -- and one unbroken band across
    // the equator. Counting bands says the shape is right without pinning the
    // test to exact pixel positions.
    const size: u32 = 64;
    var buf: [max_size * max_size]u32 = undefined;
    const px = renderIcon(.remote, size, &buf);

    const bandsIn = struct {
        fn f(row: []const u32) usize {
            var n: usize = 0;
            var inside = false;
            for (row) |v| {
                const lit = @as(u8, @truncate(v >> 24)) > 120;
                if (lit and !inside) n += 1;
                inside = lit;
            }
            return n;
        }
    }.f;

    try testing.expectEqual(@as(usize, 4), bandsIn(px[(size / 4) * size ..][0..size]));
    try testing.expectEqual(@as(usize, 1), bandsIn(px[(size / 2) * size ..][0..size]));
    try testing.expectEqual(@as(usize, 4), bandsIn(px[(size * 3 / 4) * size ..][0..size]));

    // The rim leaves the corners of the box empty, which a filled blob would not.
    try testing.expectEqual(@as(usize, 0), bandsIn(px[2 * size ..][0..size]));
}

test "the terminal icon is a frame with a hollow middle" {
    const size: u32 = 64;
    var buf: [max_size * max_size]u32 = undefined;
    const px = renderIcon(.terminal, size, &buf);
    try testing.expect(alphaOf(px[(size / 2) * size + size / 7]) > 200);
    try testing.expectEqual(@as(u8, 0), alphaOf(px[(size / 4) * size + size / 2]));
}

test "icons stay inside their box" {
    var buf: [max_size * max_size]u32 = undefined;
    const size: u32 = 32;
    for (0..count) |i| {
        const px = renderIcon(@enumFromInt(i), size, &buf);
        for (0..size) |k| {
            try testing.expectEqual(@as(u8, 0), alphaOf(px[k]));
            try testing.expectEqual(@as(u8, 0), alphaOf(px[(size - 1) * size + k]));
            try testing.expectEqual(@as(u8, 0), alphaOf(px[k * size]));
            try testing.expectEqual(@as(u8, 0), alphaOf(px[k * size + size - 1]));
        }
    }
}

test "an icon keeps its proportions as it scales" {
    // The same design at two sizes must cover the same fraction of its box,
    // which is what "looks the same on every display" means in practice.
    var buf: [max_size * max_size]u32 = undefined;
    for (0..count) |i| {
        const icon: Icon = @enumFromInt(i);
        const small = @as(f64, @floatFromInt(inkOf(icon, 24, &buf))) / (24 * 24 * 255);
        const large = @as(f64, @floatFromInt(inkOf(icon, 96, &buf))) / (96 * 96 * 255);
        try testing.expect(@abs(small - large) < 0.03);
    }
}

test "the strip places each icon at its own offset" {
    const size: u32 = 24;
    const gpa = testing.allocator;
    const strip = try gpa.alloc(u32, stripPixels(size));
    defer gpa.free(strip);
    buildStrip(size, strip);

    var cell: [max_size * max_size]u32 = undefined;
    for (0..count) |i| {
        const icon: Icon = @enumFromInt(i);
        const expected = renderIcon(icon, size, &cell);
        const x0 = stripX(icon, size);
        for (0..size) |y| {
            for (0..size) |x| {
                try testing.expectEqual(
                    expected[y * size + x],
                    strip[y * stripW(size) + x0 + x],
                );
            }
        }
    }
    try testing.expectEqual(size * @as(u32, @intCast(count)), stripW(size));
}

test "stripX never runs past the strip" {
    for ([_]u32{ 16, 32, 64, 96 }) |size| {
        const last: Icon = @enumFromInt(count - 1);
        try testing.expect(stripX(last, size) + size <= stripW(size));
    }
}
