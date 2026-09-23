//! Light and dark colour schemes.
//!
//! A theme owns both the chrome colours (tab bar, borders) and the 16 ANSI
//! palette entries, so switching themes re-colours already-rendered cells:
//! the terminal grid stores palette *indices* for the standard colours and
//! only stores literal RGB for 256-colour and truecolor escapes.

const std = @import("std");

pub const Kind = enum { dark, light };

pub const Theme = struct {
    kind: Kind,
    name: []const u8,

    bg: u32,
    fg: u32,
    cursor: u32,
    /// Foreground used for text drawn under a block cursor.
    cursor_text: u32,
    selection: u32,

    tab_bar_bg: u32,
    tab_active_bg: u32,
    tab_inactive_bg: u32,
    tab_active_fg: u32,
    tab_inactive_fg: u32,
    tab_border: u32,

    /// 0-7 normal, 8-15 bright.
    ansi: [16]u32,

    /// Colours for the command-line syntax highlighter.
    hl_command: u32,
    hl_builtin: u32,
    hl_option: u32,
    hl_string: u32,
    hl_number: u32,
    hl_operator: u32,
    hl_path: u32,
    hl_variable: u32,
    hl_comment: u32,
    hl_unknown: u32,
};

/// A soft, desaturated dark scheme in the spirit of JetBrains' Gerry Dark,
/// lightened a step: the background is a blue-grey rather than near-black, so
/// long sessions stay comfortable without the text losing contrast.
pub const dark = Theme{
    .kind = .dark,
    .name = "gerry dark",

    .bg = 0x2B2E36,
    .fg = 0xCBD1DB,
    .cursor = 0xD8DDE5,
    .cursor_text = 0x2B2E36,
    .selection = 0x425170,

    .tab_bar_bg = 0x22252C,
    .tab_active_bg = 0x333740,
    .tab_inactive_bg = 0x272B32,
    .tab_active_fg = 0xE3E7ED,
    .tab_inactive_fg = 0x8992A0,
    .tab_border = 0x1C1F24,

    .ansi = .{
        0x333740, 0xE06C77, 0x8FBF7F, 0xD9B072,
        0x6FA8DC, 0xBE8FD4, 0x5FB3C0, 0xC6CCD6,
        0x5A616E, 0xF08A96, 0xA6D493, 0xEEC888,
        0x8CC0EC, 0xD3A7E4, 0x79CBD8, 0xEDF1F6,
    },

    .hl_command = 0x6FC2B4,
    .hl_builtin = 0x6FA8DC,
    .hl_option = 0xD9B072,
    .hl_string = 0xD9A07C,
    .hl_number = 0xA6D493,
    .hl_operator = 0xBE8FD4,
    .hl_path = 0x9CC7EA,
    .hl_variable = 0xD49BC4,
    .hl_comment = 0x78838F,
    .hl_unknown = 0xC6CCD6,
};

/// The light counterpart: a warm off-white ground rather than pure white, with
/// the same hues darkened until they carry on it.
pub const light = Theme{
    .kind = .light,
    .name = "gerry light",

    .bg = 0xFAFAFA,
    .fg = 0x353A42,
    .cursor = 0x353A42,
    .cursor_text = 0xFAFAFA,
    .selection = 0xBCD4F0,

    .tab_bar_bg = 0xE7E9EC,
    .tab_active_bg = 0xFAFAFA,
    .tab_inactive_bg = 0xDCDFE4,
    .tab_active_fg = 0x23272E,
    .tab_inactive_fg = 0x666D78,
    .tab_border = 0xC4C8CE,

    .ansi = .{
        0xE1E3E7, 0xC0392B, 0x3E7D32, 0x8A6410,
        0x1F5FA8, 0x8241A8, 0x14707E, 0x353A42,
        0xA8ADB5, 0xA5271A, 0x2F6626, 0x70500B,
        0x184D8A, 0x6B3490, 0x0E5A66, 0x23272E,
    },

    .hl_command = 0x0F6E62,
    .hl_builtin = 0x1F5FA8,
    .hl_option = 0x8A6410,
    .hl_string = 0xA5271A,
    .hl_number = 0x2F6626,
    .hl_operator = 0x8241A8,
    .hl_path = 0x184D8A,
    .hl_variable = 0x9A4B12,
    .hl_comment = 0x767D88,
    .hl_unknown = 0x353A42,
};

/// How far a 256-colour cube entry is pulled toward its own brightness.
///
/// The xterm cube tops out at pure 255 primaries -- index 196 is literally
/// #FF0000 -- which next to this palette's muted ANSI set reads as
/// fluorescent, most visibly on the coloured badges prompts like to draw.
const CUBE_TEMPER: f32 = 0.24;

