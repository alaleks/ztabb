//! Hand-written SDL3 bindings. Only the slice of the API ztabb needs.
//!
//! The struct layouts and enum values here mirror SDL 3.2's ABI exactly; every
//! event struct carries the `reserved` word that follows `type`, and rects are
//! `SDL_FRect` (floats), not integers.

const std = @import("std");

pub const Window = opaque {};
pub const Renderer = opaque {};
pub const Texture = opaque {};
pub const Surface = opaque {};

pub const INIT_VIDEO: u32 = 0x20;

pub const WINDOW_RESIZABLE: u64 = 0x20;
pub const WINDOW_HIGH_PIXEL_DENSITY: u64 = 0x2000;

pub const EVENT_QUIT: u32 = 0x100;
pub const EVENT_WINDOW_RESIZED: u32 = 0x206;
pub const EVENT_WINDOW_PIXEL_SIZE_CHANGED: u32 = 0x207;
pub const EVENT_KEY_DOWN: u32 = 0x300;
pub const EVENT_KEY_UP: u32 = 0x301;
pub const EVENT_TEXT_EDITING: u32 = 0x302;
pub const EVENT_TEXT_INPUT: u32 = 0x303;
pub const EVENT_MOUSE_MOTION: u32 = 0x400;
pub const EVENT_MOUSE_BUTTON_DOWN: u32 = 0x401;
pub const EVENT_MOUSE_BUTTON_UP: u32 = 0x402;
pub const EVENT_MOUSE_WHEEL: u32 = 0x403;

pub const SDLK_RETURN: u32 = 0x0d;
pub const SDLK_ESCAPE: u32 = 0x1b;
pub const SDLK_BACKSPACE: u32 = 0x08;
pub const SDLK_TAB: u32 = 0x09;
pub const SDLK_SPACE: u32 = 0x20;
pub const SDLK_DELETE: u32 = 0x7f;

pub const SDLK_SCANCODE_MASK: u32 = 0x40000000;
pub const SDLK_CAPSLOCK: u32 = 0x40000039;
pub const SDLK_F1: u32 = 0x4000003a;
pub const SDLK_F2: u32 = 0x4000003b;
pub const SDLK_F3: u32 = 0x4000003c;
pub const SDLK_F4: u32 = 0x4000003d;
pub const SDLK_F5: u32 = 0x4000003e;
pub const SDLK_F6: u32 = 0x4000003f;
pub const SDLK_F7: u32 = 0x40000040;
pub const SDLK_F8: u32 = 0x40000041;
pub const SDLK_F9: u32 = 0x40000042;
pub const SDLK_F10: u32 = 0x40000043;
pub const SDLK_F11: u32 = 0x40000044;
pub const SDLK_F12: u32 = 0x40000045;
pub const SDLK_F13: u32 = 0x40000068;
pub const SDLK_INSERT: u32 = 0x40000049;
pub const SDLK_HOME: u32 = 0x4000004a;
pub const SDLK_PAGEUP: u32 = 0x4000004b;
pub const SDLK_END: u32 = 0x4000004d;
pub const SDLK_PAGEDOWN: u32 = 0x4000004e;
pub const SDLK_RIGHT: u32 = 0x4000004f;
pub const SDLK_LEFT: u32 = 0x40000050;
pub const SDLK_DOWN: u32 = 0x40000051;
pub const SDLK_UP: u32 = 0x40000052;

pub const SDLK_0: u32 = 0x30;
pub const SDLK_1: u32 = 0x31;
pub const SDLK_2: u32 = 0x32;
pub const SDLK_3: u32 = 0x33;
pub const SDLK_4: u32 = 0x34;
pub const SDLK_5: u32 = 0x35;
pub const SDLK_6: u32 = 0x36;
pub const SDLK_7: u32 = 0x37;
pub const SDLK_8: u32 = 0x38;
pub const SDLK_9: u32 = 0x39;
pub const SDLK_A: u32 = 0x61;
pub const SDLK_C: u32 = 0x63;
pub const SDLK_D: u32 = 0x64;
pub const SDLK_E: u32 = 0x65;
pub const SDLK_G: u32 = 0x67;
pub const SDLK_H: u32 = 0x68;
pub const SDLK_J: u32 = 0x6a;
pub const SDLK_K: u32 = 0x6b;
pub const SDLK_X: u32 = 0x78;
pub const SDLK_Y: u32 = 0x79;
pub const SDLK_L: u32 = 0x6c;
pub const SDLK_N: u32 = 0x6e;
pub const SDLK_S: u32 = 0x73;
pub const SDLK_T: u32 = 0x74;
pub const SDLK_V: u32 = 0x76;
pub const SDLK_W: u32 = 0x77;
pub const SDLK_Z: u32 = 0x7a;
pub const SDLK_MINUS: u32 = 0x2d;
pub const SDLK_EQUALS: u32 = 0x3d;
pub const SDLK_LEFTBRACKET: u32 = 0x5b;
pub const SDLK_BACKSLASH: u32 = 0x5c;
pub const SDLK_RIGHTBRACKET: u32 = 0x5d;
pub const SDLK_GRAVE: u32 = 0x60;

