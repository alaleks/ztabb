//! Entry point: wire up the allocator and hand off to the app.

const std = @import("std");
const app = @import("app");

pub fn main() !void {
    // SDL and the pty layer both call into libc, so the C allocator keeps the
    // whole process on one heap.
    var a = try app.App.init(std.heap.c_allocator);
    defer a.deinit();
    a.run();
}
