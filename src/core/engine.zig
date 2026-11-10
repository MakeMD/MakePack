//! MP-B: Engine.cs - open / probe / extract / test / compress / convert / edit-in-place / report, on the direct
//! 7z.dll binding (sevenzip.zig). The selftest (src/selftest.zig) drives all of it end to end.
//!
//! Conventions: `gpa` allocates every result (pass an arena for multi-part results: rows, plans); `io` for file
//! access; long operations take a Progress (report + cancel flag) and an optional *Diag for the message details.
//! Every guard and trap of Engine.cs comes along: zip-slip, broken-file removal, MotW marking even on failure,
//! the .makepack~ hardlink backup on edits, stale .NNN parts, half-written archives deleted, sources recycled only
//! after a clean (tested) write, encrypted -> never converted to a password-less format.
//! Gone with SevenZipSharp: reflection PackedSizes (Item.packed_size), apartment-bound Reopen, the doubled volume
//! callback (we glue .001 sets ourselves, as C# did), temp-delete-original-in-finally (update() never touches
//! the original; the .makepack~ backup stays anyway).
//!
//! Threads (for the GUI phase): Progress.report, Conflict.ask and the cancel flag are called on 7z.dll's worker
//! threads (small stacks) and block 7z.dll while they run. A GUI must not open a modal from them: post the question
//! to the UI thread and wait on an event (Conflict.ask may block that long; Progress.report must return at once).
//! Paths: every Win32 file helper here takes long paths (>= 248 UTF-16 units get the \\?\ prefix, as .NET did), so
//! nothing depends on the longPathAware manifest + LongPathsEnabled. Exception: recycle (SHFileOperationW has no
//! long-path support at all).
const std = @import("std");
const kit = @import("kit");
const types = @import("types.zig");
const sevenzip = @import("sevenzip.zig");
const S = @import("../strings.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const w = kit.w;
const fspath = Io.Dir.path;
const eqlI = types.eqlIgnoreCase;

// ---- the shared data contract (src/core/types.zig), re-exported -----------------------------------

pub const OverwriteMode = types.OverwriteMode;
pub const MotwPolicy = types.MotwPolicy;
pub const UpdateMode = types.UpdateMode;
pub const DeleteAfter = types.DeleteAfter;
pub const ArchiveKind = types.ArchiveKind;
pub const CompressionLevel = types.CompressionLevel;
pub const CompressionMethod = types.CompressionMethod;
pub const OutFormat = types.OutFormat;
pub const KindInfo = types.KindInfo;
pub const CompressOptions = types.CompressOptions;
pub const ExtractOptions = types.ExtractOptions;
/// Engine.Kinds / Engine.Kind
pub const kinds = types.kinds;
pub const kind = types.kind;
/// Engine.ParseSize (ported in types.zig: settings.zig needs it too)
pub const parseSize = types.parseSize;

/// Engine.Probe's answer (the C# enum Probe): what the bytes of a file say it is.
pub const ProbeResult = enum { not_archive, damaged, archive, encrypted_headers };

// ---- errors (replace the string-matched exceptions) -------------------------------------------------

/// Every failure a user can see. The comment is the C# exception, the OtherArc exit code (exitCodeOf) and
/// the message (friendly). "diag" = the message has arguments: the thrower fills a Diag.
/// Errors from std (AccessDenied, FileBusy, NoSpaceLeft...) pass through: exit 2, their name as the message.
pub const Error = error{
    /// OperationCanceledException - 255 - S.cancelled
    Canceled,
    /// WarningException - 1 - diag: S.unsafeSkippedFmt (count)
    UnsafeEntriesSkipped,
    /// InvalidDataException(S.WrongPassword) / SevenZipException "password" - 11
    WrongPassword,
    /// 11 - S.dataErrorEncrypted (a data/CRC error in an encrypted file: most likely a wrong password)
    DataErrorEncrypted,
    /// 11 - S.passwordNeeded
    PasswordNeeded,
    /// 11 - S.passwordsDiffer
    PasswordsDiffer,
    /// InvalidDataException(S.Damaged) / SevenZipArchiveException (the open failed) - 3
    Damaged,
    /// 3 - S.testAfterFailed
    TestAfterFailed,
    /// 3 - S.convertMismatch
    ConvertMismatch,
    /// 3 - S.unsupportedMethod
    UnsupportedMethod,
    /// Explain's fallback for extract/test: 3 - diag: S.operationFailed + ": " + 7z.dll's text
    ArchiveFailed,
    /// ArgumentException "no corresponding signature" / IOException(S.NotAnArchive) - 2 - S.notAnArchive
    NotAnArchive,
    /// ArgumentException from Cli - 7 - diag: S.cliBadSwitchFmt (the switch)
    BadSwitch,
    /// ArgumentException from Cli.Bad("-p...") - 7 - S.cliPasswordInArgs
    PasswordInArgs,
    /// ArgumentException(S.CliNoPasswordFmt) - 7 - diag: format name
    NoPasswordForFormat,
    /// ArgumentException from Apply/Compress ("method X is not valid for Zip", SFX/ZipCrypto/volume checks) - 7 - diag
    InvalidOption,
    /// FileNotFound/DirectoryNotFoundException - 10 - diag: S.fileNotFoundFmt / S.cliNoMatchFmt
    FileNotFound,
    /// InvalidOperationException(S.NoInputs) - 10
    NoInputs,
    /// InvalidOperationException(S.SingleFileOnly) - 2
    SingleFileOnly,
    /// InvalidOperationException(S.DictionaryTooBigFmt) - 2 - diag
    DictionaryTooBig,
    /// InvalidOperationException(S.ArchiveInsideSources) - 2
    ArchiveInsideSources,
    /// InvalidOperationException(S.NotSupported) - 2
    NotSupported,
    /// InvalidOperationException(S.ConvertWouldDecryptFmt) - 2 - diag
    ConvertWouldDecrypt,
    /// IOException(S.RecycleFailedFmt) - 2 - diag (the code)
    RecycleFailed,
    /// IOException(S.CliExistsFmt) - 2 - diag (the path)
    AlreadyExists,
    /// Other SevenZipException (compress/update) - 2 - diag: S.operationFailed + ": " + text
    OperationFailed,
};

/// Engine.ExitCodeOf - codes: 0 OK, 1 warning, 2 fatal, 3 CRC/damaged, 7 bad switch, 10 no files,
/// 11 password, 255 cancelled.
pub fn exitCodeOf(err: anyerror) u8 {
    return switch (err) {
        error.Canceled => 255,
        error.UnsafeEntriesSkipped => 1,
        error.WrongPassword, error.DataErrorEncrypted, error.PasswordNeeded, error.PasswordsDiffer => 11,
        error.Damaged, error.TestAfterFailed, error.ConvertMismatch, error.UnsupportedMethod, error.ArchiveFailed => 3,
        error.BadSwitch, error.PasswordInArgs, error.NoPasswordForFormat, error.InvalidOption => 7,
        error.FileNotFound, error.NoInputs => 10,
        else => 2,
    };
}

/// The details of one failure (the C# exception message's arguments: a path, a count, 7z.dll's or Windows'
/// text), already filled into the complete localized message. The caller owns one per operation.
pub const Diag = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    /// Sets the message from a strings template ("{0}" placeholders, see strings.write). Null-safe.
    pub fn set(d: ?*Diag, template: []const u8, args: anytype) void {
        const self = d orelse return;
        var wr: Io.Writer = .fixed(&self.buf);
        S.write(&wr, template, args) catch {}; // cut short when longer than the buffer
        self.len = wr.buffered().len;
    }

    pub fn text(d: *const Diag) ?[]const u8 {
        return if (d.len > 0) d.buf[0..d.len] else null;
    }
};

/// Engine.Friendly - the words for the user: the Diag's message when the thrower left one, else the fixed
/// message of the error; Windows' own (localised) text for std's file errors, as C#'s ex.Message was. The result
/// is valid until the next friendly() on this thread.
pub fn friendly(err: anyerror, diag: ?*const Diag) []const u8 {
    if (diag) |d| if (d.text()) |t| return t;
    return switch (err) {
        error.Canceled => S.cancelled.get(),
        error.WrongPassword => S.wrongPassword.get(),
        error.DataErrorEncrypted => S.dataErrorEncrypted.get(),
        error.PasswordNeeded => S.passwordNeeded.get(),
        error.PasswordsDiffer => S.passwordsDiffer.get(),
        error.Damaged => S.damaged.get(),
        error.TestAfterFailed => S.testAfterFailed.get(),
        error.ConvertMismatch => S.convertMismatch.get(),
        error.UnsupportedMethod => S.unsupportedMethod.get(),
        error.NotAnArchive => S.notAnArchive.get(),
        error.PasswordInArgs => S.cliPasswordInArgs.get(),
        error.NoInputs => S.noInputs.get(),
        error.SingleFileOnly => S.singleFileOnly.get(),
        error.ArchiveInsideSources => S.archiveInsideSources.get(),
        error.NotSupported => S.notSupported.get(),
        error.ArchiveFailed, error.OperationFailed => S.operationFailed.get(),
        else => {
            if (winCode(err)) |code| if (sysMessage(&friendly_buf, code)) |m| return m;
            // ponytail: an error std names but Windows has no code for: "operation failed: <name>"
            return std.mem.print(&friendly_buf, "{s}: {s}", .{ S.operationFailed.get(), @errorName(err) }) catch S.operationFailed.get();
        },
    };
}

threadlocal var friendly_buf: [1536]u8 = undefined;
/// The Win32 code behind the last error.Unexpected that winErr made on this thread.
threadlocal var last_win_error: u32 = 0;

/// std's file errors -> the Win32 code whose system message says the same.
fn winCode(err: anyerror) ?u32 {
    return switch (err) {
        error.FileNotFound => 2,
        error.AccessDenied, error.PermissionDenied => 5,
        error.FileBusy => 32,
        error.PathAlreadyExists => 183,
        error.NoSpaceLeft => 112,
        error.DiskQuota => 1295,
        error.NameTooLong => 206,
        error.BadPathName => 123,
        error.NotDir => 267,
        error.DirNotEmpty => 145,
        error.OutOfMemory, error.SystemResources => 8,
        error.InputOutput => 1117,
        error.NetworkNotFound => 53,
        error.Unexpected => if (last_win_error != 0) last_win_error else null,
        else => null,
    };
}

/// Windows' text for a Win32 code or HRESULT, in the user's UI language, trimmed; null when it has none.
fn sysMessage(buf: []u8, code: u32) ?[]const u8 {
    var wbuf: [512]u16 = undefined;
    const flags: w.DWORD = w.FORMAT_MESSAGE_FROM_SYSTEM | w.FORMAT_MESSAGE_IGNORE_INSERTS;
    const n = w.FormatMessageW(flags, null, code, 0, &wbuf, wbuf.len, null);
    if (n == 0 or buf.len < 3 * n) return null;
    return std.mem.trim(u8, buf[0..std.unicode.wtf16LeToWtf8(buf, wbuf[0..n])], " \r\n.");
}

/// "operation failed: <Windows' text for the last 7z.dll HRESULT>" into the Diag.
fn failText(diag: ?*Diag) void {
    const hr: u32 = @bitCast(sevenzip.last_hr);
    var tbuf: [1536]u8 = undefined;
    const msg: []const u8 = sysMessage(&tbuf, hr) orelse (std.mem.print(&tbuf, "0x{X:0>8}", .{hr}) catch "");
    var fmt: [64]u8 = undefined;
    Diag.set(diag, std.mem.print(&fmt, "{s}: {{0}}", .{S.operationFailed.get()}) catch "{0}", .{msg});
}

// ---- progress and prompts ---------------------------------------------------------------------------

/// IProgress<(int percent, string file)> and the CancellationToken in one value.
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    /// Percent 0..100 and the current entry. ponytail rule from C#: report once per percent change, not per
    /// 7z.dll callback, or the UI thread starves.
    report: ?*const fn (ctx: ?*anyopaque, percent: u8, file: []const u8) void = null,
    /// Set from any thread to cancel; the operation ends with error.Canceled.
    cancel: ?*const std.atomic.Value(bool) = null,

    /// Engine.NoProgress
    pub const none: Progress = .{};

    pub fn cancelled(p: Progress) bool {
        return if (p.cancel) |c| c.load(.acquire) else false;
    }

    pub fn send(p: Progress, percent: u8, file: []const u8) void {
        if (p.report) |f| f(p.ctx, percent, file);
    }
};

/// Engine.Scaled: a slice lo..hi of another progress (convert's phases, a series of archives).
const Scaled = struct {
    to: Progress,
    lo: u8,
    hi: u8,

    fn progress(s: *const Scaled) Progress {
        return .{ .ctx = @constCast(s), .report = scaledReport, .cancel = s.to.cancel };
    }

    fn scaledReport(ctx: ?*anyopaque, percent: u8, file: []const u8) void {
        const s: *const Scaled = @ptrCast(@alignCast(ctx));
        s.to.send(s.lo + @as(u8, @intCast(@as(u32, percent) * (s.hi - s.lo) / 100)), file);
    }
};

/// 7z.dll's byte counts -> one report per percent (of lo..hi), the cancel flag -> "stop".
/// Called from one 7z.dll thread at a time.
const Ticker = struct {
    to: Progress,
    lo: u8 = 0,
    hi: u8 = 100,
    last: i16 = -1,
    name: [512]u8 = undefined,
    name_len: usize = 0,

    fn sz(t: *Ticker) sevenzip.Progress {
        return .{ .ctx = t, .step = step, .item = item };
    }

    fn current(t: *const Ticker) []const u8 {
        return t.name[0..t.name_len];
    }

    fn setCurrent(t: *Ticker, n: []const u8) void {
        var len = @min(n.len, t.name.len);
        while (len < n.len and len > 0 and n[len] & 0xC0 == 0x80) len -= 1; // cut before a codepoint, not inside one
        t.name_len = len;
        @memcpy(t.name[0..len], n[0..len]);
    }

    fn step(ctx: ?*anyopaque, done: u64, total: u64) bool {
        const t: *Ticker = @ptrCast(@alignCast(ctx));
        if (t.to.cancelled()) return false;
        const pct: u64 = if (total == 0) 0 else @intCast(@min(100, @as(u128, done) * 100 / total));
        const p: u8 = t.lo + @as(u8, @intCast(pct * (t.hi - t.lo) / 100));
        if (p != t.last) {
            t.last = p;
            t.to.send(p, t.current());
        }
        return true;
    }

    fn item(ctx: ?*anyopaque, n: []const u8) void {
        const t: *Ticker = @ptrCast(@alignCast(ctx));
        t.setCurrent(n);
    }
};