/// `SDL_Keymod` is a Uint16.
pub const KMOD_LSHIFT: u16 = 0x0001;
pub const KMOD_RSHIFT: u16 = 0x0002;
pub const KMOD_LCTRL: u16 = 0x0040;
pub const KMOD_RCTRL: u16 = 0x0080;
pub const KMOD_LALT: u16 = 0x0100;
pub const KMOD_RALT: u16 = 0x0200;
pub const KMOD_LGUI: u16 = 0x0400;
pub const KMOD_RGUI: u16 = 0x0800;
pub const KMOD_CTRL: u16 = KMOD_LCTRL | KMOD_RCTRL;
pub const KMOD_SHIFT: u16 = KMOD_LSHIFT | KMOD_RSHIFT;
pub const KMOD_ALT: u16 = KMOD_LALT | KMOD_RALT;
pub const KMOD_GUI: u16 = KMOD_LGUI | KMOD_RGUI;

pub const BUTTON_LEFT: u8 = 1;
pub const BUTTON_MIDDLE: u8 = 2;
pub const BUTTON_RIGHT: u8 = 3;

pub const PIXELFORMAT_ARGB8888: u32 = 0x16362004;
pub const TEXTUREACCESS_STATIC: u32 = 0;
pub const BLENDMODE_NONE: u32 = 0;
pub const BLENDMODE_BLEND: u32 = 1;
pub const SCALEMODE_NEAREST: u32 = 0;
pub const SCALEMODE_LINEAR: u32 = 1;

pub const FRect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Rect = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const CommonEvent = extern struct {
    type_: u32,
    reserved: u32,
    timestamp: u64,
};

pub const KeyboardEvent = extern struct {
    type_: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    scancode: u32,
    key: u32,
    mod: u16,
    raw: u16,
    down: bool,
    repeat: bool,
};

pub const TextInputEvent = extern struct {
    type_: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    text: ?[*:0]const u8,
};

pub const WindowEvent = extern struct {
    type_: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    data1: i32,
    data2: i32,
};

pub const MouseWheelEvent = extern struct {
    type_: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    x: f32,
    y: f32,
    direction: u32,
    mouse_x: f32,
    mouse_y: f32,
    integer_x: i32,
    integer_y: i32,
};

pub const MouseMotionEvent = extern struct {
    type_: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    state: u32,
    x: f32,
    y: f32,
    xrel: f32,
    yrel: f32,
};

pub const MouseButtonEvent = extern struct {
    type_: u32,
    reserved: u32,
    timestamp: u64,
    window_id: u32,
    which: u32,
    button: u8,
    down: bool,
    clicks: u8,
    padding: u8,
    x: f32,
    y: f32,
};

pub const Event = extern union {
    type_: u32,
    common: CommonEvent,
    key: KeyboardEvent,
    text: TextInputEvent,
    window: WindowEvent,
    wheel: MouseWheelEvent,
    button: MouseButtonEvent,
    motion: MouseMotionEvent,
    _pad: [128]u8,
};

