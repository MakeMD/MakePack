//! MP-C: one MakePack process per session (Program.cs Main / Send / Serve / Absolute).
//! Explorer runs a verb once per selected item; whoever owns the mutex owns the UI and every other instance
//! hands its argument list over the pipe and leaves.
//!
//! The protocol is an external contract shared with the installed C# build: mutex "MakePack-<session id>"
//! (session namespace, new Mutex(false, name)), pipe \\.\pipe\MakePack-<session id>, one connection per
//! invocation, one UTF-8 line per argument. The C# client writes CRLF (StreamWriter.WriteLine) and its server
//! reads lines like StreamReader (CR, LF or CRLF): accept all three, drop empty lines; send CRLF.
//! No arguments at all = "show me the window".
//! Tests use their own name (main also honours MAKEPACK_INSTANCE) so they never talk to a running MakePack.
const std = @import("std");
const kit = @import("kit");
const pw = @import("platform_win.zig");

const w = kit.w;
const Allocator = std.mem.Allocator;

/// "MakePack-<session id of this process>".
pub fn sessionName(buf: *[32]u8) []const u8 {
    const sid = kit.win.sessionId(w.GetCurrentProcessId()) catch 0;
    return std.mem.print(buf, "MakePack-{d}", .{sid}) catch unreachable; // 9 + at most 10 digits
}

pub const Instance = struct {
    mutex: ?*anyopaque,
    /// This process owns the mutex: it serves the pipe and runs the UI.
    server: bool,

    /// CreateMutexW(name) + WaitForSingleObject(0); an abandoned mutex counts as owned.
    pub fn acquire(name: []const u8) !Instance {
        var buf: [256]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const h = w.CreateMutexW(null, 0, (try kit.win.toW(fba.allocator(), name)).ptr) orelse return error.Unexpected;
        const r = w.WaitForSingleObject(h, 0);
        return .{ .mutex = h, .server = r == w.WAIT_OBJECT_0 or r == w.WAIT_ABANDONED };
    }

    /// Held until the very end of the process: ReleaseMutex (server only; same thread as acquire) + CloseHandle.
    pub fn release(i: *Instance) void {
        const h = i.mutex orelse return;
        if (i.server) _ = w.ReleaseMutex(h);
        _ = w.CloseHandle(h);
        i.mutex = null;
    }
};

fn pipeName(gpa: Allocator, name: []const u8) ![:0]u16 {
    const p = try std.mem.concat(gpa, u8, &.{ "\\\\.\\pipe\\", name });
    defer gpa.free(p);
    return kit.win.toW(gpa, p);
}

/// Program.Send: retries for 1.5 s (each try waits up to 200 ms for a busy pipe, then 50 ms pause). False =
/// nobody answered: the server was on its way out; the caller runs standalone (ponytail from C#: no retry loop).
pub fn send(gpa: Allocator, name: []const u8, args: []const []const u8) bool {
    const pipe = pipeName(gpa, name) catch return false;
    defer gpa.free(pipe);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    for (args) |a| payload.print(gpa, "{s}\r\n", .{a}) catch return false;

    const start = w.GetTickCount64();
    while (w.GetTickCount64() - start < 1500) {
        if (writeOnce(pipe, payload.items)) return true;
        _ = w.WaitNamedPipeW(pipe.ptr, 200); // a busy pipe: wait for a free instance; none at all: returns at once
        w.Sleep(50);
    }
    return false;
}

fn writeOnce(pipe: [:0]const u16, data: []const u8) bool {
    const h = w.CreateFileW(pipe.ptr, @bitCast(@as(i32, w.GENERIC_WRITE)), 0, null, w.OPEN_EXISTING, 0, null);
    if (h == w.INVALID_HANDLE_VALUE) return false;
    defer _ = w.CloseHandle(h);
    var done: usize = 0;
    while (done < data.len) {
        var n: w.DWORD = 0;
        const chunk: w.DWORD = @intCast(@min(data.len - done, 1 << 20));
        if (w.WriteFile(h, data[done..].ptr, chunk, &n, null) == 0) return false;
        done += n;
    }
    return true;
}

/// Gets each forwarded argument list (valid during the call), on the server thread: post it to the UI thread.
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, args: []const []const u8) void,
};

/// Program.Serve: a background thread that accepts connections forever (a failed one: 50 ms pause, go on).
pub fn serve(gpa: Allocator, name: []const u8, handler: Handler) !void {
    // Owned by the thread, which never ends: not from gpa, whose leak check at exit would report it.
    const pipe = try pipeName(std.heap.smp_allocator, name);
    errdefer std.heap.smp_allocator.free(pipe);
    const t = try std.Thread.spawn(.{}, struct {
        fn loop(g: Allocator, p: [:0]const u16, hd: Handler) void {
            while (true) serveOne(g, p, hd) catch w.Sleep(50);
        }
    }.loop, .{ gpa, pipe, handler });
    t.detach();
}

/// One connection: create an instance of the pipe, wait for a client, read to EOF, hand the lines over.
pub fn serveOne(gpa: Allocator, pipe: [:0]const u16, handler: Handler) !void {
    const h = try createPipe(pipe);
    defer _ = w.CloseHandle(h);
    return accept(gpa, h, handler);
}