/// Func<string, OverwriteMode?>: asked about one clash (the target path, or the entry name for Append);
/// null = the user cancelled. Extract asks only while the mode is Ask.
pub const Conflict = struct {
    ctx: ?*anyopaque = null,
    ask: *const fn (ctx: ?*anyopaque, path: []const u8) ?OverwriteMode,

    /// `_ => OverwriteMode.Overwrite`
    pub const always_overwrite: Conflict = .{ .ask = struct {
        fn f(_: ?*anyopaque, _: []const u8) ?OverwriteMode {
            return .Overwrite;
        }
    }.f };
};

// ---- the open archive -------------------------------------------------------------------------------

/// An opened archive. For x.tar.gz the binding holds the inner .tar (see open). Owns its strings.
pub const Archive = struct {
    gpa: Allocator,
    io: Io,
    x: *sevenzip.InArchive,
    /// What the user opened.
    source: []const u8,
    /// What the binding has open (a temp .tar when nested, the joined file of a .001 set).
    open_path: []const u8,
    password: ?[]const u8,
    /// Set when the binding holds a temp file (nested, or a joined .001 set); removed on close.
    temp_dir: ?[]const u8,

    /// C# Nested => TempDir != null (a joined .001 set counts too: it is not the file on disk).
    pub fn nested(a: *const Archive) bool {
        return a.temp_dir != null;
    }

    /// The file name the user knows it by.
    pub fn display(a: *const Archive) []const u8 {
        return fspath.basename(a.source);
    }

    pub fn items(a: *const Archive) []const sevenzip.Item {
        return a.x.items;
    }

    /// Dispose: closes the binding, removes temp_dir, frees `a`.
    pub fn close(a: *Archive) void {
        a.x.close();
        if (a.temp_dir) |d| {
            nuke(a.io, d);
            forget(d);
            a.gpa.free(d);
        }
        a.gpa.free(a.source);
        a.gpa.free(a.open_path);
        if (a.password) |p| a.gpa.free(p);
        a.gpa.destroy(a);
    }
};

/// One row of the Info window / report header.
pub const Row = struct { label: []const u8, value: []const u8 };

/// One archive of PlanSeparate.
pub const Planned = struct { input: []const u8, output: []const u8 };

// ---- lifetime ---------------------------------------------------------------------------------------

/// Process-wide state: the folder of 7z.dll / 7z.sfx and the temp dirs handed out (Engine.Temps).
var exe_dir_buf: [2048]u8 = undefined;
var exe_dir: []const u8 = "";
var temps: std.ArrayList([]u8) = .empty;
var temps_lock: kit.win.Lock = .{};
const scratch = std.heap.smp_allocator;

/// The static constructor: loads "<exe_dir>\7z.dll" (tests: paths.seven_zip_dll's folder). Repeatable.
pub fn init(gpa: Allocator, io: Io, dir: []const u8) anyerror!void {
    _ = .{ gpa, io };
    if (dir.len + 8 > exe_dir_buf.len) return error.NameTooLong;
    @memcpy(exe_dir_buf[0..dir.len], dir);
    exe_dir = exe_dir_buf[0..dir.len];
    var buf: [2100]u8 = undefined;
    try sevenzip.load(try std.mem.print(&buf, "{s}\\7z.dll", .{std.mem.trimEnd(u8, dir, "\\/")}));
}

/// ProcessExit: removes every temp dir newTempDir handed out that is still there.
pub fn deinit(io: Io) void {
    temps_lock.lock();
    defer temps_lock.unlock();
    for (temps.items) |t| {
        nuke(io, t);
        scratch.free(t);
    }
    temps.clearAndFree(scratch);
}

fn forget(dir: []const u8) void {
    temps_lock.lock();
    defer temps_lock.unlock();
    for (temps.items, 0..) |t, i| if (std.mem.eql(u8, t, dir)) {
        scratch.free(temps.swapRemove(i));
        return;
    };
}

/// Selftest only: damages the fresh archive between write and test (a bad disk).
pub var before_test_hook: ?*const fn (path: []const u8) void = null;

// ---- names and paths --------------------------------------------------------------------------------

const tarball_exts = [_][]const u8{ ".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz" };

/// parts.7z.001: the first slice of a split set.
fn isFirstPart(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".001");
}

/// Path.GetFileNameWithoutExtension (of a name: everything before the last dot).
fn withoutExt(name: []const u8) []const u8 {
    const b = fspath.basename(name);
    return if (std.mem.findScalarLast(u8, b, '.')) |i| b[0..i] else b;
}

/// Path.GetExtension without the dot ("" when none, or when the name ends with the dot).
fn extOf(name: []const u8) []const u8 {
    const b = fspath.basename(name);
    const i = std.mem.findScalarLast(u8, b, '.') orelse return "";
    return b[i + 1 ..];
}

/// Engine.BaseName: "x.tar.gz" -> "x", "x.zip" -> "x" (a slice of `file_name`'s last component).
pub fn baseName(file_name: []const u8) []const u8 {
    const n = fspath.basename(file_name);
    for (tarball_exts) |e| if (std.ascii.endsWithIgnoreCase(n, e)) return n[0 .. n.len - e.len];
    return withoutExt(n);
}

/// Engine.Part: name.001, name.002... (7-Zip's split numbering, at least 3 digits).
pub fn part(gpa: Allocator, path: []const u8, n: u32) ![]u8 {
    return gpa.print("{s}.{d:0>3}", .{ path, n });
}

/// Engine.SamePath: full paths equal, OrdinalIgnoreCase.
pub fn samePath(a: []const u8, b: []const u8) bool {
    const fa = fullPath(scratch, a) catch return false;
    defer scratch.free(fa);
    const fb = fullPath(scratch, b) catch return false;
    defer scratch.free(fb);
    return eqlI(fa, fb);
}

/// Engine.Norm: entry name for display - forward slashes, no trailing slash, no leading "./".
pub fn norm(gpa: Allocator, name: []const u8) ![]u8 {
    const n = try gpa.dupe(u8, name);
    std.mem.replaceScalar(u8, n, '\\', '/');
    var s: []const u8 = std.mem.trimEnd(u8, n, "/");
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    if (std.mem.eql(u8, s, ".")) s = "";
    std.mem.copyForwards(u8, n, s);
    return gpa.realloc(n, s.len);
}

/// Engine.Unique: "name (2).ext", "name (3).ext"... the first that does not exist.
pub fn unique(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    _ = io;
    const dir = fspath.dirname(path) orelse "";
    const b = fspath.basename(path);
    const stem = withoutExt(b);
    const ext = b[stem.len..];
    var i: u32 = 2;
    while (true) : (i += 1) {
        const p = if (dir.len > 0) try gpa.print("{s}\\{s} ({d}){s}", .{ std.mem.trimEnd(u8, dir, "\\"), stem, i, ext }) else try gpa.print("{s} ({d}){s}", .{ stem, i, ext });
        if (!fileExists(p)) return p;
        gpa.free(p);
    }
}

/// "0.#" / "0.##" with the user's decimal separator (half away from zero, as .NET formats).
fn fixed(wr: *Io.Writer, v: f64, digits: u8) !void {
    const scale: u64 = if (digits == 1) 10 else 100;
    const n: u64 = @round(v * @as(f64, @floatFromInt(scale)));
    var frac = n % scale;
    try wr.print("{d}", .{n / scale});
    if (frac == 0) return;
    var d = digits;
    if (d == 2 and frac % 10 == 0) {
        frac /= 10;
        d = 1;
    }
    try wr.writeAll(S.decimal_sep);
    if (d == 2) try wr.print("{d:0>2}", .{frac}) else try wr.print("{d}", .{frac});
}

/// Engine.NiceSize: "512 B", "1,5 KB", "2,25 GB" (decimal separator of the user's culture: strings.decimal_sep).
pub fn niceSize(buf: *[32]u8, bytes: i64) []const u8 {
    var wr: Io.Writer = .fixed(buf);
    const b: f64 = @floatFromInt(bytes);
    if (bytes < 1024) {
        wr.print("{d} B", .{bytes}) catch {};
    } else if (bytes < 1 << 20) {
        fixed(&wr, b / 1024.0, 1) catch {};
        wr.writeAll(" KB") catch {};
    } else if (bytes < 1 << 30) {
        fixed(&wr, b / (1024.0 * 1024.0), 1) catch {};
        wr.writeAll(" MB") catch {};
    } else {
        fixed(&wr, b / (1024.0 * 1024.0 * 1024.0), 2) catch {};
        wr.writeAll(" GB") catch {};
    }
    return wr.buffered();
}

/// Engine.Size7z: 7-Zip size syntax with the unit always spelled out ("64m", "1536k", "1000b").
pub fn size7z(buf: *[32]u8, bytes: i64) []const u8 {
    return (if (@mod(bytes, 1 << 20) == 0)
        std.mem.print(buf, "{d}m", .{bytes >> 20})
    else if (@mod(bytes, 1024) == 0)
        std.mem.print(buf, "{d}k", .{bytes >> 10})
    else
        std.mem.print(buf, "{d}b", .{bytes})) catch unreachable;
}

/// Engine.DefaultArchivePath: one archive of all inputs - named after the single input or the folder they
/// share; next to them, or in `folder` when it exists.
pub fn defaultArchivePath(gpa: Allocator, io: Io, inputs: []const []const u8, ext: []const u8, folder: ?[]const u8) ![]u8 {
    _ = io;
    if (inputs.len == 0) return gpa.dupe(u8, "");
    const first = try fullPath(scratch, std.mem.trimEnd(u8, inputs[0], "\\/"));
    defer scratch.free(first);
    const parent = fspath.dirname(first) orelse first;
    var name: []const u8 = if (inputs.len == 1)
        (if (dirExists(first)) fspath.basename(first) else withoutExt(first))
    else
        fspath.basename(parent);
    if (name.len == 0) name = S.app;
    const into = if (folder != null and dirExists(folder.?)) folder.? else parent;
    return joinName(gpa, into, name, ext);
}

/// Path.Combine(dir, name + ext) without doubling a root's backslash.
fn joinName(gpa: Allocator, dir: []const u8, name: []const u8, ext: []const u8) ![]u8 {
    const sep: []const u8 = if (dir.len == 0 or fspath.isSep(dir[dir.len - 1])) "" else "\\";
    return std.mem.concat(gpa, u8, &.{ dir, sep, name, ext });
}

/// Engine.PlanSeparate: one archive per input; clashing names keep their whole name, then " (2)", " (3)".
pub fn planSeparate(gpa: Allocator, io: Io, inputs: []const []const u8, ext: []const u8, folder: ?[]const u8) ![]Planned {
    _ = io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const into: ?[]const u8 = if (folder != null and dirExists(folder.?)) folder.? else null;
    const Parts = struct { dir: []const u8, name: []const u8 };
    const parts = struct {
        fn f(a: Allocator, input: []const u8, whole: bool, to: ?[]const u8) !Parts {
            const full = try fullPath(a, std.mem.trimEnd(u8, input, "\\/"));
            var name: []const u8 = if (dirExists(full) or whole) fspath.basename(full) else withoutExt(full);
            if (name.len == 0) name = fspath.basename(full); // ".gitignore"
            if (name.len == 0) name = S.app; // a drive root
            return .{ .dir = to orelse (fspath.dirname(full) orelse full), .name = name };
        }
    }.f;
    const keys = try ar.alloc([]u8, inputs.len);
    for (inputs, keys) |in, *k| {
        const p = try parts(ar, in, false, into);
        k.* = try joinName(ar, p.dir, p.name, ext);
    }
    const plan = try gpa.alloc(Planned, inputs.len);
    var used: std.ArrayList([]const u8) = .empty;
    for (inputs, 0..) |in, i| {
        var clash = false;
        for (keys, 0..) |k, j| if (j != i and eqlI(k, keys[i])) {
            clash = true;
        };
        const p = try parts(ar, in, clash, into);
        var out = try joinName(gpa, p.dir, p.name, ext);
        var n: u32 = 2;
        while (isUsed(used.items, out)) : (n += 1) {
            gpa.free(out);
            const nm = try ar.print("{s} ({d})", .{ p.name, n });
            out = try joinName(gpa, p.dir, nm, ext);
        }
        try used.append(ar, out);
        plan[i] = .{ .input = try gpa.dupe(u8, in), .output = out };
    }
    return plan;
}

fn isUsed(list: []const []const u8, s: []const u8) bool {
    for (list) |u| if (eqlI(u, s)) return true;
    return false;
}

/// "%TEMP%\MakePack" (GetTempPathW, no trailing backslash) into `buf`.
fn tempRoot(buf: *[w.MAX_PATH * 3 + 16]u8) ![]const u8 {
    var wbuf: [w.MAX_PATH + 1]u16 = undefined;
    const n = w.GetTempPathW(wbuf.len, &wbuf);
    if (n == 0 or n > wbuf.len) return error.Unexpected;
    var tbuf: [w.MAX_PATH * 3]u8 = undefined;
    const tmp = std.mem.trimEnd(u8, tbuf[0..std.unicode.wtf16LeToWtf8(&tbuf, wbuf[0..n])], "\\");
    return std.mem.print(buf, "{s}\\MakePack", .{tmp});
}

/// Engine.NewTempDir: %TEMP%\MakePack\<guid>, remembered for deinit.
pub fn newTempDir(gpa: Allocator, io: Io) ![]u8 {
    var rb: [w.MAX_PATH * 3 + 16]u8 = undefined;
    const root = try tempRoot(&rb);
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    const d = try gpa.print("{s}\\{x}", .{ root, &rnd });
    errdefer gpa.free(d);
    try Io.Dir.cwd().createDirPath(io, d);
    temps_lock.lock();
    defer temps_lock.unlock();
    try temps.append(scratch, try scratch.dupe(u8, d));
    return d;
}

/// GUI startup: the temp dirs that killed runs left in %TEMP%\MakePack, once untouched for a day. One a running
/// MakePack still uses is kept: Windows refuses to rename a folder while a file in it is open (7z.dll holds the
/// nested .tar / joined .001 it lists), so each is renamed before it is deleted.
// ponytail: a temp file an external viewer keeps open without a lock for a day can go; C# had no sweep at all.
pub fn sweepStaleTemps(io: Io) void {
    var rb: [w.MAX_PATH * 3 + 16]u8 = undefined;
    sweepDir(io, tempRoot(&rb) catch return, 24 * 3600);
}

fn sweepDir(io: Io, root: []const u8, max_age_s: i64) void {
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const cutoff = Io.Timestamp.now(io, .real).toSeconds() - max_age_s;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (st.mtime.toSeconds() > cutoff) continue;
        var nb: [300]u8 = undefined;
        // a "-gone" folder is one an earlier sweep renamed but could not finish deleting
        const gone = if (std.mem.endsWith(u8, e.name, "-gone")) e.name else blk: {
            const g = std.mem.print(&nb, "{s}-gone", .{e.name}) catch continue;
            dir.rename(e.name, dir, g, io) catch continue; // in use
            break :blk g;
        };
        dir.deleteTree(io, gone) catch {};
    }
}