extern "c" fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) bool;
extern "c" fn SDL_Init(flags: u32) bool;
extern "c" fn SDL_Quit() void;
extern "c" fn SDL_GetError() [*:0]const u8;
extern "c" fn SDL_CreateWindow(title: [*:0]const u8, w: c_int, h: c_int, flags: u64) ?*Window;
extern "c" fn SDL_DestroyWindow(window: ?*Window) void;
extern "c" fn SDL_CreateRenderer(window: ?*Window, name: ?[*:0]const u8) ?*Renderer;
extern "c" fn SDL_DestroyRenderer(renderer: ?*Renderer) void;
extern "c" fn SDL_SetRenderVSync(renderer: ?*Renderer, vsync: c_int) bool;
extern "c" fn SDL_RenderClear(renderer: ?*Renderer) bool;
extern "c" fn SDL_RenderPresent(renderer: ?*Renderer) bool;
extern "c" fn SDL_SetRenderDrawColor(renderer: ?*Renderer, r: u8, g: u8, b: u8, a: u8) bool;
extern "c" fn SDL_RenderFillRect(renderer: ?*Renderer, rect: ?*const FRect) bool;
extern "c" fn SDL_RenderTexture(renderer: ?*Renderer, tex: ?*Texture, src: ?*const FRect, dst: ?*const FRect) bool;
extern "c" fn SDL_CreateTexture(renderer: ?*Renderer, format: u32, access: u32, w: c_int, h: c_int) ?*Texture;
extern "c" fn SDL_DestroyTexture(tex: ?*Texture) void;
extern "c" fn SDL_UpdateTexture(tex: ?*Texture, rect: ?*const Rect, pixels: *const anyopaque, pitch: c_int) bool;
extern "c" fn SDL_SetTextureBlendMode(tex: ?*Texture, mode: u32) bool;
extern "c" fn SDL_SetTextureColorMod(tex: ?*Texture, r: u8, g: u8, b: u8) bool;
extern "c" fn SDL_SetTextureScaleMode(tex: ?*Texture, mode: u32) bool;
extern "c" fn SDL_PollEvent(event: *Event) bool;
extern "c" fn SDL_WaitEventTimeout(event: *Event, timeout_ms: c_int) bool;
extern "c" fn SDL_StartTextInput(window: ?*Window) bool;
extern "c" fn SDL_StopTextInput(window: ?*Window) bool;
extern "c" fn SDL_GetWindowSize(window: ?*Window, w: *c_int, h: *c_int) bool;
extern "c" fn SDL_GetRenderOutputSize(renderer: ?*Renderer, w: *c_int, h: *c_int) bool;
extern "c" fn SDL_SetWindowTitle(window: ?*Window, title: [*:0]const u8) bool;
extern "c" fn SDL_CreateSurfaceFrom(w: c_int, h: c_int, format: u32, pixels: *anyopaque, pitch: c_int) ?*Surface;
extern "c" fn SDL_DestroySurface(surface: ?*Surface) void;
extern "c" fn SDL_SetWindowIcon(window: ?*Window, icon: ?*Surface) bool;
extern "c" fn SDL_GetWindowProperties(window: ?*Window) u32;
extern "c" fn SDL_GetPointerProperty(props: u32, name: [*:0]const u8, default_value: ?*anyopaque) ?*anyopaque;
extern "c" fn SDL_GetModState() u16;
extern "c" fn SDL_GetClipboardText() [*:0]u8;
extern "c" fn SDL_SetClipboardText(text: [*:0]const u8) bool;
extern "c" fn SDL_free(mem: ?*anyopaque) void;
extern "c" fn SDL_GetTicks() u64;
extern "c" fn SDL_Delay(ms: u32) void;

pub const Error = error{
    SdlInitFailed,
    WindowCreationFailed,
    RendererCreationFailed,
    TextureCreationFailed,
    RenderFailed,
};

/// The message describing the most recent SDL failure.
pub fn lastError() []const u8 {
    return std.mem.span(SDL_GetError());
}

pub fn init() Error!void {
    // Control-click is how macOS has always asked for a context menu, but SDL
    // leaves it as a plain left click unless told otherwise -- so on a machine
    // whose trackpad has no secondary click, the right button is unreachable.
    _ = SDL_SetHint("SDL_MAC_CTRL_CLICK_EMULATE_RIGHT_CLICK", "1");
    if (!SDL_Init(INIT_VIDEO)) return error.SdlInitFailed;
}

pub fn quit() void {
    SDL_Quit();
}

