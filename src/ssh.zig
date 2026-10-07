//! Reads `~/.ssh/config` so ztabb can offer the hosts defined there.
//!
//! Only the directives a connection picker needs are kept: the host alias, and
//! the HostName / User / Port / IdentityFile that describe it. Wildcard
//! patterns (`Host *`) are parsed but flagged, since they are defaults rather
//! than connectable entries. `Include` directives are followed one level deep,
//! which covers the common `Include conf.d/*` layout without risking cycles.

const std = @import("std");

pub const MAX_HOSTS = 128;
pub const MAX_FIELD = 128;

pub const Host = struct {
    alias: []const u8,
    hostname: []const u8 = "",
    user: []const u8 = "",
    identity_file: []const u8 = "",
    port: u16 = 22,
    /// True for patterns such as `Host *` that cannot be connected to directly.
    is_pattern: bool = false,

    /// The argument vector for connecting to this host.
    ///
    /// Only the alias is passed: ssh applies the rest of the config itself, so
    /// duplicating HostName/User/Port here would override a `Match` block the
    /// parser deliberately does not model.
    pub fn command(self: Host, buf: *[MAX_FIELD:0]u8) error{NameTooLong}![*:0]const u8 {
        if (self.alias.len >= buf.len) return error.NameTooLong;
        @memcpy(buf[0..self.alias.len], self.alias);
        buf[self.alias.len] = 0;
        return @ptrCast(buf);
    }
};

/// Parsed hosts plus the arena backing their strings.
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    hosts: []Host,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// Hosts that can actually be connected to, i.e. excluding patterns,
    /// in alphabetical order.
    ///
    /// Sorted here rather than in the picker so that the index the picker
    /// shows and the index it connects to are the same one.
    pub fn connectable(self: *const Config, out: []Host) []Host {
        var n: usize = 0;
        for (self.hosts) |h| {
            if (h.is_pattern or n == out.len) continue;
            out[n] = h;
            n += 1;
        }
        std.mem.sort(Host, out[0..n], {}, aliasBefore);
        return out[0..n];
    }

    /// Case-insensitive, so `Web` and `web` sort together rather than the
    /// capitals coming first; ties break on the exact bytes so the order is
    /// the same on every run.
    fn aliasBefore(_: void, a: Host, b: Host) bool {
        return switch (std.ascii.orderIgnoreCase(a.alias, b.alias)) {
            .lt => true,
            .gt => false,
            .eq => std.mem.order(u8, a.alias, b.alias) == .lt,
        };
    }
};

/// Parses `~/.ssh/config`. Returns an empty config when the file is absent,
/// which is the normal case for users who do not use ssh.
pub fn load(gpa: std.mem.Allocator, io: std.Io) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const home = homeDir() orelse {
        return .{ .arena = arena, .hosts = &.{} };
    };
    const path = try std.fs.path.join(a, &.{ home, ".ssh", "config" });

    var hosts: std.ArrayListUnmanaged(Host) = .empty;
    try parseFile(a, io, path, &hosts, 1);
    return .{ .arena = arena, .hosts = try hosts.toOwnedSlice(a) };
}

/// Parses `text` directly. Exposed for tests and for callers that already hold
/// the file contents; all returned strings are allocated from `a`.
pub fn parseText(
    a: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayListUnmanaged(Host),
) std.mem.Allocator.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var block_start: ?usize = null;
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;

        const kv = splitDirective(line) orelse continue;
        const key = kv.key;
        const value = kv.value;

        if (std.ascii.eqlIgnoreCase(key, "host")) {
            // A single `Host` line may declare several aliases.
            const first = out.items.len;
            var names = std.mem.tokenizeAny(u8, value, " \t");
            while (names.next()) |name| {
                if (out.items.len >= MAX_HOSTS) return;
                if (name.len > MAX_FIELD) continue;
                // A negated pattern (`!prod`) excludes rather than declares.
                if (name[0] == '!') continue;
                try out.append(a, .{
                    .alias = try a.dupe(u8, name),
                    .is_pattern = std.mem.indexOfAny(u8, name, "*?") != null,
                });
            }
            block_start = if (out.items.len > first) first else null;
            continue;
        }

        // Any other directive applies to the most recent Host block. Lines
        // before the first Host are global defaults with nowhere to go.
        const first = block_start orelse continue;
        const hosts = out.items[first..];

        if (std.ascii.eqlIgnoreCase(key, "hostname")) {
            const parsed = try a.dupe(u8, unquote(value));
            for (hosts) |*host| host.hostname = parsed;
        } else if (std.ascii.eqlIgnoreCase(key, "user")) {
            const parsed = try a.dupe(u8, unquote(value));
            for (hosts) |*host| host.user = parsed;
        } else if (std.ascii.eqlIgnoreCase(key, "identityfile")) {
            const parsed = try a.dupe(u8, unquote(value));
            for (hosts) |*host| host.identity_file = parsed;
        } else if (std.ascii.eqlIgnoreCase(key, "port")) {
            const parsed = std.fmt.parseInt(u16, unquote(value), 10) catch continue;
            for (hosts) |*host| host.port = parsed;
        }
    }
}