/// Takes the glare off a saturated colour without changing which colour it
/// is: every channel moves the same fraction toward the grey of the same
/// brightness, so the hue and the ordering of the ramp survive.
pub fn temper(rgb: u32) u32 {
    const r: f32 = @floatFromInt((rgb >> 16) & 0xff);
    const g: f32 = @floatFromInt((rgb >> 8) & 0xff);
    const b: f32 = @floatFromInt(rgb & 0xff);
    const grey = 0.299 * r + 0.587 * g + 0.114 * b;
    const k = CUBE_TEMPER;
    const chan = struct {
        fn f(x: f32, target: f32, amount: f32) u32 {
            return @intFromFloat(@round(std.math.clamp(
                x * (1 - amount) + target * amount,
                0,
                255,
            )));
        }
    }.f;
    return (chan(r, grey, k) << 16) | (chan(g, grey, k) << 8) | chan(b, grey, k);
}

/// Blends two packed colours, `t` of the way from `b` to `a`.
pub fn mix(a: u32, b: u32, t: f32) u32 {
    const chan = struct {
        fn f(x: u32, y: u32, k: f32) u32 {
            const fx: f32 = @floatFromInt(x & 0xff);
            const fy: f32 = @floatFromInt(y & 0xff);
            return @intFromFloat(@round(std.math.clamp(fx * k + fy * (1 - k), 0, 255)));
        }
    }.f;
    return (chan(a >> 16, b >> 16, t) << 16) |
        (chan(a >> 8, b >> 8, t) << 8) |
        chan(a, b, t);
}

/// Top colour of the active tab's gradient: its own background lifted toward
/// the accent, so the focused tab reads at a glance without a hard outline.
pub fn tabGradientTop(t: *const Theme) u32 {
    return mix(t.ansi[4], t.tab_active_bg, if (t.kind == .dark) 0.22 else 0.12);
}

pub fn byKind(kind: Kind) *const Theme {
    return switch (kind) {
        .dark => &dark,
        .light => &light,
    };
}

pub fn toggle(kind: Kind) Kind {
    return switch (kind) {
        .dark => .light,
        .light => .dark,
    };
}

/// Resolves `ZTABB_THEME`, falling back to dark.
pub fn fromEnv() Kind {
    const raw = std.c.getenv("ZTABB_THEME") orelse return .dark;
    return parse(std.mem.span(raw)) orelse .dark;
}

pub fn parse(name: []const u8) ?Kind {
    if (std.ascii.eqlIgnoreCase(name, "light")) return .light;
    if (std.ascii.eqlIgnoreCase(name, "dark")) return .dark;
    return null;
}