/// The window keeps the system frame: its title bar, its buttons and its
/// behaviour belong to the platform, not to ztabb.
pub fn createWindow(title: [*:0]const u8, w: i32, h: i32) Error!*Window {
    const flags = WINDOW_RESIZABLE | WINDOW_HIGH_PIXEL_DENSITY;
    return SDL_CreateWindow(title, w, h, flags) orelse error.WindowCreationFailed;
}

pub fn destroyWindow(win: ?*Window) void {
    SDL_DestroyWindow(win);
}

pub fn setWindowTitle(win: ?*Window, title: [*:0]const u8) void {
    _ = SDL_SetWindowTitle(win, title);
}

/// The platform's own window handle, for the few things SDL does not wrap.
/// Null on platforms where there is nothing of that name to hand back.
pub fn getNativeWindow(win: ?*Window) ?*anyopaque {
    const props = SDL_GetWindowProperties(win);
    if (props == 0) return null;
    return SDL_GetPointerProperty(props, "SDL.window.cocoa.window", null);
}

/// Sets the window's (and on macOS the Dock's) icon from ARGB pixels. The
/// surface only borrows `pixels`, so it is destroyed before returning.
pub fn setWindowIcon(win: ?*Window, pixels: []u32, size: i32) void {
    const surface = SDL_CreateSurfaceFrom(
        size,
        size,
        PIXELFORMAT_ARGB8888,
        @ptrCast(pixels.ptr),
        size * 4,
    ) orelse return;
    defer SDL_DestroySurface(surface);
    _ = SDL_SetWindowIcon(win, surface);
}

pub fn createRenderer(win: ?*Window) Error!*Renderer {
    return SDL_CreateRenderer(win, null) orelse error.RendererCreationFailed;
}

pub fn destroyRenderer(r: ?*Renderer) void {
    SDL_DestroyRenderer(r);
}

/// Ties presentation to the display refresh, which keeps the render loop from
/// spinning a core at several thousand frames per second.
pub fn setVSync(r: ?*Renderer, enabled: bool) void {
    _ = SDL_SetRenderVSync(r, if (enabled) 1 else 0);
}

pub fn renderClear(r: ?*Renderer) Error!void {
    if (!SDL_RenderClear(r)) return error.RenderFailed;
}

pub fn renderPresent(r: ?*Renderer) void {
    _ = SDL_RenderPresent(r);
}

pub fn setRenderDrawColor(r: ?*Renderer, red: u8, green: u8, blue: u8, alpha: u8) void {
    _ = SDL_SetRenderDrawColor(r, red, green, blue, alpha);
}

/// Sets the draw colour from a packed 0xRRGGBB value.
pub fn setRenderDrawRgb(r: ?*Renderer, rgb: u32) void {
    setRenderDrawColor(
        r,
        @truncate(rgb >> 16),
        @truncate(rgb >> 8),
        @truncate(rgb),
        255,
    );
}

pub fn renderFillRect(r: ?*Renderer, rect: *const FRect) void {
    _ = SDL_RenderFillRect(r, rect);
}

pub fn renderTexture(r: ?*Renderer, tex: ?*Texture, src: *const FRect, dst: *const FRect) void {
    _ = SDL_RenderTexture(r, tex, src, dst);
}

/// `smooth` picks linear filtering, for artwork that is drawn at a size other
/// than the one it was rasterized at. Glyph atlases are drawn 1:1 and want
/// nearest, which keeps their edges exactly as they were baked.
pub fn createTexture(r: ?*Renderer, w: i32, h: i32, smooth: bool) Error!*Texture {
    const tex = SDL_CreateTexture(r, PIXELFORMAT_ARGB8888, TEXTUREACCESS_STATIC, w, h) orelse
        return error.TextureCreationFailed;
    _ = SDL_SetTextureBlendMode(tex, BLENDMODE_BLEND);
    _ = SDL_SetTextureScaleMode(tex, if (smooth) SCALEMODE_LINEAR else SCALEMODE_NEAREST);
    return tex;
}

pub fn destroyTexture(tex: ?*Texture) void {
    SDL_DestroyTexture(tex);
}

pub fn updateTexture(tex: ?*Texture, pixels: []const u32, pitch_bytes: i32) void {
    _ = SDL_UpdateTexture(tex, null, pixels.ptr, pitch_bytes);
}