test "sweepDir: stale temp dirs go, one with an open file stays" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "old/sub");
    try tmp.dir.createDirPath(io, "busy");
    try tmp.dir.writeFile(io, .{ .sub_path = "busy/x.tar", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const held = try tmp.dir.openFile(io, "busy/x.tar", .{});
    sweepDir(io, root, 3600); // nothing is an hour old yet
    try tmp.dir.access(io, "old", .{});
    sweepDir(io, root, -60); // everything counts as stale
    held.close(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "old", .{}));
    try tmp.dir.access(io, "busy/x.tar", .{});
}

/// Engine.Nuke: delete a folder tree, ignoring every error.
pub fn nuke(io: Io, dir: []const u8) void {
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

/// Engine.TryDelete: delete a file, ignoring every error.
// Win32 with heap paths, not std: it also runs inside 7z.dll callbacks, on its small-stack worker threads
// (std's Windows path calls put a 64 KB PathSpace on the stack).
pub fn tryDelete(io: Io, file: []const u8) void {
    _ = io;
    const wp = wide(file) catch return;
    defer scratch.free(wp);
    _ = w.DeleteFileW(wp.ptr);
}

/// Directory.CreateDirectory (heap paths: safe on 7z.dll's worker threads, see tryDelete).
fn mkdirs(path: []const u8) !void {
    const wp = try wide(path);
    defer scratch.free(wp);
    if (w.CreateDirectoryW(wp.ptr, null) != 0) return;
    switch (w.GetLastError()) {
        w.ERROR_ALREADY_EXISTS => if (!dirExists(path)) return error.PathAlreadyExists,
        w.ERROR_PATH_NOT_FOUND => {
            const parent = fspath.dirname(path) orelse return error.FileNotFound;
            try mkdirs(parent);
            if (w.CreateDirectoryW(wp.ptr, null) == 0 and !dirExists(path)) return winErr(w.GetLastError());
        },
        else => |e| return winErr(e),
    }
}

/// Engine.SfxModule: "<exe dir>\7z.sfx".
pub fn sfxModule(gpa: Allocator) ![]u8 {
    return gpa.print("{s}\\7z.sfx", .{std.mem.trimEnd(u8, exe_dir, "\\/")});
}

// ---- Win32 file helpers (paths the way .NET's File/Directory/Path see them) ----------------------------

/// A path for the Win32 file APIs (scratch-owned): kit.win.longPathW prefixes long ones (>= 248 UTF-16 units)
/// `\\?\` as .NET does, so nothing here depends on the longPathAware manifest + HKLM LongPathsEnabled. Heap only:
/// safe on 7z.dll's small-stack worker threads.
fn wide(p: []const u8) ![:0]u16 {
    return kit.win.longPathW(scratch, p);
}

/// File.Exists / Directory.Exists (long paths too).
pub const fileExists = kit.win.isFile;
pub const dirExists = kit.win.isDir;

/// Path.GetFullPath (GetFullPathNameW: relative to the current directory, "." and ".." folded, trailing
/// dots and spaces of a segment dropped).
pub fn fullPath(gpa: Allocator, p: []const u8) ![]u8 {
    if (p.len == 0) return error.BadPathName;
    const wp = try kit.win.toW(scratch, p); // not wide(): the result must stay a plain path
    defer scratch.free(wp);
    var buf: [1024]u16 = undefined;
    const n = w.GetFullPathNameW(wp.ptr, buf.len, &buf, null);
    if (n == 0) return error.BadPathName;
    if (n < buf.len) return kit.win.fromW(gpa, buf[0..n]);
    const big = try scratch.alloc(u16, n);
    defer scratch.free(big);
    const m = w.GetFullPathNameW(wp.ptr, n, big.ptr, null);
    if (m == 0 or m >= n) return error.BadPathName;
    return kit.win.fromW(gpa, big[0..m]);
}

/// Last write time as FILETIME ticks, null when the file is not there.
fn lastWrite(p: []const u8) ?u64 {
    const wp = wide(p) catch return null;
    defer scratch.free(wp);
    var d: w.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (w.GetFileAttributesExW(wp.ptr, w.GetFileExInfoStandard, &d) == 0) return null;
    return @as(u64, d.ftLastWriteTime.dwHighDateTime) << 32 | d.ftLastWriteTime.dwLowDateTime;
}

fn winErr(code: w.DWORD) anyerror {
    last_win_error = code;
    return switch (code) {
        2, 3 => error.FileNotFound,
        5 => error.AccessDenied,
        32, 33 => error.FileBusy,
        80, 183 => error.PathAlreadyExists,
        39, 112 => error.NoSpaceLeft,
        else => error.Unexpected,
    };
}

/// File.Move(from, to, overwrite)
fn move(from: []const u8, to: []const u8, replace: bool) !void {
    const f = try wide(from);
    defer scratch.free(f);
    const t = try wide(to);
    defer scratch.free(t);
    const flags: w.DWORD = @intCast(w.MOVEFILE_COPY_ALLOWED | w.MOVEFILE_WRITE_THROUGH | (if (replace) w.MOVEFILE_REPLACE_EXISTING else 0));
    if (w.MoveFileExW(f.ptr, t.ptr, flags) == 0) return winErr(w.GetLastError());
}

fn hardLink(link: []const u8, existing: []const u8) !void {
    const l = try wide(link);
    defer scratch.free(l);
    const e = try wide(existing);
    defer scratch.free(e);
    if (w.CreateHardLinkW(l.ptr, e.ptr, null) == 0) return winErr(w.GetLastError());
}

/// A small whole file through Win32 (alternate data streams: "x.7z:Zone.Identifier"), null when absent.
fn readSmall(gpa: Allocator, p: []const u8) ?[]u8 {
    const wp = wide(p) catch return null;
    defer scratch.free(wp);
    const share: w.DWORD = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE;
    const h = w.CreateFileW(wp.ptr, w.GENERIC_READ, share, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return null;
    defer _ = w.CloseHandle(h);
    var size: w.LARGE_INTEGER = undefined;
    if (w.GetFileSizeEx(h, &size) == 0 or size.QuadPart > 1 << 20) return null;
    const buf = gpa.alloc(u8, @intCast(size.QuadPart)) catch return null;
    var got: w.DWORD = 0;
    if (w.ReadFile(h, buf.ptr, @intCast(buf.len), &got, null) == 0 or got != buf.len) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

fn writeSmall(p: []const u8, data: []const u8) !void {
    const wp = try wide(p);
    defer scratch.free(wp);
    const h = w.CreateFileW(wp.ptr, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return winErr(w.GetLastError());
    defer _ = w.CloseHandle(h);
    var put: w.DWORD = 0;
    if (w.WriteFile(h, data.ptr, @intCast(data.len), &put, null) == 0 or put != data.len) return winErr(w.GetLastError());
}

fn fileSize(io: Io, p: []const u8) !u64 {
    return (try Io.Dir.cwd().statFile(io, p, .{})).size;
}

/// OrdinalIgnoreCase key: every UTF-16 unit upper-cased as NTFS and .NET's ordinal comparison do it ("Файл" ==
/// "файл"; std.ascii would fold only A-Z).
fn upperW(gpa: Allocator, s: []const u8) ![]u16 {
    const u = try std.unicode.wtf8ToWtf16LeAlloc(gpa, s);
    for (u) |*c| c.* = std.os.windows.toUpperWtf16(c.*);
    return u;
}

/// upperW as WTF-8, for hash-map keys.
fn upper(gpa: Allocator, s: []const u8) ![]u8 {
    const u = try upperW(scratch, s);
    defer scratch.free(u);
    return std.unicode.wtf16LeToWtf8Alloc(gpa, u);
}

/// `a` starts with `prefix`, OrdinalIgnoreCase.
fn startsWithI(a: []const u8, prefix: []const u8) bool {
    return a.len >= prefix.len and eqlI(a[0..prefix.len], prefix);
}

/// Path.Combine(dir, rel): a rooted `rel` ("\x", "C:x", "//server/x") replaces `dir`, as .NET does.
fn combine(gpa: Allocator, dir: []const u8, rel: []const u8) ![]u8 {
    if (rel.len > 0 and (fspath.isSep(rel[0]) or (rel.len > 1 and rel[1] == ':'))) return gpa.dupe(u8, rel);
    return joinName(gpa, dir, rel, "");
}

/// Stream `pieces` into a new `output` (Engine.Glue). Cancel is checked per MB.
fn glue(io: Io, pieces: []const []const u8, output: []const u8, progress: Progress) !void {
    var out = try Io.Dir.cwd().createFile(io, output, .{});
    defer out.close(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var wr = out.writer(io, &wbuf);
    for (pieces) |p| {
        var in = try Io.Dir.cwd().openFile(io, p, .{});
        defer in.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        var rd = in.reader(io, &rbuf);
        while (true) {
            if (progress.cancelled()) return error.Canceled;
            _ = rd.interface.stream(&wr.interface, .limited(1 << 20)) catch |e| switch (e) {
                error.EndOfStream => break,
                error.ReadFailed => return rd.err.?,
                error.WriteFailed => return wr.err.?,
            };
        }
    }
    wr.interface.flush() catch return wr.err.?;
}

/// The parts of a .001 set, in order (gpa owns each and the list).
fn partsOf(gpa: Allocator, first_part: []const u8) ![][]u8 {
    const stem = first_part[0 .. first_part.len - 4];
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    var n: u32 = 1;
    while (true) : (n += 1) {
        const p = try part(gpa, stem, n);
        if (!fileExists(p)) {
            gpa.free(p);
            break;
        }
        try list.append(gpa, p);
    }
    return list.toOwnedSlice(gpa);
}

/// Engine.Join: glues a .001 set (C#: SevenZipSharp's volume callback served .002 onwards twice).
fn joinParts(gpa: Allocator, io: Io, first_part: []const u8, joined: []const u8, progress: Progress) !void {
    const parts = try partsOf(gpa, first_part);
    defer kit.win.freeList(gpa, parts);
    if (parts.len == 0) return error.FileNotFound;
    try glue(io, @ptrCast(parts), joined, progress);
}

/// A .001 set counts all its parts.
fn sizeOnDisk(gpa: Allocator, io: Io, archive: []const u8) u64 {
    if (!isFirstPart(archive)) return fileSize(io, archive) catch 0;
    const parts = partsOf(gpa, archive) catch return 0;
    defer kit.win.freeList(gpa, parts);
    var sum: u64 = 0;
    for (parts) |p| sum += fileSize(io, p) catch 0;
    return sum;
}

// ---- what is this file? -----------------------------------------------------------------------------
// The binding cannot tell "not an archive", "truncated" and "needs a password" apart before it is asked,
// so the three are told apart here, from the bytes.

const Sig = struct { off: i64, b: []const u8 };
const sig_7z: Sig = .{ .off = 0, .b = "7z\xBC\xAF\x27\x1C" };
const sig_rar4: Sig = .{ .off = 0, .b = "Rar!\x1A\x07\x00" };
const sig_rar5: Sig = .{ .off = 0, .b = "Rar!\x1A\x07\x01\x00" };
const sig_pe: Sig = .{ .off = 0, .b = "MZ" };

/// Offset -> bytes that must be there. A negative offset counts back from the end of the file.
// ponytail: the formats that carry a signature, minus the three above (which are probed further). Something
// 7z.dll could still open but that is not listed (exe/nsis, ...) is answered "not an archive".
const signatures = [_]Sig{
    .{ .off = 0, .b = "PK\x03\x04" }, .{ .off = 0, .b = "PK\x05\x06" }, .{ .off = 0, .b = "PK\x07\x08" }, // zip
    .{ .off = 0, .b = "\x1F\x8B" }, // gzip
    .{ .off = 0, .b = "BZh" }, // bzip2
    .{ .off = 0, .b = "\xFD7zXZ\x00" }, // xz
    .{ .off = 0, .b = "\x1F\x9D" }, // compress (.z)
    .{ .off = 0, .b = "MSCF" }, // cab
    .{ .off = 0, .b = "MSWIM\x00\x00\x00" }, // wim
    .{ .off = 0, .b = "\x60\xEA" }, // arj
    .{ .off = 2, .b = "-lh" }, // lzh
    .{ .off = 0, .b = "07070" }, .{ .off = 0, .b = "\xC7\x71" }, .{ .off = 0, .b = "\x71\xC7" }, // cpio
    .{ .off = 0, .b = "\xED\xAB\xEE\xDB" }, // rpm
    .{ .off = 0, .b = "!<arch>\n" }, // deb / ar
    .{ .off = 0, .b = "xar!" }, // xar
    .{ .off = 0, .b = "conectix" }, .{ .off = -512, .b = "conectix" }, // vhd
    .{ .off = -512, .b = "koly" }, // dmg
    .{ .off = 32769, .b = "CD001" }, // iso
    .{ .off = 32769, .b = "BEA01" }, // udf
    .{ .off = 257, .b = "ustar" }, // tar
    .{ .off = 0, .b = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1" }, // compound: msi, msp
    .{ .off = 0, .b = "ITSF" }, // chm
    sig_pe, // exe/dll: SFX, installers (7z.dll reads PE)
};

/// Formats with no signature at all: only the name can vouch for them (".001" is answered earlier).
const no_signature = [_][]const u8{ "tar", "lzma" };

const Bytes = struct {
    f: Io.File,
    io: Io,
    size: u64,

    fn open(io: Io, path: []const u8) !Bytes {
        const f = try Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
        errdefer f.close(io);
        return .{ .f = f, .io = io, .size = try f.length(io) };
    }

    fn close(b: Bytes) void {
        b.f.close(b.io);
    }

    /// `buf.len` bytes at `offset` (negative = from the end), or empty.
    fn at(b: Bytes, offset: i64, buf: []u8) []const u8 {
        const off = if (offset < 0) offset + @as(i64, @intCast(b.size)) else offset;
        if (off < 0 or buf.len == 0 or @as(u64, @intCast(off)) + buf.len > b.size) return &.{};
        const n = b.f.readPositionalAll(b.io, buf, @intCast(off)) catch return &.{};
        return if (n == buf.len) buf else &.{};
    }

    fn matches(b: Bytes, s: Sig) bool {
        var buf: [16]u8 = undefined;
        return std.mem.eql(u8, b.at(s.off, buf[0..s.b.len]), s.b);
    }

    /// CRC32 (IEEE 802.3) of a byte range - the checksum 7z stores.
    fn crc(b: Bytes, offset: u64, count: u64) u32 {
        var h: std.hash.Crc32 = .init();
        var buf: [64 * 1024]u8 = undefined;
        var off = offset;
        var left = count;
        while (left > 0) {
            const want: usize = @intCast(@min(left, buf.len));
            const n = b.f.readPositional(b.io, &.{buf[0..want]}, off) catch break;
            if (n == 0) break;
            h.update(buf[0..n]);
            off += n;
            left -= n;
        }
        return h.final();
    }

    /// The 32-byte 7z start header is self-checking and says where the next header (the file list) is:
    /// signature(6) version(2) StartHeaderCRC(4) NextHeaderOffset(8) NextHeaderSize(8) NextHeaderCRC(4).
    fn sevenZip(b: Bytes) ProbeResult {
        var buf: [32]u8 = undefined;
        const head = b.at(0, &buf);
        if (head.len < 32 or b.crc(12, 20) != std.mem.readInt(u32, head[8..12], .little)) return .damaged;
        const offset = std.mem.readInt(u64, head[12..20], .little);
        const size = std.mem.readInt(u64, head[20..28], .little);
        if (size == 0) return .archive; // intact, and empty
        const room = b.size - 32;
        if (offset > room or size > room - offset) return .damaged; // truncated
        // An intact 7z with encrypted headers looks exactly like this one: the encryption only shows when the
        // open fails, which is where the password prompt picks it up.
        return if (b.crc(32 + offset, size) == std.mem.readInt(u32, head[28..32], .little)) .archive else .damaged;
    }

    /// A 7z start header somewhere after an exe stub whose CRC checks out: a 7z SFX.
    // ponytail: only the first 4 MB are searched - 7-Zip's own stubs are ~200 KB.
    fn sfxSevenZip(b: Bytes) bool {
        const len: usize = @intCast(@min(b.size, 4 << 20));
        const head = scratch.alloc(u8, len) catch return false;
        defer scratch.free(head);
        if (b.at(0, head).len != len) return false;
        var i = std.mem.find(u8, head, sig_7z.b);
        while (i) |p| : (i = if (std.mem.find(u8, head[p + 1 ..], sig_7z.b)) |n| p + 1 + n else null) {
            if (p + 32 > head.len) break;
            if (std.hash.Crc32.hash(head[p + 12 .. p + 32]) != std.mem.readInt(u32, head[p + 8 ..][0..4], .little)) continue;
            // A header with a file list that fits in the file: an empty 7z (size 0) has no names to hide - that is
            // also what MakePack.exe itself carries (assoc.empty_seven_zip, for Explorer's New menu).
            const off = std.mem.readInt(u64, head[p + 12 ..][0..8], .little);
            const sz = std.mem.readInt(u64, head[p + 20 ..][0..8], .little);
            const room = b.size - (p + 32);
            if (sz > 0 and off <= room and sz <= room - off) return true;
        }
        return false;
    }
};

/// Engine.Probe: damaged, not an archive, or an archive - and whether its file list is behind a password.
pub fn probe(io: Io, path: []const u8) ProbeResult {
    // A split volume holds the first slice: the 7z signature is there but the next header lives in another part.
    if (isFirstPart(path)) return .archive;
    const b = Bytes.open(io, path) catch return .archive; // unreadable: let open report the real Windows error
    defer b.close();
    var buf: [16]u8 = undefined;
    if (b.matches(sig_7z)) return b.sevenZip();
    if (b.matches(sig_rar4)) return if (rar4Encrypted(b.at(7, buf[0..7]))) .encrypted_headers else .archive;
    if (b.matches(sig_rar5)) return if (rar5Encrypted(b.at(8, buf[0..16]))) .encrypted_headers else .archive;
    for (signatures) |s| if (b.matches(s)) return .archive;
    for (no_signature) |e| if (std.ascii.eqlIgnoreCase(e, extOf(path))) return .archive;
    return .not_archive;
}

/// Engine.CanEncryptHeaders: only 7z (also inside an SFX) and rar can hide their file list.
pub fn canEncryptHeaders(io: Io, path: []const u8) bool {
    const b = Bytes.open(io, path) catch return false;
    defer b.close();
    return b.matches(sig_7z) or b.matches(sig_rar4) or b.matches(sig_rar5) or (b.matches(sig_pe) and b.sfxSevenZip());
}

/// Engine.Rar4Encrypted: MAIN_HEAD (the 7 bytes after the signature) has MHD_PASSWORD.
// ponytail: readable only while the main head itself is; when it is not, the open loop still asks.
pub fn rar4Encrypted(head: []const u8) bool {
    return head.len >= 7 and head[2] == 0x73 and std.mem.readInt(u16, head[3..5], .little) & 0x0080 != 0;
}

/// Engine.Rar5Encrypted: the first header after the signature is an encryption header (type 4).
pub fn rar5Encrypted(head: []const u8) bool {
    var i: usize = 4;
    _ = vint(head, &i) orelse return false;
    return (vint(head, &i) orelse return false) == 4;
}

/// RAR5 variable int: 7 bits per byte, lowest group first, high bit = another byte follows.
fn vint(b: []const u8, i: *usize) ?u64 {
    var value: u64 = 0;
    var shift: u7 = 0;
    while (i.* < b.len and shift < 64) : (shift += 7) {
        const c = b[i.*];
        i.* += 1;
        value |= @as(u64, c & 0x7F) << @intCast(shift);
        if (c & 0x80 == 0) return value;
    }
    return null; // ran off the end
}

/// Engine.LooksLikeArchive: worth opening rather than compressing (drag and drop); an exe is never.
pub fn looksLikeArchive(io: Io, path: []const u8) bool {
    if (Bytes.open(io, path)) |b| {
        defer b.close();
        if (b.matches(sig_pe)) return false;
    } else |_| {}
    return probe(io, path) != .not_archive;
}

/// Engine.IsSfx: the archive file starts with an exe stub (read-only: an edit would cut the stub off).
pub fn isSfx(io: Io, a: *const Archive) bool {
    const b = Bytes.open(io, a.open_path) catch return false;
    defer b.close();
    return b.matches(sig_pe);
}

/// Engine.CanDelete: 7z.dll can rewrite it in place (7z, zip, tar, wim; not nested, not SFX).
pub fn canDelete(io: Io, a: *const Archive) bool {
    return !a.nested() and !isSfx(io, a) and switch (a.x.props.format) {
        .SevenZip, .Zip, .Tar, .Wim => true,
        else => false,
    };
}

// ---- open / extract / test ----------------------------------------------------------------------------

fn nonEmpty(p: ?[]const u8) ?[]const u8 {
    return if (p != null and p.?.len > 0) p else null;
}

/// The binding's open, its errors in Engine's words.
fn openX(gpa: Allocator, path: []const u8, password: ?[]const u8, shown: []const u8, progress: Progress, diag: ?*Diag) !*sevenzip.InArchive {
    return sevenzip.InArchive.open(gpa, path, password, progress.cancel) catch |e| switch (e) {
        error.NotArchive => error.NotAnArchive,
        error.Failed => error.Damaged, // SevenZipArchiveException: the open itself failed
        error.FileNotFound => {
            Diag.set(diag, S.fileNotFoundFmt.get(), .{shown});
            return error.FileNotFound;
        },
        else => e,
    };
}

/// True when the archive is a container holding exactly one archive (x.tar.gz, x.tgz, ...): its inner name.
fn innerArchive(path: []const u8, x: *const sevenzip.InArchive) ?[]const u8 {
    if (x.items.len != 1) return null;
    switch (x.props.format) {
        .GZip, .BZip2, .XZ, .Lzma, .Lzma86, .Lzw, .Split => {},
        else => return null,
    }
    const entry = fspath.basename(x.items[0].path); // Split reports a full path
    const outer = fspath.basename(path);
    if (nestable(entry)) return entry;
    for (tarball_exts) |e| if (std.ascii.endsWithIgnoreCase(outer, e)) return "";
    return null;
}

/// An inner entry worth opening in turn: a .tar or anything with a known archive extension.
fn nestable(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".tar") or types.isArchiveExt(extOf(name));
}

/// Engine.Open: opens the archive, unwrapping containers that hold one archive (x.tar.gz, parts.7z.001,
/// x.tar.gz.001, up to 3 levels). Close with Archive.close. Only `progress.cancel` is used (error.Canceled; the
/// temp files of a half-done unwrap are removed).
pub fn open(gpa: Allocator, io: Io, path: []const u8, password: ?[]const u8, progress: Progress, diag: ?*Diag) anyerror!*Archive {
    const pw = nonEmpty(password);
    var dir: ?[]u8 = null;
    errdefer if (dir) |d| {
        nuke(io, d);
        forget(d);
        gpa.free(d);
    };
    var open_path = try gpa.dupe(u8, path);
    errdefer gpa.free(open_path);
    if (isFirstPart(path)) {
        if (!fileExists(path)) {
            Diag.set(diag, S.fileNotFoundFmt.get(), .{path});
            return error.FileNotFound;
        }
        dir = try newTempDir(gpa, io);
        const joined = try joinName(gpa, dir.?, withoutExt(path), ""); // parts.7z.001 -> parts.7z
        gpa.free(open_path);
        open_path = joined;
        try joinParts(gpa, io, path, open_path, progress);
    }
    var x = try openX(gpa, open_path, pw, path, progress, diag);
    errdefer x.close();
    // ponytail: 3 levels covers split -> gz -> tar; deeper nesting is shown as the file it is.
    var depth: u32 = 0;
    while (depth < 3) : (depth += 1) {
        const entry = innerArchive(open_path, x) orelse break;
        if (dir == null) dir = try newTempDir(gpa, io);
        const sub = try gpa.print("{s}\\{d}", .{ dir.?, depth });
        defer gpa.free(sub);
        try Io.Dir.cwd().createDirPath(io, sub);
        const inner = if (entry.len > 0)
            try joinName(gpa, sub, entry, "")
        else
            try joinName(gpa, sub, baseName(open_path), ".tar");
        errdefer gpa.free(inner);
        try extractOne(x, inner, progress);
        const y = try openX(gpa, inner, null, path, progress, diag);
        x.close();
        x = y;
        gpa.free(open_path);
        open_path = inner;
    }
    const a = try gpa.create(Archive);
    errdefer gpa.destroy(a);
    const source = try gpa.dupe(u8, path);
    errdefer gpa.free(source);
    a.* = .{
        .gpa = gpa,
        .io = io,
        .x = x,
        .source = source,
        .open_path = open_path,
        .password = if (pw) |p| try gpa.dupe(u8, p) else null,
        .temp_dir = dir,
    };
    return a;
}

/// 7-Zip's "opened with errors / warnings" (Props.error_flags / warning_flags): the list may be partial. The text
/// for the main cause, null = clean. A truncated .gz opens clean (its end is only seen when decoding: Test says).
pub fn openWarning(p: sevenzip.Props) ?S.Str {
    const f = p.error_flags | p.warning_flags;
    const af = sevenzip.arc_flag;
    if (f & af.unexpected_end != 0) return S.openedTruncated;
    if (f & (af.headers_error | af.encrypted_headers_error) != 0) return S.openedBadHeaders;
    if (f & af.data_after_end != 0) return S.openedDataAfterEnd;
    if (f != 0) return S.openedWithErrors;
    return null;
}

/// Item 0 of a container into `file`.
fn extractOne(x: *sevenzip.InArchive, file: []const u8, progress: Progress) !void {
    const Ctx = struct {
        file: []const u8,
        progress: Progress,
        fn target(ctx: ?*anyopaque, _: *const sevenzip.Item) anyerror!sevenzip.Target {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return .{ .file = c.file };
        }
        fn step(ctx: ?*anyopaque, _: u64, _: u64) bool {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            return !c.progress.cancelled();
        }
    };
    var c: Ctx = .{ .file = file, .progress = progress };
    x.extract(&.{0}, .{ .ctx = &c, .target = Ctx.target, .progress = .{ .ctx = &c, .step = Ctx.step } }) catch |e| return switch (e) {
        error.DataError => error.Damaged,
        else => e,
    };
}

/// Zip-slip guard: true when the entry would land outside `dest_full` (which ends with \).
// The binding writes where we say: "../x", "..\x", "\x", "C:x" and "//server/share/x" must all be caught here.
fn escapes(dest_full: []const u8, raw: []const u8) bool {
    if (raw.len == 0) return false;
    var segs = std.mem.splitAny(u8, raw, "/\\");
    while (segs.next()) |seg| {
        // "..", ".. ", "..." - but "." is fine
        if (std.mem.trim(u8, seg, " .").len == 0 and std.mem.count(u8, seg, ".") > 1) return true;
    }
    const joined = combine(scratch, dest_full, raw) catch return true;
    defer scratch.free(joined);
    const full = fullPath(scratch, joined) catch return true; // invalid characters, path too long, ...
    defer scratch.free(full);
    return !startsWithI(full, dest_full);
}

/// Characters a Windows name cannot hold (a zip from elsewhere can): "_" instead, as 7-Zip does.
fn sanitize(name: []u8) void {
    for (name) |*c| if (c.* < 0x20 or std.mem.findScalar(u8, "<>:\"|?*", c.*) != null) {
        c.* = '_';
    };
}

/// Engine.Extract. `indices` null = whole archive; `on_conflict` is asked only while `mode` is Ask;
/// `motw` = the caller's settings.current().Motw (C# read Settings.Current when null).
pub fn extract(
    gpa: Allocator,
    io: Io,
    a: *Archive,
    dest_dir: []const u8,
    indices: ?[]const u32,
    mode: OverwriteMode,
    progress: Progress,
    on_conflict: Conflict,
    motw: MotwPolicy,
    options: ExtractOptions,
    diag: ?*Diag,
) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    try Io.Dir.cwd().createDirPath(io, dest_dir);
    const full = try fullPath(ar, dest_dir);
    const dest_full = try std.mem.concat(ar, u8, &.{ std.mem.trimEnd(u8, full, "\\"), "\\" });

    const X = struct {
        ar: Allocator,
        io: Io,
        dest_full: []const u8,
        o: ExtractOptions,
        mode: OverwriteMode,
        on_conflict: Conflict,
        marking: bool,
        ticker: Ticker,
        /// What actually landed on disk, renames included: the files to mark.
        written: std.ArrayList([]const u8) = .empty,
        unsafe: u32 = 0,
        cancelled: bool = false,
        /// Started and not finished: when the extraction stops, this is the broken one.
        in_flight: ?[]const u8 = null,
        first_fail: ?sevenzip.OpResult = null,

        fn dest(x: *@This(), raw: []const u8) ![]u8 {
            const r = try x.ar.dupe(u8, if (x.o.no_paths) fspath.basename(std.mem.trimEnd(u8, raw, "/\\")) else raw);
            sanitize(r);
            const joined = try combine(x.ar, x.dest_full, r);
            return fullPath(x.ar, joined);
        }

        fn target(ctx: ?*anyopaque, it: *const sevenzip.Item) anyerror!sevenzip.Target {
            const x: *@This() = @ptrCast(@alignCast(ctx));
            if (x.ticker.to.cancelled()) {
                x.cancelled = true;
                return error.Canceled;
            }
            if (escapes(x.dest_full, it.path)) {
                x.unsafe += 1;
                return .skip;
            }
            x.ticker.setCurrent(it.path);
            if (it.is_dir) {
                if (!x.o.no_paths) mkdirs(try x.dest(it.path)) catch {}; // no paths: no (empty) folders either
                return .skip;
            }
            var path = try x.dest(it.path);
            if (fileExists(path)) {
                if (x.o.update != .Replace) {
                    // ponytail: 2 s of slack for zip's 2-second timestamps; a copy newer by under 2 s counts as the same.
                    const disk = lastWrite(path) orelse 0;
                    if (@as(i128, it.mtime) - @as(i128, disk) <= 2 * 10_000_000) return .skip; // FILETIME: 100 ns ticks
                } else switch ((if (x.mode == .Ask) x.on_conflict.ask(x.on_conflict.ctx, path) else x.mode) orelse .Ask) {
                    .Overwrite => {},
                    .Skip => return .skip,
                    .Rename => path = try unique(x.ar, x.io, path),
                    .Ask => { // null = the user cancelled
                        x.cancelled = true;
                        return error.Canceled;
                    },
                }
            } else if (x.o.update == .Existing) return .skip;
            if (fspath.dirname(path)) |d| try mkdirs(d);
            x.in_flight = path;
            if (x.marking) try x.written.append(x.ar, path);
            return .{ .file = path };
        }

        fn done(ctx: ?*anyopaque, _: *const sevenzip.Item, r: sevenzip.OpResult) void {
            const x: *@This() = @ptrCast(@alignCast(ctx));
            if (r != .ok) {
                if (x.first_fail == null) x.first_fail = r;
                // 7z.dll leaves a file that failed its CRC on disk, full of garbage.
                if (!x.o.keep_broken) if (x.in_flight) |p| tryDelete(x.io, p);
            }
            x.in_flight = null;
        }
    };
    const zone: ?[]u8 = if (motw == .Never) null else zoneOf(ar, io, a.source);
    var x: X = .{ .ar = ar, .io = io, .dest_full = dest_full, .o = options, .mode = mode, .on_conflict = on_conflict, .marking = zone != null, .ticker = .{ .to = progress } };
    const result = a.x.extract(indices, .{ .ctx = &x, .target = X.target, .done = X.done, .progress = x.ticker.sz() });
    if (x.in_flight) |p| if (!options.keep_broken) tryDelete(io, p);
    // Cancelled or failed half way, what did land is marked all the same: an unmarked exe is the hole.
    if (zone) |z| mark(io, x.written.items, z, motw);
    result catch |e| {
        if (x.cancelled or progress.cancelled()) return error.Canceled;
        return explain(a, e, x.first_fail, diag);
    };
    if (x.cancelled or progress.cancelled()) return error.Canceled;
    if (x.unsafe > 0) {
        Diag.set(diag, S.unsafeSkippedFmt.get(), .{x.unsafe});
        return error.UnsafeEntriesSkipped;
    }
    progress.send(100, "");
}

/// Engine.Explain: why an extraction or a test failed. Measured in C#: an AES zip with a wrong password says
/// "wrong password"; a body-encrypted 7z with a wrong password only says "data error" - so encrypted data plus
/// a data error is reported as a probable wrong password (7-Zip cannot split that case either).
fn explain(a: *const Archive, e: anyerror, first: ?sevenzip.OpResult, diag: ?*Diag) anyerror {
    return switch (e) {
        error.WrongPassword, error.DataError => {
            if (first == .wrong_password) return error.WrongPassword;
            if (a.password != null or anyEncrypted(a)) return error.DataErrorEncrypted;
            return error.Damaged;
        },
        error.UnsupportedMethod, error.PasswordNeeded, error.Canceled => e,
        error.Failed, error.InvalidOption => {
            failText(diag);
            return error.ArchiveFailed;
        },
        else => e, // Windows' own errors (disk full, access denied) and the sink's
    };
}

fn anyEncrypted(a: *const Archive) bool {
    for (a.x.items) |it| if (it.encrypted) return true;
    return false;
}

/// Engine.Test: true = every item checked out. A data error in an encrypted archive is DataErrorEncrypted.
pub fn testArchive(gpa: Allocator, io: Io, a: *Archive, progress: Progress, diag: ?*Diag) anyerror!bool {
    _ = .{ gpa, io };
    const T = struct {
        first: ?sevenzip.OpResult = null,
        ticker: Ticker,
        fn done(ctx: ?*anyopaque, it: *const sevenzip.Item, r: sevenzip.OpResult) void {
            const t: *@This() = @ptrCast(@alignCast(ctx));
            if (r != .ok and t.first == null) t.first = r;
            t.ticker.setCurrent(it.path);
        }
    };
    var t: T = .{ .ticker = .{ .to = progress } };
    a.x.check(null, .{ .ctx = &t, .done = T.done, .progress = t.ticker.sz() }) catch |e| {
        if (progress.cancelled()) return error.Canceled;
        const why = explain(a, e, t.first, diag);
        return if (why == error.Damaged) false else why;
    };
    if (progress.cancelled()) return error.Canceled;
    // A truncated zip / tar opens with a partial list and checks out what is there: 7-Zip calls that an error.
    return t.first == null and a.x.props.error_flags == 0;
}

// ---- info / report ------------------------------------------------------------------------------------

fn label(s: S.Str) []const u8 {
    return std.mem.trimEnd(u8, s.get(), ":");
}

/// Engine.Describe: the Info window's rows, in order (unpacked size summed from the entries; packed = on disk).
pub fn describe(gpa: Allocator, io: Io, a: *Archive) anyerror![]Row {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const its = a.x.items;
    const props = a.x.props;

    var files: u64 = 0;
    var unpacked: i64 = 0;
    var encrypted = false;
    // Folders: every parent of every path, and every folder entry, counted once.
    var folders: std.StringHashMapUnmanaged(void) = .empty;
    for (its) |it| {
        const n = try norm(ar, it.path);
        if (!it.is_dir) {
            files += 1;
            unpacked += @intCast(it.size);
            encrypted = encrypted or it.encrypted;
        }
        var end: usize = if (it.is_dir) n.len else std.mem.findScalarLast(u8, n, '/') orelse 0;
        while (end > 0) {
            try folders.put(ar, try upper(ar, n[0..end]), {});
            end = std.mem.findScalarLast(u8, n[0..end], '/') orelse 0;
        }
    }
    const packed_size: i64 = @intCast(sizeOnDisk(ar, io, a.source));

    var methods: []const u8 = props.method orelse "";
    if (methods.len == 0) {
        var list: std.ArrayList(u8) = .empty;
        var seen: std.ArrayList([]const u8) = .empty;
        for (its) |it| if (!it.is_dir and it.method.len > 0) {
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, it.method)) break;
            } else {
                try seen.append(ar, it.method);
                if (list.items.len > 0) try list.appendSlice(ar, ", ");
                try list.appendSlice(ar, it.method);
            }
        };
        methods = list.items;
    }

    var rows: std.ArrayList(Row) = .empty;
    const R = struct {
        fn add(g: Allocator, r: *std.ArrayList(Row), l: []const u8, v: []const u8) !void {
            try r.append(g, .{ .label = l, .value = try g.dupe(u8, v) });
        }
    };
    var nb: [32]u8 = undefined;
    try R.add(gpa, &rows, S.infoFile.get(), a.source);
    const fmt_name: []const u8 = switch (props.format) {
        .SevenZip => "7z",
        .other => props.format_name,
        else => @tagName(props.format),
    };
    try R.add(gpa, &rows, label(S.format), if (a.nested()) try ar.print("{s} ({s})", .{ fmt_name, fspath.basename(a.open_path) }) else fmt_name);
    try R.add(gpa, &rows, label(S.method), if (methods.len > 0) methods else "-");
    if (dictionaryOf(methods)) |d| try R.add(gpa, &rows, label(S.dictionary), niceSize(&nb, d));
    const solid: []const u8 = if (!props.solid) S.no.get() else if (props.blocks) |b|
        try ar.print("{s} ({s})", .{ S.yes.get(), try S.fill(ar, S.blocksFmt.get(), .{b}) })
    else
        S.yes.get();
    try R.add(gpa, &rows, S.solid.get(), solid);
    try R.add(gpa, &rows, S.encrypted.get(), if (!encrypted) S.no.get() else if (namesEncrypted(ar, io, a)) S.encryptedDataAndNames.get() else S.encryptedData.get());
    try R.add(gpa, &rows, S.files.get(), try ar.print("{d}", .{files}));
    try R.add(gpa, &rows, S.folders.get(), try ar.print("{d}", .{folders.count()}));
    try R.add(gpa, &rows, S.unpacked.get(), niceSize(&nb, unpacked));
    try R.add(gpa, &rows, S.@"packed".get(), niceSize(&nb, packed_size));
    var ratio: Io.Writer.Allocating = .init(ar);
    if (unpacked > 0) {
        try fixed(&ratio.writer, @as(f64, @floatFromInt(packed_size)) * 100.0 / @as(f64, @floatFromInt(unpacked)), 1);
        try ratio.writer.writeAll("%");
    } else try ratio.writer.writeAll("-");
    try R.add(gpa, &rows, S.ratio.get(), ratio.written());
    if (isFirstPart(a.source)) {
        const parts = try partsOf(ar, a.source);
        try R.add(gpa, &rows, S.volumesCount.get(), try ar.print("{d}", .{parts.len}));
    } else if (props.volumes) |v| if (v > 1) {
        // ponytail: only real sets; C# showed any "Number of volumes" the handler reported
        try R.add(gpa, &rows, S.volumesCount.get(), try ar.print("{d}", .{v}));
    };
    if (props.comment) |c| if (c.len > 0) try R.add(gpa, &rows, S.comment.get(), c);
    return rows.toOwnedSlice(gpa);
}

/// Opened only with a password, but would not even list without one: the names are encrypted too.
fn namesEncrypted(gpa: Allocator, io: Io, a: *const Archive) bool {
    if (a.password == null) return false;
    const b = open(gpa, io, a.source, null, .none, null) catch return true;
    b.close();
    return false;
}

/// WebUtility.HtmlEncode: < > & " ' and U+00A0..U+00FF as numeric entities.
fn html(wr: *Io.Writer, s: []const u8) !void {
    // Not WTF-8 (never from the binding): still escape the markup characters, byte by byte.
    const view = std.unicode.Wtf8View.init(s) catch {
        for (s) |c| try if (std.mem.findScalar(u8, "<>&\"'", c) != null) wr.print("&#{d};", .{c}) else wr.writeByte(c);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepointSlice()) |cs| {
        const cp = std.unicode.wtf8Decode(cs) catch 0;
        switch (cp) {
            '<' => try wr.writeAll("&lt;"),
            '>' => try wr.writeAll("&gt;"),
            '&' => try wr.writeAll("&amp;"),
            '"' => try wr.writeAll("&quot;"),
            '\'' => try wr.writeAll("&#39;"),
            0xA0...0xFF => try wr.print("&#{d};", .{cp}),
            else => try wr.writeAll(cs),
        }
    }
}

/// FILETIME ticks -> "yyyy-MM-dd HH:mm" in local time (DateTime.FromFileTime).
fn localTime(buf: *[32]u8, ft: u64) []const u8 {
    const f: w.FILETIME = .{ .dwLowDateTime = @truncate(ft), .dwHighDateTime = @truncate(ft >> 32) };
    var utc: w.SYSTEMTIME = undefined;
    var loc: w.SYSTEMTIME = undefined;
    if (w.FileTimeToSystemTime(&f, &utc) == 0 or w.SystemTimeToTzSpecificLocalTime(null, &utc, &loc) == 0) return "";
    return std.mem.print(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ loc.wYear, loc.wMonth, loc.wDay, loc.wHour, loc.wMinute }) catch "";
}

