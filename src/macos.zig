//! macOS window integration.
//!
//! Lets the window's content run the full height of the frame and hides the
//! system's own title text, so ztabb can set the title in its own face and
//! colours. The frame itself, its buttons and every behaviour attached to them
//! stay exactly as the platform draws them: this changes what the title bar
//! *shows*, not what it *is*.
//!
//! On any other platform every call here is a no-op and the window keeps its
//! ordinary title.

const std = @import("std");
const builtin = @import("builtin");

pub const enabled = builtin.os.tag == .macos;

const objc = struct {
    const Id = ?*anyopaque;
    const Sel = ?*anyopaque;

    extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
    extern "c" fn objc_msgSend() void;

    /// objc_msgSend has no single signature: on arm64 it must be called
    /// through a pointer typed for the exact arguments, not as a variadic.
    fn msg(comptime Fn: type) *const Fn {
        return @ptrCast(&objc_msgSend);
    }

    fn sel(comptime name: [:0]const u8) Sel {
        return sel_registerName(name.ptr);
    }
};

const CGFloat = f64;
const CGPoint = extern struct { x: CGFloat, y: CGFloat };
const CGSize = extern struct { width: CGFloat, height: CGFloat };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

/// `NSWindowStyleMaskFullSizeContentView`.
const FULL_SIZE_CONTENT_VIEW: u64 = 1 << 15;
/// `NSWindowTitleVisibilityHidden`.
const TITLE_HIDDEN: i64 = 1;

/// Turns the title bar into a transparent strip over the content.
///
/// Returns the height of that strip in window points, which is the inset the
/// caller must leave clear at the top; zero when there is nothing to do.
pub fn useTransparentTitlebar(nswindow: ?*anyopaque) f32 {
    if (!enabled) return 0;
    const window = nswindow orelse return 0;

    const setBool = objc.msg(fn (objc.Id, objc.Sel, bool) callconv(.c) void);
    const setI64 = objc.msg(fn (objc.Id, objc.Sel, i64) callconv(.c) void);
    const setU64 = objc.msg(fn (objc.Id, objc.Sel, u64) callconv(.c) void);
    const getU64 = objc.msg(fn (objc.Id, objc.Sel) callconv(.c) u64);

    // Let the content view run behind the title bar, then take the title text
    // away and make the bar itself transparent. The buttons are untouched.
    const mask = getU64(window, objc.sel("styleMask"));
    setU64(window, objc.sel("setStyleMask:"), mask | FULL_SIZE_CONTENT_VIEW);
    setBool(window, objc.sel("setTitlebarAppearsTransparent:"), true);
    setI64(window, objc.sel("setTitleVisibility:"), TITLE_HIDDEN);

    return titlebarHeight(window);
}

/// The height of the title bar in window points: the part of the frame the
/// content now runs behind, and which the buttons sit in.
fn titlebarHeight(window: objc.Id) f32 {
    const getRect = objc.msg(fn (objc.Id, objc.Sel) callconv(.c) CGRect);
    const frame = getRect(window, objc.sel("frame"));
    const content = getRect(window, objc.sel("contentLayoutRect"));
    const height = frame.size.height - content.size.height;
    // A sane fallback if the window is mid-transition and reports nothing
    // useful: 28pt is the standard bar.
    if (height <= 0 or height > 200) return 28;
    return @floatCast(height);
}

/// Where the window's own buttons end, in points, so a title drawn in the bar
/// starts clear of them.
pub fn trafficLightsWidth() f32 {
    if (!enabled) return 0;
    // Three buttons on a 20pt pitch from a 20pt inset.
    return 78;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test "every call is inert off macOS" {
    if (enabled) return;
    try testing.expectEqual(@as(f32, 0), useTransparentTitlebar(null));
    try testing.expectEqual(@as(f32, 0), trafficLightsWidth());
}

test "a null window is handled rather than dereferenced" {
    // SDL hands back null when the platform has no Cocoa window to give.
    try testing.expectEqual(@as(f32, 0), useTransparentTitlebar(null));
}

test "the buttons leave room for a title beside them" {
    if (!enabled) return;
    try testing.expect(trafficLightsWidth() > 60);
    try testing.expect(trafficLightsWidth() < 140);
}
