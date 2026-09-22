const std = @import("std");

pub const SDL_INIT_VIDEO: u32 = 0x20;

pub const SDL_WINDOW_RESIZABLE: u32 = 0x20;
pub const SDL_WINDOW_HIDDEN: u32 = 0x8;

pub const SDL_EVENT_QUIT: u32 = 0x100;
pub const SDL_EVENT_WINDOW_RESIZED: u32 = 0x106;
pub const SDL_EVENT_KEY_DOWN: u32 = 0x300;
pub const SDL_EVENT_KEY_UP: u32 = 0x301;
pub const SDL_EVENT_TEXT_INPUT: u32 = 0x302;
pub const SDL_EVENT_MOUSE_BUTTON_DOWN: u32 = 0x305;
pub const SDL_EVENT_MOUSE_BUTTON_UP: u32 = 0x306;
pub const SDL_EVENT_MOUSE_MOTION: u32 = 0x304;
pub const SDL_EVENT_MOUSE_WHEEL: u32 = 0x307;

pub const SDLK_RETURN: u32 = 0x0d;
pub const SDLK_ESCAPE: u32 = 0x1b;
pub const SDLK_BACKSPACE: u32 = 0x08;
pub const SDLK_TAB: u32 = 0x09;
pub const SDLK_DELETE: u32 = 0x7f;
pub const SDLK_UP: u32 = 0x40000052;
pub const SDLK_DOWN: u32 = 0x40000051;
pub const SDLK_LEFT: u32 = 0x40000050;
pub const SDLK_RIGHT: u32 = 0x4000004f;
pub const SDLK_HOME: u32 = 0x4000004a;
pub const SDLK_END: u32 = 0x4000004d;
pub const SDLK_PAGEUP: u32 = 0x4000004b;
pub const SDLK_PAGEDOWN: u32 = 0x4000004e;
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
pub const SDLK_INSERT: u32 = 0x40000049;
pub const SDLK_KP_0: u32 = 0x40000062;
pub const SDLK_KP_1: u32 = 0x40000059;
pub const SDLK_KP_2: u32 = 0x4000005a;
pub const SDLK_KP_3: u32 = 0x4000005b;
pub const SDLK_KP_4: u32 = 0x4000005c;
pub const SDLK_KP_5: u32 = 0x4000005d;
pub const SDLK_KP_6: u32 = 0x4000005e;
pub const SDLK_KP_7: u32 = 0x4000005f;
pub const SDLK_KP_8: u32 = 0x40000060;
pub const SDLK_KP_9: u32 = 0x40000061;
pub const SDLK_KP_ENTER: u32 = 0x40000058;
pub const SDLK_KP_SPACE: u32 = 0x400000cd;
pub const SDLK_KP_TAB: u32 = 0x400000ba;
pub const SDLK_KP_BACKSPACE: u32 = 0x400000bb;
pub const SDLK_KP_MINUS: u32 = 0x40000056;
pub const SDLK_KP_PLUS: u32 = 0x40000057;
pub const SDLK_KP_MULTIPLY: u32 = 0x40000055;
pub const SDLK_KP_DIVIDE: u32 = 0x40000054;
pub const SDLK_KP_PERIOD: u32 = 0x40000063;
pub const SDLK_KP_COMMA: u32 = 0x40000085;
pub const SDLK_KP_EQUALS: u32 = 0x40000067;
pub const SDLK_KP_LEFTPAREN: u32 = 0x400000b6;
pub const SDLK_KP_RIGHTPAREN: u32 = 0x400000b7;
pub const SDLK_KP_LEFTBRACE: u32 = 0x400000b8;
pub const SDLK_KP_RIGHTBRACE: u32 = 0x400000b9;
pub const SDLK_KP_A: u32 = 0x400000bc;
pub const SDLK_KP_B: u32 = 0x400000bd;
pub const SDLK_KP_C: u32 = 0x400000be;
pub const SDLK_KP_D: u32 = 0x400000bf;
pub const SDLK_KP_E: u32 = 0x400000c0;
pub const SDLK_KP_F: u32 = 0x400000c1;
pub const SDLK_KP_XOR: u32 = 0x400000c2;
pub const SDLK_KP_POWER: u32 = 0x400000c3;
pub const SDLK_KP_PERCENT: u32 = 0x400000c4;
pub const SDLK_KP_LESS: u32 = 0x400000c5;
pub const SDLK_KP_GREATER: u32 = 0x400000c6;
pub const SDLK_KP_AMPERSAND: u32 = 0x400000c7;
pub const SDLK_KP_DBLAMPERSAND: u32 = 0x400000c8;
pub const SDLK_KP_00: u32 = 0x400000b0;
pub const SDLK_KP_000: u32 = 0x400000b1;
pub const SDLK_KP_EQUALSAS400: u32 = 0x40000086;
pub const SDLK_BRACKETLEFT: u32 = 0x5b;
pub const SDLK_BRACKETRIGHT: u32 = 0x5d;
pub const SDLK_F13: u32 = 0x40000068;
pub const SDLK_F14: u32 = 0x40000069;
pub const SDLK_F15: u32 = 0x4000006a;
pub const SDLK_F16: u32 = 0x4000006b;
pub const SDLK_F17: u32 = 0x4000006c;
pub const SDLK_F18: u32 = 0x4000006d;
pub const SDLK_F19: u32 = 0x4000006e;
pub const SDLK_F20: u32 = 0x4000006f;
pub const SDLK_F21: u32 = 0x40000070;
pub const SDLK_F22: u32 = 0x40000071;
pub const SDLK_F23: u32 = 0x40000072;
pub const SDLK_F24: u32 = 0x40000073;
pub const SDLK_EXECUTE: u32 = 0x40000074;
pub const SDLK_HELP: u32 = 0x40000075;
pub const SDLK_MENU: u32 = 0x40000076;
pub const SDLK_MUTE: u32 = 0x4000007f;
pub const SDLK_VOLUMEUP: u32 = 0x40000080;
pub const SDLK_VOLUMEDOWN: u32 = 0x40000081;
pub const SDLK_SYSREQ: u32 = 0x4000009a;
pub const SDLK_PRINTSCREEN: u32 = 0x40000046;
pub const SDLK_SCROLLLOCK: u32 = 0x40000047;
pub const SDLK_PAUSE: u32 = 0x40000048;
pub const SDLK_CAPSLOCK: u32 = 0x40000039;
pub const SDLK_NUMLOCKCLEAR: u32 = 0x40000053;
pub const SDLK_CRSEL: u32 = 0x400000a3;
pub const SDLK_EXSEL: u32 = 0x400000a4;
pub const SDLK_SPACE: u32 = 0x20;
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
pub const SDLK_B: u32 = 0x62;
pub const SDLK_C: u32 = 0x63;
pub const SDLK_D: u32 = 0x64;
pub const SDLK_E: u32 = 0x65;
pub const SDLK_F: u32 = 0x66;
pub const SDLK_G: u32 = 0x67;
pub const SDLK_H: u32 = 0x68;
pub const SDLK_I: u32 = 0x69;
pub const SDLK_J: u32 = 0x6a;
pub const SDLK_K: u32 = 0x6b;
pub const SDLK_L: u32 = 0x6c;
pub const SDLK_M: u32 = 0x6d;
pub const SDLK_N: u32 = 0x6e;
pub const SDLK_O: u32 = 0x6f;
pub const SDLK_P: u32 = 0x70;
pub const SDLK_Q: u32 = 0x71;
pub const SDLK_R: u32 = 0x72;
pub const SDLK_S: u32 = 0x73;
pub const SDLK_T: u32 = 0x74;
pub const SDLK_U: u32 = 0x75;
pub const SDLK_V: u32 = 0x76;
pub const SDLK_W: u32 = 0x77;
pub const SDLK_X: u32 = 0x78;
pub const SDLK_Y: u32 = 0x79;
pub const SDLK_Z: u32 = 0x7a;
pub const SDLK_EXCLAIM: u32 = 0x21;
pub const SDLK_DBLAPOSTROPHE: u32 = 0x22;
pub const SDLK_DOLLAR: u32 = 0x24;
pub const SDLK_AMPERSAND: u32 = 0x26;
pub const SDLK_APOSTROPHE: u32 = 0x27;
pub const SDLK_LEFTPAREN: u32 = 0x28;
pub const SDLK_RIGHTPAREN: u32 = 0x29;
pub const SDLK_ASTERISK: u32 = 0x2a;
pub const SDLK_PLUS: u32 = 0x2b;
pub const SDLK_COMMA: u32 = 0x2c;
pub const SDLK_MINUS: u32 = 0x2d;
pub const SDLK_EQUALS: u32 = 0x3d;
pub const SDLK_PERIOD: u32 = 0x2e;
pub const SDLK_SLASH: u32 = 0x2f;
pub const SDLK_COLON: u32 = 0x3a;
pub const SDLK_SEMICOLON: u32 = 0x3b;
pub const SDLK_LESS: u32 = 0x3c;
pub const SDLK_GREATER: u32 = 0x3e;
pub const SDLK_QUESTION: u32 = 0x3f;
pub const SDLK_AT: u32 = 0x40;
pub const SDLK_LEFTBRACKET: u32 = 0x5b;
pub const SDLK_BACKSLASH: u32 = 0x5c;
pub const SDLK_RIGHTBRACKET: u32 = 0x5d;
pub const SDLK_CARET: u32 = 0x5e;
pub const SDLK_UNDERSCORE: u32 = 0x5f;
pub const SDLK_GRAVE: u32 = 0x60;
pub const SDLK_LEFTBRACE: u32 = 0x7b;
pub const SDLK_BAR: u32 = 0x7c;
pub const SDLK_RIGHTBRACE: u32 = 0x7d;
pub const SDLK_TILDE: u32 = 0x7e;