/// Engine.Report: Describe's rows, then one line per file (path, size, modified, CRC, method), path order.
pub fn report(gpa: Allocator, io: Io, a: *Archive, as_html: bool) anyerror![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const head = try describe(ar, io, a);
    const Line = [5][]const u8;
    const Keyed = struct { key: []const u16, line: Line };
    var keyed: std.ArrayList(Keyed) = .empty;
    for (a.x.items) |it| if (!it.is_dir) {
        var g: [40]u8 = undefined;
        var t: [32]u8 = undefined;
        const n = try norm(ar, it.path);
        try keyed.append(ar, .{ .key = try upperW(ar, n), .line = .{
            n,
            try ar.dupe(u8, S.group(&g, it.size)),
            try ar.dupe(u8, localTime(&t, it.mtime)),
            try ar.print("{X:0>8}", .{it.crc orelse 0}),
            it.method,
        } });
    };
    std.mem.sort(Keyed, keyed.items, {}, struct { // OrdinalIgnoreCase: upper-cased UTF-16 units
        fn f(_: void, l: Keyed, r: Keyed) bool {
            return std.mem.order(u16, l.key, r.key) == .lt;
        }
    }.f);
    var lines: std.ArrayList(Line) = .empty;
    for (keyed.items) |k| try lines.append(ar, k.line);
    const cols: Line = .{ S.name.get(), S.size.get(), S.modified.get(), S.crc.get(), label(S.method) };
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const wr = &out.writer;
    if (!as_html) {
        for (head) |r| try wr.print("{s}: {s}\r\n", .{ r.label, r.value });
        try wr.writeAll("\r\n");
        var width: [5]usize = @splat(0);
        for (0..5) |i| width[i] = chars(cols[i]);
        for (lines.items) |l| for (0..5) |i| {
            width[i] = @max(width[i], chars(l[i]));
        };
        var row: Io.Writer.Allocating = .init(ar);
        for ([_][]const Line{ &.{cols}, lines.items }) |set| for (set) |l| {
            row.clearRetainingCapacity();
            for (l, 0..) |c, i| {
                if (i > 0) try row.writer.writeAll("  ");
                const pad = width[i] - chars(c);
                if (i == 1 or i == 3) try row.writer.splatByteAll(' ', pad);
                try row.writer.writeAll(c);
                if (i != 1 and i != 3) try row.writer.splatByteAll(' ', pad);
            }
            try wr.print("{s}\r\n", .{std.mem.trimEnd(u8, row.written(), " ")});
        };
        return out.toOwnedSlice();
    }
    // names can hold < > & " - from zips made anywhere
    try wr.writeAll("<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>");
    try html(wr, a.display());
    try wr.writeAll("</title>\n<style>body{font:14px Segoe UI,sans-serif;margin:24px}table{border-collapse:collapse}td,th{padding:3px 10px;text-align:left}" ++
        "th{border-bottom:1px solid #999}.n{text-align:right;font-variant-numeric:tabular-nums}tr:nth-child(even) td{background:#f4f4f4}" ++
        "</style></head><body>\n<h1>");
    try html(wr, a.display());
    try wr.writeAll("</h1>\n<table>\n");
    for (head) |r| {
        try wr.writeAll("<tr><th>");
        try html(wr, r.label);
        try wr.writeAll("</th><td>");
        try html(wr, r.value);
        try wr.writeAll("</td></tr>\n");
    }
    try wr.writeAll("</table>\n<h2>");
    try html(wr, S.filesHeading.get());
    try wr.writeAll("</h2>\n<table>\n<tr>");
    for (cols) |c| {
        try wr.writeAll("<th>");
        try html(wr, c);
        try wr.writeAll("</th>");
    }
    try wr.writeAll("</tr>\n");
    for (lines.items) |l| {
        try wr.writeAll("<tr>");
        for (l, 0..) |c, i| {
            try wr.writeAll(if (i == 1 or i == 3) "<td class=\"n\">" else "<td>");
            try html(wr, c);
            try wr.writeAll("</td>");
        }
        try wr.writeAll("</tr>\n");
    }
    try wr.writeAll("</table>\n</body></html>\n");
    return out.toOwnedSlice();
}