/// Relative luminance per WCAG 2.1, used to check contrast in tests.
fn luminance(rgb: u32) f64 {
    const channel = struct {
        fn f(v: u32) f64 {
            const c = @as(f64, @floatFromInt(v)) / 255.0;
            return if (c <= 0.03928) c / 12.92 else std.math.pow(f64, (c + 0.055) / 1.055, 2.4);
        }
    }.f;
    const r = channel((rgb >> 16) & 0xff);
    const g = channel((rgb >> 8) & 0xff);
    const b = channel(rgb & 0xff);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

pub fn contrastRatio(a: u32, b: u32) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

test "toggle round-trips" {
    try std.testing.expectEqual(Kind.light, toggle(.dark));
    try std.testing.expectEqual(Kind.dark, toggle(.light));
    try std.testing.expectEqual(Kind.dark, toggle(toggle(.dark)));
}

test "byKind returns the matching theme" {
    try std.testing.expectEqual(Kind.dark, byKind(.dark).kind);
    try std.testing.expectEqual(Kind.light, byKind(.light).kind);
    try std.testing.expectEqualStrings("gerry light", byKind(.light).name);
    try std.testing.expectEqualStrings("gerry dark", byKind(.dark).name);
}

test "the dark ground sits above black but stays dark" {
    try std.testing.expect(luminance(dark.bg) > luminance(0x1A1A1A));
    try std.testing.expect(luminance(dark.bg) < 0.06);
}

test "mix interpolates between two colours" {
    try std.testing.expectEqual(@as(u32, 0xFF0000), mix(0xFF0000, 0x00FF00, 1.0));
    try std.testing.expectEqual(@as(u32, 0x00FF00), mix(0xFF0000, 0x00FF00, 0.0));
    try std.testing.expectEqual(@as(u32, 0x808080), mix(0xFFFFFF, 0x010101, 0.5));
    // Channels stay independent: each is the midpoint of its own pair.
    try std.testing.expectEqual(@as(u32, 0x804121), mix(0xFF8040, 0x010101, 0.5));
}

test "the active tab gradient is visible but not garish" {
    for ([_]*const Theme{ &dark, &light }) |t| {
        const top = tabGradientTop(t);
        try std.testing.expect(top != t.tab_active_bg);
        // Distinct from the inactive tabs beside it...
        try std.testing.expect(contrastRatio(top, t.tab_inactive_bg) > 1.05);
        // ...while the label stays readable across the whole sweep.
        try std.testing.expect(contrastRatio(t.tab_active_fg, top) >= 4.0);
    }
}

test "the light ground is off-white rather than pure white" {
    try std.testing.expect(light.bg != 0xFFFFFF);
    try std.testing.expect(luminance(light.bg) > 0.9);
}

test "bright ANSI colours are brighter than their normal counterparts" {
    for ([_]*const Theme{ &dark, &light }) |t| {
        for (1..7) |i| {
            const normal = luminance(t.ansi[i]);
            const bright = luminance(t.ansi[i + 8]);
            if (t.kind == .dark) {
                try std.testing.expect(bright > normal);
            } else {
                // On a light ground "bright" reads as more saturated, so only
                // require that the two are distinguishable.
                try std.testing.expect(t.ansi[i] != t.ansi[i + 8]);
            }
        }
    }
}

test "every ANSI colour is legible on its own background" {
    for ([_]*const Theme{ &dark, &light }) |t| {
        for (1..8) |i| {
            try std.testing.expect(contrastRatio(t.ansi[i], t.bg) >= 3.0);
            try std.testing.expect(contrastRatio(t.ansi[i + 8], t.bg) >= 3.0);
        }
    }
}

test "parse accepts either case and rejects junk" {
    try std.testing.expectEqual(Kind.light, parse("light").?);
    try std.testing.expectEqual(Kind.light, parse("LIGHT").?);
    try std.testing.expectEqual(Kind.dark, parse("Dark").?);
    try std.testing.expect(parse("solarized") == null);
    try std.testing.expect(parse("") == null);
}

test "both themes keep body text readable" {
    // WCAG AA for body text is 4.5:1.
    for ([_]*const Theme{ &dark, &light }) |t| {
        try std.testing.expect(contrastRatio(t.fg, t.bg) >= 4.5);
        try std.testing.expect(contrastRatio(t.tab_active_fg, t.tab_active_bg) >= 4.5);
        try std.testing.expect(contrastRatio(t.tab_inactive_fg, t.tab_inactive_bg) >= 3.0);
    }
}

test "highlight colours stand off their own background" {
    for ([_]*const Theme{ &dark, &light }) |t| {
        const colors = [_]u32{
            t.hl_command, t.hl_builtin,  t.hl_option,   t.hl_string,  t.hl_number,
            t.hl_path,    t.hl_variable, t.hl_operator, t.hl_comment,
        };
        for (colors) |c| {
            try std.testing.expect(contrastRatio(c, t.bg) >= 3.0);
        }
    }
}

test "ansi palette has no duplicate entries within a brightness band" {
    for ([_]*const Theme{ &dark, &light }) |t| {
        // Index 0/7 double as background/foreground, so compare 1..6 only.
        for (1..7) |i| {
            for (i + 1..7) |j| {
                try std.testing.expect(t.ansi[i] != t.ansi[j]);
            }
        }
    }
}

test "the selection is visible against the ground it sits on" {
    // It used to be so close to the background that a selected range was hard
    // to see at all, while still having to leave the text readable.
    for ([_]Theme{ dark, light }) |t| {
        try std.testing.expect(contrastRatio(t.selection, t.bg) >= 1.45);
        try std.testing.expect(contrastRatio(t.fg, t.selection) >= 4.5);
    }
}

test "tempering softens a colour without moving its hue" {
    // Pure cube red: still unmistakably red, just not fluorescent.
    const red = temper(0xFF0000);
    const r = (red >> 16) & 0xff;
    const g = (red >> 8) & 0xff;
    const b = red & 0xff;
    try std.testing.expect(r > g and r > b);
    try std.testing.expectEqual(g, b); // the two low channels move together
    try std.testing.expect(r < 0xFF); // ...and the high one came down
    try std.testing.expect(r > 0xA0); // ...but not into brown

    // Saturation falls: the gap between the channels narrows.
    try std.testing.expect((r - g) < 0xFF);
}

test "tempering leaves greys alone and keeps the ramp in order" {
    for ([_]u32{ 0x000000, 0x808080, 0xFFFFFF, 0x1C1C1C }) |grey| {
        try std.testing.expectEqual(grey, temper(grey));
    }
    // Each step of the cube's red ramp stays brighter than the one below it.
    const levels = [_]u32{ 0, 95, 135, 175, 215, 255 };
    var last: f64 = -1;
    for (levels) |v| {
        const l = luminance(temper(v << 16));
        try std.testing.expect(l > last);
        last = l;
    }
}

test "theme background differs between light and dark" {
    try std.testing.expect(dark.bg != light.bg);
    try std.testing.expect(luminance(light.bg) > luminance(dark.bg));
}
