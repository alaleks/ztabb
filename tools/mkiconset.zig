//! Writes the `.iconset` directory macOS builds an `.icns` from.
//!
//! Every size is rendered at its own resolution rather than scaled from one
//! master, which is the whole reason the artwork is geometry and not a bitmap.
//!
//! Driven by `zig build icon`, which then hands the directory to `iconutil`.

const std = @import("std");
const appicon = @import("appicon");
const png = @import("png");

/// The sizes an `.icns` is expected to carry, and the names iconutil wants.
const Entry = struct { px: u32, name: []const u8 };
const entries = [_]Entry{
    .{ .px = 16, .name = "icon_16x16.png" },
    .{ .px = 32, .name = "icon_16x16@2x.png" },
    .{ .px = 32, .name = "icon_32x32.png" },
    .{ .px = 64, .name = "icon_32x32@2x.png" },
    .{ .px = 128, .name = "icon_128x128.png" },
    .{ .px = 256, .name = "icon_128x128@2x.png" },
    .{ .px = 256, .name = "icon_256x256.png" },
    .{ .px = 512, .name = "icon_256x256@2x.png" },
    .{ .px = 512, .name = "icon_512x512.png" },
    .{ .px = 1024, .name = "icon_512x512@2x.png" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        std.debug.print("usage: mkiconset <out.iconset>\n", .{});
        return error.MissingArgument;
    }
    const out_dir_path = args[1];

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_dir_path, .{});
    defer dir.close(io);

    for (entries) |entry| {
        const pixels = try gpa.alloc(u32, entry.px * entry.px);
        defer gpa.free(pixels);
        appicon.render(entry.px, pixels);

        const bytes = try png.encodeArgb(gpa, pixels, entry.px);
        defer gpa.free(bytes);

        try dir.writeFile(io, .{ .sub_path = entry.name, .data = bytes });
    }
}