/// string.Length for padding: UTF-16 units (= code points for the BMP).
fn chars(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

/// Engine.WriteReport: text with a UTF-8 BOM (Notepad and Excel then read Cyrillic right), HTML without.
pub fn writeReport(gpa: Allocator, io: Io, a: *Archive, path: []const u8, as_html: bool) anyerror!void {
    const text = try report(gpa, io, a, as_html);
    defer gpa.free(text);
    var f = try Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    if (!as_html) try f.writeStreamingAll(io, "\xEF\xBB\xBF");
    try f.writeStreamingAll(io, text);
}

/// Engine.DictionaryOf: "LZMA2:24" -> 2^24, "LZMA:1536m" -> 1.5 GB, "PPMD:o6:mem24" -> 2^24; null = none.
pub fn dictionaryOf(method_text: []const u8) ?i64 {
    var it = std.mem.splitAny(u8, method_text, " :");
    while (it.next()) |p| {
        const t = if (std.ascii.startsWithIgnoreCase(p, "mem")) p[3..] else p;
        if (t.len == 0 or !std.ascii.isDigit(t[0])) continue; // "LZMA2", "BCJ", "o6"; the first number is the coder's
        if (std.fmt.parseInt(i32, t, 10)) |n| {
            if (n < 40) return @as(i64, 1) << @intCast(n); // a bare number is a power of two
        } else |_| {}
        if (parseSize(t)) |s| if (s > 0) return s; // "1536m"
    }
    return null;
}

// ---- compress -------------------------------------------------------------------------------------------

/// An archive entry and where its data comes from (null source = a folder; empty folders survive).
const Entry = struct { name: []const u8, source: ?[]const u8, folder: ?[]const u8 = null, size: u64 = 0 };

/// Engine.BuildDict: entry names relative to each input's parent, under `prefix`; a later duplicate name
/// (OrdinalIgnoreCase) replaces the earlier one. Hidden and system files are archived
/// too; an unreadable subfolder is skipped, not fatal; links to folders are followed (as C# did).
fn buildDict(ar: Allocator, io: Io, inputs: []const []const u8, prefix: []const u8) ![]Entry {
    const D = struct {
        ar: Allocator,
        io: Io,
        list: std.ArrayList(Entry) = .empty,
        seen: std.StringHashMapUnmanaged(usize) = .empty,

        fn put(d: *@This(), e: Entry) !void {
            const g = try d.seen.getOrPut(d.ar, try upper(d.ar, e.name));
            if (g.found_existing) d.list.items[g.value_ptr.*] = e else {
                g.value_ptr.* = d.list.items.len;
                try d.list.append(d.ar, e);
            }
        }

        // ponytail: depth cap instead of junction-loop detection (C# had neither).
        fn walk(d: *@This(), dir: []const u8, name: []const u8, depth: u32) !void {
            if (depth > 64) return;
            var h = Io.Dir.cwd().openDir(d.io, dir, .{ .iterate = true }) catch return;
            defer h.close(d.io);
            var it = h.iterate();
            while (it.next(d.io) catch return) |e| {
                const path = try joinName(d.ar, dir, e.name, "");
                const sub = try std.mem.concat(d.ar, u8, &.{ name, "\\", e.name });
                const st = Io.Dir.cwd().statFile(d.io, path, .{}) catch continue; // follows links; a dangling one is skipped
                if (st.kind == .directory) {
                    try d.put(.{ .name = sub, .source = null, .folder = path });
                    try d.walk(path, sub, depth + 1);
                } else try d.put(.{ .name = sub, .source = path, .size = st.size });
            }
        }
    };
    var d: D = .{ .ar = ar, .io = io };
    for (inputs) |input| {
        const full = try fullPath(ar, std.mem.trimEnd(u8, input, "\\/"));
        if (dirExists(full)) {
            const name = try std.mem.concat(ar, u8, &.{ prefix, fspath.basename(full) });
            try d.put(.{ .name = name, .source = null, .folder = full });
            try d.walk(full, name, 0);
        } else if (fileExists(full)) {
            try d.put(.{ .name = try std.mem.concat(ar, u8, &.{ prefix, fspath.basename(full) }), .source = full, .size = fileSize(io, full) catch 0 });
        }
    }
    return d.list.items;
}

/// Engine.MethodsFor: the methods a format can be written with, its default first.
pub fn methodsFor(k: ArchiveKind) []const CompressionMethod {
    return switch (k) {
        .SevenZip => &.{ .Lzma2, .Lzma, .Ppmd, .BZip2 },
        .Zip => &.{ .Deflate, .Deflate64, .BZip2, .Lzma, .Ppmd },
        else => &.{},
    };
}

/// Engine.HasDictionary: only LZMA-family coders take d= (PPMd wants mem=; 7z.dll says E_INVALIDARG).
pub fn hasDictionary(format: OutFormat, m: CompressionMethod) bool {
    return m == .Lzma or m == .Lzma2 or (m == .Default and format == .SevenZip);
}

/// Engine.DictionaryFits: ~11.5x the dictionary (capped at the input size) against installed RAM.
// ponytail: installed RAM, not free RAM - free memory moves while we look; 7z.dll's own E_OUTOFMEMORY covers the rest.
pub fn dictionaryFits(o: CompressOptions, input_bytes: i64, ram_bytes: i64) struct { fits: bool, need: i64 } {
    const need: i64 = @trunc(@as(f64, @floatFromInt(@min(o.dictionary, @max(input_bytes, 1)))) * 11.5);
    return .{ .fits = o.dictionary == 0 or need <= ram_bytes, .need = need };
}

fn installedRam() i64 {
    var m: w.MEMORYSTATUSEX = undefined;
    m.dwLength = @sizeOf(w.MEMORYSTATUSEX);
    if (w.GlobalMemoryStatusEx(&m) == 0) return std.math.maxInt(i64);
    return @intCast(m.ullTotalPhys);
}

/// SevenZipSharp's method names (7-Zip's m= values).
fn methodName(m: CompressionMethod) []const u8 {
    return switch (m) {
        .Copy => "Copy",
        .Deflate => "Deflate",
        .Deflate64 => "Deflate64",
        .BZip2 => "BZip2",
        .Lzma => "LZMA",
        .Lzma2 => "LZMA2",
        .Ppmd => "PPMd",
        .Default => "",
    };
}

/// Engine.Apply: the knobs shared by create and append, each checked against the format first: 7z.dll takes a
/// wrong one either with E_INVALIDARG or (zip + s=) by writing a broken archive. Also the encryption switches
/// (C# set them on the compressor): he=on for 7z with a password, em=ZipCrypto when asked.
fn applyProps(ar: Allocator, format: OutFormat, o: CompressOptions, encrypting: bool, diag: ?*Diag) ![]sevenzip.Prop {
    var props: std.ArrayList(sevenzip.Prop) = .empty;
    if (encrypting and o.encrypt_headers and format == .SevenZip) try props.append(ar, .{ .name = "he", .value = "on" });
    if (encrypting and o.zip_crypto and format == .Zip) try props.append(ar, .{ .name = "em", .value = "ZipCrypto" });
    // ponytail: tar and wim store; SevenZipSharp sent them no level either.
    if (format != .Tar and format != .Wim) {
        const levels = [_][]const u8{ "0", "1", "3", "5", "7", "9" };
        try props.append(ar, .{ .name = "x", .value = levels[@backingInt(o.level)] });
    }
    if (o.level == .None) return props.items; // Store: no coder, nothing below applies

    const seven = format == .SevenZip;
    const k: ?ArchiveKind = if (seven) .SevenZip else if (format == .Zip) .Zip else null;
    const known = for (if (k) |kk| methodsFor(kk) else &.{}) |m| {
        if (m == o.method) break true;
    } else false;
    const what: ?[]const u8 = if (!(o.method == .Default or known))
        try ar.print("method {t}", .{o.method})
    else if (!(o.dictionary == 0 or hasDictionary(format, o.method)))
        "a dictionary size"
    else if (!(o.solid == null or seven))
        "solid"
    else if (!(o.filter == null or seven))
        "an exe filter"
    else if (!(o.threads == 0 or k != null))
        "a thread count"
    else
        null;
    if (what) |wh| {
        Diag.set(diag, "{0} is not valid for {1}", .{ wh, @tagName(format) });
        return error.InvalidOption;
    }
    if (o.method != .Default) try props.append(ar, .{ .name = "m", .value = methodName(o.method) });
    if (o.dictionary > 0) {
        var b: [32]u8 = undefined;
        try props.append(ar, .{ .name = "d", .value = try ar.dupe(u8, size7z(&b, o.dictionary)) });
    }
    if (o.solid) |s| try props.append(ar, .{ .name = "s", .value = s });
    if (o.filter) |f| try props.append(ar, .{ .name = "f", .value = f });
    if (o.threads > 0) try props.append(ar, .{ .name = "mt", .value = try ar.print("{d}", .{o.threads}) });
    return props.items;
}

/// The binding's write errors in Engine's words.
fn writeErr(e: anyerror, diag: ?*Diag) anyerror {
    return switch (e) {
        // InvalidOption here = 7z.dll's E_INVALIDARG (our own option checks ran before): C#'s SevenZipException
        error.Failed, error.InvalidOption => {
            failText(diag);
            return error.OperationFailed;
        },
        error.DataError => error.Damaged,
        error.NotArchive => error.NotAnArchive,
        else => e,
    };
}

/// Engine.Pack + Run: one archive of `entries`; cancel = Canceled, and a half-written archive never stays.
fn pack(gpa: Allocator, io: Io, entries: []const Entry, out_path: []const u8, format: OutFormat, props: []const sevenzip.Prop, password: ?[]const u8, progress: Progress, lo: u8, hi: u8, diag: ?*Diag) !void {
    const items = try gpa.alloc(sevenzip.NewItem, entries.len);
    defer gpa.free(items);
    for (entries, items) |e, *it| it.* = .{ .name = e.name, .source = e.source, .folder = e.folder };
    var ticker: Ticker = .{ .to = progress, .lo = lo, .hi = hi };
    sevenzip.create(gpa, out_path, items, .{ .format = format, .props = props, .password = password, .progress = ticker.sz() }) catch |e| {
        if (progress.cancelled()) return error.Canceled;
        return writeErr(e, diag);
    };
    // ponytail: 7z.dll only lets us abort between callbacks; a cancel that lands after the last one still counts.
    if (progress.cancelled()) {
        tryDelete(io, out_path);
        return error.Canceled;
    }
}

/// True when `path` is `folder` itself or somewhere under it (a file input: the same file).
fn inside(path: []const u8, folder: []const u8) bool {
    if (!dirExists(folder)) return samePath(path, folder); // C# checked folders only: x.7z packed into x.7z went too
    const f = fullPath(scratch, folder) catch return false;
    defer scratch.free(f);
    const p = fullPath(scratch, path) catch return false;
    defer scratch.free(p);
    const fs = std.mem.trimEnd(u8, f, "\\/");
    return startsWithI(p, fs) and (p.len == fs.len or p[fs.len] == '\\');
}

/// Every name.NNN, not just a run from .001: a gap must not let an old .009 survive into the new set.
fn deleteParts(io: Io, path: []const u8) !void {
    const full = try fullPath(scratch, path);
    defer scratch.free(full);
    const dir = fspath.dirname(full) orelse return;
    const name = fspath.basename(full);
    var h = Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer h.close(io);
    var it = h.iterate();
    while (try it.next(io)) |e| {
        if (e.name.len < name.len + 4 or e.name[name.len] != '.' or !eqlI(e.name[0..name.len], name)) continue;
        const n = e.name[name.len + 1 ..];
        for (n) |c| {
            if (!std.ascii.isDigit(c)) break;
        } else try h.deleteFile(io, e.name);
    }
}

/// Cuts a finished file into parts in place, from the end: copy the tail out, truncate, repeat. The extra disk
/// space is one part instead of a second copy of the whole archive.
// ponytail: not cancellable - it is a plain file copy, seconds even for big sets.
fn split(gpa: Allocator, io: Io, whole: []const u8, out_path: []const u8, size: i64) !void {
    {
        var f = try Io.Dir.cwd().openFile(io, whole, .{ .mode = .read_write });
        defer f.close(io);
        const len = try f.length(io);
        const vol: u64 = @intCast(size);
        const count = @max(1, (len + vol - 1) / vol);
        var buf: [64 * 1024]u8 = undefined;
        var n = count;
        while (n > 1) : (n -= 1) {
            const p = try part(gpa, out_path, @intCast(n));
            defer gpa.free(p);
            var out = try Io.Dir.cwd().createFile(io, p, .{ .exclusive = true });
            defer out.close(io);
            var off = (n - 1) * vol;
            var at: u64 = 0;
            while (off < len) {
                const got = try f.readPositional(io, &.{buf[0..@intCast(@min(buf.len, len - off))]}, off);
                if (got == 0) break;
                try out.writePositionalAll(io, buf[0..got], at);
                off += got;
                at += got;
            }
            try f.setLength(io, (n - 1) * vol);
        }
    }
    const first = try part(gpa, out_path, 1);
    defer gpa.free(first);
    try move(whole, first, false);
}

/// Engine.Compress: one archive of `inputs` at `out_path` (volumes, SFX, test-after, delete-sources).
pub fn compress(gpa: Allocator, io: Io, inputs: []const []const u8, out_path: []const u8, k: ArchiveKind, o: CompressOptions, progress: Progress, diag: ?*Diag) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const info = kind(k);
    // A "<archive>.makepack~" backup (cli's `a -y` moves the old archive there) sits next to the archive, so packing
    // the archive's own folder would put the old archive into the new one: never packed.
    const backup = try std.mem.concat(ar, u8, &.{ try fullPath(ar, out_path), ".makepack~" });
    var entries = try buildDict(ar, io, inputs, "");
    var kept: usize = 0;
    for (entries) |e| {
        if (e.source) |s| if (startsWithI(s, backup)) continue;
        entries[kept] = e;
        kept += 1;
    }
    entries = entries[0..kept];
    if (entries.len == 0) return error.NoInputs;
    if (!info.multi and entries.len != 1) return error.SingleFileOnly;
    var input: i64 = 0;
    for (entries) |e| input += @intCast(e.size);
    const ram = installedRam();
    const fit = dictionaryFits(o, input, ram);
    if (!fit.fits) {
        var a: [32]u8 = undefined;
        var b: [32]u8 = undefined;
        var c: [32]u8 = undefined;
        Diag.set(diag, S.dictionaryTooBigFmt.get(), .{ niceSize(&a, o.dictionary), niceSize(&b, fit.need), niceSize(&c, ram) });
        return error.DictionaryTooBig;
    }
    if (o.volume_size < 0) {
        Diag.set(diag, "negative volume size", .{});
        return error.InvalidOption;
    }
    // ponytail: 7z only and no volumes - a split SFX needs a stub that reads .002..., 7z.sfx does not.
    if (o.sfx and (k != .SevenZip or o.volume_size > 0)) {
        Diag.set(diag, "SFX is 7z-only and single-file", .{});
        return error.InvalidOption;
    }
    if (o.zip_crypto and k != .Zip) {
        Diag.set(diag, "ZipCrypto is zip-only", .{});
        return error.InvalidOption;
    }
    if (o.delete_sources) for (inputs) |i| if (inside(out_path, i)) return error.ArchiveInsideSources; // recycling the folder would take the archive along
    const password = nonEmpty(o.password);
    const tarball = k == .TarGz or k == .TarBz2 or k == .TarXz;
    const plain: CompressOptions = .{ .level = o.level }; // tar.* has no method/solid/filter knobs
    // Checked before anything is written: a refused option leaves no file behind.
    const props = try applyProps(ar, info.format, if (tarball) plain else o, password != null, diag);
    if (fspath.dirname(out_path)) |d| try Io.Dir.cwd().createDirPath(io, d);

    var test_slice: Scaled = .{ .to = progress, .lo = 0, .hi = 80 };
    const work = if (o.test_after) test_slice.progress() else progress;
    // Volumes and SFX: write the whole archive, then cut it / glue the stub on.
    const target = if (o.volume_size > 0 or o.sfx) try std.mem.concat(ar, u8, &.{ out_path, ".makepack-tmp" }) else out_path;

    if (tarball) {
        const dir = try newTempDir(ar, io);
        defer {
            nuke(io, dir);
            forget(dir);
        }
        const tar = try joinName(ar, dir, baseName(out_path), ".tar");
        const tar_props = try applyProps(ar, .Tar, plain, false, diag);
        try pack(gpa, io, entries, tar, .Tar, tar_props, null, work, 0, 50, diag);
        const one = [_]Entry{.{ .name = fspath.basename(tar), .source = tar }};
        try pack(gpa, io, &one, target, info.format, props, null, work, 50, 100, diag);
    } else try pack(gpa, io, entries, target, info.format, props, password, work, 0, 100, diag);

    if (o.volume_size > 0) {
        // A stale .004 from an older, bigger set would join the new one. Deleted only now (C#: before packing), so a
        // failed or cancelled pack leaves the old set whole.
        deleteParts(io, out_path) catch |e| {
            tryDelete(io, target);
            return e;
        };
        split(ar, io, target, out_path, o.volume_size) catch |e| {
            tryDelete(io, target);
            deleteParts(io, out_path) catch {};
            return e;
        };
    }
    if (o.sfx) {
        defer tryDelete(io, target);
        // Glued into a side file first (C#: straight into out_path): a missing 7z.sfx must not cost an existing exe.
        const glued = try std.mem.concat(ar, u8, &.{ out_path, ".makepack-sfx" });
        glue(io, &.{ try sfxModule(ar), target }, glued, .none) catch |e| {
            tryDelete(io, glued);
            return e;
        };
        move(glued, out_path, true) catch |e| {
            tryDelete(io, glued);
            return e;
        };
    }

    // The archive is complete from here on: a failed or cancelled test leaves it, and never touches the sources.
    if (o.test_after) {
        const first = if (o.volume_size > 0) try part(ar, out_path, 1) else out_path;
        if (before_test_hook) |h| h(first);
        const a = try open(gpa, io, first, password, progress, diag);
        defer a.close();
        var slice: Scaled = .{ .to = progress, .lo = 80, .hi = 100 };
        const ok = try testArchive(gpa, io, a, slice.progress(), diag);
        if (progress.cancelled()) return error.Canceled;
        if (!ok) return error.TestAfterFailed;
    }
    if (progress.cancelled()) return error.Canceled;
    if (o.delete_sources) try recycle(gpa, inputs, true, diag);
    progress.send(100, "");
}

