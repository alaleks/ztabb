//! Shell command-line syntax highlighting.
//!
//! The shell owns the input line and redraws it itself, so ztabb cannot inject
//! colour into the byte stream without corrupting the shell's own cursor
//! arithmetic. Instead the highlighter runs at *render* time over the cells of
//! the current input line: `tokenize` classifies a command string, and the
//! renderer recolours the matching cells. Nothing is written back to the pty,
//! so a shell that colours its own prompt is never fought with.

const std = @import("std");
const theme = @import("theme");

pub const Kind = enum {
    /// The first word of a command: the program being run.
    command,
    /// A shell builtin or keyword in command position.
    builtin,
    /// `-f`, `--flag`.
    option,
    /// Single-, double- or backslash-quoted text.
    string,
    /// A bare numeric argument.
    number,
    /// `|`, `&&`, `>`, `;` and friends.
    operator,
    /// An argument that looks like a filesystem path.
    path,
    /// `$VAR`, `${VAR}`, `$(...)`.
    variable,
    /// `# ...` to end of line.
    comment,
    /// Anything else.
    argument,

    pub fn color(self: Kind, th: *const theme.Theme) u32 {
        return switch (self) {
            .command => th.hl_command,
            .builtin => th.hl_builtin,
            .option => th.hl_option,
            .string => th.hl_string,
            .number => th.hl_number,
            .operator => th.hl_operator,
            .path => th.hl_path,
            .variable => th.hl_variable,
            .comment => th.hl_comment,
            .argument => th.hl_unknown,
        };
    }
};

pub const Token = struct {
    kind: Kind,
    /// Byte offsets into the input.
    start: usize,
    end: usize,

    pub fn slice(self: Token, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }
};

/// POSIX shell and zsh keywords/builtins that colour as `builtin` when they
/// appear in command position.
const builtins = [_][]const u8{
    "alias",   "bg",       "bind",     "break",   "builtin",  "case",
    "cd",      "command",  "continue", "declare", "dirs",     "do",
    "done",    "echo",     "elif",     "else",    "esac",     "eval",
    "exec",    "exit",     "export",   "fc",      "fg",       "fi",
    "for",     "function", "getopts",  "hash",    "history",  "if",
    "jobs",    "kill",     "let",      "local",   "logout",   "popd",
    "print",   "printf",   "pushd",    "pwd",     "read",     "readonly",
    "return",  "select",   "set",      "setopt",  "shift",    "source",
    "test",    "then",     "time",     "times",   "trap",     "type",
    "typeset", "ulimit",   "umask",    "unalias", "unset",    "unsetopt",
    "until",   "wait",     "whence",   "while",   "zmodload",
};

pub fn isBuiltin(word: []const u8) bool {
    for (builtins) |b| {
        if (std.mem.eql(u8, b, word)) return true;
    }
    return false;
}

/// Operators that also start a new command, so the next word is highlighted as
/// a command rather than as an argument.
fn resetsCommandPosition(op: []const u8) bool {
    const resetting = [_][]const u8{ "|", "||", "&&", ";", ";;", "&", "(", ")", "{", "}", "!", "|&" };
    for (resetting) |r| {
        if (std.mem.eql(u8, r, op)) return true;
    }
    return false;
}

fn isOperatorByte(c: u8) bool {
    return switch (c) {
        '|', '&', ';', '<', '>', '(', ')', '{', '}' => true,
        else => false,
    };
}

fn looksLikePath(word: []const u8) bool {
    if (word.len == 0) return false;
    if (word[0] == '/' or word[0] == '~') return true;
    if (std.mem.startsWith(u8, word, "./") or std.mem.startsWith(u8, word, "../")) return true;
    // An interior slash with something on both sides, e.g. `src/main.zig`.
    const slash = std.mem.indexOfScalar(u8, word, '/') orelse return false;
    return slash > 0 and slash + 1 < word.len;
}

fn isNumber(word: []const u8) bool {
    if (word.len == 0) return false;
    var i: usize = 0;
    if (word[0] == '-' or word[0] == '+') i = 1;
    if (i == word.len) return false;
    var seen_dot = false;
    while (i < word.len) : (i += 1) {
        if (word[i] == '.') {
            if (seen_dot) return false;
            seen_dot = true;
            continue;
        }
        if (!std.ascii.isDigit(word[i])) return false;
    }
    return true;
}

