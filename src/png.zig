//! A minimal PNG writer, just enough to hand icon bitmaps to `iconutil`.
//!
//! The pixel data goes into stored (uncompressed) deflate blocks, which zlib
//! and every PNG reader accept. Compressing them would need a deflate encoder
//! for no benefit: these files are a build artifact on the way to an `.icns`,
//! not something that ships or crosses a network.

const std = @import("std");

const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk table;
};

fn crc32(bytes: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (bytes) |b| c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFF;
}

/// Adler-32, the checksum a zlib stream ends with.
fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn appendU32(list: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, v: u32) !void {
    try list.appendSlice(gpa, &.{
        @truncate(v >> 24),
        @truncate(v >> 16),
        @truncate(v >> 8),
        @truncate(v),
    });
}

fn appendChunk(
    list: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    tag: *const [4]u8,
    payload: []const u8,
) !void {
    try appendU32(list, gpa, @intCast(payload.len));
    const start = list.items.len;
    try list.appendSlice(gpa, tag);
    try list.appendSlice(gpa, payload);
    try appendU32(list, gpa, crc32(list.items[start..]));
}

/// Encodes `size` x `size` ARGB pixels as an 8-bit RGBA PNG.
///
/// Caller owns the returned bytes.
pub fn encodeArgb(gpa: std.mem.Allocator, pixels: []const u32, size: u32) ![]u8 {
    std.debug.assert(pixels.len >= size * size);

    // Raw scanlines, each prefixed with filter type 0 (none).
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.ensureTotalCapacity(gpa, size * (size * 4 + 1));
    for (0..size) |y| {
        raw.appendAssumeCapacity(0);
        for (0..size) |x| {
            const px = pixels[y * size + x];
            raw.appendSliceAssumeCapacity(&.{
                @truncate(px >> 16),
                @truncate(px >> 8),
                @truncate(px),
                @truncate(px >> 24),
            });
        }
    }

    // zlib stream: header, stored deflate blocks, adler checksum.
    var z: std.ArrayListUnmanaged(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var at: usize = 0;
    while (at < raw.items.len) {
        const len: u16 = @intCast(@min(raw.items.len - at, 0xFFFF));
        const final: u8 = if (at + len >= raw.items.len) 1 else 0;
        try z.append(gpa, final);
        try z.appendSlice(gpa, &.{ @truncate(len), @truncate(len >> 8) });
        const inv = ~len;
        try z.appendSlice(gpa, &.{ @truncate(inv), @truncate(inv >> 8) });
        try z.appendSlice(gpa, raw.items[at..][0..len]);
        at += len;
    }
    try appendU32(&z, gpa, adler32(raw.items));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], size, .big);
    std.mem.writeInt(u32, ihdr[4..8], size, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try appendChunk(&out, gpa, "IHDR", &ihdr);
    try appendChunk(&out, gpa, "IDAT", z.items);
    try appendChunk(&out, gpa, "IEND", "");

    return out.toOwnedSlice(gpa);
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

test "crc32 matches the known PNG test vector" {
    try testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try testing.expectEqual(@as(u32, 0), crc32(""));
}

test "adler32 matches its known vector" {
    try testing.expectEqual(@as(u32, 0x11E60398), adler32("Wikipedia"));
    try testing.expectEqual(@as(u32, 1), adler32(""));
}

test "the file carries the PNG signature and the required chunks in order" {
    const gpa = testing.allocator;
    const pixels = [_]u32{ 0xFF112233, 0x80445566, 0x00778899, 0xFFAABBCC };
    const png = try encodeArgb(gpa, &pixels, 2);
    defer gpa.free(png);

    try testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A }, png[0..8]);
    const ihdr = std.mem.indexOf(u8, png, "IHDR").?;
    const idat = std.mem.indexOf(u8, png, "IDAT").?;
    const iend = std.mem.indexOf(u8, png, "IEND").?;
    try testing.expect(ihdr < idat and idat < iend);
    try testing.expectEqual(png.len, iend + 4 + 4); // IEND has an empty payload
}