/// Engine.CompressEach: the plan under one progress bar; cancel keeps the archives already made.
pub fn compressEach(gpa: Allocator, io: Io, plan: []const Planned, k: ArchiveKind, o: CompressOptions, progress: Progress, diag: ?*Diag) anyerror!void {
    for (plan, 0..) |p, i| {
        if (progress.cancelled()) return error.Canceled;
        var slice: Scaled = .{ .to = progress, .lo = @intCast(i * 100 / plan.len), .hi = @intCast((i + 1) * 100 / plan.len) };
        try compress(gpa, io, &.{p.input}, p.output, k, o, slice.progress(), diag);
    }
}

// ---- convert ------------------------------------------------------------------------------------------

/// Files (not folders) and their unpacked bytes, as the archive itself lists them.
fn stats(a: *const Archive) struct { files: usize, bytes: u64 } {
    var n: usize = 0;
    var b: u64 = 0;
    for (a.x.items) |it| if (!it.is_dir) {
        n += 1;
        b += it.size;
    };
    return .{ .files = n, .bytes = b };
}

/// Engine.Convert: repack `source` as `target` in `k`: unpack to a temp folder, pack into a hidden file next to the
/// target, keep it only if it tests clean and holds as many files and bytes as the original. True = converted;
/// false = kept the original because the new one was not smaller. Any failure or cancel removes the new file and
/// leaves the original alone. `target` == `source` replaces the original (callers allow that only with
/// `delete_original`).
// ponytail: no volumes or SFX here - the converted archive is always one plain file.
pub fn convert(
    gpa: Allocator,
    io: Io,
    source: []const u8,
    password: ?[]const u8,
    target: []const u8,
    k: ArchiveKind,
    level: CompressionLevel,
    keep_if_not_smaller: bool,
    delete_original: bool,
    progress: Progress,
    diag: ?*Diag,
) anyerror!bool {
    const pw = nonEmpty(password);
    // The original's password goes on, so an encrypted archive never comes out readable by anyone.
    if (pw != null and !kind(k).password) {
        Diag.set(diag, S.convertWouldDecryptFmt.get(), .{kind(k).name});
        return error.ConvertWouldDecrypt;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    const o: CompressOptions = .{ .level = level, .password = pw, .encrypt_headers = pw != null and k == .SevenZip };
    const work = try newTempDir(ar, io);
    defer {
        nuke(io, work);
        forget(work);
    }
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const full_target = try fullPath(ar, target);
    const hidden = try ar.print("{s}\\.makepack-{x}-{s}", .{ fspath.dirname(full_target) orelse ".", &rnd, fspath.basename(full_target) });
    errdefer tryDelete(io, hidden);

    var before: @TypeOf(stats(undefined)) = undefined;
    {
        const a = try open(gpa, io, source, pw, progress, diag);
        defer a.close();
        before = stats(a);
        var s: Scaled = .{ .to = progress, .lo = 0, .hi = 45 };
        try extract(gpa, io, a, work, null, .Overwrite, s.progress(), .always_overwrite, .Never, .{}, diag);
    }
    var inputs: std.ArrayList([]const u8) = .empty;
    {
        var h = try Io.Dir.cwd().openDir(io, work, .{ .iterate = true });
        defer h.close(io);
        var it = h.iterate();
        while (try it.next(io)) |e| try inputs.append(ar, try joinName(ar, work, e.name, ""));
    }
    var s2: Scaled = .{ .to = progress, .lo = 45, .hi = 90 };
    try compress(gpa, io, inputs.items, hidden, k, o, s2.progress(), diag);

    if (before_test_hook) |h| h(hidden);
    verify(gpa, io, hidden, pw, before, progress) catch |e| {
        if (e == error.Canceled) return e;
        if (diag) |d| d.len = 0;
        return error.ConvertMismatch; // would not even open: same verdict, one message
    };
    if (keep_if_not_smaller and (fileSize(io, hidden) catch 0) >= sizeOnDisk(ar, io, source)) {
        tryDelete(io, hidden);
        return false;
    }
    const zone = zoneOf(ar, io, source); // a downloaded archive's "from the Internet" mark stays on its copy
    // The new archive goes in place first, the original to the bin after (C# did it the other way round: a failed
    // move then deleted the finished copy and left the original only in the Recycle Bin).
    try move(hidden, target, true);
    if (zone) |z| writeSmall(try std.mem.concat(ar, u8, &.{ target, ":Zone.Identifier" }), z) catch {}; // no streams here
    if (delete_original and !samePath(source, target)) try recycleArchive(gpa, io, source, diag);
    progress.send(100, "");
    return true;
}

fn verify(gpa: Allocator, io: Io, path: []const u8, pw: ?[]const u8, before: @TypeOf(stats(undefined)), progress: Progress) !void {
    const b = try open(gpa, io, path, pw, progress, null);
    defer b.close();
    var s: Scaled = .{ .to = progress, .lo = 90, .hi = 100 };
    const ok = try testArchive(gpa, io, b, s.progress(), null);
    if (progress.cancelled()) return error.Canceled;
    const after = stats(b);
    if (!ok or after.files != before.files or after.bytes != before.bytes) return error.ConvertMismatch;
}

// ---- edit in place (each closes `a`: reopen afterwards) ----------------------------------------------------

fn outFormat(f: sevenzip.Format) OutFormat {
    return switch (f) {
        .Zip => .Zip,
        .Tar => .Tar,
        .Wim => .Wim,
        else => .SevenZip,
    };
}

/// Engine.Edit: writes `changes` (the archive's complete new item list) over the archive file. Delete / Rename /
/// Append close `a` in every case (C# disposed it) and pass its facts here. The archive is reopened from disk with
/// the password (a wrong one fails here, before anything is written) and the new archive goes to a side file; the
/// old bytes stay reachable as "<archive>.makepack~" (a hard link, a copy where links are not supported) until the
/// new one is in place, and are put back on any failure or cancel.
fn editPath(gpa: Allocator, io: Io, path: []const u8, password: ?[]const u8, format: OutFormat, changes: []const sevenzip.Change, props: []const sevenzip.Prop, progress: Progress, diag: ?*Diag) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var x: ?*sevenzip.InArchive = try openX(gpa, path, password, path, progress, diag);
    defer if (x) |p| p.close();
    const keep = try std.mem.concat(ar, u8, &.{ path, ".makepack~" });
    const fresh = try std.mem.concat(ar, u8, &.{ path, ".makepack-new" });
    tryDelete(io, keep);
    tryDelete(io, fresh);
    hardLink(keep, path) catch try Io.Dir.cwd().copyFile(path, Io.Dir.cwd(), keep, io, .{});
    errdefer {
        if (x) |p| p.close();
        x = null;
        tryDelete(io, fresh);
        move(keep, path, true) catch {};
    }
    var ticker: Ticker = .{ .to = progress };
    sevenzip.update(x.?, fresh, changes, .{ .format = format, .props = props, .progress = ticker.sz() }) catch |e| {
        if (progress.cancelled()) return error.Canceled;
        return writeErr(e, diag);
    };
    if (progress.cancelled()) return error.Canceled;
    x.?.close();
    x = null;
    const zone = zoneOf(ar, io, path); // the new file has none of the old one's streams: carry the download mark
    try move(fresh, path, true);
    if (zone) |z| writeSmall(try std.mem.concat(ar, u8, &.{ path, ":Zone.Identifier" }), z) catch {};
    tryDelete(io, keep);
    progress.send(100, "");
}