pub const SDL_KMOD_LSHIFT: u32 = 0x01;
pub const SDL_KMOD_RSHIFT: u32 = 0x02;
pub const SDL_KMOD_LCTRL: u32 = 0x40;
pub const SDL_KMOD_RCTRL: u32 = 0x80;
pub const SDL_KMOD_LALT: u32 = 0x100;
pub const SDL_KMOD_RALT: u32 = 0x200;
pub const SDL_KMOD_LGUI: u32 = 0x400;
pub const SDL_KMOD_RGUI: u32 = 0x800;
pub const SDL_KMOD_CAPS: u32 = 0x10000;
pub const SDL_KMOD_NUM: u32 = 0x20000;

pub const SDL_BUTTON_LEFT: u32 = 1;
pub const SDL_BUTTON_MIDDLE: u32 = 2;
pub const SDL_BUTTON_RIGHT: u32 = 3;

pub extern "c" fn SDL_Init(flags: u32) bool;
pub extern "c" fn SDL_Quit() void;
pub extern "c" fn SDL_GetError() [*:0]const u8;
pub extern "c" fn SDL_CreateWindow(title: [*]const u8, width: i32, height: i32, flags: u32) ?*void;
pub extern "c" fn SDL_DestroyWindow(window: ?*void) void;
pub extern "c" fn SDL_CreateRenderer(window: ?*void, name: ?[*]const u8) ?*void;
pub extern "c" fn SDL_DestroyRenderer(renderer: ?*void) void;
pub extern "c" fn SDL_RenderClear(renderer: ?*void) bool;
pub extern "c" fn SDL_RenderPresent(renderer: ?*void) bool;
pub extern "c" fn SDL_SetRenderDrawColor(renderer: ?*void, r: u8, g: u8, b: u8, a: u8) bool;
pub extern "c" fn SDL_RenderFillRect(renderer: ?*void, rect: ?*const Rect) bool;
pub extern "c" fn SDL_PollEvent(event: *Event) bool;
pub extern "c" fn SDL_WaitEvent(event: *Event) bool;
pub extern "c" fn SDL_StartTextInput(window: ?*void) void;
pub extern "c" fn SDL_StopTextInput(window: ?*void) void;
pub extern "c" fn SDL_GetWindowSize(window: ?*void, w: *i32, h: *i32) bool;