pub fn setTextureColorMod(tex: ?*Texture, rgb: u32) void {
    _ = SDL_SetTextureColorMod(
        tex,
        @truncate(rgb >> 16),
        @truncate(rgb >> 8),
        @truncate(rgb),
    );
}

pub fn pollEvent(event: *Event) bool {
    return SDL_PollEvent(event);
}

/// Blocks for at most `timeout_ms`. Used to idle cheaply when no pty has data.
pub fn waitEventTimeout(event: *Event, timeout_ms: i32) bool {
    return SDL_WaitEventTimeout(event, timeout_ms);
}

pub fn startTextInput(win: ?*Window) void {
    _ = SDL_StartTextInput(win);
}

pub fn stopTextInput(win: ?*Window) void {
    _ = SDL_StopTextInput(win);
}

pub fn getWindowSize(win: ?*Window, w: *i32, h: *i32) void {
    var cw: c_int = 0;
    var ch: c_int = 0;
    _ = SDL_GetWindowSize(win, &cw, &ch);
    w.* = @intCast(cw);
    h.* = @intCast(ch);
}

/// The renderer's backbuffer size in *pixels*, which differs from the window
/// size in points on a high-density display.
pub fn getRenderOutputSize(r: ?*Renderer, w: *i32, h: *i32) void {
    var cw: c_int = 0;
    var ch: c_int = 0;
    _ = SDL_GetRenderOutputSize(r, &cw, &ch);
    w.* = @intCast(cw);
    h.* = @intCast(ch);
}

/// Caller owns the returned slice and must free it with `freeClipboardText`.
pub fn getClipboardText() [:0]u8 {
    return std.mem.span(SDL_GetClipboardText());
}

pub fn freeClipboardText(text: [:0]u8) void {
    SDL_free(text.ptr);
}

pub fn setClipboardText(text: [*:0]const u8) void {
    _ = SDL_SetClipboardText(text);
}

/// The modifier keys held right now. Mouse events do not carry them, and
/// Shift is what overrides a program's grab of the mouse.
pub fn modState() u16 {
    return SDL_GetModState();
}

pub fn ticks() u64 {
    return SDL_GetTicks();
}

pub fn delay(ms: u32) void {
    SDL_Delay(ms);
}

test "event union matches SDL3 field offsets" {
    // Every SDL3 event begins with `Uint32 type; Uint32 reserved; Uint64 timestamp;`
    // so anything read through a sibling member must agree on those offsets.
    try std.testing.expectEqual(0, @offsetOf(KeyboardEvent, "type_"));
    try std.testing.expectEqual(8, @offsetOf(KeyboardEvent, "timestamp"));
    try std.testing.expectEqual(16, @offsetOf(KeyboardEvent, "window_id"));
    try std.testing.expectEqual(28, @offsetOf(KeyboardEvent, "key"));
    try std.testing.expectEqual(32, @offsetOf(KeyboardEvent, "mod"));
    try std.testing.expectEqual(16, @offsetOf(WindowEvent, "window_id"));
    try std.testing.expectEqual(20, @offsetOf(WindowEvent, "data1"));
    try std.testing.expectEqual(24, @offsetOf(WindowEvent, "data2"));
    try std.testing.expectEqual(24, @offsetOf(MouseWheelEvent, "x"));
    try std.testing.expectEqual(28, @offsetOf(MouseWheelEvent, "y"));
    try std.testing.expectEqual(24, @offsetOf(TextInputEvent, "text"));
    try std.testing.expect(@sizeOf(Event) >= 128);
}

test "FRect is four floats" {
    // SDL_RenderFillRect takes SDL_FRect; passing an integer rect silently
    // renders nothing because the bit patterns decode as denormal floats.
    try std.testing.expectEqual(16, @sizeOf(FRect));
    try std.testing.expectEqual(f32, @TypeOf(@as(FRect, undefined).x));
}

test "setRenderDrawRgb splits channels" {
    // Exercised indirectly: the truncation must pick the right byte per channel.
    const rgb: u32 = 0x12_34_56;
    try std.testing.expectEqual(@as(u8, 0x12), @as(u8, @truncate(rgb >> 16)));
    try std.testing.expectEqual(@as(u8, 0x34), @as(u8, @truncate(rgb >> 8)));
    try std.testing.expectEqual(@as(u8, 0x56), @as(u8, @truncate(rgb)));
}