/// What edit needs from `a`, copied out (the caller closes `a`).
const Facts = struct { path: []u8, password: ?[]u8, format: OutFormat };

fn facts(ar: Allocator, io: Io, a: *Archive) !Facts {
    if (!canDelete(io, a)) return error.NotSupported;
    return .{
        .path = try ar.dupe(u8, a.open_path),
        .password = if (a.password) |p| try ar.dupe(u8, p) else null,
        .format = outFormat(a.x.props.format),
    };
}

/// Engine.Delete
pub fn delete(gpa: Allocator, io: Io, a: *Archive, indices: []const u32, diag: ?*Diag) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var changes: std.ArrayList(sevenzip.Change) = .empty;
    const f = blk: {
        defer a.close();
        for (a.x.items) |it| if (std.mem.findScalar(u32, indices, it.index) == null) try changes.append(ar, .{ .keep = it.index });
        break :blk try facts(ar, io, a);
    };
    try editPath(gpa, io, f.path, f.password, f.format, changes.items, &.{}, .none, diag);
}

/// Engine.Rename: entry `from` ("dir/name", as norm gives it) and, for a folder, everything under it.
pub fn rename(gpa: Allocator, io: Io, a: *Archive, from: []const u8, to: []const u8, diag: ?*Diag) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var changes: std.ArrayList(sevenzip.Change) = .empty;
    const f = blk: {
        defer a.close();
        for (a.x.items) |it| {
            const n = try norm(ar, it.path);
            if (eqlI(n, from) or (n.len > from.len and n[from.len] == '/' and eqlI(n[0..from.len], from))) {
                const name = try std.mem.concat(ar, u8, &.{ to, n[from.len..] });
                std.mem.replaceScalar(u8, name, '/', '\\');
                try changes.append(ar, .{ .rename = .{ .index = it.index, .name = name } });
            } else try changes.append(ar, .{ .keep = it.index });
        }
        break :blk try facts(ar, io, a);
    };
    try editPath(gpa, io, f.path, f.password, f.format, changes.items, &.{}, .none, diag);
}