/// Classifies `input` into non-overlapping tokens in source order.
///
/// Writes at most `out.len` tokens and returns the ones written; the caller
/// sizes the buffer, so the highlighter never allocates.
pub fn tokenize(input: []const u8, out: []Token) []Token {
    var n: usize = 0;
    var i: usize = 0;
    var command_position = true;

    const push = struct {
        fn f(buf: []Token, count: *usize, kind: Kind, start: usize, end: usize) void {
            if (count.* < buf.len and end > start) {
                buf[count.*] = .{ .kind = kind, .start = start, .end = end };
                count.* += 1;
            }
        }
    }.f;

    while (i < input.len) {
        const c = input[i];

        if (c == ' ' or c == '\t') {
            i += 1;
            continue;
        }

        if (c == '#') {
            push(out, &n, .comment, i, input.len);
            break;
        }

        if (isOperatorByte(c)) {
            const start = i;
            i += 1;
            // Two-byte operators: || && ;; >> << <& >& |&
            if (i < input.len and isOperatorByte(input[i]) and
                (input[i] == c or input[i] == '&'))
            {
                i += 1;
            }
            push(out, &n, .operator, start, i);
            command_position = resetsCommandPosition(input[start..i]);
            continue;
        }

        if (c == '\'' or c == '"') {
            const start = i;
            i += 1;
            while (i < input.len) : (i += 1) {
                if (c == '"' and input[i] == '\\' and i + 1 < input.len) {
                    i += 1;
                    continue;
                }
                if (input[i] == c) {
                    i += 1;
                    break;
                }
            }
            // An unterminated quote still highlights, which is the useful
            // behaviour while the line is being typed.
            push(out, &n, .string, start, i);
            command_position = false;
            continue;
        }

        if (c == '$') {
            const start = i;
            i += 1;
            if (i < input.len and input[i] == '{') {
                while (i < input.len and input[i] != '}') i += 1;
                if (i < input.len) i += 1;
            } else if (i < input.len and input[i] == '(') {
                var depth: usize = 0;
                while (i < input.len) : (i += 1) {
                    if (input[i] == '(') depth += 1;
                    if (input[i] == ')') {
                        depth -= 1;
                        if (depth == 0) {
                            i += 1;
                            break;
                        }
                    }
                }
            } else {
                while (i < input.len and (std.ascii.isAlphanumeric(input[i]) or input[i] == '_')) i += 1;
            }
            push(out, &n, .variable, start, i);
            command_position = false;
            continue;
        }

        // A bare word: runs until whitespace or an operator.
        const start = i;
        while (i < input.len) : (i += 1) {
            const w = input[i];
            if (w == ' ' or w == '\t' or isOperatorByte(w) or w == '\'' or w == '"' or w == '$') break;
            if (w == '\\' and i + 1 < input.len) i += 1;
        }
        const word = input[start..i];
        if (word.len == 0) {
            i += 1;
            continue;
        }

        const kind: Kind = if (command_position)
            (if (isBuiltin(word)) .builtin else .command)
        else if (word[0] == '-' and word.len > 1)
            // `-5` is read as an option: on a command line `tail -5` is far
            // more common than a negative numeric argument.
            .option
        else if (isNumber(word))
            .number
        else if (looksLikePath(word))
            .path
        else
            .argument;

        push(out, &n, kind, start, i);

        // `VAR=value cmd` keeps the next word in command position.
        const is_assignment = command_position and
            std.mem.indexOfScalar(u8, word, '=') != null and word[0] != '=';
        if (!is_assignment) command_position = false;
    }

    return out[0..n];
}

/// The token covering byte offset `at`, if any.
pub fn tokenAt(tokens: []const Token, at: usize) ?Token {
    for (tokens) |t| {
        if (at >= t.start and at < t.end) return t;
    }
    return null;
}

