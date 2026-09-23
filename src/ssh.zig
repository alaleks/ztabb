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
    while (lines.next()) |raw| {
        const line = trim(raw);
        if (line.len == 0 or line[0] == '#') continue;

        const kv = splitDirective(line) orelse continue;
        const key = kv.key;
        const value = kv.value;

        if (std.ascii.eqlIgnoreCase(key, "host")) {
            // A single `Host` line may declare several aliases.
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
            continue;
        }

        // Any other directive applies to the most recent Host block. Lines
        // before the first Host are global defaults with nowhere to go.
        if (out.items.len == 0) continue;
        const host = &out.items[out.items.len - 1];

        if (std.ascii.eqlIgnoreCase(key, "hostname")) {
            host.hostname = try a.dupe(u8, unquote(value));
        } else if (std.ascii.eqlIgnoreCase(key, "user")) {
            host.user = try a.dupe(u8, unquote(value));
        } else if (std.ascii.eqlIgnoreCase(key, "identityfile")) {
            host.identity_file = try a.dupe(u8, unquote(value));
        } else if (std.ascii.eqlIgnoreCase(key, "port")) {
            host.port = std.fmt.parseInt(u16, unquote(value), 10) catch host.port;
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
            // Globs are not expanded; a literal path is the common case.
            if (std.mem.indexOfAny(u8, pattern, "*?") != null) continue;
            const path = if (pattern.len > 0 and pattern[0] == '/')
                try a.dupe(u8, pattern)
            else if (std.mem.startsWith(u8, pattern, "~/"))
                try std.fs.path.join(a, &.{ home, pattern[2..] })
            else
                try std.fs.path.join(a, &.{ home, ".ssh", pattern });
            try parseFile(a, io, path, out, depth);
        }
    }
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
    // Directives attach to the last alias on the line, matching ssh's own
    // behaviour of applying the block to every listed pattern.
    try testing.expectEqualStrings("www", hosts[2].user);
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
    const long = "x" ** (MAX_FIELD + 4);
    const host = Host{ .alias = long };
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