/// Engine.Append: adds files and folders under `prefix` ("" or "dir/sub/"); a name already there goes to
/// `on_conflict` (Overwrite replaces, Skip keeps the old one, null cancels before anything is written).
/// `o.password` / `o.encrypt_headers` are ignored: the archive keeps its own (7z.dll keeps header encryption).
pub fn append(gpa: Allocator, io: Io, a: *Archive, inputs: []const []const u8, prefix: []const u8, o: CompressOptions, progress: Progress, on_conflict: Conflict, diag: ?*Diag) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const ar = arena.allocator();
    var changes: std.ArrayList(sevenzip.Change) = .empty;
    const f = blk: {
        defer a.close();
        const f = try facts(ar, io, a);
        // name -> item, the first of duplicates (TryAdd)
        var existing: std.StringHashMapUnmanaged(*const sevenzip.Item) = .empty;
        for (a.x.items) |*it| {
            const g = try existing.getOrPut(ar, try upper(ar, try norm(ar, it.path)));
            if (!g.found_existing) g.value_ptr.* = it;
        }
        const pre = try ar.dupe(u8, prefix);
        std.mem.replaceScalar(u8, pre, '/', '\\');
        const dict = try buildDict(ar, io, inputs, pre);
        if (dict.len == 0) return error.NoInputs;
        var drop = try ar.alloc(bool, a.x.items.len);
        @memset(drop, false);
        var adds: std.ArrayList(sevenzip.Change) = .empty;
        for (dict) |e| {
            const n = try norm(ar, e.name);
            const old = existing.get(try upper(ar, n)) orelse {
                try adds.append(ar, .{ .add = .{ .name = e.name, .source = e.source, .folder = e.folder } });
                continue;
            };
            if (old.is_dir and e.source == null) continue; // the folder is there already
            switch (on_conflict.ask(on_conflict.ctx, n) orelse return error.Canceled) {
                .Overwrite => {
                    drop[old.index] = true;
                    try adds.append(ar, .{ .add = .{ .name = e.name, .source = e.source, .folder = e.folder } });
                },
                .Skip => {},
                else => return error.Canceled,
            }
        }
        for (a.x.items) |it| if (!drop[it.index]) try changes.append(ar, .{ .keep = it.index });
        if (adds.items.len == 0 and changes.items.len == a.x.items.len) return; // nothing to write
        try changes.appendSlice(ar, adds.items);
        break :blk f;
    };
    var plain = o;
    plain.password = null;
    plain.encrypt_headers = false;
    plain.zip_crypto = false;
    const props = try applyProps(ar, f.format, plain, false, diag);
    try editPath(gpa, io, f.path, f.password, f.format, changes.items, props, progress, diag);
}

// ---- recycle bin and Mark of the Web -----------------------------------------------------------------

/// Engine.Recycle: to the Recycle Bin in one shell call (FOF_WANTNUKEWARNING where there is no bin);
/// `undo` false = Shift+Del, gone for good.
pub fn recycle(gpa: Allocator, paths: []const []const u8, undo: bool, diag: ?*Diag) anyerror!void {
    var list: std.ArrayList(u16) = .empty; // double-NUL-terminated list
    defer list.deinit(gpa);
    for (paths) |p| {
        const full = try fullPath(gpa, std.mem.trimEnd(u8, p, "\\/"));
        defer gpa.free(full);
        if (!kit.win.exists(full)) continue;
        const wp = try kit.win.toW(gpa, full);
        defer gpa.free(wp);
        try list.appendSlice(gpa, wp[0 .. wp.len + 1]);
    }
    if (list.items.len == 0) return;
    try list.append(gpa, 0);
    const base: c_int = w.FOF_SILENT | w.FOF_NOCONFIRMATION | w.FOF_NOERRORUI;
    var op: w.SHFILEOPSTRUCTW = std.mem.zeroes(w.SHFILEOPSTRUCTW);
    op.wFunc = w.FO_DELETE;
    op.pFrom = list.items.ptr;
    op.fFlags = @intCast(base | (if (undo) w.FOF_ALLOWUNDO | w.FOF_WANTNUKEWARNING else 0));
    const rc = w.SHFileOperationW(&op);
    if (rc != 0 or op.fAnyOperationsAborted != 0) {
        Diag.set(diag, S.recycleFailedFmt.get(), .{rc});
        return error.RecycleFailed;
    }
}

/// Engine.RecycleArchive: the archive (every part of a .001 set) after a clean extraction; close it first.
pub fn recycleArchive(gpa: Allocator, io: Io, source: []const u8, diag: ?*Diag) anyerror!void {
    _ = io;
    if (!isFirstPart(source)) return recycle(gpa, &.{source}, true, diag);
    const parts = try partsOf(gpa, source);
    defer kit.win.freeList(gpa, parts);
    try recycle(gpa, @ptrCast(parts), true, diag);
}

/// Files that can run code, or open into something that can (archives, disk images): list, roughly.
const risky = [_][]const u8{
    "exe",  "com",  "scr",  "pif",  "cpl",  "msi",  "msp",  "msix", "appx", "appxbundle", "dll",  "ocx",  "sys",  "drv",
    "bat",  "cmd",  "ps1",  "psm1", "psd1", "vbs",  "vbe",  "js",   "jse",  "wsf",        "wsh",  "hta",  "lnk",  "url",
    "scf",  "reg",  "inf",  "jar",  "chm",  "iso",  "img",  "vhd",  "vhdx", "doc",        "docx", "docm", "dot",  "dotx",
    "dotm", "rtf",  "xls",  "xlsx", "xlsm", "xlsb", "xlt",  "xltx", "xltm", "xla",        "xlam", "ppt",  "pptx", "pptm",
    "pps",  "ppsx", "ppsm", "pot",  "potx", "potm", "ppam", "one",  "pub",  "vsd",        "vsdx", "vsdm", "pdf",
};

/// Engine.ZoneOf: the archive's Zone.Identifier stream, null when it has none.
pub fn zoneOf(gpa: Allocator, io: Io, archive: []const u8) ?[]u8 {
    _ = io;
    const p = std.mem.concat(scratch, u8, &.{ archive, ":Zone.Identifier" }) catch return null;
    defer scratch.free(p);
    const z = readSmall(gpa, p) orelse return null;
    if (!std.mem.startsWith(u8, z, "\xEF\xBB\xBF")) return z; // File.ReadAllText drops a BOM
    std.mem.copyForwards(u8, z, z[3..]);
    return gpa.realloc(z, z.len - 3) catch z[0 .. z.len - 3];
}

/// Engine.Marks: does `policy` pass the mark on to `file` (Risky = programs, scripts, Office, archives)?
pub fn marks(policy: MotwPolicy, file: []const u8) bool {
    return switch (policy) {
        .All => true,
        .Risky => blk: {
            const e = extOf(file);
            for (risky) |r| if (std.ascii.eqlIgnoreCase(r, e)) break :blk true;
            break :blk types.isArchiveExt(e);
        },
        .Never => false,
    };
}

fn mark(io: Io, files: []const []const u8, zone: []const u8, policy: MotwPolicy) void {
    _ = io;
    for (files) |f| if (marks(policy, f) and fileExists(f)) {
        const p = std.mem.concat(scratch, u8, &.{ f, ":Zone.Identifier" }) catch continue;
        defer scratch.free(p);
        writeSmall(p, zone) catch {}; // FAT32 / exFAT have no streams
    };
}

// ---- tests ------------------------------------------------------------------------------------------

const testing = std.testing;

test "exit codes and messages (the error contract)" {
    const saved = S.uk;
    defer S.uk = saved;
    S.uk = false;
    try testing.expectEqual(@as(u8, 255), exitCodeOf(error.Canceled));
    try testing.expectEqual(@as(u8, 1), exitCodeOf(error.UnsafeEntriesSkipped));
    try testing.expectEqual(@as(u8, 11), exitCodeOf(error.PasswordNeeded));
    try testing.expectEqual(@as(u8, 3), exitCodeOf(error.Damaged));
    try testing.expectEqual(@as(u8, 7), exitCodeOf(error.PasswordInArgs));
    try testing.expectEqual(@as(u8, 10), exitCodeOf(error.NoInputs));
    try testing.expectEqual(@as(u8, 2), exitCodeOf(error.NotAnArchive));
    try testing.expectEqual(@as(u8, 2), exitCodeOf(error.AccessDenied)); // std errors: fatal
    try testing.expectEqualStrings("The file is damaged.", friendly(error.Damaged, null));
    var d: Diag = .{};
    try testing.expect(d.text() == null);
    Diag.set(&d, S.unsafeSkippedFmt.get(), .{3});
    try testing.expectEqualStrings("3 entries with unsafe paths were skipped (path traversal attempt).", friendly(error.UnsafeEntriesSkipped, &d));
    Diag.set(null, "ignored", .{});
    try testing.expectEqual(OverwriteMode.Overwrite, Conflict.always_overwrite.ask(null, "x").?);
    try testing.expect(!Progress.none.cancelled());
    // std's file errors read as Windows' own words (localised), never as a Zig error name.
    for ([_]anyerror{ error.AccessDenied, error.FileBusy, error.NoSpaceLeft, error.PathAlreadyExists, error.FileNotFound }) |e| {
        const m = friendly(e, null);
        try testing.expect(m.len > 0 and std.mem.find(u8, m, @errorName(e)) == null);
    }
    try testing.expect(winErr(1392) == error.Unexpected); // ERROR_FILE_CORRUPT: the code is kept for the message
    try testing.expect(std.mem.find(u8, friendly(error.Unexpected, null), "Unexpected") == null);
    try testing.expect(std.mem.startsWith(u8, friendly(error.NoSuchThing, null), S.operationFailed.get()));
}

test "OrdinalIgnoreCase folding, cut names, long paths" {
    const gpa = testing.allocator;
    const a = try upper(gpa, "Файл ïé.txt");
    defer gpa.free(a);
    const b = try upper(gpa, "файл ÏÉ.TXT");
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
    var t: Ticker = .{ .to = .none };
    var long: [601]u8 = undefined;
    long[0] = 'a';
    for (0..300) |i| @memcpy(long[1 + 2 * i ..][0..2], "ж");
    t.setCurrent(&long); // byte 512 would be half of a letter
    try testing.expect(t.name_len == 511 and std.unicode.utf8ValidateSlice(t.current()));
    t.setCurrent(long[1..]);
    try testing.expect(t.name_len == 512);
    // wide(): \\?\ only past 247 units, and then absolute
    const short = try wide("C:\\x\\y.txt");
    defer scratch.free(short);
    try testing.expect(short[0] == 'C');
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(gpa);
    try deep.appendSlice(gpa, "C:\\a");
    for (0..60) |_| try deep.appendSlice(gpa, "\\dir/.");
    const lw = try wide(deep.items);
    defer scratch.free(lw);
    try testing.expect(std.mem.startsWith(u16, lw, std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\a\\dir\\dir")) and std.mem.findScalar(u16, lw, '/') == null);
    var h: Io.Writer.Allocating = .init(gpa);
    defer h.deinit();
    try html(&h.writer, "<b>\xFF&");
    try testing.expectEqualStrings("&#60;b&#62;\xFF&#38;", h.written());
}

test "names, sizes and parsers" {
    const gpa = testing.allocator;
    try testing.expectEqualStrings("x", baseName("C:\\a\\x.tar.gz"));
    try testing.expectEqualStrings("x", baseName("x.ZIP"));
    try testing.expectEqualStrings("a.b", baseName("a.b.7z"));
    const p = try part(gpa, "a.7z", 2);
    defer gpa.free(p);
    try testing.expectEqualStrings("a.7z.002", p);
    for ([_][2][]const u8{ .{ "./a\\b/", "a/b" }, .{ "././x", "x" }, .{ ".", "" }, .{ "dir\\", "dir" } }) |c| {
        const n = try norm(gpa, c[0]);
        defer gpa.free(n);
        try testing.expectEqualStrings(c[1], n);
    }
    const saved = S.decimal_sep;
    defer S.decimal_sep = saved;
    S.decimal_sep = ",";
    var b: [32]u8 = undefined;
    try testing.expectEqualStrings("512 B", niceSize(&b, 512));
    try testing.expectEqualStrings("1,5 KB", niceSize(&b, 1536));
    try testing.expectEqualStrings("64 KB", niceSize(&b, 64 << 10));
    try testing.expectEqualStrings("2,25 GB", niceSize(&b, (9 << 30) / 4));
    try testing.expectEqualStrings("64k", size7z(&b, 64 << 10));
    try testing.expectEqualStrings("3m", size7z(&b, 3 << 20));
    try testing.expectEqualStrings("1000b", size7z(&b, 1000));
    try testing.expectEqual(@as(?i64, 1 << 24), dictionaryOf("PPMD:o6:mem24"));
    try testing.expectEqual(@as(?i64, 1536 << 20), dictionaryOf("LZMA:1536m"));
    try testing.expectEqual(@as(?i64, 1 << 20), dictionaryOf("BCJ2 LZMA2:20 LZMA:20:lc0:lp2"));
    try testing.expectEqual(@as(?i64, null), dictionaryOf("Deflate"));
    try testing.expect(rar4Encrypted(&.{ 0, 0, 0x73, 0x80, 0x00, 0x0D, 0x00 }));
    try testing.expect(!rar4Encrypted(&.{ 0, 0, 0x73, 0x00, 0x00, 0x0D, 0x00 }));
    try testing.expect(!rar4Encrypted(&.{ 0, 0, 0x74, 0x80, 0x00, 0x0D, 0x00 }));
    try testing.expect(rar5Encrypted(&.{ 0, 0, 0, 0, 0x0A, 0x04 }));
    try testing.expect(rar5Encrypted(&.{ 0, 0, 0, 0, 0x80, 0x01, 0x04 }));
    try testing.expect(!rar5Encrypted(&.{ 0, 0, 0, 0, 0x0A, 0x01 }));
    try testing.expect(marks(.Risky, "a.EXE") and marks(.Risky, "d.zip") and !marks(.Risky, "c.txt") and marks(.All, "c.txt") and !marks(.Never, "a.exe"));
    try testing.expect(escapes("C:\\d\\", "../x") and escapes("C:\\d\\", "a\\..\\..\\x") and escapes("C:\\d\\", "\\x") and escapes("C:\\d\\", "C:x"));
    try testing.expect(escapes("C:\\d\\", "...\\x") and !escapes("C:\\d\\", "./a/b") and !escapes("C:\\d\\", "a..b/c"));
    const G: i64 = 1 << 30;
    const big = dictionaryFits(.{ .dictionary = G }, 10 * G, 8 * G);
    try testing.expect(!big.fits and big.need > 8 * G);
    try testing.expect(dictionaryFits(.{ .dictionary = G }, 1 << 20, 8 * G).fits);
    try testing.expect(dictionaryFits(.{}, 100 * G, 1).fits);
}

test "contract compiles" {
    @import("../testutil.zig").refAllDeep(@This(), 2);
}