pub const Rect = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const KeyboardEvent = extern struct {
    type_: u32,
    timestamp: u64,
    windowID: u32,
    which: u32,
    scancode: u32,
    key: u32,
    modifiers: u32,
    repeat: bool,
};

pub const TextInputEvent = extern struct {
    type_: u32,
    timestamp: u64,
    windowID: u32,
    text: [*]u8,
};

pub const WindowEvent = extern struct {
    type_: u32,
    timestamp: u64,
    windowID: u32,
    data1: i32,
    data2: i32,
};

pub const MouseButtonEvent = extern struct {
    type_: u32,
    timestamp: u64,
    windowID: u32,
    which: u32,
    button: u32,
    clicks: u32,
    grid_x: i32,
    grid_y: i32,
    x: f32,
    y: f32,
    relative_x: f32,
    relative_y: f32,
    buttons: u32,
};

pub const MouseMotionEvent = extern struct {
    type_: u32,
    timestamp: u64,
    windowID: u32,
    which: u32,
    x: f32,
    y: f32,
    relative_x: f32,
    relative_y: f32,
    buttons: u32,
};

pub const MouseWheelEvent = extern struct {
    type_: u32,
    timestamp: u64,
    windowID: u32,
    which: u32,
    x: i32,
    y: i32,
    precise_x: f32,
    precise_y: f32,
    direction: u32,
};

