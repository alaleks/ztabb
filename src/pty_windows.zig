//! The Windows pseudo-console.
//!
//! Windows has no `openpty` and no `fork`: a console program is driven through
//! ConPTY, which hands back a pair of pipes and a pseudo-console handle, and
//! the child is started with that handle attached through a process attribute.
//!
//! The shape of the API matches `pty_posix.zig` exactly, so everything above
//! this file is written once.

const std = @import("std");
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
/// A Win32 `BOOL` is an enum in std rather than an integer, so a call's result
/// is read with `toBool` rather than compared against zero.
const BOOL = windows.BOOL;
/// Declared here because std no longer does: a signed 32-bit status where
/// `S_OK` is zero.
const HRESULT = windows.LONG;
const WORD = windows.WORD;
const HPCON = *anyopaque;

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const STILL_ACTIVE: DWORD = 259;
/// `WaitForSingleObject` returning this means the handle was signalled;
/// anything else is a timeout or a failure.
const WAIT_OBJECT_0: DWORD = 0;
/// How long a closing pane gives its child before insisting. The POSIX side
/// gives it the same.
const GRACE_MS: DWORD = 200;
/// The buffer for the pipe the console host writes into.
///
/// It matters more than a pipe size usually does. Every ConPTY call -- a
/// resize, a close -- can block while this pipe is full, because the host is
/// mid-write and cannot be interrupted, and ztabb drains a bounded amount per
/// frame by design. The buffer therefore has to absorb whatever the host emits
/// between two drains, and a full repaint of a large window is a great deal
/// more than the few kilobytes `CreatePipe` gives by default.
///
/// This lowers the odds of that stall; it does not remove it. Removing it takes
/// a reader thread that drains the pipe continuously, which is what a ConPTY
/// front end really wants.
const OUT_PIPE_BYTES: DWORD = 1 << 20;
const IN_PIPE_BYTES: DWORD = 4 * 1024;
/// How long a write to the child may wait before the rest is dropped.
///
/// A child that has stopped reading its input must not stop the thread that
/// draws: the POSIX side drops such a write, and this is that bound. Long
/// enough that a child merely busy for a moment still gets the keystroke,
/// short enough that the worst case costs a few frames rather than the
/// session.
const WRITE_MS: DWORD = 50;
const PIPE_ACCESS_OUTBOUND: DWORD = 0x00000002;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
const GENERIC_READ: DWORD = 0x80000000;
const OPEN_EXISTING: DWORD = 3;
const ERROR_IO_PENDING: DWORD = 997;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;

const COORD = extern struct { x: i16, y: i16 };

const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?*u8,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