const ParseError = std.mem.Allocator.Error;

fn parseFile(
    a: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayListUnmanaged(Host),
    depth: u8,
) ParseError!void {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return;
    try parseText(a, text, out);
    if (depth > 0) try followIncludes(a, io, text, out, depth - 1);
}

/// Expands `Include` directives relative to `~/.ssh`, one level deep.
fn followIncludes(
    a: std.mem.Allocator,
    io: std.Io,
    text: []const u8,
    out: *std.ArrayListUnmanaged(Host),
    depth: u8,
) ParseError!void {
    const home = homeDir() orelse return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = trim(raw);
        const kv = splitDirective(line) orelse continue;
        if (!std.ascii.eqlIgnoreCase(kv.key, "include")) continue;

        var patterns = std.mem.tokenizeAny(u8, kv.value, " \t");
        while (patterns.next()) |pattern| {
            const path = if (pattern.len > 0 and pattern[0] == '/')
                try a.dupe(u8, pattern)
            else if (std.mem.startsWith(u8, pattern, "~/"))
                try std.fs.path.join(a, &.{ home, pattern[2..] })
            else
                try std.fs.path.join(a, &.{ home, ".ssh", pattern });
            if (std.mem.indexOfAny(u8, path, "*?") == null) {
                try parseFile(a, io, path, out, depth);
            } else {
                try parseGlob(a, io, path, out, depth);
            }
        }
    }
}

/// Expands wildcards in the final path component. This covers OpenSSH's
/// conventional `Include ~/.ssh/config.d/*` layout while keeping traversal
/// bounded to the directory explicitly named by the user.
fn parseGlob(
    a: std.mem.Allocator,
    io: std.Io,
    pattern: []const u8,
    out: *std.ArrayListUnmanaged(Host),
    depth: u8,
) ParseError!void {
    const dir_path = std.fs.path.dirname(pattern) orelse ".";
    const name_pattern = std.fs.path.basename(pattern);
    if (std.mem.indexOfAny(u8, dir_path, "*?") != null) return;

    var dir = if (std.fs.path.isAbsolute(dir_path))
        std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer paths.deinit(a);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory or !wildcardMatch(name_pattern, entry.name)) continue;
        try paths.append(a, try std.fs.path.join(a, &.{ dir_path, entry.name }));
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn before(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.before);
    for (paths.items) |path| try parseFile(a, io, path, out, depth);
}

fn wildcardMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = n;
        } else if (star) |at| {
            p = at + 1;
            retry += 1;
            n = retry;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// The user's home directory: `$HOME`, or `%USERPROFILE%` on Windows, which
/// is where OpenSSH for Windows looks for `.ssh` too.
fn homeDir() ?[]const u8 {
    const names: []const [*:0]const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "USERPROFILE", "HOME" }
    else
        &.{"HOME"};
    for (names) |name| {
        const raw = std.c.getenv(name) orelse continue;
        const s = std.mem.span(raw);
        if (s.len > 0) return s;
    }
    return null;
}

const Directive = struct { key: []const u8, value: []const u8 };

/// ssh_config accepts `Key value`, `Key=value` and `Key = value`.
fn splitDirective(line: []const u8) ?Directive {
    const sep = std.mem.indexOfAny(u8, line, " \t=") orelse return null;
    const key = line[0..sep];
    if (key.len == 0) return null;
    var rest = line[sep..];
    rest = std.mem.trimStart(u8, rest, " \t");
    if (rest.len > 0 and rest[0] == '=') rest = std.mem.trimStart(u8, rest[1..], " \t");
    if (rest.len == 0) return null;
    return .{ .key = key, .value = trim(rest) };
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn parseForTest(a: std.mem.Allocator, text: []const u8) ![]Host {
    var hosts: std.ArrayListUnmanaged(Host) = .empty;
    try parseText(a, text, &hosts);
    return hosts.toOwnedSlice(a);
}

test "parses a plain host block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\Host prod
        \\    HostName prod.example.com
        \\    User deploy
        \\    Port 2222
        \\    IdentityFile ~/.ssh/id_prod
    );
    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("prod", hosts[0].alias);
    try testing.expectEqualStrings("prod.example.com", hosts[0].hostname);
    try testing.expectEqualStrings("deploy", hosts[0].user);
    try testing.expectEqualStrings("~/.ssh/id_prod", hosts[0].identity_file);
    try testing.expectEqual(@as(u16, 2222), hosts[0].port);
    try testing.expect(!hosts[0].is_pattern);
}

