//! Serialises an argument vector using the quoting rules consumed by
//! CommandLineToArgvW and the Microsoft C runtime.

const std = @import("std");
r
pub const Error = error{BufferTooSmall};

pub fn encode(argv: []const [*:0]const u8, buf: []u8) Error![]const u8 {
    var n: usize = 0;
    for (argv, 0..) |arg_z, arg_index| {
        const arg = std.mem.span(arg_z);
        if (arg_index > 0) try appendByte(buf, &n, ' ');

        const quoted = arg.len == 0 or std.mem.indexOfAny(u8, arg, " \t\"") != null;
        if (!quoted) {
            try appendSlice(buf, &n, arg);
            continue;
        }

        try appendByte(buf, &n, '"');
        var slashes: usize = 0;
        for (arg) |byte| {
            if (byte == '\\') {
                slashes += 1;
                continue;
            }
            if (byte == '"') {
                try appendRepeat(buf, &n, '\\', slashes * 2 + 1);
                try appendByte(buf, &n, '"');
            } else {
                try appendRepeat(buf, &n, '\\', slashes);
                try appendByte(buf, &n, byte);
            }
            slashes = 0;
        }
        // Backslashes immediately before the closing quote must be doubled so
        // they remain literal rather than escaping that quote.
        try appendRepeat(buf, &n, '\\', slashes * 2);
        try appendByte(buf, &n, '"');
    }
    return buf[0..n];
}

fn appendByte(buf: []u8, n: *usize, byte: u8) Error!void {
    if (n.* == buf.len) return error.BufferTooSmall;
    buf[n.*] = byte;
    n.* += 1;
}

fn appendSlice(buf: []u8, n: *usize, bytes: []const u8) Error!void {
    if (bytes.len > buf.len - n.*) return error.BufferTooSmall;
    @memcpy(buf[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
}

fn appendRepeat(buf: []u8, n: *usize, byte: u8, count: usize) Error!void {
    if (count > buf.len - n.*) return error.BufferTooSmall;
    @memset(buf[n.*..][0..count], byte);
    n.* += count;
}

const testing = std.testing;

test "separate arguments remain separate" {
    const argv = [_][*:0]const u8{ "ssh", "server" };
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ssh server", try encode(&argv, &buf));
}

test "spaces quotes and trailing backslashes are escaped" {
    const argv = [_][*:0]const u8{ "program.exe", "two words", "say\"hi", "C:\\Program Files\\" };
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "program.exe \"two words\" \"say\\\"hi\" \"C:\\Program Files\\\\\"",
        try encode(&argv, &buf),
    );
}

test "empty arguments are preserved" {
    const argv = [_][*:0]const u8{ "program.exe", "" };
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("program.exe \"\"", try encode(&argv, &buf));
}

test "a short output buffer is rejected" {
    const argv = [_][*:0]const u8{ "ssh", "server" };
    var buf: [3]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, encode(&argv, &buf));
}
