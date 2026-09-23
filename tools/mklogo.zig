//! Renders the README logo: the application icon with its cursor blinking.
//!
//! Two frames, written as PNGs for `ffmpeg` to assemble into a GIF. Drawn from
//! the same code as the icon in the Dock, so the two can never drift apart.
//!
//! Driven by `zig build logo`.

const std = @import("std");
const appicon = @import("appicon");
const png = @import("png");

const SIZE: u32 = 512;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        std.debug.print("usage: mklogo <out-dir>\n", .{});
        return error.MissingArgument;
    }

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, args[1], .{});
    defer dir.close(io);

    const pixels = try gpa.alloc(u32, SIZE * SIZE);
    defer gpa.free(pixels);

    for ([_]bool{ true, false }, 0..) |cursor, i| {
        appicon.renderFrame(SIZE, cursor, pixels);
        const bytes = try png.encodeArgb(gpa, pixels, SIZE);
        defer gpa.free(bytes);

        var name: [32]u8 = undefined;
        const sub = try std.fmt.bufPrint(&name, "logo-{d}.png", .{i});
        try dir.writeFile(io, .{ .sub_path = sub, .data = bytes });
    }
}