/// Fills `colors[i]` with the highlight colour for `input[i]`, using
/// `fallback` for bytes no token covers (whitespace, mostly).
///
/// This is the form the renderer wants: it walks cells left to right and needs
/// a colour per column without re-searching the token list each time.
pub fn colorize(
    input: []const u8,
    th: *const theme.Theme,
    fallback: u32,
    colors: []u32,
) void {
    const n = @min(input.len, colors.len);
    for (colors[0..n]) |*c| c.* = fallback;

    var buf: [64]Token = undefined;
    for (tokenize(input, &buf)) |t| {
        const color = t.kind.color(th);
        var i = t.start;
        while (i < @min(t.end, n)) : (i += 1) colors[i] = color;
    }
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

fn kinds(input: []const u8, buf: []Token) []Token {
    return tokenize(input, buf);
}

fn expectToken(t: Token, input: []const u8, kind: Kind, text: []const u8) !void {
    try testing.expectEqual(kind, t.kind);
    try testing.expectEqualStrings(text, t.slice(input));
}

test "the first word is the command and the rest are arguments" {
    var buf: [16]Token = undefined;
    const input = "git status";
    const toks = kinds(input, &buf);
    try testing.expectEqual(@as(usize, 2), toks.len);
    try expectToken(toks[0], input, .command, "git");
    try expectToken(toks[1], input, .argument, "status");
}

test "builtins are distinguished from external commands" {
    var buf: [16]Token = undefined;
    const input = "cd /tmp";
    const toks = kinds(input, &buf);
    try expectToken(toks[0], input, .builtin, "cd");
    try expectToken(toks[1], input, .path, "/tmp");

    const input2 = "ls";
    const toks2 = kinds(input2, &buf);
    try expectToken(toks2[0], input2, .command, "ls");
}

test "options are recognised in both short and long form" {
    var buf: [16]Token = undefined;
    const input = "ls -la --color=auto";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .option, "-la");
    try expectToken(toks[2], input, .option, "--color=auto");
}

test "a dash-prefixed number reads as an option, a bare one as a number" {
    var buf: [16]Token = undefined;
    const input = "tail -5 x";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .option, "-5");

    const input2 = "seq 1 100";
    const toks2 = kinds(input2, &buf);
    try expectToken(toks2[1], input2, .number, "1");
    try expectToken(toks2[2], input2, .number, "100");
}

test "quoted strings are one token, including when unterminated" {
    var buf: [16]Token = undefined;
    const input = "echo 'hello world' \"and more\"";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .string, "'hello world'");
    try expectToken(toks[2], input, .string, "\"and more\"");

    const partial = "echo \"unfinished";
    const toks2 = kinds(partial, &buf);
    try expectToken(toks2[1], partial, .string, "\"unfinished");
}

test "an escaped quote does not end a double-quoted string" {
    var buf: [16]Token = undefined;
    const input = "echo \"a \\\" b\" tail";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .string, "\"a \\\" b\"");
    try expectToken(toks[2], input, .argument, "tail");
}

test "a backslash inside single quotes is literal" {
    var buf: [16]Token = undefined;
    const input = "echo 'a\\' b";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .string, "'a\\'");
    try expectToken(toks[2], input, .argument, "b");
}

test "variables in three forms" {
    var buf: [16]Token = undefined;
    const input = "echo $HOME ${PATH} $(date)";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .variable, "$HOME");
    try expectToken(toks[2], input, .variable, "${PATH}");
    try expectToken(toks[3], input, .variable, "$(date)");
}

test "nested command substitution closes at the right paren" {
    var buf: [16]Token = undefined;
    const input = "echo $(dirname $(pwd)) after";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .variable, "$(dirname $(pwd))");
    try expectToken(toks[2], input, .argument, "after");
}

test "operators are tokenised, one and two bytes alike" {
    var buf: [32]Token = undefined;
    const input = "a | b && c >> d ; e";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .operator, "|");
    try expectToken(toks[3], input, .operator, "&&");
    try expectToken(toks[5], input, .operator, ">>");
    try expectToken(toks[7], input, .operator, ";");
}

test "a pipe puts the next word back in command position" {
    var buf: [32]Token = undefined;
    const input = "cat file | grep x";
    const toks = kinds(input, &buf);
    try expectToken(toks[0], input, .command, "cat");
    try expectToken(toks[1], input, .argument, "file");
    try expectToken(toks[3], input, .command, "grep");
    try expectToken(toks[4], input, .argument, "x");
}

test "a redirection does not start a new command" {
    var buf: [32]Token = undefined;
    const input = "echo hi > out.txt";
    const toks = kinds(input, &buf);
    try expectToken(toks[3], input, .argument, "out.txt");
}

test "paths are recognised in several shapes" {
    var buf: [32]Token = undefined;
    const input = "cp /etc/hosts ./backup ../up ~/home src/main.zig plain";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .path, "/etc/hosts");
    try expectToken(toks[2], input, .path, "./backup");
    try expectToken(toks[3], input, .path, "../up");
    try expectToken(toks[4], input, .path, "~/home");
    try expectToken(toks[5], input, .path, "src/main.zig");
    try expectToken(toks[6], input, .argument, "plain");
}