test "port defaults to 22 and survives a malformed value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\Host a
        \\Host b
        \\  Port not-a-number
        \\Host c
        \\  Port 70000
    );
    try testing.expectEqual(@as(u16, 22), hosts[0].port);
    try testing.expectEqual(@as(u16, 22), hosts[1].port);
    try testing.expectEqual(@as(u16, 22), hosts[2].port);
}

test "one Host line can declare several aliases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\Host web1 web2 web3
        \\  User www
    );
    try testing.expectEqual(@as(usize, 3), hosts.len);
    try testing.expectEqualStrings("web1", hosts[0].alias);
    try testing.expectEqualStrings("web3", hosts[2].alias);
    for (hosts) |host| try testing.expectEqualStrings("www", host.user);
}

test "include filename wildcards match the usual config directory layout" {
    try testing.expect(wildcardMatch("*", "prod.conf"));
    try testing.expect(wildcardMatch("*.conf", "prod.conf"));
    try testing.expect(wildcardMatch("host-?.conf", "host-a.conf"));
    try testing.expect(!wildcardMatch("*.conf", "README"));
    try testing.expect(!wildcardMatch("host-?.conf", "host-long.conf"));
}

test "wildcard hosts are flagged as patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\Host *
        \\  User default
        \\Host bastion
        \\Host dev-?
    );
    try testing.expect(hosts[0].is_pattern);
    try testing.expect(!hosts[1].is_pattern);
    try testing.expect(hosts[2].is_pattern);
}

test "negated patterns are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(), "Host * !secret\n");
    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("*", hosts[0].alias);
}

test "comments and blank lines are ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\# a comment
        \\
        \\Host real
        \\   # another
        \\   HostName real.example.com
        \\
    );
    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("real.example.com", hosts[0].hostname);
}

test "equals-separated and quoted values parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\Host=weird
        \\HostName="my host.example.com"
        \\User = bob
        \\Port=2022
    );
    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("weird", hosts[0].alias);
    try testing.expectEqualStrings("my host.example.com", hosts[0].hostname);
    try testing.expectEqualStrings("bob", hosts[0].user);
    try testing.expectEqual(@as(u16, 2022), hosts[0].port);
}

test "directive keywords are case-insensitive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\HOST upper
        \\  hostname lower.example.com
        \\  UsEr mixed
    );
    try testing.expectEqualStrings("lower.example.com", hosts[0].hostname);
    try testing.expectEqualStrings("mixed", hosts[0].user);
}

test "CRLF line endings parse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(), "Host win\r\n  HostName win.example.com\r\n");
    try testing.expectEqualStrings("win", hosts[0].alias);
    try testing.expectEqualStrings("win.example.com", hosts[0].hostname);
}

test "directives before the first Host block are dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const hosts = try parseForTest(arena.allocator(),
        \\ServerAliveInterval 60
        \\Host after
        \\  User u
    );
    try testing.expectEqual(@as(usize, 1), hosts.len);
    try testing.expectEqualStrings("after", hosts[0].alias);
}

test "an empty or whitespace-only config yields no hosts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try parseForTest(arena.allocator(), "")).len);
    try testing.expectEqual(@as(usize, 0), (try parseForTest(arena.allocator(), "  \n\t\n")).len);
    try testing.expectEqual(@as(usize, 0), (try parseForTest(arena.allocator(), "Host\n")).len);
}

test "the host limit is respected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const a = arena.allocator();
    defer arena.deinit();
    var text: std.ArrayListUnmanaged(u8) = .empty;
    for (0..MAX_HOSTS * 2) |i| try text.print(a, "Host h{d}\n", .{i});
    const hosts = try parseForTest(a, text.items);
    try testing.expectEqual(@as(usize, MAX_HOSTS), hosts.len);
}

test "connectable filters out patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const hosts = try parseForTest(arena.allocator(),
        \\Host *
        \\Host one
        \\Host two
    );
    var cfg = Config{ .arena = arena, .hosts = hosts };
    defer cfg.deinit();

    var buf: [8]Host = undefined;
    const usable = cfg.connectable(&buf);
    try testing.expectEqual(@as(usize, 2), usable.len);
    try testing.expectEqualStrings("one", usable[0].alias);
    try testing.expectEqualStrings("two", usable[1].alias);
}