/// Like .NET's NamedPipeServerStream: byte mode, unlimited instances, remote clients rejected (nobody on the
/// network may hand us arguments); the default DACL lets only this user (and admins) write. First instance only:
/// a name another process already holds (a squatter) fails instead of sharing its clients; overlapped, so a
/// client that never finishes cannot hold the serve thread (accept's read timeout).
pub fn createPipe(pipe: [:0]const u16) !w.HANDLE {
    const mode = w.PIPE_TYPE_BYTE | w.PIPE_WAIT | w.PIPE_REJECT_REMOTE_CLIENTS;
    const open = w.PIPE_ACCESS_INBOUND | w.FILE_FLAG_FIRST_PIPE_INSTANCE | w.FILE_FLAG_OVERLAPPED;
    const h = w.CreateNamedPipeW(pipe.ptr, open, mode, w.PIPE_UNLIMITED_INSTANCES, 0, 4096, 0, null);
    if (h == w.INVALID_HANDLE_VALUE) return error.PipeFailed;
    return h;
}

/// The arguments of one invocation never come near this (a command line is at most 32k characters).
const max_payload = 1 << 20;
/// From connect to the client's close; send() writes its whole list at once, so this is only ever hit by a client
/// that hangs (the serve thread then drops it and takes the next one).
const read_timeout_ms = 5000;

/// Waits for an overlapped call on `h` up to `ms`; false = failed or timed out (then cancelled and drained).
/// `n` = bytes moved. A closed client (broken pipe / no data) counts as done with n = 0.
fn finish(h: w.HANDLE, ov: *w.OVERLAPPED, ms: u32, n: *w.DWORD) bool {
    if (w.WaitForSingleObject(ov.hEvent, ms) != w.WAIT_OBJECT_0) {
        _ = w.CancelIoEx(h, ov);
        _ = w.GetOverlappedResult(h, ov, n, 1);
        return false;
    }
    if (w.GetOverlappedResult(h, ov, n, 0) != 0) return true;
    n.* = 0;
    const e = w.GetLastError();
    return e == w.ERROR_BROKEN_PIPE or e == w.ERROR_NO_DATA;
}

/// Waits for the client on `h` (an instance from createPipe), reads to EOF, hands the lines over.
pub fn accept(gpa: Allocator, h: w.HANDLE, handler: Handler) !void {
    // A client that connected before this call: ERROR_PIPE_CONNECTED; one that also wrote its list and closed
    // already: ERROR_NO_DATA - its bytes are still buffered (WaitForConnectionAsync counts both as connected).
    const ev = w.CreateEventW(null, 1, 0, null) orelse return error.PipeFailed;
    defer _ = w.CloseHandle(ev);
    var ov: w.OVERLAPPED = std.mem.zeroes(w.OVERLAPPED);
    ov.hEvent = ev;
    var n: w.DWORD = 0;
    if (w.ConnectNamedPipe(h, &ov) == 0) switch (w.GetLastError()) {
        w.ERROR_PIPE_CONNECTED, w.ERROR_NO_DATA => {},
        w.ERROR_IO_PENDING => if (!finish(h, &ov, w.INFINITE, &n)) return error.PipeFailed,
        else => return error.PipeFailed,
    };
    defer _ = w.DisconnectNamedPipe(h);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    var buf: [4096]u8 = undefined;
    const deadline = w.GetTickCount64() + read_timeout_ms;
    while (true) {
        n = 0;
        if (w.ReadFile(h, &buf, buf.len, &n, &ov) == 0) switch (w.GetLastError()) {
            w.ERROR_BROKEN_PIPE, w.ERROR_NO_DATA => break, // the client closed: end of its list
            w.ERROR_IO_PENDING => {
                const left: u32 = @intCast(deadline -| w.GetTickCount64());
                if (!finish(h, &ov, left, &n)) return error.PipeFailed;
            },
            else => return error.PipeFailed,
        };
        if (n == 0) break;
        if (got.items.len + n > max_payload) return error.PipeFailed;
        try got.appendSlice(gpa, buf[0..n]);
    }
    const args = try splitLines(gpa, got.items);
    defer gpa.free(args);
    handler.f(handler.ctx, args); // no arguments at all = "show me the window"
}

/// StreamReader.ReadLine semantics (CR, LF or CRLF end a line), empty lines dropped. Slices of `data`.
pub fn splitLines(gpa: Allocator, data: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, data, "\r\n");
    while (it.next()) |line| try list.append(gpa, line);
    return list.toOwnedSlice(gpa);
}

/// Program.Absolute: Explorer's working directory is not the one a shell hands us, so paths travel absolute.
/// Leaves the verb (x, a, convert), the switches (--here --sub -o --profile --quick) and a --profile's name.
/// The result and the new strings are allocated with `gpa` (main passes its arena).
pub fn absolute(gpa: Allocator, args: []const []const u8) ![]const []const u8 {
    const copy = try gpa.dupe([]const u8, args);
    for (copy, 0..) |arg, i| {
        const keep = if (i == 0) isAny(arg, &.{ "x", "a", "convert" }) else isAny(arg, &.{ "--here", "--sub", "-o", "--profile", "--quick" });
        if (keep) continue;
        if (i > 0 and std.mem.eql(u8, copy[i - 1], "--profile")) continue; // a profile name, not a path
        if (pw.isRooted(arg)) continue;
        copy[i] = pw.fullPath(gpa, arg) catch continue; // not a path after all
    }
    return copy;
}

fn isAny(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

test "contract compiles" {
    @import("../testutil.zig").refAllDeep(@This(), 2);
}