/// `STARTUPINFOEX`: the plain structure followed by the attribute list that
/// carries the pseudo-console.
const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*SECURITY_ATTRIBUTES,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *DWORD,
    bWait: BOOL,
) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;
extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *anyopaque,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: ?[*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

/// Makes each pty's input pipe name unique within this process.
var pipe_seq: std.atomic.Value(u32) = .init(0);

pub const SpawnError = error{
    OpenPtyFailed,
    ForkFailed,
};

/// The command line a fresh tab runs, in UTF-16 as CreateProcessW wants it.
var shell_buf: [512]u16 = undefined;

pub const Pty = struct {
    /// Our end of the pipes: what the child writes, and what it reads.
    out_read: HANDLE,
    in_write: HANDLE,
    /// Signalled when an asynchronous write to the input pipe finishes. One
    /// write is in flight at a time, so one event is enough.
    in_event: HANDLE,
    console: HPCON,
    process: HANDLE,
    thread: HANDLE,
    /// The attribute list outlives CreateProcessW, so it is freed with the pty.
    attrs: ?*anyopaque,
    attrs_buf: []u8,
    gpa: std.mem.Allocator,

    exited: bool = false,
    exit_status: u32 = 0,
    /// Set once `close` has run, so a second close is a no-op rather than a
    /// double free of the attribute buffer.
    closed: bool = false,
    /// The size the child was last told about.
    cols: u16,
    rows: u16,

    /// Starts `argv[0]` under a pseudo-console sized `cols` x `rows`.
    ///
    /// `extra_env` is accepted for symmetry with the POSIX side; ConPTY takes
    /// its environment from the parent, and the variables that matter here
    /// (TERM and friends) are meaningless to a Windows console host.
    pub fn spawn(
        argv: []const [*:0]const u8,
        extra_env: []const [*:0]const u8,
        cols: u16,
        rows: u16,
    ) SpawnError!Pty {
        _ = extra_env;
        std.debug.assert(argv.len > 0);
        const gpa = std.heap.page_allocator;

        // Two pipes: one the console writes its output into, one it reads
        // input from. We keep the far end of each.
        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;
        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        if (!CreatePipe(&out_read, &out_write, null, OUT_PIPE_BYTES).toBool()) return error.OpenPtyFailed;
        errdefer _ = CloseHandle(out_read);
        // The input pipe is a named one, unlike the output pipe, because
        // `write` has to be able to give up on it. `CreatePipe` hands back
        // handles that can only be written synchronously, and the only way to
        // ask such a pipe how much room is left is to peek at the end the
        // console host reads from -- which deadlocks: the file system
        // serialises requests per pipe instance, so a peek queues behind the
        // host's own blocking read, and that read finishes only once we have
        // written. `CreateNamedPipeW` takes FILE_FLAG_OVERLAPPED, so the write
        // can be posted and abandoned instead, and the host's end is never
        // touched. The client connects below, which is why no
        // `ConnectNamedPipe` is needed.
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buf,
            "\\\\.\\pipe\\ztabb-in-{d}-{d}",
            .{ GetCurrentProcessId(), pipe_seq.fetchAdd(1, .monotonic) },
        ) catch unreachable;
        var name_w: [96]u16 = undefined;
        const name_len = std.unicode.utf8ToUtf16Le(&name_w, name) catch {
            _ = CloseHandle(out_write);
            return error.OpenPtyFailed;
        };
        name_w[name_len] = 0;
        const name_z: [*:0]const u16 = @ptrCast(&name_w);

        in_write = CreateNamedPipeW(
            name_z,
            PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
            0, // byte stream, blocking mode: the overlapped flag does the waiting
            1,
            IN_PIPE_BYTES,
            0,
            0,
            null,
        );
        if (in_write == INVALID_HANDLE_VALUE) {
            _ = CloseHandle(out_write);
            return error.OpenPtyFailed;
        }
        errdefer _ = CloseHandle(in_write);

        in_read = CreateFileW(name_z, GENERIC_READ, 0, null, OPEN_EXISTING, 0, null);
        if (in_read == INVALID_HANDLE_VALUE) {
            _ = CloseHandle(out_write);
            return error.OpenPtyFailed;
        }

        const in_event = CreateEventW(null, .TRUE, .FALSE, null) orelse {
            _ = CloseHandle(in_read);
            _ = CloseHandle(out_write);
            return error.OpenPtyFailed;
        };
        errdefer _ = CloseHandle(in_event);

        // Our ends must not reach the child, or it inherits a copy of the pipe
        // and the read never reports end of file when the child exits.
        _ = SetHandleInformation(out_read, HANDLE_FLAG_INHERIT, 0);
        _ = SetHandleInformation(in_write, HANDLE_FLAG_INHERIT, 0);

        // The pseudo-console's own ends of the pipes have to outlive the call
        // that creates the child, not merely the one that creates the console.
        // Microsoft's sample is explicit about it -- "close these after
        // CreateProcess of child application with pseudoconsole object" -- and
        // closing them a few lines earlier, as this did, left the client with
        // no console to attach to. It fell back to the one this process already
        // had: its output went to our own stdout, writes to the input pipe
        // reached nobody, and the only thing ever to come back down the pipe
        // was conhost's own sixteen-byte handshake. On a terminal that means a
        // window that shows nothing a program prints.
        // Both of the console's ends close once the child exists. Holding
        // either open for longer keeps a reference on the device, and the
        // documentation is explicit that this stops a broken channel from ever
        // looking broken.
        defer {
            _ = CloseHandle(in_read);
            _ = CloseHandle(out_write);
        }

        var console: HPCON = undefined;
        const size = COORD{ .x = @intCast(@max(cols, 1)), .y = @intCast(@max(rows, 1)) };
        const hr = CreatePseudoConsole(size, in_read, out_write, 0, &console);
        if (hr != 0) return error.OpenPtyFailed;
        errdefer ClosePseudoConsole(console);

        // The pseudo-console reaches the child through a process attribute,
        // which needs a sized buffer allocated before it can be filled in.
        var attr_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
        const attrs_buf = gpa.alignedAlloc(u8, .of(usize), attr_size) catch
            return error.OpenPtyFailed;
        errdefer gpa.free(attrs_buf);
        const attrs: *anyopaque = @ptrCast(attrs_buf.ptr);
        if (!InitializeProcThreadAttributeList(attrs, 1, 0, &attr_size).toBool()) {
            return error.OpenPtyFailed;
        }
        errdefer DeleteProcThreadAttributeList(attrs);
        if (!UpdateProcThreadAttribute(
            attrs,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            console,
            @sizeOf(HPCON),
            null,
            null,
        ).toBool()) return error.OpenPtyFailed;

        var si = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        si.lpAttributeList = attrs;
        // Without this, a console child of a console process whose own std
        // handles are redirected silently inherits those redirected handles
        // instead of the pseudo-console: its output goes to our stdout and the
        // window stays blank. Naming the handles -- and leaving them null --
        // stops that fallback, and the PTY connection remakes the real ones.
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;

        var cmdline: [1024]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&cmdline, std.mem.span(argv[0])) catch
            return error.ForkFailed;
        cmdline[n] = 0;

        var pi = std.mem.zeroes(PROCESS_INFORMATION);
        if (!CreateProcessW(
            null,
            @ptrCast(&cmdline),
            null,
            null,
            .FALSE, // handles reach the child through the attribute, not inheritance
            // Only the flag the pseudo-console needs. This also asked for
            // CREATE_UNICODE_ENVIRONMENT, which describes the encoding of an
            // environment block -- and none is passed here, so it described
            // nothing. Microsoft's sample passes this one flag alone, and that
            // was the last place this call differed from it.
            EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            &si,
            &pi,
        ).toBool()) return error.ForkFailed;

        return .{
            .out_read = out_read,
            .in_write = in_write,
            .in_event = in_event,
            .console = console,
            .process = pi.hProcess,
            .thread = pi.hThread,
            .attrs = attrs,
            .attrs_buf = attrs_buf,
            .gpa = gpa,
            .cols = cols,
            .rows = rows,
        };
    }

    pub fn spawnShell(cols: u16, rows: u16) SpawnError!Pty {
        const argv = [_][*:0]const u8{defaultShell()};
        return spawn(&argv, &.{}, cols, rows);
    }

    /// Reads whatever the child has produced, returning 0 when nothing is
    /// ready.
    ///
    /// The pipe is asked first: a plain `ReadFile` on an empty pipe blocks
    /// until something arrives, which would stall the render loop.
    pub fn read(self: *Pty, buf: []u8) error{Closed}!usize {
        var available: DWORD = 0;
        if (!PeekNamedPipe(self.out_read, null, 0, null, &available, null).toBool()) {
            return error.Closed;
        }
        if (available == 0) return 0;

        var got: DWORD = 0;
        const want: DWORD = @intCast(@min(buf.len, available));
        if (!ReadFile(self.out_read, buf.ptr, want, &got, null).toBool()) return error.Closed;
        if (got == 0) return error.Closed;
        return got;
    }

    /// One attempt at handing bytes over, bounded by WRITE_MS. Returns how
    /// many the child took, which is zero when it is not draining its input.
    ///
    /// A caller that must not lose bytes retries, and between tries it has to
    /// drain this pty's output: a child blocked writing its echo into a pipe
    /// nobody has emptied has stopped reading, and waiting alone never moves it.
    pub fn writeSome(self: *Pty, buf: []const u8) error{Closed}!usize {
        if (buf.len == 0) return 0;
        const want: DWORD = @intCast(@min(buf.len, IN_PIPE_BYTES));
        var ov = OVERLAPPED{ .hEvent = self.in_event };
        _ = ResetEvent(self.in_event);

        var put: DWORD = 0;
        if (WriteFile(self.in_write, buf.ptr, want, &put, @ptrCast(&ov)).toBool()) {
            // Room was there: the write finished inside the call, which is what
            // typing into a healthy child does every time.
            if (put == 0) return error.Closed;
            return put;
        }
        if (GetLastError() != ERROR_IO_PENDING) return error.Closed;

        if (WaitForSingleObject(self.in_event, WRITE_MS) != WAIT_OBJECT_0) {
            // Not draining. Take the write back rather than hold up the caller,
            // and report whatever got through before we gave up.
            _ = CancelIoEx(self.in_write, &ov);
            var cancelled: DWORD = 0;
            _ = GetOverlappedResult(self.in_write, &ov, &cancelled, .TRUE);
            return cancelled;
        }

        var done: DWORD = 0;
        if (!GetOverlappedResult(self.in_write, &ov, &done, .FALSE).toBool()) return error.Closed;
        if (done == 0) return error.Closed;
        return done;
    }

    /// Writes the whole slice, dropping what the child will not take. Right for
    /// a keystroke; `Tabs.writeAll` is the path that does not lose a paste.
    pub fn write(self: *Pty, buf: []const u8) error{Closed}!void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try self.writeSome(buf[off..]);
            if (n == 0) return;
            off += n;
        }
    }

    /// Waits for the child to say something, or for the timeout.
    ///
    /// ConPTY's pipes cannot be waited on the way a descriptor can, so this
    /// polls until the child speaks or the budget runs out.
    ///
    /// Against the clock, not by counting sleeps. `Sleep(1)` does not return in
    /// a millisecond: Windows rounds it up to the timer resolution, about
    /// fifteen, so taking one off the budget per sleep overspent it more than
    /// twenty times over. Asking for six milliseconds after a keystroke -- which
    /// is what the render loop does, so the shell's echo lands in the same frame
    /// as the key -- waited a tenth of a second instead, on the thread that
    /// draws. A test asking for two milliseconds two thousand times took a
    /// minute and a half, which is how this came to light.
    ///
    /// One sleep quantum of overshoot is left, and cannot be helped without
    /// asking the whole system for a finer timer.
    pub fn waitReadable(self: *Pty, timeout_ms: i32) bool {
        const deadline = GetTickCount64() + @as(u64, @intCast(@max(timeout_ms, 0)));
        while (true) {
            var available: DWORD = 0;
            if (!PeekNamedPipe(self.out_read, null, 0, null, &available, null).toBool()) return false;
            if (available > 0) return true;
            if (GetTickCount64() >= deadline) return false;
            Sleep(1);
        }
    }

    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        // Same reasoning as the POSIX side: a resize the child already knows
        // about only makes it redraw.
        if (cols == self.cols and rows == self.rows) return;
        self.cols = cols;
        self.rows = rows;
        const size = COORD{ .x = @intCast(@max(cols, 1)), .y = @intCast(@max(rows, 1)) };
        _ = ResizePseudoConsole(self.console, size);
    }

    /// Reports whether the child has finished, without waiting for it.
    pub fn poll(self: *Pty) bool {
        if (self.exited) return true;
        var code: DWORD = 0;
        if (!GetExitCodeProcess(self.process, &code).toBool()) return false;
        if (code == STILL_ACTIVE) return false;
        self.exited = true;
        self.exit_status = code;
        return true;
    }

    /// Hangs the child up and tears the console down, without ever blocking
    /// indefinitely.
    ///
    /// The order here matters, and it is not the order it reads most naturally
    /// in. `ClosePseudoConsole` waits for the console host to finish flushing
    /// what it has written, and if nobody is draining the output pipe it waits
    /// for ever -- the pipe fills, the host's write blocks, and the close waits
    /// on a write that cannot complete. ztabb drains a bounded amount per frame
    /// on purpose, so a pane being closed usually does have output still in
    /// flight; closing the console first was a deadlock waiting for a busy
    /// pane, on the thread that draws.
    ///
    /// Closing our ends of the pipes first is what lets the host unwind: its
    /// pending writes fail, and the child sees end of file on its input, which
    /// is the hang-up a real terminal performs. Only then is the console itself
    /// closed, and the wait for the child bounded the way the POSIX side is.
    pub fn close(self: *Pty) void {
        if (self.closed) return;
        self.closed = true;

        _ = CloseHandle(self.in_write);
        _ = CloseHandle(self.out_read);
        _ = CloseHandle(self.in_event);
        ClosePseudoConsole(self.console);

        if (!self.exited) {
            if (WaitForSingleObject(self.process, GRACE_MS) != WAIT_OBJECT_0) {
                _ = TerminateProcess(self.process, 1);
                // Bounded even after a kill: a process being torn down by the
                // kernel still takes a moment to become signalled.
                _ = WaitForSingleObject(self.process, GRACE_MS);
            }
            self.exited = true;
        }

        if (self.attrs) |a| DeleteProcThreadAttributeList(a);
        self.gpa.free(self.attrs_buf);
        _ = CloseHandle(self.thread);
        _ = CloseHandle(self.process);
    }
};

/// `%COMSPEC%`, which is where Windows records the command processor, falling
/// back to the name it has always had.
pub fn defaultShell() [*:0]const u8 {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("COMSPEC");
    var wide: [260]u16 = undefined;
    const n = GetEnvironmentVariableW(name, &wide, wide.len);
    if (n == 0 or n >= wide.len) return "cmd.exe";

    const len = std.unicode.utf16LeToUtf8(std.mem.asBytes(&shell_buf), wide[0..n]) catch
        return "cmd.exe";
    const bytes = std.mem.asBytes(&shell_buf);
    if (len >= bytes.len) return "cmd.exe";
    bytes[len] = 0;
    return @ptrCast(bytes.ptr);
}