test "connectable sorts the hosts alphabetically" {
    // The file's order is whatever the user wrote; the picker wants a list
    // that can be scanned.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const hosts = try parseForTest(arena.allocator(),
        \\Host zeta
        \\Host Alpha
        \\Host beta
        \\Host alpha
    );
    var cfg = Config{ .arena = arena, .hosts = hosts };
    defer cfg.deinit();

    var buf: [8]Host = undefined;
    const usable = cfg.connectable(&buf);
    try testing.expectEqual(@as(usize, 4), usable.len);
    // Case-insensitive, so the capitals do not all come first; the tie
    // between `Alpha` and `alpha` breaks the same way every run.
    try testing.expectEqualStrings("Alpha", usable[0].alias);
    try testing.expectEqualStrings("alpha", usable[1].alias);
    try testing.expectEqualStrings("beta", usable[2].alias);
    try testing.expectEqualStrings("zeta", usable[3].alias);
}

test "sorting survives more hosts than the caller's buffer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const hosts = try parseForTest(arena.allocator(),
        \\Host d
        \\Host c
        \\Host b
        \\Host a
    );
    var cfg = Config{ .arena = arena, .hosts = hosts };
    defer cfg.deinit();

    var buf: [2]Host = undefined;
    const usable = cfg.connectable(&buf);
    try testing.expectEqual(@as(usize, 2), usable.len);
    try testing.expectEqualStrings("c", usable[0].alias);
    try testing.expectEqualStrings("d", usable[1].alias);
}

test "command yields a null-terminated alias" {
    const host = Host{ .alias = "prod" };
    var buf: [MAX_FIELD:0]u8 = undefined;
    const arg = try host.command(&buf);
    try testing.expectEqualStrings("prod", std.mem.span(arg));
}

test "command rejects an over-long alias rather than overflowing" {
    const long: [MAX_FIELD + 4]u8 = @splat('x');
    const host = Host{ .alias = &long };
    var buf: [MAX_FIELD:0]u8 = undefined;
    try testing.expectError(error.NameTooLong, host.command(&buf));
}

test "load tolerates a missing config file" {
    // Whatever this machine has, load must not fail.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var cfg = try load(testing.allocator, threaded.io());
    defer cfg.deinit();
    for (cfg.hosts) |h| try testing.expect(h.alias.len > 0);
}

test "fuzzing the config parser never panics and keeps every host usable" {
    // This parser is handed a file from the user's disk at startup, and lays it
    // out into fields of fixed width. What it must never do is overrun one, or
    // hand back a host `command` cannot spell -- both would be reached before
    // the window is even up.
    const almost_long: [MAX_FIELD - 1]u8 = @splat('x');
    const exact_long: [MAX_FIELD]u8 = @splat('y');
    const too_long: [MAX_FIELD + 7]u8 = @splat('z');
    const words = [_][]const u8{
        "Host",      "HostName",  "User",       "Port", "IdentityFile",
        "Match",     "ProxyJump", "*",          "?",    "!secret",
        "a",         "h1",        "\"quoted\"", "#c",   "=",
        "\t",        " ",         "\r",         "",     &almost_long,
        &exact_long, &too_long,
    };

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();

    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(testing.allocator);

    for (0..600) |_| {
        text.clearRetainingCapacity();
        for (0..rand.uintLessThan(usize, 30)) |_| {
            for (0..rand.uintLessThan(usize, 5)) |_| {
                try text.appendSlice(testing.allocator, words[rand.uintLessThan(usize, words.len)]);
                if (rand.boolean()) try text.append(testing.allocator, ' ');
            }
            try text.append(testing.allocator, '\n');
        }

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var hosts: std.ArrayListUnmanaged(Host) = .empty;
        try parseText(arena.allocator(), text.items, &hosts);

        try testing.expect(hosts.items.len <= MAX_HOSTS);
        for (hosts.items) |h| {
            // A parsed alias has to be spellable as a command, or the picker
            // offers a row that cannot be connected to.
            try testing.expect(h.alias.len > 0);
            var buf: [MAX_FIELD:0]u8 = undefined;
            const cmd = h.command(&buf) catch |err| {
                try testing.expectEqual(error.NameTooLong, err);
                continue;
            };
            try testing.expect(std.mem.len(cmd) == h.alias.len);
        }
    }
}
