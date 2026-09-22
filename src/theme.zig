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

pub const dark = Theme{
    .kind = .dark,
    .name = "dark",

    .bg = 0x1E1E1E,
    .fg = 0xD4D4D4,
    .cursor = 0xD4D4D4,
    .cursor_text = 0x1E1E1E,
    .selection = 0x264F78,

    .tab_bar_bg = 0x181818,
    .tab_active_bg = 0x2D2D2D,
    .tab_inactive_bg = 0x202020,
    .tab_active_fg = 0xE8E8E8,
    .tab_inactive_fg = 0x8A8A8A,
    .tab_border = 0x0E0E0E,

    .ansi = .{
        0x1E1E1E, 0xCD3131, 0x0DBC79, 0xE5E510,
        0x2472C8, 0xBC3FBC, 0x11A8CD, 0xD4D4D4,
        0x666666, 0xF14C4C, 0x23D18B, 0xF5F543,
        0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
    },

    .hl_command = 0x4EC9B0,
    .hl_builtin = 0x569CD6,
    .hl_option = 0xDCDCAA,
    .hl_string = 0xCE9178,
    .hl_number = 0xB5CEA8,
    .hl_operator = 0xD670D6,
    .hl_path = 0x9CDCFE,
    .hl_variable = 0xC586C0,
    .hl_comment = 0x6A9955,
    .hl_unknown = 0xD4D4D4,
};

pub const light = Theme{
    .kind = .light,
    .name = "light",

    .bg = 0xFFFFFF,
    .fg = 0x24292F,
    .cursor = 0x24292F,
    .cursor_text = 0xFFFFFF,
    .selection = 0xADD6FF,

    .tab_bar_bg = 0xE8E8E8,
    .tab_active_bg = 0xFFFFFF,
    .tab_inactive_bg = 0xDCDCDC,
    .tab_active_fg = 0x1F1F1F,
    .tab_inactive_fg = 0x6E6E6E,
    .tab_border = 0xC6C6C6,

    .ansi = .{
        0xFFFFFF, 0xCD3131, 0x00BC00, 0x949800,
        0x0451A5, 0xBC05BC, 0x0598BC, 0x24292F,
        0xABABAB, 0xCD3131, 0x14CE14, 0xB5BA00,
        0x0451A5, 0xBC05BC, 0x0598BC, 0x1F1F1F,
    },

    .hl_command = 0x0F7A6E,
    .hl_builtin = 0x0451A5,
    .hl_option = 0x8A6D00,
    .hl_string = 0xA31515,
    .hl_number = 0x116329,
    .hl_operator = 0xAF00DB,
    .hl_path = 0x0550AE,
    .hl_variable = 0x953800,
    .hl_comment = 0x6A737D,
    .hl_unknown = 0x24292F,
};

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
    try std.testing.expectEqualStrings("light", byKind(.light).name);
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

test "theme background differs between light and dark" {
    try std.testing.expect(dark.bg != light.bg);
    try std.testing.expect(luminance(light.bg) > luminance(dark.bg));
}