test "a trailing slash alone is not a path" {
    var buf: [16]Token = undefined;
    const input = "echo a/";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .argument, "a/");
}

test "a leading assignment keeps the next word as the command" {
    var buf: [16]Token = undefined;
    const input = "FOO=bar make build";
    const toks = kinds(input, &buf);
    try expectToken(toks[1], input, .command, "make");
    try expectToken(toks[2], input, .argument, "build");
}

test "comments run to end of line" {
    var buf: [16]Token = undefined;
    const input = "ls -l # list files";
    const toks = kinds(input, &buf);
    try testing.expectEqual(@as(usize, 3), toks.len);
    try expectToken(toks[2], input, .comment, "# list files");
}

test "empty and whitespace-only input produce no tokens" {
    var buf: [16]Token = undefined;
    try testing.expectEqual(@as(usize, 0), kinds("", &buf).len);
    try testing.expectEqual(@as(usize, 0), kinds("    \t  ", &buf).len);
}

test "tokens never overlap and stay in source order" {
    var buf: [64]Token = undefined;
    const input = "VAR=1 git commit -m 'msg $x' | tee -a /tmp/log && echo $? # done";
    const toks = kinds(input, &buf);
    var prev_end: usize = 0;
    for (toks) |t| {
        try testing.expect(t.start >= prev_end);
        try testing.expect(t.end > t.start);
        try testing.expect(t.end <= input.len);
        prev_end = t.end;
    }
}

test "a token buffer smaller than the token count truncates safely" {
    var buf: [2]Token = undefined;
    const toks = kinds("a b c d e f g", &buf);
    try testing.expectEqual(@as(usize, 2), toks.len);
}

test "tokenAt finds the covering token" {
    var buf: [16]Token = undefined;
    const input = "git status";
    const toks = kinds(input, &buf);
    try testing.expectEqual(Kind.command, tokenAt(toks, 1).?.kind);
    try testing.expectEqual(Kind.argument, tokenAt(toks, 5).?.kind);
    try testing.expect(tokenAt(toks, 3) == null); // the space
    try testing.expect(tokenAt(toks, 99) == null);
}

test "colorize assigns a colour per byte and falls back on gaps" {
    const input = "cd /tmp";
    var colors: [16]u32 = undefined;
    colorize(input, &theme.dark, 0xABCDEF, &colors);
    try testing.expectEqual(theme.dark.hl_builtin, colors[0]);
    try testing.expectEqual(theme.dark.hl_builtin, colors[1]);
    try testing.expectEqual(@as(u32, 0xABCDEF), colors[2]); // the space
    try testing.expectEqual(theme.dark.hl_path, colors[3]);
    try testing.expectEqual(theme.dark.hl_path, colors[6]);
}

test "colorize follows the theme" {
    const input = "ls";
    var dark_colors: [4]u32 = undefined;
    var light_colors: [4]u32 = undefined;
    colorize(input, &theme.dark, 0, &dark_colors);
    colorize(input, &theme.light, 0, &light_colors);
    try testing.expect(dark_colors[0] != light_colors[0]);
    try testing.expectEqual(theme.light.hl_command, light_colors[0]);
}

test "colorize tolerates a colour buffer shorter than the input" {
    const input = "some fairly long command line";
    var colors: [4]u32 = undefined;
    colorize(input, &theme.dark, 0, &colors);
    try testing.expectEqual(theme.dark.hl_command, colors[0]);
}

test "every kind maps to a colour in both themes" {
    inline for (std.meta.fields(Kind)) |f| {
        const k: Kind = @enumFromInt(f.value);
        try testing.expect(k.color(&theme.dark) != k.color(&theme.light) or
            k.color(&theme.dark) != 0);
    }
}

test "fuzzing the tokenizer never panics or produces bad spans" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rand = prng.random();
    const alphabet = "abc -$'\"|&;<>(){}#/=. \t\\1";
    var input: [96]u8 = undefined;
    var buf: [96]Token = undefined;
    for (0..5000) |_| {
        const len = rand.uintLessThan(usize, input.len);
        for (input[0..len]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        var prev_end: usize = 0;
        for (tokenize(input[0..len], &buf)) |t| {
            try testing.expect(t.start >= prev_end);
            try testing.expect(t.end <= len);
            try testing.expect(t.end > t.start);
            prev_end = t.end;
        }
    }
}