test "the header records the size, depth and colour type" {
    const gpa = testing.allocator;
    const pixels = [_]u32{0} ** (4 * 4);
    const png = try encodeArgb(gpa, &pixels, 4);
    defer gpa.free(png);

    const at = std.mem.indexOf(u8, png, "IHDR").? + 4;
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, png[at..][0..4], .big));
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, png[at + 4 ..][0..4], .big));
    try testing.expectEqual(@as(u8, 8), png[at + 8]);
    try testing.expectEqual(@as(u8, 6), png[at + 9]);
}

test "every chunk's CRC checks out" {
    const gpa = testing.allocator;
    const pixels = [_]u32{0xFF00FF00} ** (8 * 8);
    const png = try encodeArgb(gpa, &pixels, 8);
    defer gpa.free(png);

    var at: usize = 8;
    var chunks: usize = 0;
    while (at + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        const body = png[at + 4 ..][0 .. 4 + len];
        const stored = std.mem.readInt(u32, png[at + 8 + len ..][0..4], .big);
        try testing.expectEqual(crc32(body), stored);
        at += 12 + len;
        chunks += 1;
    }
    try testing.expectEqual(@as(usize, 3), chunks);
    try testing.expectEqual(png.len, at);
}

test "the zlib stream is well formed and its last block is marked final" {
    const gpa = testing.allocator;
    const pixels = [_]u32{0xFFFFFFFF} ** (4 * 4);
    const png = try encodeArgb(gpa, &pixels, 4);
    defer gpa.free(png);

    const at = std.mem.indexOf(u8, png, "IDAT").?;
    const len = std.mem.readInt(u32, png[at - 4 ..][0..4], .big);
    const z = png[at + 4 ..][0..len];
    try testing.expectEqual(@as(u8, 0x78), z[0]);

    // Walk the stored blocks; the run must end exactly at the checksum.
    var i: usize = 2;
    var saw_final = false;
    while (!saw_final) {
        saw_final = z[i] & 1 != 0;
        const block_len = std.mem.readInt(u16, z[i + 1 ..][0..2], .little);
        const nlen = std.mem.readInt(u16, z[i + 3 ..][0..2], .little);
        try testing.expectEqual(block_len, ~nlen);
        i += 5 + @as(usize, block_len);
    }
    try testing.expectEqual(z.len, i + 4);
}

test "pixels survive the round trip in RGBA order" {
    const gpa = testing.allocator;
    // One opaque red pixel: ARGB in, RGBA out.
    const pixels = [_]u32{0xFFFF0000};
    const png = try encodeArgb(gpa, &pixels, 1);
    defer gpa.free(png);

    const at = std.mem.indexOf(u8, png, "IDAT").? + 4;
    // zlib header (2) + block header (5) + filter byte (1).
    const rgba = png[at + 8 ..][0..4];
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0x00, 0xFF }, rgba);
}

test "a large image spills into several stored blocks" {
    // Stored blocks cap at 65535 bytes, and a 256px icon is far past that.
    const gpa = testing.allocator;
    const size: u32 = 256;
    const pixels = try gpa.alloc(u32, size * size);
    defer gpa.free(pixels);
    @memset(pixels, 0xFF203040);

    const png = try encodeArgb(gpa, pixels, size);
    defer gpa.free(png);

    const at = std.mem.indexOf(u8, png, "IDAT").?;
    const len = std.mem.readInt(u32, png[at - 4 ..][0..4], .big);
    const z = png[at + 4 ..][0..len];

    var i: usize = 2;
    var blocks: usize = 0;
    var saw_final = false;
    while (!saw_final) {
        saw_final = z[i] & 1 != 0;
        // Widened: a full 65535-byte block plus the header overflows a u16.
        i += 5 + @as(usize, std.mem.readInt(u16, z[i + 1 ..][0..2], .little));
        blocks += 1;
    }
    try testing.expect(blocks > 1);
    try testing.expectEqual(z.len, i + 4);
}