pub const Event = extern union {
    key: KeyboardEvent,
    text: TextInputEvent,
    window: WindowEvent,
    button: MouseButtonEvent,
    motion: MouseMotionEvent,
    wheel: MouseWheelEvent,
};

pub fn init() !void {
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        std.debug.print("SDL_Init failed: {s}\n", .{SDL_GetError()});
        return error.SdlInitFailed;
    }
}

pub fn quit() void {
    SDL_Quit();
}

pub fn createWindow(title: []const u8, w: i32, h: i32) !*void {
    const win = SDL_CreateWindow(title.ptr, w, h, SDL_WINDOW_RESIZABLE) orelse return error.WindowCreationFailed;
    return win;
}

pub fn destroyWindow(win: ?*void) void {
    SDL_DestroyWindow(win);
}

pub fn createRenderer(win: ?*void) !*void {
    const r = SDL_CreateRenderer(win, null) orelse return error.RendererCreationFailed;
    return r;
}

pub fn destroyRenderer(r: ?*void) void {
    SDL_DestroyRenderer(r);
}

pub fn renderClear(r: ?*void) !void {
    if (!SDL_RenderClear(r)) return error.RenderFailed;
}

pub fn renderPresent(r: ?*void) !void {
    if (!SDL_RenderPresent(r)) return error.RenderFailed;
}

pub fn setRenderDrawColor(r: ?*void, red: u8, green: u8, blue: u8, alpha: u8) !void {
    if (!SDL_SetRenderDrawColor(r, red, green, blue, alpha)) return error.RenderFailed;
}

pub fn renderFillRect(r: ?*void, rect: *const Rect) !void {
    if (!SDL_RenderFillRect(r, rect)) return error.RenderFailed;
}

pub fn pollEvent(event: *Event) bool {
    return SDL_PollEvent(event);
}

pub fn waitEvent(event: *Event) bool {
    return SDL_WaitEvent(event);
}

pub fn startTextInput(win: ?*void) void {
    SDL_StartTextInput(win);
}

pub fn stopTextInput(win: ?*void) void {
    SDL_StopTextInput(win);
}

pub fn getWindowSize(win: ?*void, w: *i32, h: *i32) bool {
    return SDL_GetWindowSize(win, w, h);
}

